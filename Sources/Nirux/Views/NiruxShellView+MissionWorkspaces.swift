import AppKit

// MARK: - Mission Worktrees

extension NiruxShellView {
    /// `nirux://new-worktree`: create a git worktree, move an optional
    /// handover file into it, and open a workspace. Its space is decided
    /// once the worktree exists (docs/design/spaces.md, "Routing"): its
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
                    // The workspace and terminal the skill names.
                    let requester = self.requestingTerminal(workspaceID: parentWorkspaceID, agentUUID: parentAgentUUID)
                    if let parent = self.validMissionParent(requester) {
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
                        // It lists under that one, Missions on or off; under
                        // its task when that one is a sub-task: two levels at
                        // most. Its Mission, if any, stays with the asker.
                        parentWorkspaceID: requester.map { self.isSubtask($0.workspace) ? $0.workspace.parentWorkspaceID : $0.workspace.id }
                            ?? nil,
                        reportsToLead: reportsToLead,
                        deliveredHandover: deliveredHandover,
                        worktreeBranch: checkedOutBranch,
                        startedOutsideNirux: startedOutsideNirux,
                        startedByAgent: !startedOutsideNirux,
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
    /// for its workspace (docs/design/spaces.md, "Routing"), for this repository.
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
    /// `folder`: that repository anchor's config (docs/design/spaces.md, S12), or,
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
        HandoverFile.filename(for: agent)
    }

