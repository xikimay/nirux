import AppKit

// MARK: - Mission Worktrees

extension NiruxShellView {
    /// `nirux://new-worktree`: create a git worktree, move an optional
    /// handover file into it, and open a workspace. Its space is decided
    /// once the worktree exists (docs/spaces.md, "Routing"): its
    /// repository's space, else the parent's current space, else
    /// `requestedProfileID` (the space the requesting shell started in),
    /// else the default space, with the banner that says so.
    ///
    /// A new branch starts from origin's base branch, fetched first (see
    /// `newWorktreeStart`), unless `startsFromHead` (a stacked branch): then
    /// from `repoRoot`'s HEAD.
    func createWorktreeWorkspace(
        branch: String,
        repoRoot: String,
        agent: NiruxApp.WorkspaceAgent? = .claude,
        handoverPath: String? = nil,
        profileID requestedProfileID: String? = nil,
        parentWorkspaceID: String? = nil,
        parentAgentUUID: String? = nil,
        startsFromHead: Bool = false
    ) {
        let routesByAnchor = routesByAnchor
        // The space the repository goes to, decided as below, holds the
        // base branch its tasks start from (its board's).
        let spaces = workspaceStore.profiles
        let parentSpaceID = parentWorkspaceID.flatMap { id in workspaces.first { $0.id == id && !$0.isClosing }?.profileID }
        let stateDirectory = Persistence.stateDirectory
        DispatchQueue.global(qos: .userInitiated).async {
            let start = startsFromHead ? nil : Self.newWorktreeStart(branch: branch, repoRoot: repoRoot) {
                Self.baseBranch(
                    of: repoRoot, routesByAnchor: routesByAnchor, parentSpaceID: parentSpaceID,
                    requestedSpaceID: requestedProfileID, spaces: spaces, stateDirectory: stateDirectory
                )
            }
            let (path, error) = GitWorktree.create(branch: branch, repoRoot: repoRoot, newBranchStartPoint: start?.startPoint)
            // Read back from the checkout: the session is named after the
            // branch it will actually work on (see `SessionName`).
            let checkedOutBranch = path.flatMap(GitWorktree.currentBranch(at:))
            let identity = routesByAnchor
                ? path.flatMap { FolderIdentity.identify($0, timeout: FolderIdentity.backgroundRoutingTimeout) } : nil
            // Move handover file into the worktree if provided. The path comes
            // from a URL: HandoverFile only accepts the user's own regular file
            // directly in /tmp, never a symlink or hard link.
            var deliveredHandover = false
            var handoverText: String?
            var handoverError: HandoverFile.TransferError?
            if let path, let handoverPath {
                switch HandoverFile.transfer(
                    from: handoverPath,
                    toDirectory: path,
                    filename: Self.handoverFilename(for: agent ?? .claude)
                ) {
                case .success(let content):
                    deliveredHandover = true
                    handoverText = String(decoding: content, as: UTF8.self)
                case .failure(let error): handoverError = error
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // An agent retrying the same `open` after its handover was
                // delivered: focus the workspace the first request opened
                // instead of adding a duplicate agent in the same folder.
                if let handoverPath, handoverError == .cannotOpen(ENOENT),
                   let previousID = DeliveredHandovers.workspaceID(for: handoverPath),
                   self.workspaces.contains(where: { $0.id == previousID }) {
                    self.focusWorkspace(id: previousID, editorTakesKeyboard: false)
                    return
                }
                if let handoverPath, let handoverError {
                    NSLog("[Worktree] Ignored handover \(handoverPath): \(handoverError)")
                    self.presentProblem(
                        "Handover ignored for “\(branch)”",
                        "The worktree opens without it. \(handoverError.explanation)\n\n\(handoverPath)"
                    )
                }
                if let path {
                    let childWorkspaceID = UUID().uuidString
                    let childAgentUUID = UUID().uuidString
                    if deliveredHandover, let handoverPath {
                        DeliveredHandovers.record(handoverPath, workspaceID: childWorkspaceID)
                    }
                    var missionID: String?
                    if let parent = self.validMissionParent(
                        workspaceID: parentWorkspaceID,
                        agentUUID: parentAgentUUID
                    ) {
                        let candidateID = UUID().uuidString
                        let request = MissionCreationRequest(
                            id: candidateID,
                            parentWorkspaceID: parent.workspaceID,
                            parentAgentUUID: parent.agentUUID,
                            childWorkspaceID: childWorkspaceID,
                            childAgentUUID: childAgentUUID,
                            childAgentKind: agent?.rawValue ?? "agent",
                            branch: branch
                        )
                        if MissionStore.shared.create(
                            request,
                            enabled: Self.currentMissionHandoffsEnabled()
                        ) != nil {
                            missionID = candidateID
                        }
                    }
                    let decision = self.decideSpace(
                        identity: identity, parentWorkspaceID: parentWorkspaceID, startedFromSpaceID: requestedProfileID
                    )
                    self.addWorkspace(
                        title: branch,
                        cwd: path,
                        agent: agent,
                        profileID: decision.spaceID,
                        workspaceID: childWorkspaceID,
                        initialAgentUUID: childAgentUUID,
                        missionID: missionID,
                        deliveredHandover: deliveredHandover,
                        handoverText: handoverText,
                        worktreeBranch: checkedOutBranch
                    )
                    self.saveState()
                    if decision.reason == .general { self.presentSpaceArrival(workspaceID: childWorkspaceID) }
                    // Above the banner, when there is one.
                    if let start, let fetchError = start.fetchError {
                        let from = start.startPoint == nil ? "the checkout’s HEAD" : "it as last fetched"
                        self.presentToast(
                            "Couldn’t fetch \(start.remoteBranchName): “\(branch)” starts from \(from). \(fetchError)", tone: .error
                        )
                    }
                    // A new branch's worktree can exist although git failed
                    // (a failing post-checkout hook): it opens, and git's
                    // error says what may be missing.
                    if let error {
                        NSLog("[Worktree] git reported a problem creating \(branch): \(error)")
                        self.presentProblem(
                            "“\(branch)” is open, but git reported a problem",
                            "The worktree may be incomplete.\n\n" + NewTaskPanel.lastLines(of: error, maxLines: 12)
                        )
                    }
                } else {
                    NSLog("[Worktree] Failed to create worktree for \(branch): \(error ?? "unknown")")
                    self.presentProblem(
                        "Couldn’t create worktree “\(branch)”",
                        error ?? "git worktree add failed"
                    )
                }
            }
        }
    }

    /// Non-blocking report for URL-driven actions that fail after the
    /// request was accepted (the agent's `open` already exited 0).
    func presentProblem(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = NiruxURLRequest.displaySafe(title)
        alert.informativeText = NiruxURLRequest.displaySafeLines(message)
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            runModal(alert)
        }
    }

