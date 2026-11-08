import AppKit

// MARK: - Anchors and New Space… (docs/spaces.md, "Spaces and anchors")

extension NiruxShellView {
    /// What a picked folder gives.
    enum AnchorPick: Equatable, Sendable {
        case anchor(SpaceAnchor)
        /// "Add Repository…" on a folder in no repository.
        case notARepository(String)
        case missing(String)
    }

    /// How long git may take to name a folder the user picked.
    nonisolated static let anchorPickTimeout: TimeInterval = 5

    /// Names the repository holding `folder` (`asRepository`), or the folder
    /// itself, off the main thread.
    nonisolated static func pickAnchor(
        _ folder: String, asRepository: Bool,
        completion: @escaping @MainActor @Sendable (AnchorPick) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let pick: AnchorPick
            if !asRepository {
                if let path = folder.realPath, NiruxURLRequest.directoryExists(path) {
                    pick = .anchor(.folder(path))
                } else {
                    pick = .missing(folder)
                }
            } else if let identity = FolderIdentity.identify(folder, timeout: anchorPickTimeout) {
                if let commonDir = identity.commonDir {
                    pick = .anchor(.repository(commonDir: commonDir, topLevel: identity.topLevel))
                } else {
                    pick = .notARepository(identity.path)
                }
            } else {
                pick = .missing(folder)
            }
            DispatchQueue.main.async { @MainActor in completion(pick) }
        }
    }

    /// A repository or folder another space has: asks before taking it.
    /// True when it is free, or the user agreed.
    func confirmTakingAnchor(_ anchor: SpaceAnchor, intoSpaceNamed name: String, excluding spaceID: String?) -> Bool {
        guard let key = anchor.key, let owner = workspaceStore.profile(anchoring: key), owner.id != spaceID else { return true }
        let alert = NSAlert()
        alert.messageText = "“\(anchor.name)” belongs to “\(owner.name)”"
        alert.informativeText = "A repository or folder belongs to one space. Move it to “\(name)”? "
            + "Workspaces already open stay where they are."
        alert.addButton(withTitle: "Move to “\(name)”")
        alert.addButton(withTitle: "Cancel")
        return runModal(alert) == .alertFirstButtonReturn
    }

    // MARK: Space menu

    /// "Add Repository…": picks a folder, anchors its repository to the
    /// space (or the folder, when it is in none and the user agrees), then
    /// offers to move that repository's workspaces in.
    func addRepository(toSpace spaceID: String) {
        guard spaceID != WorkspaceProfile.defaultID, profiles.contains(where: { $0.id == spaceID }) else { return }
        sideEffects.chooseFolder("Add Repository", window) { [weak self] folder in
            guard let folder else { return }
            Self.pickAnchor(folder, asRepository: true) { [weak self] pick in
                self?.finishAddingRepository(pick, toSpace: spaceID)
            }
        }
    }

    private func finishAddingRepository(_ pick: AnchorPick, toSpace spaceID: String) {
        guard let space = profiles.first(where: { $0.id == spaceID }) else { return }
        switch pick {
        case .missing(let folder):
            showToast("That folder is gone: \(folder.abbreviatedPath())", tone: .error)
        case .notARepository(let folder):
            let alert = NSAlert()
            alert.messageText = "“\((folder as NSString).lastPathComponent)” isn’t in a git repository"
            alert.informativeText = "Add it to “\(space.name)” as a folder? Workspaces opened in it or below join the space."
            alert.addButton(withTitle: "Add Folder")
            alert.addButton(withTitle: "Cancel")
            guard runModal(alert) == .alertFirstButtonReturn else { return }
            addAnchor(.folder(folder), toSpace: spaceID)
        case .anchor(let anchor):
            addAnchor(anchor, toSpace: spaceID)
        }
    }

    /// Anchors it to the space, after asking when another space has it,
    /// moves `workspaceID` there, then offers the others of that
    /// repository or folder.
    func addAnchor(_ anchor: SpaceAnchor, toSpace spaceID: String, moving workspaceID: String? = nil) {
        guard let space = profiles.first(where: { $0.id == spaceID }),
              confirmTakingAnchor(anchor, intoSpaceNamed: space.name, excluding: spaceID),
              workspaceStore.addAnchor(anchor, toProfile: spaceID)
        else { return }
        if let workspaceID { moveWorkspaceToSpace(workspaceID: workspaceID, profileID: spaceID) }
        updateSidebar()
        saveState()
        offerToMoveWorkspaces(into: spaceID) {}
    }

    func removeSpaceAnchor(key: String, fromSpace spaceID: String) {
        guard workspaceStore.removeAnchor(key: key, fromProfile: spaceID) else { return }
        updateSidebar()
        saveState()
    }

    func makeDefaultSpaceAnchor(key: String, inSpace spaceID: String) {
        guard workspaceStore.makeDefaultAnchor(key: key, inProfile: spaceID) else { return }
        updateSidebar()
        saveState()
    }

    /// The banner's "Anchor to…": the repository holding the workspace's
    /// folder (or the folder) joins the space, and so does the workspace.
    func anchorWorkspaceFolder(workspaceID: String, toSpace spaceID: String) {
        guard let workspace = workspaces.first(where: { $0.id == workspaceID && !$0.isClosing }) else { return }
        Self.identifyOffMain(workspace.cwd, timeout: Self.anchorPickTimeout) { [weak self] identity in
            guard let self else { return }
            guard let identity else { return self.showToast("That folder is gone", tone: .error) }
            self.addAnchor(identity.anchor, toSpace: spaceID, moving: workspaceID)
        }
    }

    // MARK: Moving workspaces in

    /// Offers to move the open workspaces whose folder (or focused
    /// terminal's folder) now routes to the space, those in the default
    /// space checked. `then` runs once the user answered, or at once when
    /// there is nothing to offer.
    func offerToMoveWorkspaces(into spaceID: String, then: @escaping @MainActor @Sendable () -> Void) {
        let candidates = workspaces.filter { !$0.isClosing && $0.profileID != spaceID }
            .map { (id: $0.id, folders: Array(Set([$0.cwd, $0.focusedWorkingDirectory]))) }
        guard !candidates.isEmpty else { return then() }
        let folders = Array(Set(candidates.flatMap(\.folders)))
        Self.identifyAllOffMain(folders) { [weak self] identities in
            guard let self else { return }
            let spaces = self.workspaceStore.profiles
            let matching = candidates.filter { candidate in
                candidate.folders.contains { folder in
                    identities[folder].map { SpaceRouting.anchoringSpace(of: $0, in: spaces) == spaceID } ?? false
                }
            }.compactMap { candidate in
                self.workspaces.first { $0.id == candidate.id && !$0.isClosing && $0.profileID != spaceID }
            }
            if !matching.isEmpty { self.askToMove(matching, into: spaceID) }
            then()
        }
    }

    private func askToMove(_ matching: [WorkspaceState], into spaceID: String) {
        guard let space = profiles.first(where: { $0.id == spaceID }) else { return }
        let alert = NSAlert()
        alert.messageText = "Move workspaces to “\(space.name)”?"
        alert.informativeText = matching.count == 1
            ? "This workspace is in one of its repositories or folders."
            : "These workspaces are in its repositories or folders."
        let boxes = matching.map { workspace -> NSButton in
            let from = profiles.first { $0.id == workspace.profileID }?.name ?? ""
            let box = NSButton(checkboxWithTitle: "\(workspace.title) — in “\(from)”", target: nil, action: nil)
            box.state = workspace.profileID == WorkspaceProfile.defaultID ? .on : .off
            box.lineBreakMode = .byTruncatingMiddle
            return box
        }
        let stack = NSStackView(views: boxes)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.frame = NSRect(x: 0, y: 0, width: 360, height: CGFloat(boxes.count) * 24)
        alert.accessoryView = stack
        alert.addButton(withTitle: "Move")
        alert.addButton(withTitle: "Don’t Move")
        guard runModal(alert) == .alertFirstButtonReturn else { return }
        for (workspace, box) in zip(matching, boxes) where box.state == .on {
            moveWorkspaceToSpace(workspaceID: workspace.id, profileID: spaceID)
        }
    }

    /// Each folder's identity, off the main thread; a folder that is gone
    /// is left out.
    nonisolated static func identifyAllOffMain(
        _ folders: [String],
        completion: @escaping @MainActor @Sendable ([String: FolderIdentity]) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            var identities: [String: FolderIdentity] = [:]
            for folder in folders {
                identities[folder] = FolderIdentity.identify(folder, timeout: 2)
            }
            DispatchQueue.main.async { @MainActor in completion(identities) }
        }
    }

    // MARK: New Space…

    /// The New Space… sheet, the focused terminal's repository already in
    /// it unless another space has it. `workspaceID` (the banner's "New
    /// Space…") suggests that workspace's folder instead.
    func showNewSpacePanel(suggestingFolderOf workspaceID: String? = nil) {
        guard let window else { return }
        if let open = newSpacePanel?.panel {
            open.makeKeyAndOrderFront(nil)
            return
        }
        let source = workspaceID.flatMap { id in workspaces.first { $0.id == id } }
        let folder = source?.cwd ?? activeWorkspace?.focusedWorkingDirectory
        let panel = NewSpacePanel()
        newSpacePanel = panel
        panel.onAddRepository = { [weak self, weak panel] in
            guard let panel else { return }
            self?.pickAnchorForNewSpace(asRepository: true, panel: panel)
        }
        panel.onAddFolder = { [weak self, weak panel] in
            guard let panel else { return }
            self?.pickAnchorForNewSpace(asRepository: false, panel: panel)
        }
        panel.onCreate = { [weak self] draft in self?.createSpace(draft) }
        panel.onDismiss = { [weak self, weak panel] in
            guard let self else { return }
            if self.newSpacePanel === panel { self.newSpacePanel = nil }
            self.focusActiveTerminal(in: self.window)
        }
        let colorHex = workspaceStore.unusedColorHex()
        guard let folder else { return panel.show(attachedTo: window, colorHex: colorHex, suggestion: nil) }
        Self.identifyOffMain(folder, timeout: 1) { [weak self, weak panel] identity in
            guard let self, let panel, self.newSpacePanel === panel, let window = self.window else { return }
            var suggestion: SpaceAnchor?
            if let identity, identity.commonDir != nil,
               identity.anchor.key.flatMap(self.workspaceStore.profile(anchoring:)) == nil {
                suggestion = identity.anchor
            }
            panel.show(attachedTo: window, colorHex: colorHex, suggestion: suggestion)
        }
    }

    private func pickAnchorForNewSpace(asRepository: Bool, panel: NewSpacePanel) {
        sideEffects.chooseFolder(asRepository ? "Add Repository" : "Add Folder", panel.panel) { [weak self, weak panel] folder in
            guard let folder else { return }
            Self.pickAnchor(folder, asRepository: asRepository) { [weak self, weak panel] pick in
                guard let self, let panel, panel.panel != nil else { return }
                switch pick {
                case .missing(let folder):
                    panel.showError("That folder is gone: \(folder.abbreviatedPath())")
                case .notARepository(let folder):
                    panel.showError("\(folder.abbreviatedPath()) isn’t in a git repository. Add Folder… adds a plain folder.")
                case .anchor(let anchor):
                    let typed = panel.nameField.stringValue.trimmingCharacters(in: .whitespaces)
                    let owner = anchor.key.flatMap(self.workspaceStore.profile(anchoring:))
                    guard self.confirmTakingAnchor(anchor, intoSpaceNamed: typed.isEmpty ? "the new space" : typed, excluding: nil)
                    else { return }
                    panel.add(anchor, movingFrom: owner?.name)
                }
            }
        }
    }

    /// Creates the space (or fills an empty one of that name that has no
    /// repository), offers to move its repositories' workspaces in, then
    /// shows it, opening a workspace in its default folder when it is
    /// empty.
    func createSpace(_ draft: NewSpacePanel.Draft) {
        let spaceID: String
        if let empty = profiles.first(where: { space in
            space.id != WorkspaceProfile.defaultID && space.name == draft.name && space.anchors.isEmpty
                && workspaceStore.visibleWorkspaceIndices(in: space.id).isEmpty
        }) {
            spaceID = empty.id
            workspaceStore.setProfileColor(id: spaceID, colorHex: draft.colorHex)
            workspaceStore.setAnchors(draft.anchors, forProfile: spaceID)
        } else {
            spaceID = workspaceStore.createProfile(
                named: draft.name, colorHex: draft.colorHex, anchors: draft.anchors, select: false
            ).id
        }
        updateSidebar()
        saveState()
        let finish: @MainActor @Sendable () -> Void = { [weak self] in
            guard let self, self.profiles.contains(where: { $0.id == spaceID }) else { return }
            self.selectProfile(spaceID)
            self.updateSidebar()
            self.saveState()
        }
        guard !draft.anchors.isEmpty else { return finish() }
        offerToMoveWorkspaces(into: spaceID, then: finish)
    }
}