    /// Types each pending Mission message into its recipient's prompt if
    /// that prompt is free (see `MissionStore.pendingPromptDeliveries`); the
    /// others wait for that agent's next turn end. Runs when a Mission event
    /// arrives and when a turn ends.
    func typeMissionMessages() {
        typeLeadNotices()
        typeRuleDecisions()
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
            guard let recipient = missionRecipient(of: delivery), let pty = recipient.pty,
                  pty.acceptsMissionMessage(
                      runningSince: runningSince(of: delivery.event, in: recipient, snapshot: snapshot, now: now), snapshot: snapshot
                  ),
                  let text = MissionPromptText.text(
                      for: delivery, childTitle: childWorkspace?.title, parentTitle: parentWorkspace?.title
                  ),
                  let paste = TypedPromptSanitizer.bracketedPaste(for: text),
                  // Recorded first: a failed save must not type it twice.
                  MissionStore.shared.markTyped(delivery, at: now)
            else { continue }
            let sender = NewTask.MissionParent(workspaceID: mission.parentWorkspaceID, agentUUID: mission.parentAgentUUID)
            let toChild = !Self.goesToParent(delivery.event)
            let receiver = MissionPromptText.quoted(childWorkspace?.title ?? mission.branch)
            let byUser = delivery.event.answeredByUser == true
            let recipientTitle = MissionPromptText.quoted((toChild ? childWorkspace : parentWorkspace)?.title ?? mission.branch)
            let what = byUser ? "your answer" : "a Mission message"
            typeMissionPrompt(paste, into: pty, keepingInFront: pty.foregroundProcess(snapshot: snapshot)?.instance) { [weak self] unsent in
                guard let self else { return }
                switch unsent {
                case .left:
                    MissionStore.shared.unmarkTyped(delivery)
                case .inPrompt(let why):
                    // Only someone at its prompt can send it now: again, it would follow as a copy.
                    if toChild, !byUser {
                        self.tellProposer(sender, "Your message to “\(receiver)” is in its prompt but wasn't sent: \(why). "
                            + "It waits there for someone to press Enter or clear it.")
                    }
                    self.showToast("All of \(what) for “\(recipientTitle)” is in its prompt, unsent: \(why). Press Enter there to send it.")
                case .cut:
                    if toChild, !byUser {
                        self.tellProposer(sender, "Your message to “\(receiver)” was cut off: its agent stopped reading, so only its start "
                            + "is in its prompt. Send it again once its prompt is clear.")
                    }
                    self.showToast("Only the start of \(what) for “\(recipientTitle)” went into its prompt: its agent stopped reading. "
                        + "Clear it there.")
                }
            }
            missionWaits.noteTyped(into: recipient, at: now)
            typedAny = true
        }
        // The cards' "Asking …" and "Answer … ready" rows follow.
        if typedAny { updateSidebar(snapshot: snapshot) }
    }

    /// What became of a long Mission message that wasn't sent.
    enum UnsentMessage: Sendable {
        /// Its agent left, or its task closed, before it was all in.
        case left
        /// All of it is in the prompt: Nirux didn't press Enter, for `why`.
        case inPrompt(why: String)
        /// Its agent stopped reading: only its start is in the prompt.
        case cut
    }

    /// `paste` (a bracketed paste) and Enter into `pty`: in one write when
    /// the terminal's input queue holds it with its Enter, else as the agent
    /// reads it (`PtySession.pasteInBackground`), Enter once it is all in,
    /// for the agent it went to, with no key since and no dialog. Otherwise
    /// `unsent` says what became of it.
    func typeMissionPrompt(
        _ paste: String, into pty: PtySession, keepingInFront process: ProcessInstance?,
        unsent: @escaping @MainActor @Sendable (UnsentMessage) -> Void
    ) {
        guard paste.utf8.count + 1 > PtySession.inputQueueBytes else { return pty.sendRaw(paste + "\r") }
        pty.pasteInBackground(paste, keepingInFront: process, cancelled: { false }) { [weak self] outcome, typedAt in
            switch outcome {
            case .pasted:
                // After the keys ghostty routed meanwhile, noted the same way.
                DispatchQueue.main.async { self?.pressEnter(after: typedAt, into: pty, for: process, unsent: unsent) }
            case .timedOut:
                unsent(.cut)
            case .closed, .agentLeft, .cancelled:
                unsent(.left)
            }
        }
    }

    /// Enter after a long paste typed at `typedAt`, if nothing since makes
    /// it someone else's prompt. An empty process snapshot is read again.
    private func pressEnter(
        after typedAt: TimeInterval, into pty: PtySession, for process: ProcessInstance?, tries: Int = 3,
        unsent: @escaping @MainActor @Sendable (UnsentMessage) -> Void
    ) {
        guard workspaces.contains(where: { !$0.isClosing && $0.columns.contains { $0.pty === pty } }) else { return unsent(.left) }
        let snapshot = ProcessSnapshot()
        if snapshot.isEmpty, tries > 1 {
            return DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.pressEnter(after: typedAt, into: pty, for: process, tries: tries - 1, unsent: unsent)
            }
        }
        guard !snapshot.isEmpty else { return unsent(.inPrompt(why: "Nirux couldn't read the running processes")) }
        // The paste's own keys are its draft: anything since is someone's.
        guard pty.lastInputAt == typedAt, pty.lastDraftInputAt == typedAt, !pty.dialogWaitsForKeys,
              pty.foregroundProcess(snapshot: snapshot)?.instance == process
        else { return unsent(.inPrompt(why: "someone typed meanwhile or a dialog opened")) }
        pty.sendRaw("\r")
    }

    /// The column a Mission message is typed into: the parent's for a
    /// question or a completion, the child's for the rest.
    func missionRecipient(of delivery: MissionStore.AcceptedEvent) -> ColumnState? {
        missionEnd(delivery.mission, parent: Self.goesToParent(delivery.event))?.column
    }

    nonisolated static func goesToParent(_ event: MissionEvent) -> Bool {
        event.kind == .question || event.kind == .completed
    }

    /// A Mission's parent or child: its workspace, and the column its agent
    /// runs in, if it still has one.
    func missionEnd(_ mission: Mission, parent: Bool) -> (workspace: WorkspaceState, column: ColumnState?)? {
        guard let workspace = workspaces.first(where: { $0.id == (parent ? mission.parentWorkspaceID : mission.childWorkspaceID) })
        else { return nil }
        let agentUUID = parent ? mission.parentAgentUUID : mission.childAgentUUID
        return (workspace, workspace.columns.first { $0.agentUUID == agentUUID })
    }

    /// A `tell` goes only to the `claude` that ran when it was sent, or one
    /// holding the conversation it was sent to (a restart resuming it). The
    /// rest goes to whichever runs now: the child ended its turn to wait for
    /// its answer, and a parent restored since resumed its conversation.
    func runningSince(of event: MissionEvent, in column: ColumnState?, snapshot: ProcessSnapshot, now: TimeInterval) -> TimeInterval {
        guard event.kind == .instruction else { return now }
        let held = column.flatMap { conversation(of: $0, snapshot: snapshot) }
        return held != nil && held == event.childSessionID ? now : event.timestamp
    }

    /// The conversation `column`'s `claude` confirmed through its own
    /// hooks, while it runs; the one it will resume, while it waits to.
    func conversation(of column: ColumnState, snapshot: ProcessSnapshot) -> String? {
        if case .claude(resume: .session(let resumes)?, _)? = column.deferredAgent?.agent { return resumes }
        return column.confirmedClaudeSessionID(foregroundProcess: column.pty?.foregroundProcess(snapshot: snapshot))
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
                  let paste = TypedPromptSanitizer.bracketedPaste(for: notice.text)
            else { return true }
            // A user's answer it carries may be long.
            let lead = MissionPromptText.quoted(workspace.title)
            typeMissionPrompt(paste, into: pty, keepingInFront: pty.foregroundProcess(snapshot: snapshot)?.instance) { [weak self] unsent in
                guard let self else { return }
                switch unsent {
                case .left: self.pendingLeadNotices.append(notice)
                case .inPrompt(let why): self.showToast("All of a message for “\(lead)” is in its prompt, unsent: \(why). Press Enter there to send it.")
                case .cut: self.showToast("Only the start of a message for “\(lead)” went into its prompt: its agent stopped reading. Clear it there.")
                }
            }
            missionWaits.noteTyped(into: column, at: now)
            return false
        }
    }

    static func currentMissionHandoffsEnabled() -> Bool {
        PersistedSettings.effective(Persistence.load()?.settings).missionHandoffsEnabled
    }

    /// A ⌘N task's Mission, reporting to `parent` (see
    /// `NewTask.Request.reportsTo`); nil when that parent can't take one.
    /// `reportsToTask`: a task's agent asked for it with its tools, which
    /// answer through the app, so its terminal needs no Mission variables
    /// and the setting doesn't matter; it must still be open, and no Lead's.
    func createMission(
        parent: NewTask.MissionParent, childWorkspaceID: String, childAgentUUID: String,
        agent: NiruxApp.WorkspaceAgent, branch: String, reportsToTask: Bool = false
    ) -> Mission? {
        let valid = reportsToTask
            ? requestingTerminal(workspaceID: parent.workspaceID, agentUUID: parent.agentUUID).flatMap { requester in
                requester.workspace.isLead ? nil : (workspaceID: requester.workspace.id, agentUUID: parent.agentUUID, isLead: false)
            }
            : validMissionParent(workspaceID: parent.workspaceID, agentUUID: parent.agentUUID)
        guard let valid else { return nil }
        let request = MissionCreationRequest(
            id: UUID().uuidString,
            parentWorkspaceID: valid.workspaceID,
            parentAgentUUID: valid.agentUUID,
            childWorkspaceID: childWorkspaceID,
            childAgentUUID: childAgentUUID,
            childAgentKind: agent.rawValue,
            branch: branch,
            reportsToLead: valid.isLead,
            reportsToTask: reportsToTask
        )
        return MissionStore.shared.create(request, enabled: Self.currentMissionHandoffsEnabled())
    }

    /// The parent a new worktree's Mission reports to: any agent's column
    /// with Mission handoffs on, a space's Lead whatever the setting.
    private func validMissionParent(
        workspaceID: String?, agentUUID: String?
    ) -> (workspaceID: String, agentUUID: String, isLead: Bool)? {
        validMissionParent(requestingTerminal(workspaceID: workspaceID, agentUUID: agentUUID))
    }

    /// A Mission's parent: a Lead, or Missions on, and a terminal that can
    /// answer its child (`terminalCarriesMissions`).
    private func validMissionParent(
        _ requester: (workspace: WorkspaceState, column: ColumnState)?
    ) -> (workspaceID: String, agentUUID: String, isLead: Bool)? {
        // The state file read last.
        guard let requester, let agentUUID = requester.column.agentUUID,
              Self.terminalCarriesMissions(requester.column.launchEnvironment),
              requester.workspace.isLead || Self.currentMissionHandoffsEnabled()
        else { return nil }
        return (requester.workspace.id, agentUUID, requester.workspace.isLead)
    }

    /// The open workspace a request names, and its terminal that sent it:
    /// a workspace id alone (a hand-written URL, an old copy of the skill)
    /// links nothing.
    func requestingTerminal(workspaceID: String?, agentUUID: String?) -> (workspace: WorkspaceState, column: ColumnState)? {
        guard let workspaceID, let agentUUID, UUID(uuidString: workspaceID) != nil, UUID(uuidString: agentUUID) != nil,
              let workspace = workspaces.first(where: { $0.id == workspaceID && !$0.isClosing }),
              let column = workspace.columns.first(where: { $0.agentUUID == agentUUID })
        else { return nil }
        return (workspace, column)
    }

    /// A terminal started with the Mission variables and a `NIRUX_CLI_PATH`
    /// still there: its agent can answer a child. One started before
    /// Missions were turned on, or whose Nirux was moved since, can't (the
    /// skill used to check both itself).
    nonisolated static func terminalCarriesMissions(_ environment: [String: String]?) -> Bool {
        guard environment?["NIRUX_MISSION_HANDOFFS"] == "1", let cli = environment?["NIRUX_CLI_PATH"] else { return false }
        guard FileManager.default.isExecutableFile(atPath: cli) else {
            NSLog("[Mission] No Mission: the asking terminal's Nirux is gone (%@)", cli)
            return false
        }
        return true
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