    /// Where a `nirux://new-worktree` branch starts.
    struct NewWorktreeStart: Sendable {
        /// `refs/remotes/origin/<base>`; nil when it is missing after a
        /// failed fetch: the checkout's HEAD then.
        let startPoint: String?
        /// `origin/<base>`.
        let remoteBranchName: String
        /// Why origin's branch couldn't be fetched.
        let fetchError: String?
    }

    /// The board base branch of the space `repoRoot` goes to, decided as
    /// for its workspace (docs/spaces.md, "Routing"), when that board is
    /// about this repository.
    nonisolated static func baseBranch(
        of repoRoot: String, routesByAnchor: Bool, parentSpaceID: String?, requestedSpaceID: String?,
        spaces: [WorkspaceProfile], stateDirectory: URL
    ) -> String? {
        let identity = routesByAnchor ? FolderIdentity.identify(repoRoot, timeout: FolderIdentity.backgroundRoutingTimeout) : nil
        let spaceID = SpaceRouting.route(
            identity: identity, parentSpaceID: parentSpaceID, startedFromSpaceID: requestedSpaceID, spaces: spaces
        ).spaceID
        // The board is set up for one repository, the space's default one
        // (a space anchored to none: its only one, as before anchors).
        // General has none: whatever its board says is about no repository.
        guard spaceID != WorkspaceProfile.defaultID else { return nil }
        if let defaultKey = spaces.first(where: { $0.id == spaceID })?.anchors.defaultAnchor?.key,
           identity?.anchor.key != defaultKey {
            return nil
        }
        return BoardConfigStore(spaceID: spaceID, stateDirectory: stateDirectory)?.load().config?.baseBranch
    }

