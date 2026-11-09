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
        startsFromHead: Bool = false,
        startedOutsideNirux: Bool = false
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
            // A worktree an agent already works in (the branch was checked
            // out) never runs the setup script again. One opened from outside
            // Nirux runs none, and leaves it to a later request from Nirux.
            let firstSetup = !startedOutsideNirux && (path.map(SpaceSetupScript.claimFirstRun(worktree:)) ?? false)
            // Read back from the checkout: the session is named after the
            // branch it will actually work on (see `SessionName`).
            let checkedOutBranch = path.flatMap(GitWorktree.currentBranch(at:))
            let identity = routesByAnchor
                ? path.flatMap { FolderIdentity.identify($0, timeout: FolderIdentity.backgroundRoutingTimeout) } : nil
            // Move handover file into the worktree if provided. The path comes
            // from a URL: HandoverFile only accepts the user's own regular file
            // directly in /tmp, never a symlink or hard link.
            var deliveredHandover = false
            var handoverError: HandoverFile.TransferError?
            if let path, let handoverPath {
                switch HandoverFile.transfer(
                    from: handoverPath,
                    toDirectory: path,
                    filename: Self.handoverFilename(for: agent ?? .claude)
                ) {
                case .success:
                    deliveredHandover = true
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
                    var reportsToLead = false
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
                            branch: branch,
                            reportsToLead: parent.isLead
                        )
                        if MissionStore.shared.create(
                            request,
                            enabled: Self.currentMissionHandoffsEnabled()
                        ) != nil {
                            missionID = candidateID
                            reportsToLead = parent.isLead
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
                        // The skill names its workspace and terminal: the
                        // child lists under it, Missions on or off.
                        parentWorkspaceID: parentWorkspaceID,
                        reportsToLead: reportsToLead,
                        deliveredHandover: deliveredHandover,
                        worktreeBranch: checkedOutBranch,
                        startedOutsideNirux: startedOutsideNirux,
                        startedByAgent: false,
                        setupScript: firstSetup ? self.setupScript(for: decision) : nil
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
    /// for its workspace (docs/spaces.md, "Routing"), for this repository.
    nonisolated static func baseBranch(
        of repoRoot: String, routesByAnchor: Bool, parentSpaceID: String?, requestedSpaceID: String?,
        spaces: [WorkspaceProfile], stateDirectory: URL
    ) -> String? {
        let identity = routesByAnchor ? FolderIdentity.identify(repoRoot, timeout: FolderIdentity.backgroundRoutingTimeout) : nil
        let spaceID = SpaceRouting.route(
            identity: identity, parentSpaceID: parentSpaceID, startedFromSpaceID: requestedSpaceID, spaces: spaces
        ).spaceID
        // General has no repository: whatever its board says is about none.
        guard spaceID != WorkspaceProfile.defaultID else { return nil }
        return boardBaseBranch(
            for: repoRoot, spaceID: spaceID, anchors: spaces.first { $0.id == spaceID }?.anchors ?? [],
            stateDirectory: stateDirectory
        )
    }

    /// The base branch a space's board sets for the repository holding
    /// `folder`: that repository anchor's config (docs/spaces.md, S12), or,
    /// in a space anchored to no repository, its one config, as before
    /// anchors: for any folder without anchors, for the repository of its
    /// default folder anchor with one. Nil when the board sets none for it.
    /// Runs git: off the main thread.
    nonisolated static func boardBaseBranch(
        for folder: String, spaceID: String, anchors: [SpaceAnchor], stateDirectory: URL
    ) -> String? {
        guard let loaded = BoardConfigStore(spaceID: spaceID, stateDirectory: stateDirectory)?.load(),
              loaded.status != .unreadable
        else { return nil }
        let timeout = FolderIdentity.backgroundRoutingTimeout
        guard !BoardSections.repositoryAnchors(anchors).isEmpty else {
            let legacy = loaded.entries.first { $0.slot == .legacy }?.config.baseBranch
            guard let defaultFolder = anchors.defaultAnchor?.folder else { return legacy }
            let repository = FolderIdentity.identify(defaultFolder, timeout: timeout)?.commonDir
            return repository != nil && FolderIdentity.identify(folder, timeout: timeout)?.commonDir == repository ? legacy : nil
        }
        guard let commonDir = FolderIdentity.identify(folder, timeout: timeout)?.commonDir else { return nil }
        // Placing schema 1's config needs the anchors' remotes; the others don't.
        let context = loaded.entries.contains { $0.slot == .legacy }
            ? BoardSections.readContext(anchors: anchors) : BoardSections.Context(anchors: anchors)
        return BoardSections.sections(loaded.entries, context: context).first { $0.commonDir == commonDir }?.config?.baseBranch
    }

    /// Origin's base branch (see `NewTask.resolveTarget`), fetched, for a
    /// branch that exists nowhere yet: one that exists opens as it is, with
    /// no fetch. Nil without origin, for a branch `create` finds, one a
    /// local branch or worktree has in another case, and what `create`
    /// refuses anyway: `create` then works as before.
    /// `baseBranch` (the space's board setting) is read only when needed.
    nonisolated static func newWorktreeStart(
        branch: String, repoRoot: String, baseBranch: () -> String?
    ) -> NewWorktreeStart? {
        // From a URL: nothing reaches git, let alone the network, before
        // `repoRoot` is a checkout's top level and `branch` a branch name
        // (a leading "-" would be an option).
        guard GitWorktree.repositoryTopLevelProblem(repoRoot) == nil,
              GitWorktree.isValidBranchName(branch, repoRoot: repoRoot),
              // Never `feat/x` next to a local `Feat/x`, which the filesystem
              // takes for the same: git refuses it, and its cleanup would
              // then delete that branch as its own (see `afterFailedNewBranch`).
              !GitWorktree.localBranchExistsIgnoringCase(branch, repoRoot: repoRoot),
              !GitWorktree.existingBranch(branch, repoRoot: repoRoot).remote,
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

    /// Types each pending Mission message into its recipient's prompt if
    /// that prompt is free (see `MissionStore.pendingPromptDeliveries`); the
    /// others wait for that agent's next turn end. Runs when a Mission event
    /// arrives and when a turn ends.
    func typeMissionMessages() {
        typeLeadNotices()
        let handoffsEnabled = Self.currentMissionHandoffsEnabled()
        guard MissionStore.shared.pendingPromptDeliveries().contains(where: { $0.mission.isCarried(handoffsEnabled: handoffsEnabled) })
        else { return }
        // Apply what may still wait out a queue's drain debounce: a dialog
        // that opened, a prompt that went in, or the child's `completed`,
        // which must not close the Mission after a `tell` reopened it.
        AgentHookCenter.shared.drain()
        MissionEventCenter.shared.drain()
        let snapshot = ProcessSnapshot()
        let now = Date().timeIntervalSince1970
        var typedAny = false
        for delivery in MissionStore.shared.pendingPromptDeliveries(now: now)
        where delivery.mission.isCarried(handoffsEnabled: handoffsEnabled) {
            let mission = delivery.mission
            let childWorkspace = workspaces.first { $0.id == mission.childWorkspaceID }
            let parentWorkspace = workspaces.first { $0.id == mission.parentWorkspaceID }
            let toParent = delivery.event.kind == .question || delivery.event.kind == .completed
            let recipient = toParent
                ? parentWorkspace?.columns.first { $0.agentUUID == mission.parentAgentUUID }
                : childWorkspace?.columns.first { $0.agentUUID == mission.childAgentUUID }
            // A `tell` goes only to the `claude` that ran when it was sent.
            // The rest goes to whichever runs now: the child ended its turn
            // to wait for its answer, and a parent restored since resumed
            // its conversation.
            let runningSince = delivery.event.kind == .instruction ? delivery.event.timestamp : now
            guard let pty = recipient?.pty,
                  pty.acceptsMissionMessage(runningSince: runningSince, snapshot: snapshot),
                  let text = MissionPromptText.text(
                      for: delivery, childTitle: childWorkspace?.title, parentTitle: parentWorkspace?.title
                  ),
                  let input = RemotePromptSanitizer.terminalInput(for: text),
                  // Recorded first: a failed save must not type it twice.
                  MissionStore.shared.markTyped(delivery, at: now)
            else { continue }
            pty.sendRaw(input)
            typedAny = true
        }
        // The cards' "Asking …" and "Answer … ready" rows follow.
        if typedAny { updateSidebar(snapshot: snapshot) }
    }

    /// Types each Lead notice whose Lead's prompt is free; the others wait
    /// for its next turn end, an hour at most. A Lead that is gone drops
    /// its own.
    func typeLeadNotices() {
        guard !pendingLeadNotices.isEmpty else { return }
        let snapshot = ProcessSnapshot()
        let now = Date().timeIntervalSince1970
        pendingLeadNotices = pendingLeadNotices.filter { notice in
            guard now - notice.queuedAt < MissionEventCLI.parentMessageLifetime,
                  let workspace = workspaces.first(where: { $0.id == notice.workspaceID && !$0.isClosing }),
                  let column = workspace.columns.first(where: { $0.agentUUID == notice.agentUUID })
            else { return false }
            guard let pty = column.pty, pty.acceptsMissionMessage(runningSince: now, snapshot: snapshot),
                  let input = RemotePromptSanitizer.terminalInput(for: notice.text)
            else { return true }
            pty.sendRaw(input)
            return false
        }
    }

    static func currentMissionHandoffsEnabled() -> Bool {
        PersistedSettings.effective(Persistence.load()?.settings).missionHandoffsEnabled
    }

    /// A ⌘N task's Mission, reporting to `parent` (see
    /// `NewTask.Request.reportsTo`); nil when that parent can't take one.
    func createMission(
        parent: NewTask.MissionParent, childWorkspaceID: String, childAgentUUID: String,
        agent: NiruxApp.WorkspaceAgent, branch: String
    ) -> Mission? {
        guard let valid = validMissionParent(workspaceID: parent.workspaceID, agentUUID: parent.agentUUID) else { return nil }
        let request = MissionCreationRequest(
            id: UUID().uuidString,
            parentWorkspaceID: valid.workspaceID,
            parentAgentUUID: valid.agentUUID,
            childWorkspaceID: childWorkspaceID,
            childAgentUUID: childAgentUUID,
            childAgentKind: agent.rawValue,
            branch: branch,
            reportsToLead: valid.isLead
        )
        return MissionStore.shared.create(request, enabled: Self.currentMissionHandoffsEnabled())
    }

    /// The parent a new worktree's Mission reports to: any agent's column
    /// with Mission handoffs on, a space's Lead whatever the setting.
    private func validMissionParent(
        workspaceID: String?, agentUUID: String?
    ) -> (workspaceID: String, agentUUID: String, isLead: Bool)? {
        guard let workspace = requestingWorkspace(workspaceID: workspaceID, agentUUID: agentUUID), let agentUUID,
              workspace.isLead || Self.currentMissionHandoffsEnabled()
        else { return nil }
        return (workspace.id, agentUUID, workspace.isLead)
    }

    /// The open workspace a request names, with the terminal that sent it:
    /// a workspace id alone (a hand-written URL, an old copy of the skill)
    /// links nothing.
    func requestingWorkspace(workspaceID: String?, agentUUID: String?) -> WorkspaceState? {
        guard let workspaceID, let agentUUID, UUID(uuidString: workspaceID) != nil, UUID(uuidString: agentUUID) != nil,
              let workspace = workspaces.first(where: { $0.id == workspaceID && !$0.isClosing }),
              workspace.columns.contains(where: { $0.agentUUID == agentUUID })
        else { return nil }
        return workspace
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

/// A line for a Lead's prompt (see `NiruxShellView.pendingLeadNotices`).
struct LeadNotice: Equatable {
    let workspaceID: String
    let agentUUID: String
    let text: String
    /// Epoch seconds.
    let queuedAt: TimeInterval
}
