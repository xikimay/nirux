import AppKit

// MARK: - Routing new workspaces (docs/spaces.md, "Routing")

extension NiruxShellView {
    /// Where a plain new workspace of a space opens: its default anchor's
    /// folder (a repository's main checkout), else the first of its other
    /// anchors' folders still there (the default one moved), else the home
    /// folder. Also the home folder for a space that doesn't exist. A stat
    /// on the main thread, so a terminal never starts in a folder that is
    /// gone: an anchor on a network volume that went away waits for it.
    func defaultFolder(forSpace spaceID: String) -> String {
        let space = profiles.first { $0.id == spaceID }
        let folders = [space?.defaultFolder] + (space?.anchors.map(\.folder) ?? [])
        return folders.lazy.compactMap { $0 }.first(where: NiruxURLRequest.directoryExists) ?? sideEffects.homeDirectory()
    }

    /// A space has a repository or folder: only then is git asked where a
    /// new workspace's folder belongs.
    var routesByAnchor: Bool {
        profiles.contains { $0.anchors.contains(where: \.isKnown) }
    }

    /// Decides the space of a workspace about to open on `folder`, then
    /// calls `open` with it. Git names the folder's repository off the main
    /// thread, and only once a space has an anchor: until then `open` runs
    /// at once. The parent's space is read when deciding, so a parent moved
    /// meanwhile counts where it is now.
    func routeWorkspace(
        folder: String,
        parentWorkspaceID: String? = nil,
        startedFromSpaceID: String?,
        open: @escaping @MainActor @Sendable (SpaceRouting.Decision) -> Void
    ) {
        guard routesByAnchor else {
            return open(decideSpace(identity: nil, parentWorkspaceID: parentWorkspaceID, startedFromSpaceID: startedFromSpaceID))
        }
        Self.identifyOffMain(folder, timeout: sideEffects.routingTimeout) { [weak self] identity in
            guard let self else { return }
            open(self.decideSpace(identity: identity, parentWorkspaceID: parentWorkspaceID, startedFromSpaceID: startedFromSpaceID))
        }
    }

    func decideSpace(identity: FolderIdentity?, parentWorkspaceID: String?, startedFromSpaceID: String?) -> SpaceRouting.Decision {
        let parentSpaceID = parentWorkspaceID.flatMap { id in
            workspaces.first { $0.id == id && !$0.isClosing }?.profileID
        }
        return SpaceRouting.route(
            identity: identity, parentSpaceID: parentSpaceID, startedFromSpaceID: startedFromSpaceID,
            spaces: workspaceStore.profiles
        )
    }

    /// A workspace the user opened from a space on an existing folder (Open
    /// Worktree, the board, a worktree made in the panel): it goes where
    /// its folder belongs, else to its parent's space, else to that space.
    func openRoutedWorkspace(
        title: String,
        cwd: String,
        agent: NiruxApp.WorkspaceAgent? = nil,
        parentWorkspaceID: String? = nil,
        startedFromSpaceID: String?,
        worktreeBranch: String? = nil
    ) {
        routeWorkspace(folder: cwd, parentWorkspaceID: parentWorkspaceID, startedFromSpaceID: startedFromSpaceID) { [weak self] decision in
            self?.addWorkspace(title: title, cwd: cwd, agent: agent, profileID: decision.spaceID, worktreeBranch: worktreeBranch)
            self?.saveState()
        }
    }

    /// The setup script of the anchor that routed a new worktree, if it has
    /// one (see SpaceSetupScript).
    func setupScript(for decision: SpaceRouting.Decision) -> URL? {
        guard decision.reason == .anchor, let anchor = decision.anchor else { return nil }
        return SpaceSetupScript.scriptToRun(spaceID: decision.spaceID, anchor: anchor)
    }

    /// `nirux://new-workspace`. From a Nirux terminal, `requestedSpaceID`
    /// is the space its shell started in; a request from outside, or one
    /// the user confirmed, names none and goes where its folder belongs,
    /// else to the default space, with the banner that says so.
    func openRequestedWorkspace(
        title: String?, cwd: String?, agent: NiruxApp.WorkspaceAgent?, requestedSpaceID: String?, startedOutsideNirux: Bool = false
    ) {
        let folder = cwd ?? defaultFolder(forSpace: requestedSpaceID ?? WorkspaceProfile.defaultID)
        routeWorkspace(folder: folder, startedFromSpaceID: requestedSpaceID) { [weak self] decision in
            guard let self else { return }
            let workspaceID = UUID().uuidString
            self.addWorkspace(
                title: title, cwd: folder, agent: agent, profileID: decision.spaceID, workspaceID: workspaceID,
                startedOutsideNirux: startedOutsideNirux
            )
            self.saveState()
            if decision.reason == .general { self.presentSpaceArrival(workspaceID: workspaceID) }
        }
    }