    /// Origin's base branch (see `NewTask.resolveTarget`), fetched, for a
    /// branch that exists nowhere yet: one that exists opens as it is, with
    /// no fetch. Nil without origin, for a branch that exists, and for what
    /// `create` refuses anyway: `create` then works as before.
    /// `baseBranch` (the space's board setting) is read only when needed.
    nonisolated static func newWorktreeStart(
        branch: String, repoRoot: String, baseBranch: () -> String?
    ) -> NewWorktreeStart? {
        // From a URL: nothing reaches git, let alone the network, before
        // `repoRoot` is a checkout's top level and `branch` a branch name
        // (a leading "-" would be an option).
        guard GitWorktree.repositoryTopLevelProblem(repoRoot) == nil,
              GitWorktree.isValidBranchName(branch, repoRoot: repoRoot),
              // Only a branch that exists nowhere, in any case: `create` would
              // otherwise make `feat/x` next to `Feat/x`, which the filesystem
              // takes for one, then delete that one as its own after git
              // refuses (see `afterFailedNewBranch`).
              let target = NewTask.resolveTarget(folder: repoRoot, baseBranch: baseBranch()),
              let remoteBranch = target.remoteBranch, let name = target.remoteBranchName
        else { return nil }
        let fetchError = GitWorktree.fetch(branch: remoteBranch, repoRoot: target.repository)
        // Never fetched (a board base origin doesn't have, say): from HEAD.
        let startPoint = fetchError != nil && GitWorktree.commitID(of: target.startPoint, in: repoRoot) == nil
            ? nil : target.startPoint
        return NewWorktreeStart(startPoint: startPoint, remoteBranchName: name, fetchError: fetchError)
    }

    nonisolated static func handoverFilename(for agent: NiruxApp.WorkspaceAgent) -> String {
        switch agent {
        case .claude: return ".claude-handover.md"
        case .codex: return ".codex-handover.md"
        }
    }

    /// Types each pending `tell` into its child's prompt if that prompt is
    /// free; the others wait for the child's next turn end. Runs when a
    /// `tell` arrives and when a turn ends.
    func typeMissionInstructions() {
        guard !MissionStore.shared.pendingInstructions().isEmpty, Self.currentMissionHandoffsEnabled() else { return }
        // Apply what may still wait out a queue's drain debounce: a dialog
        // that opened, or the child's `completed`, which must not close the
        // Mission after a `tell` reopened it.
        AgentHookCenter.shared.drain()
        MissionEventCenter.shared.drain()
        let snapshot = ProcessSnapshot()
        for instruction in MissionStore.shared.pendingInstructions() {
            let mission = instruction.mission
            guard let pty = workspaces.first(where: { $0.id == mission.childWorkspaceID })?
                .columns.first(where: { $0.agentUUID == mission.childAgentUUID })?.pty,
                pty.acceptsMissionInstruction(toldAt: instruction.event.timestamp, snapshot: snapshot),
                let input = RemotePromptSanitizer.terminalInput(for: instruction.event.message),
                // Recorded first: a failed save must not type it twice.
                MissionStore.shared.markInstructionTyped(eventID: instruction.event.id)
            else { continue }
            pty.sendRaw(input)
        }
    }

    static func currentMissionHandoffsEnabled() -> Bool {
        Persistence.load()?.settings?.missionHandoffsEnabled == true
    }

    private func validMissionParent(
        workspaceID: String?, agentUUID: String?
    ) -> (workspaceID: String, agentUUID: String)? {
        guard Self.currentMissionHandoffsEnabled(),
              let workspaceID,
              let agentUUID,
              UUID(uuidString: workspaceID) != nil,
              UUID(uuidString: agentUUID) != nil,
              let workspace = workspaces.first(where: { $0.id == workspaceID }),
              workspace.columns.contains(where: { $0.agentUUID == agentUUID })
        else { return nil }
        return (workspaceID, agentUUID)
    }
}

/// Handover paths already moved into a worktree, so a retried request for
/// the same handover can be recognized (bounded; newest kept).
@MainActor
private enum DeliveredHandovers {
    private static var workspaceByPath: [(path: String, workspaceID: String)] = []

    static func record(_ path: String, workspaceID: String) {
        workspaceByPath.removeAll { $0.path == path }
        workspaceByPath.append((path, workspaceID))
        if workspaceByPath.count > 32 { workspaceByPath.removeFirst() }
    }

    static func workspaceID(for path: String) -> String? {
        workspaceByPath.last { $0.path == path }?.workspaceID
    }
}
