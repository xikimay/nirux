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
    /// from `repoRoot`'s HEAD. `title` names the workspace; nil: the branch.
    func createWorktreeWorkspace(
        branch: String,
        title: String? = nil,
        repoRoot: String,
        agent: CodingAgent? = .claude,
        handoverPath: String? = nil,
        profileID requestedProfileID: String? = nil,
        parentWorkspaceID: String? = nil,
        parentAgentUUID: String? = nil,
        startsFromHead: Bool = false,
        startedOutsideNirux: Bool = false,
        confirmedCodexLaunch: ConfirmedCodexLaunch? = nil
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
                    filename: HandoverFile.filename(for: agent ?? .claude)
                ) {
                case .success:
                    deliveredHandover = true
                case .failure(let error): handoverError = error
                }
            }
            DispatchQueue.main.async { [weak self, deliveredHandover, handoverError] in
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
                            reportsToLead: parent.isLead,
                            // The agent that asked wrote its handover.
                            startedByParent: true
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
                    let openWorktree: @MainActor (CodingAgent?, CodexLaunchMode?) -> Void = {
                        [missionID, reportsToLead] agent, mode in
                        self.addWorkspace(
                            title: title ?? branch,
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
                            codexMode: mode, startedByAgent: !startedOutsideNirux,
                            setupScript: firstSetup ? self.setupScript(for: decision) : nil
                        )
                        self.saveState()
                        if decision.reason == .general { self.presentSpaceArrival(workspaceID: childWorkspaceID) }
                    }
                    // The first sheet approved the worktree and handover. Declining a different space's
                    // Codex mode leaves that work accessible in a plain terminal.
                    self.withConfirmedCodexLaunch(confirmedCodexLaunch, required: startedOutsideNirux && agent == .codex,
                                                  in: decision.spaceID, folder: path, ifDeclined: {
                        openWorktree(nil, nil)
                    }) { mode in openWorktree(agent, mode) }
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

    /// Types each pending Mission message into its recipient's prompt if
    /// that prompt is free (see `MissionStore.pendingPromptDeliveries`); the
    /// others wait for that agent's next turn end. Runs when a Mission event
    /// arrives and when a turn ends.
    /// `seenAtPrompt`: a column whose `claude`, with no prompt yet, the user
    /// says sits at its prompt (`typeWaitingMessagesNow`): one message goes
    /// in on their word.
    @discardableResult
    func typeMissionMessages(seenAtPrompt: UUID? = nil) -> TypedOnSight? {
        var onSight = typeLeadNotices(seenAtPrompt: seenAtPrompt)
        typeRuleDecisions()
        let handoffsEnabled = Self.currentMissionHandoffsEnabled()
        guard MissionStore.shared.pendingPromptDeliveries().contains(where: { $0.mission.isCarried(handoffsEnabled: handoffsEnabled) })
        else { return onSight }
        // Apply what may still wait out a queue's drain debounce: a dialog
        // that opened, a prompt that went in, or the child's `completed`,
        // which must not close the Mission after a `tell` reopened it.
        guard hooksReadBeforeTyping() else { return onSight }
        guard MissionEventCenter.shared.drain() else {
            typeMissionMessagesSoon()
            return onSight
        }
        let snapshot = ProcessSnapshot()
        let now = Date().timeIntervalSince1970
        var typedAny = false
        for delivery in MissionStore.shared.pendingPromptDeliveries(now: now)
        where delivery.mission.isCarried(handoffsEnabled: handoffsEnabled) {
            let mission = delivery.mission
            let recipientID = Self.goesToParent(delivery.event) ? mission.parentWorkspaceID : mission.childWorkspaceID
            guard !resumingTasks.contains(recipientID) else { continue }
            let childWorkspace = workspaces.first { $0.id == mission.childWorkspaceID }
            let parentWorkspace = workspaces.first { $0.id == mission.parentWorkspaceID }
            guard let recipient = missionRecipient(of: delivery), let pty = recipient.pty,
                  let agent = Self.recipientAgent(of: delivery, foreground: pty.foregroundProcess(snapshot: snapshot))
            else { continue }
            if agent == .codex {
                guard let delivery = MissionStore.shared.pendingPromptDelivery(delivery) else { continue }
                queueForCodex(delivery, childTitle: childWorkspace?.title, parentTitle: parentWorkspace?.title, snapshot: snapshot, now: now)
                continue
            }
            guard !missionWaits.typing.contains(delivery.event.id) else { continue }
            let refusal = pty.missionPromptRefusal(
                runningSince: runningSince(of: delivery.event, in: recipient, snapshot: snapshot, now: now), snapshot: snapshot,
                seenByUser: recipient.id == seenAtPrompt, agent: agent
            )
            if recipient.id == seenAtPrompt, onSight == nil { onSight = .refused(refusal) }
            guard refusal == nil,
                  let delivery = MissionStore.shared.pendingPromptDelivery(delivery),
                  let text = MissionPromptText.text(
                      for: delivery, childTitle: childWorkspace?.title, parentTitle: parentWorkspace?.title
                  ),
                  let paste = TypedPromptSanitizer.bracketedPaste(for: text)
            else { continue }
            let toChild = !Self.goesToParent(delivery.event)
            let byUser = delivery.event.answeredByUser == true
            // Its sender hears what stayed in the prompt: an agent, about its own message.
            let sender = toChild && !byUser
                ? delivery.event.leadSender ?? NewTask.MissionParent(workspaceID: mission.parentWorkspaceID, agentUUID: mission.parentAgentUUID)
                : nil
            let recipientTitle = MissionPromptText.quoted((toChild ? childWorkspace : parentWorkspace)?.title ?? mission.branch)
            missionWaits.typing.insert(delivery.event.id)
            let front = pty.foregroundProcess(snapshot: snapshot)?.instance
            typeMissionPrompt(paste, into: pty, keepingInFront: front, typedByNirux: !byUser) { [weak self] typed in
                guard let self else { return }
                self.finishTyping(delivery, typed, at: now)
                self.reportUnsent(typed, what: byUser ? "your answer" : "a Mission message", for: recipientTitle, telling: sender)
                // agy says when it takes a prompt (OSC 7501 working).
                guard typed == .sent, agent == .agy, let front else { return }
                self.checkStarted(front, in: pty, since: now) { shell in
                    if let sender {
                        shell.tellProposer(sender, "Your message to “\(recipientTitle)” was typed into its prompt, but Antigravity hasn't "
                            + "started it: it may still sit there. Look at “\(recipientTitle)” before sending it again.")
                    }
                    shell.showToast("Antigravity in “\(recipientTitle)” hasn't started the Mission message typed into it.")
                }
            }
            missionWaits.noteTyped(into: recipient, at: now)
            if recipient.id == seenAtPrompt { onSight = .typed }
            typedAny = true
        }
        // The cards' "Asking …" and "Answer … ready" rows follow.
        if typedAny { updateSidebar(snapshot: snapshot) }
        return onSight
    }

    /// What became of the user's word that a column's `claude` sits at its
    /// prompt (`typeMissionMessages(seenAtPrompt:)`): one went in, or why
    /// none did (nil: its prompt looked free, yet it couldn't be typed).
    enum TypedOnSight: Equatable {
        case typed
        case refused(AgentPromptRefusal?)
    }

    /// Applies the hook queue before deciding what to type into a prompt: a
    /// dialog that opened, a prompt that went in. False when a receiver was
    /// writing to it, and Mission typing passes again in a moment.
    func hooksReadBeforeTyping() -> Bool {
        guard AgentHookCenter.shared.drain() else {
            typeMissionMessagesSoon()
            return false
        }
        return true
    }

    private func typeMissionMessagesSoon() {
        guard !missionWaits.typingPassSoon else { return }
        missionWaits.typingPassSoon = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.missionWaits.typingPassSoon = false
            self?.typeMissionMessages()
        }
    }

    nonisolated static func recipientAgent(of delivery: MissionStore.AcceptedEvent, foreground: ForegroundProcess?) -> CodingAgent? {
        guard goesToParent(delivery.event) else { return delivery.mission.deliveryAgent }
        return foreground?.interactiveAgent.flatMap { $0.isLaunchable ? $0 : nil }
    }

    private func queueForCodex(
        _ delivery: MissionStore.AcceptedEvent, childTitle: String?, parentTitle: String?, snapshot: ProcessSnapshot,
        now: TimeInterval
    ) {
        let id = delivery.event.id
        guard !missionWaits.typing.contains(id), let column = missionRecipient(of: delivery),
              let text = MissionPromptText.text(for: delivery, childTitle: childTitle, parentTitle: parentTitle)
        else { return }
        let toParent = Self.goesToParent(delivery.event)
        let sender = toParent || delivery.event.answeredByUser == true ? nil : delivery.event.leadSender
            ?? NewTask.MissionParent(workspaceID: delivery.mission.parentWorkspaceID, agentUUID: delivery.mission.parentAgentUUID)
        let since = runningSince(of: delivery.event, in: column, snapshot: snapshot, now: now)
        missionWaits.typing.insert(id)
        let queued = queueForCodex(text, id: id, in: column, runningSince: since, snapshot: snapshot, now: now,
                                   title: (toParent ? parentTitle : childTitle) ?? delivery.mission.branch, sender: sender) { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .queued: self.finishTyping(delivery, .sent, at: now)
            case .unconfirmed: self.finishTyping(delivery, .cut, at: now)
            case .refused: self.missionWaits.typing.remove(id)
            }
        }
        if !queued { missionWaits.typing.remove(id) }
    }

    @discardableResult
    private func queueForCodex(
        _ text: String, id: String, in column: ColumnState, runningSince: TimeInterval, snapshot: ProcessSnapshot,
        now: TimeInterval, title: String, sender: NewTask.MissionParent?, done: @escaping @MainActor (CodexQueue.Outcome) -> Void
    ) -> Bool {
        guard missionWaits.tries[id, default: 0] < Self.missionTypingTries, !missionWaits.codexQueuing.contains(column.id),
              column.codexMissionRefusal(runningSince: runningSince, snapshot: snapshot) == nil, let pty = column.pty,
              let codex = pty.foregroundProcess(snapshot: snapshot), let thread = column.provenCodexSessionID(of: codex),
              let command = CodexQueue.command(of: codex), let message = TypedPromptSanitizer.sanitize(text)
        else { return false }
        let columnID = column.id
        let recipient = MissionPromptText.quoted(title)
        missionWaits.codexQueuing.insert(columnID)
        let request = CodexQueue.Request(
            command: command, thread: thread, message: message, codexHome: ProcessSnapshot.environment(of: codex.instance.pid)["CODEX_HOME"]
        )
        sideEffects.queueCodexMessage(request) { [weak self] outcome in
            guard let self else { return }
            self.missionWaits.codexQueuing.remove(columnID)
            done(outcome)
            switch outcome {
            case .queued:
                self.updateSidebar()
                self.checkStarted(codex.instance, in: pty, since: now) { shell in
                    if let sender {
                        shell.tellProposer(sender, "Your message to “\(recipient)” is in its Codex's queue, but Codex hasn't started it yet: "
                            + "it starts it once that conversation is idle. Don't send it again.")
                    }
                    shell.showToast("Codex in “\(recipient)” hasn't started the Mission message in its queue yet.")
                }
            case .unconfirmed:
                if let sender {
                    self.tellProposer(sender, "Your message to “\(recipient)” may be in its Codex's queue: Codex didn't answer within "
                        + "\(Int(CodexQueue.timeout)) seconds, and Nirux won't hand it over again. Check “\(recipient)” before sending it again.")
                }
                self.showToast("Codex in “\(recipient)” didn't confirm the Mission message Nirux handed it.")
            case .refused(let why):
                self.missionWaits.tries[id, default: 0] += 1
                MissionWaitLog.logger.error(
                    "Codex didn't queue a Mission message: id=\(id.prefix(8), privacy: .public) why=\(why, privacy: .public)"
                )
            }
        }
        missionWaits.noteTyped(into: column, at: now)
        return true
    }

    /// Runs `notice` when `process`, an agent that says its state (Codex,
    /// Antigravity), started no turn `MissionWaitState.startWait` after
    /// `sentAt`, when Nirux handed it a message.
    private func checkStarted(
        _ process: ProcessInstance, in pty: PtySession, since sentAt: TimeInterval, notice: @escaping @MainActor (NiruxShellView) -> Void
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + missionWaits.startWait) { [weak self, weak pty] in
            guard let self, let pty, !pty.startedTurn(since: sentAt, by: process) else { return }
            notice(self)
        }
    }

    /// Records what became of a Mission message Nirux typed: typed once its
    /// Enter went in, and never typed again once any of it reached the
    /// prompt (a tell is given up then, an answer or a question counts as
    /// typed). One whose agent left before any of it did waits for the next
    /// free prompt.
    private func finishTyping(_ delivery: MissionStore.AcceptedEvent, _ typed: TypedMessage, at timestamp: TimeInterval) {
        let store = MissionStore.shared
        let id = delivery.event.id
        switch typed {
        case .left:
            break
        case .sent, .inPrompt, .cut:
            let recorded = typed != .sent && delivery.event.kind == .instruction
                ? store.noteInstructions(heldNotice: [], expired: [id], at: Date().timeIntervalSince1970)
                : store.markTyped(delivery, at: delivery.event.kind == .question ? timestamp : Date().timeIntervalSince1970)
            // Unrecorded, it stays out of reach: typed again, it would go in twice.
            guard recorded else {
                return MissionWaitLog.logger.error("A typed Mission message wasn't recorded: id=\(id.prefix(8), privacy: .public)")
            }
        }
        missionWaits.typing.remove(id)
    }

    /// Tells the user, and the message's `sender` when one is given, what
    /// of `what` stayed in `recipient`'s prompt unsent.
    func reportUnsent(_ typed: TypedMessage, what: String, for recipient: String, telling sender: NewTask.MissionParent?) {
        let (user, writer): (String, String)
        switch typed {
        case .sent, .left:
            return
        case .inPrompt(let why):
            user = "All of \(what) for “\(recipient)” is in its prompt, unsent: \(why). Press Enter there to send it."
            writer = "Your message to “\(recipient)” is in its prompt but wasn't sent: \(why). "
                + "It waits there for someone to press Enter or clear it."
        case .cut:
            user = "Only the start of \(what) for “\(recipient)” went into its prompt: it stopped taking it. Clear it there."
            writer = "Your message to “\(recipient)” was cut off: only its start reached its prompt, and Nirux won't type it again. "
                + "Send it again (an answer's rest with tell) once its prompt is clear."
        }
        if let sender { tellProposer(sender, writer) }
        showToast(user)
    }

    /// What became of a Mission message Nirux typed.
    enum TypedMessage: Equatable, Sendable {
        /// All of it, and its Enter.
        case sent
        /// None of it reached the prompt: its agent left, or its task closed.
        case left
        /// All of it is in the prompt: Nirux didn't press Enter, for `why`.
        case inPrompt(why: String)
        /// Only its start reached the prompt.
        case cut
    }

    /// `paste` (a bracketed paste) and Enter into `pty`: in one write when
    /// the terminal's input queue holds it with its Enter, else as the agent
    /// reads it (`PtySession.pasteInBackground`), Enter once it is all in,
    /// for the agent it went to, with no key since and no dialog. `done`
    /// says what became of it.
    /// `typedByNirux` false: the user's own words (an answer from the
    /// popover), their prompt.
    func typeMissionPrompt(
        _ paste: String, into pty: PtySession, keepingInFront process: ProcessInstance?, typedByNirux: Bool = true,
        done: @escaping @MainActor @Sendable (TypedMessage) -> Void
    ) {
        guard paste.utf8.count + 1 > PtySession.inputQueueBytes else {
            pty.sendRaw(paste + "\r", typedByNirux: typedByNirux)
            return done(.sent)
        }
        pty.pasteInBackground(paste, keepingInFront: process, cancelled: { false }) { [weak self] result, typedAt in
            guard result.outcome == .pasted else { return done(result.written > 0 ? .cut : .left) }
            // After the keys ghostty routed meanwhile, noted the same way.
            DispatchQueue.main.async {
                guard let self else { return done(.inPrompt(why: "Nirux is closing")) }
                self.pressEnter(after: typedAt, into: pty, for: process, typedByNirux: typedByNirux, done: done)
            }
        }
    }

    /// Enter after a long paste typed at `typedAt`, if nothing since makes
    /// it someone else's prompt. An empty process snapshot is read again.
    /// A session record that shows its `claude` waiting on a screen is
    /// read again this many times, `recordRereadDelay` apart, before Enter
    /// is given up: Claude Code writes it after the change, so it may still
    /// show a dialog the hooks saw close.
    nonisolated static let recordRereads = 4
    nonisolated static let recordRereadDelay: TimeInterval = 0.5

    private func pressEnter(
        after typedAt: TimeInterval, into pty: PtySession, for process: ProcessInstance?, typedByNirux: Bool, tries: Int = 3,
        rereads: Int = recordRereads, done: @escaping @MainActor @Sendable (TypedMessage) -> Void
    ) {
        guard workspaces.contains(where: { !$0.isClosing && $0.columns.contains { $0.pty === pty } }) else { return done(.left) }
        let snapshot = ProcessSnapshot()
        func again(after delay: TimeInterval, tries: Int, rereads: Int) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return done(.inPrompt(why: "Nirux is closing")) }
                self.pressEnter(
                    after: typedAt, into: pty, for: process, typedByNirux: typedByNirux, tries: tries, rereads: rereads, done: done
                )
            }
        }
        if snapshot.isEmpty, tries > 1 { return again(after: 0.5, tries: tries - 1, rereads: rereads) }
        guard !snapshot.isEmpty else { return done(.inPrompt(why: "Nirux couldn't read the running processes")) }
        // The paste's own keys are the last: anything since is someone's.
        guard pty.mayPressEnter(after: typedAt, for: process, snapshot: snapshot)
        else { return done(.inPrompt(why: "someone typed meanwhile or a dialog opened")) }
        if let process, PtySession.sessionRecord(of: process).showsWait(of: process) {
            guard rereads > 0 else { return done(.inPrompt(why: "Claude Code shows a screen of its own")) }
            return again(after: Self.recordRereadDelay, tries: tries, rereads: rereads - 1)
        }
        pty.sendRaw("\r", typedByNirux: typedByNirux)
        done(.sent)
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
        // A conversation not known (an older build, or none confirmed yet) counts as the same.
        guard event.kind == .instruction, let sentTo = event.childSessionID else { return now }
        let held = column.flatMap { conversation(of: $0, foreground: $0.pty?.foregroundProcess(snapshot: snapshot)) }
        return held == sentTo ? now : event.timestamp
    }

    /// The conversation `column`'s `claude` (`foreground`) confirmed through
    /// its own hooks, its `codex` proved, or its `agy` reported, while it
    /// runs; the one it will resume, while it waits to.
    func conversation(of column: ColumnState, foreground: ForegroundProcess?) -> String? {
        if let resumes = column.deferredAgent?.launch.sessionID { return resumes }
        if let foreground, foreground.agent == .codex { return column.provenCodexSessionID(of: foreground) }
        if let foreground, foreground.agent == .agy {
            return column.boundAgySessionID(of: foreground.instance) ?? Self.resumedConversation(ofAgy: foreground.arguments)
        }
        return column.confirmedClaudeSessionID(foregroundProcess: foreground)
    }

    /// The conversation `agy --conversation <id>` (or `=<id>`) resumes.
    nonisolated static func resumedConversation(ofAgy arguments: [String]) -> String? {
        arguments.firstIndex(of: "--conversation").flatMap { arguments[safe: $0 + 1] }
            ?? arguments.lazy.compactMap { $0.hasPrefix("--conversation=") ? String($0.dropFirst("--conversation=".count)) : nil }.first
    }

    /// Types each Lead notice whose Lead's prompt is free; the others wait
    /// for its next turn end, an hour at most. A Lead that is gone drops
    /// its own.
    /// `seenAtPrompt` as `typeMissionMessages` takes it, and what became of
    /// it.
    @discardableResult
    func typeLeadNotices(seenAtPrompt: UUID? = nil) -> TypedOnSight? {
        guard !pendingLeadNotices.isEmpty, hooksReadBeforeTyping() else { return nil }
        let snapshot = ProcessSnapshot()
        let now = Date().timeIntervalSince1970
        var onSight: TypedOnSight?
        let notices = pendingLeadNotices
        pendingLeadNotices.removeAll()
        for notice in notices {
            guard now - notice.queuedAt < MissionEventCLI.parentMessageLifetime,
                  let workspace = workspaces.first(where: { $0.id == notice.workspaceID && !$0.isClosing }),
                  let column = workspace.columns.first(where: { $0.agentUUID == notice.agentUUID })
            else { continue }
            guard let pty = column.pty, let process = pty.foregroundProcess(snapshot: snapshot),
                  let agent = process.interactiveAgent, agent.isLaunchable else {
                pendingLeadNotices.append(notice)
                continue
            }
            guard notice.isFor(agentStartedAt: process.instance.startedAt) || workspace.runsRestartedLead(process) else { continue }
            if agent == .codex {
                pendingLeadNotices.append(notice)
                queueForCodex(notice.text, id: notice.waitID, in: column, runningSince: now, snapshot: snapshot,
                              now: now, title: workspace.title, sender: nil) { [weak self] outcome in
                    if case .refused = outcome { return }
                    self?.pendingLeadNotices.removeAll { $0 == notice }
                }
                continue
            }
            let refusal = pty.missionPromptRefusal(runningSince: now, snapshot: snapshot, seenByUser: column.id == seenAtPrompt, agent: agent)
            if column.id == seenAtPrompt, onSight == nil { onSight = .refused(refusal) }
            guard refusal == nil, let paste = TypedPromptSanitizer.bracketedPaste(for: notice.text) else {
                pendingLeadNotices.append(notice)
                continue
            }
            let lead = MissionPromptText.quoted(workspace.title)
            typeMissionPrompt(paste, into: pty, keepingInFront: process.instance) { [weak self] typed in
                guard let self else { return }
                if typed == .left { self.pendingLeadNotices.append(notice) }
                self.reportUnsent(typed, what: "a message", for: lead, telling: nil)
                if typed == .sent, agent == .agy {
                    self.checkStarted(process.instance, in: pty, since: now) { shell in
                        shell.showToast("Antigravity in “\(lead)” hasn't started the notice typed into it.")
                    }
                }
            }
            missionWaits.noteTyped(into: column, at: now)
            if column.id == seenAtPrompt { onSight = .typed }
        }
        return onSight
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
        agent: CodingAgent, branch: String, reportsToTask: Bool = false, startedByParent: Bool = false
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
            reportsToTask: reportsToTask,
            startedByParent: startedByParent
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
    var waitID: String { "notice-\(queuedAt)" }
    let workspaceID: String
    let agentUUID: String
    let text: String
    /// Epoch seconds.
    let queuedAt: TimeInterval
    /// Only an agent started by then takes it: the one that saw what it
    /// answers. Nil: any.
    var forAgentStartedBy: TimeInterval?

    /// Whether the agent started at `agentStartedAt` (nil: not known)
    /// takes it.
    func isFor(agentStartedAt: TimeInterval?) -> Bool {
        guard let forAgentStartedBy, let agentStartedAt else { return true }
        return agentStartedAt <= forAgentStartedBy
    }
}
