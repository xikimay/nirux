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

    /// Runs `body`, which may show an app-modal alert, from the main run
    /// loop rather than from the main-queue block that calls this: the main
    /// queue runs no other block until such an alert is answered (see
    /// SessionResume).
    func runFromRunLoop(_ body: @escaping @MainActor @Sendable () -> Void) {
        // On the main thread, which Swift 6.1 doesn't infer for this block.
        RunLoop.main.perform(inModes: [.default]) {
            MainActor.assumeIsolated { body() }
        }
    }

    /// The home folder or a folder holding it: as a space's folder it would
    /// take in every folder under the home folder.
    func isTooBroadForAFolderAnchor(_ path: String) -> Bool {
        let homes = [sideEffects.homeDirectory(), NSHomeDirectory()].map { $0.realPath ?? $0 }
        return homes.contains { SpaceRouting.contains(path, $0) }
    }

    func tooBroadFolderMessage(_ path: String) -> String {
        "\(path.abbreviatedPath()) can’t be a space’s folder: every folder in it would join the space."
    }

    /// Only `projects.json` keeps anchors for sure: an older build's mirror
    /// has none, so a change made while the file can't be written (a newer
    /// Nirux saved it, or it is unreadable) would be lost or undone at the
    /// next launch. Says so when it can't.
    func canChangeAnchors() -> Bool {
        guard projectStore.availability == .writable else {
            showToast(Self.anchorsLockedMessage, tone: .error)
            return false
        }
        return true
    }

    static let anchorsLockedMessage = "Repositories can’t change now: a newer Nirux saved the spaces, or projects.json can’t be read"

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
        guard spaceID != WorkspaceProfile.defaultID, profiles.contains(where: { $0.id == spaceID }),
              canChangeAnchors()
        else { return }
        sideEffects.chooseFolder("Add Repository", window) { [weak self] folder in
            guard let folder else { return }
            Self.pickAnchor(folder, asRepository: true) { [weak self] pick in
                self?.runFromRunLoop { [weak self] in self?.finishAddingRepository(pick, toSpace: spaceID) }
            }
        }
    }

    /// A folder in no repository joins as a folder once the user agrees,
    /// never the home folder or one holding it.
    private func finishAddingRepository(_ pick: AnchorPick, toSpace spaceID: String, moving workspaceID: String? = nil) {
        guard let space = profiles.first(where: { $0.id == spaceID }) else { return }
        switch pick {
        case .missing(let folder):
            showToast("That folder is gone: \(folder.abbreviatedPath())", tone: .error)
        case .notARepository(let folder):
            guard !isTooBroadForAFolderAnchor(folder) else { return showToast(tooBroadFolderMessage(folder), tone: .error) }
            let alert = NSAlert()
            alert.messageText = "“\((folder as NSString).lastPathComponent)” isn’t in a git repository"
            alert.informativeText = "Add it to “\(space.name)” as a folder? Workspaces opened in it or below join the space."
            alert.addButton(withTitle: "Add Folder")
            alert.addButton(withTitle: "Cancel")
            guard runModal(alert) == .alertFirstButtonReturn else { return }
            addAnchor(.folder(folder), toSpace: spaceID, moving: workspaceID)
        case .anchor(let anchor):
            addAnchor(anchor, toSpace: spaceID, moving: workspaceID)
        }
    }

    /// Anchors it to the space, after asking when another space has it,
    /// moves `workspaceID` there, then offers the others of that
    /// repository or folder. May show an alert: call it from the run loop.
    func addAnchor(_ anchor: SpaceAnchor, toSpace spaceID: String, moving workspaceID: String? = nil) {
        if case .folder(let path) = anchor.kind, isTooBroadForAFolderAnchor(path) {
            return showToast(tooBroadFolderMessage(path), tone: .error)
        }
        guard canChangeAnchors(),
              let space = profiles.first(where: { $0.id == spaceID }),
              confirmTakingAnchor(anchor, intoSpaceNamed: space.name, excluding: spaceID),
              workspaceStore.addAnchor(anchor, toProfile: spaceID)
        else { return }
        if let workspaceID { moveWorkspaceToSpace(workspaceID: workspaceID, profileID: spaceID) }
        updateSidebar()
        saveState()
        offerToMoveWorkspaces(into: spaceID) {}
    }

    func removeSpaceAnchor(key: String, fromSpace spaceID: String) {
        guard canChangeAnchors(), workspaceStore.removeAnchor(key: key, fromProfile: spaceID) else { return }
        updateSidebar()
        saveState()
    }

    func makeDefaultSpaceAnchor(key: String, inSpace spaceID: String) {
        guard canChangeAnchors(), workspaceStore.makeDefaultAnchor(key: key, inProfile: spaceID) else { return }
        updateSidebar()
        saveState()
    }

    /// The banner's "Anchor to…": the repository holding the workspace's
    /// folder joins the space, and so does the workspace. A folder in no
    /// repository asks first, as "Add Repository…" does.
    func anchorWorkspaceFolder(workspaceID: String, toSpace spaceID: String) {
        guard let workspace = workspaces.first(where: { $0.id == workspaceID && !$0.isClosing }),
              canChangeAnchors()
        else { return }
        Self.pickAnchor(workspace.cwd, asRepository: true) { [weak self] pick in
            self?.runFromRunLoop { [weak self] in
                self?.finishAddingRepository(pick, toSpace: spaceID, moving: workspaceID)
            }
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
            self?.runFromRunLoop { [weak self] in
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

    /// Each folder's identity, off the main thread and side by side, so the
    /// wait stays about one git call however many workspaces are open; a
    /// folder that is gone is left out.
    nonisolated static func identifyAllOffMain(
        _ folders: [String],
        completion: @escaping @MainActor @Sendable ([String: FolderIdentity]) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let results = IdentityResults()
            DispatchQueue.concurrentPerform(iterations: folders.count) { index in
                results.set(FolderIdentity.identify(folders[index], timeout: 2), for: folders[index])
            }
            let identities = results.all
            DispatchQueue.main.async { @MainActor in completion(identities) }
        }
    }

    // MARK: New Space…

    /// The New Space… sheet, the focused terminal's repository already in
    /// it unless another space has it. `workspaceID` (the banner's "New
    /// Space…") suggests that workspace's folder instead.
    func showNewSpacePanel(suggestingFolderOf workspaceID: String? = nil) {
        guard let window else { return }
        // Shown, or about to be once git has named the repository.
        if let pending = newSpacePanel {
            pending.panel?.makeKeyAndOrderFront(nil)
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
        Self.identifyOffMain(folder, timeout: max(1, sideEffects.routingTimeout)) { [weak self, weak panel] identity in
            guard let self, let panel, self.newSpacePanel === panel else { return }
            guard let window = self.window else {
                self.newSpacePanel = nil
                return
            }
            var suggestion: SpaceAnchor?
            if self.projectStore.availability == .writable, let identity, identity.commonDir != nil,
               identity.anchor.key.flatMap(self.workspaceStore.profile(anchoring:)) == nil {
                suggestion = identity.anchor
            }
            panel.show(attachedTo: window, colorHex: colorHex, suggestion: suggestion)
        }
    }

    private func pickAnchorForNewSpace(asRepository: Bool, panel: NewSpacePanel) {
        guard projectStore.availability == .writable else { return panel.showError(Self.anchorsLockedMessage + ".") }
        sideEffects.chooseFolder(asRepository ? "Add Repository" : "Add Folder", panel.panel) { [weak self, weak panel] folder in
            guard let folder else { return }
            Self.pickAnchor(folder, asRepository: asRepository) { [weak self, weak panel] pick in
                self?.runFromRunLoop { [weak self, weak panel] in
                    guard let self, let panel, panel.panel != nil else { return }
                    self.addPickedAnchor(pick, to: panel)
                }
            }
        }
    }

    private func addPickedAnchor(_ pick: AnchorPick, to panel: NewSpacePanel) {
        switch pick {
        case .missing(let folder):
            panel.showError("That folder is gone: \(folder.abbreviatedPath())")
        case .notARepository(let folder):
            panel.showError(isTooBroadForAFolderAnchor(folder)
                ? tooBroadFolderMessage(folder)
                : "\(folder.abbreviatedPath()) isn’t in a git repository. Add Folder… adds a plain folder.")
        case .anchor(let anchor):
            // Already listed: nothing to ask.
            guard !panel.rows.contains(where: { $0.anchor.key == anchor.key }) else { return }
            if case .folder(let path) = anchor.kind, isTooBroadForAFolderAnchor(path) {
                return panel.showError(tooBroadFolderMessage(path))
            }
            let typed = panel.nameField.stringValue.trimmingCharacters(in: .whitespaces)
            let owner = anchor.key.flatMap(workspaceStore.profile(anchoring:))
            guard confirmTakingAnchor(anchor, intoSpaceNamed: typed.isEmpty ? "the new space" : typed, excluding: nil)
            else { return }
            panel.add(anchor, movingFrom: owner?.name)
        }
    }

    /// Creates the space (or fills an empty one of that name that has no
    /// repository), offers to move its repositories' workspaces in, then
    /// shows it: its empty view when none moved in.
    func createSpace(_ draft: NewSpacePanel.Draft) {
        // The sheet adds none then; one taken from another space would come
        // back to it at the next launch.
        let anchors = projectStore.availability == .writable ? draft.anchors : []
        if anchors.count != draft.anchors.count { showToast(Self.anchorsLockedMessage, tone: .error) }
        let spaceID: String
        if let empty = profiles.first(where: { space in
            space.id != WorkspaceProfile.defaultID && space.name == draft.name && space.anchors.isEmpty
                && workspaceStore.visibleWorkspaceIndices(in: space.id).isEmpty
        }) {
            spaceID = empty.id
            workspaceStore.setProfileColor(id: spaceID, colorHex: draft.colorHex)
            workspaceStore.setAnchors(anchors, forProfile: spaceID)
        } else {
            spaceID = workspaceStore.createProfile(
                named: draft.name, colorHex: draft.colorHex, anchors: anchors, select: false
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
        guard !anchors.isEmpty else { return finish() }
        offerToMoveWorkspaces(into: spaceID, then: finish)
    }
}

/// `identifyAllOffMain`'s results, filled from several threads.
private final class IdentityResults: @unchecked Sendable {
    private let lock = NSLock()
    private var identities: [String: FolderIdentity] = [:]

    func set(_ identity: FolderIdentity?, for folder: String) {
        lock.lock()
        defer { lock.unlock() }
        identities[folder] = identity
    }

    var all: [String: FolderIdentity] {
        lock.lock()
        defer { lock.unlock() }
        return identities
    }
}