    /// Off the main thread through a nonisolated function, so the closure
    /// can't inherit this view's main-actor isolation (see NewTask).
    nonisolated static func identifyOffMain(
        _ folder: String,
        timeout: TimeInterval = FolderIdentity.routingTimeout,
        completion: @escaping @MainActor @Sendable (FolderIdentity?) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let identity = FolderIdentity.identify(folder, timeout: timeout)
            DispatchQueue.main.async { @MainActor in
                completion(identity)
            }
        }
    }

    // MARK: - The banner

    /// Says a workspace opened in the default space because no space claims
    /// its folder, with "Move to…" and "Anchor to…".
    func presentSpaceArrival(workspaceID: String) {
        guard let workspace = workspaces.first(where: { $0.id == workspaceID }) else { return }
        spaceArrivalGeneration += 1
        let generation = spaceArrivalGeneration
        let banner = spaceArrivalBanner ?? SpaceArrivalBanner()
        spaceArrivalBanner = banner
        let general = profiles.first { $0.id == WorkspaceProfile.defaultID }?.name ?? WorkspaceProfile.defaultProfile.name
        let message = "“\(NiruxURLRequest.displaySafe(workspace.title, limit: 60))” opened in \(general): no space has its folder."
        banner.show(message, workspaceID: workspaceID, offersMove: profiles.count > 1)
        banner.moveMenu = { [weak self] in self?.spaceArrivalMoveMenu(workspaceID: workspaceID) }
        banner.anchorMenu = { [weak self] in self?.spaceArrivalAnchorMenu(workspaceID: workspaceID) }
        banner.onClose = { [weak self] in self?.dismissSpaceArrival() }
        addSubview(banner, positioned: .above, relativeTo: nil)
        spaceArrivalShownAt = ProcessInfo.processInfo.systemUptime
        layoutToast()
        NSAccessibility.post(
            element: window ?? banner,
            notification: .announcementRequested,
            userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue]
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + SpaceArrivalBanner.duration) { [weak self] in
            guard let self, generation == self.spaceArrivalGeneration else { return }
            self.dismissSpaceArrival()
        }
    }

    func dismissSpaceArrival() {
        guard let banner = spaceArrivalBanner else { return }
        spaceArrivalGeneration += 1
        banner.removeFromSuperview()
        spaceArrivalBanner = nil
        layoutToast()
    }

    /// A click in the window elsewhere than on the banner puts it away, not
    /// in its first half second (a click already on its way).
    func dismissSpaceArrivalOnClick(_ event: NSEvent) {
        guard let banner = spaceArrivalBanner,
              ProcessInfo.processInfo.systemUptime - spaceArrivalShownAt > Self.toastInputGrace
        else { return }
        let point = banner.convert(event.locationInWindow, from: nil)
        if !banner.bounds.contains(point) { dismissSpaceArrival() }
    }

    /// The spaces the workspace can move to.
    func spaceArrivalMoveMenu(workspaceID: String) -> NSMenu? {
        guard let workspace = workspaces.first(where: { $0.id == workspaceID && !$0.isClosing }) else { return nil }
        let targets = profiles.filter { $0.id != workspace.profileID }
        guard !targets.isEmpty else { return nil }
        let menu = NSMenu()
        for space in targets {
            menu.addClosureItem(title: space.name) { [weak self] in
                self?.dismissSpaceArrival()
                self?.moveWorkspaceToSpace(workspaceID: workspaceID, profileID: space.id)
            }
        }
        return menu
    }

    /// The spaces its folder's repository (or the folder) can be anchored
    /// to, then "New Space…".
    func spaceArrivalAnchorMenu(workspaceID: String) -> NSMenu? {
        guard workspaces.contains(where: { $0.id == workspaceID && !$0.isClosing }) else { return nil }
        let menu = NSMenu()
        for space in profiles where space.id != WorkspaceProfile.defaultID {
            menu.addClosureItem(title: space.name) { [weak self] in
                self?.dismissSpaceArrival()
                self?.anchorWorkspaceFolder(workspaceID: workspaceID, toSpace: space.id)
            }
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        menu.addClosureItem(title: "New Space…") { [weak self] in
            self?.dismissSpaceArrival()
            self?.showNewSpacePanel(suggestingFolderOf: workspaceID)
        }
        return menu
    }
}
