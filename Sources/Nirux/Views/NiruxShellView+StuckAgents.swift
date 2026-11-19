import AppKit

// MARK: - Stuck agents: long waits, failed turns, mid-turn exits, silent turns

extension NiruxShellView {
    /// Minutes a dialog may wait on the user before its agent reads as
    /// stuck, until Settings says otherwise.
    static let defaultStuckAgentMinutes = 10
    /// What Settings offers; 0 turns the check off.
    static let stuckAgentMinuteChoices = [0, 5, 10, 15, 30, 60]

    static func currentStuckAgentMinutes() -> Int {
        Persistence.load()?.settings?.stuckAgentMinutes ?? defaultStuckAgentMinutes
    }

    static func stuckWaitThreshold(minutes: Int) -> TimeInterval? {
        minutes > 0 ? TimeInterval(minutes) * 60 : nil
    }

    static func currentCirclingHintEnabled() -> Bool {
        PersistedSettings.effective(Persistence.load()?.settings).agentCirclingHint
    }

    /// One column on a status refresh: follow its foreground agent, send
    /// the alert a stuck state owes (once), and show or take down the
    /// notice of an agent that died mid-turn. The alert (the in-app flag,
    /// the Dock badge, the system banner) is not for the column on screen
    /// while Nirux is in front: it stays owed, and goes out once the
    /// column or Nirux leaves the front with the agent still stuck.
    func refreshStuckAgent(
        _ column: ColumnState,
        in workspace: WorkspaceState,
        foregroundProcess: ForegroundProcess?,
        snapshot: ProcessSnapshot,
        now: TimeInterval,
        appIsActive: Bool = NSApp.isActive
    ) {
        column.trackForegroundAgent(foregroundProcess, snapshot: snapshot, now: now)
        column.noteTranscriptGrowth(foreground: foregroundProcess, now: now)
        guard let pty = column.pty else { return }
        let onScreen = appIsActive && workspace === activeWorkspace
            && workspace.columns[safe: workspace.focusedIndex] === column
        // Taken only when it can be delivered: an alert goes out once.
        if !onScreen, let reason = pty.takeAgentStuckAlert(
            now: now, waitThreshold: stuckAgentWaitThreshold, foreground: foregroundProcess
        ) {
            column.notifyAgentAttention(reason: reason)
        }
        let stuck = pty.agentStuckState(now: now, waitThreshold: stuckAgentWaitThreshold, foreground: foregroundProcess)
        if case .exitedMidTurn(let exit)? = stuck {
            column.showAgentExit(exit)
        } else {
            column.showAgentExit(nil)
        }
    }

    /// While Nirux is in the background the heartbeat stops, and a blocked
    /// agent fires no hook to refresh anything: a slow watch keeps the
    /// stuck-agent alerts going — the long wait, the confirmed exit — for
    /// the user who is away. Half a minute is well inside the minutes a
    /// wait threshold counts, and one process-table scan per tick is cheap.
    static let stuckWatchInterval: TimeInterval = 30

    func startStuckWatch() {
        guard stuckWatchTimer == nil else { return }
        stuckWatchTimer = Timer.scheduledTimer(withTimeInterval: Self.stuckWatchInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshStuckAgents() }
        }
    }

    func stopStuckWatch() {
        stuckWatchTimer?.invalidate()
        stuckWatchTimer = nil
    }

    /// The stuck-agent pass alone, for every column: no status tick, no
    /// sidebar rebuild.
    func refreshStuckAgents(
        snapshot: ProcessSnapshot = ProcessSnapshot(),
        now: TimeInterval = Date().timeIntervalSince1970,
        appIsActive: Bool = NSApp.isActive
    ) {
        for workspace in workspaces {
            for column in workspace.columns {
                refreshStuckAgent(
                    column, in: workspace,
                    foregroundProcess: column.pty?.foregroundProcess(snapshot: snapshot), snapshot: snapshot, now: now,
                    appIsActive: appIsActive
                )
            }
        }
        closeEndedAgentSessions(now: now)
        // A child's question nobody answered comes to the user away too.
        noteMissionQuestionHandOffs(missionQuestions(foreground: { $0.pty?.foregroundProcess(snapshot: snapshot) }, now: now))
        // The log, and one more try, away too.
        checkMissionWaits(snapshot: snapshot, now: now)
    }

    /// What the column's row shows of a stuck agent.
    func sidebarStuckState(
        of column: ColumnState,
        foregroundProcess: ForegroundProcess?,
        snapshot: ProcessSnapshot,
        now: TimeInterval
    ) -> SidebarStuckState? {
        guard let pty = column.pty else { return nil }
        switch pty.agentStuckState(now: now, waitThreshold: stuckAgentWaitThreshold, foreground: foregroundProcess) {
        case .waiting(let reason, let since)?:
            return .waiting(reason, duration: SidebarRenderer.shortDuration(now - since))
        case .stoppedOnError(let failure)?:
            let resume = SidebarStuckState.Resume(
                pty.agentResumeRefusal(foreground: foregroundProcess, snapshot: snapshot, now: now)
            )
            return .stoppedOnError(kind: failure.kind, detail: failure.detail, failedAt: failure.failedAt, resume: resume)
        case .exitedMidTurn(let exit)?:
            return .exitedMidTurn(processName: exit.processName)
        case .silent(let silence)?:
            return .silent(
                duration: SidebarRenderer.shortDuration(now - silence.startedAt), since: silence.since,
                interruptible: pty.silentInterruptPlan(foreground: foregroundProcess).offersEsc
            )
        case nil:
            return nil
        }
    }

    /// Resume clicked under a column whose turn failed: `continue` goes to
    /// its `claude` only if that is still the failure the button showed
    /// and the agent is back at its prompt (see `resumeRefusal`). Never
    /// sent otherwise, and never without a click.
    func resumeFailedAgent(workspaceIndex: Int, columnIndex: Int, failedAt: TimeInterval) {
        // A prompt or a dialog may still wait out the hook queue's drain
        // debounce: apply it before deciding.
        AgentHookCenter.shared.drain()
        let snapshot = ProcessSnapshot()
        defer { updateSidebar(snapshot: snapshot) }
        guard let (_, pty) = stuckAgentTerminal(workspaceIndex: workspaceIndex, columnIndex: columnIndex) else { return }
        let refusal = pty.agentTurnFailure?.failedAt == failedAt
            ? pty.resumeFailedTurn(snapshot: snapshot, now: Date().timeIntervalSince1970)
            : .notStopped
        if let refusal { showToast(Self.resumeRefusalText(refusal)) }
    }

    /// Interrupt clicked under a turn gone silent: Esc goes to its `claude`
    /// only while that silence lasts (see `interruptSilentTurn`). Never
    /// Enter: the user sends their message again. Once the turn is over,
    /// the Mission messages waiting for it go in.
    func interruptSilentAgent(workspaceIndex: Int, columnIndex: Int, since: TimeInterval) {
        // A hook may still wait out the queue's drain debounce: the agent
        // may have moved on.
        AgentHookCenter.shared.drain()
        let snapshot = ProcessSnapshot()
        defer { updateSidebar(snapshot: snapshot) }
        guard let (column, pty) = stuckAgentTerminal(workspaceIndex: workspaceIndex, columnIndex: columnIndex) else { return }
        let transcript = pty.agentTranscriptPath
        let (sentAt, offset) = (Date(), transcript.map(TranscriptLastMessage.size(of:)) ?? 0)
        let outcome = pty.interruptSilentTurn(
            since: since, waitThreshold: stuckAgentWaitThreshold, snapshot: snapshot, now: sentAt.timeIntervalSince1970
        )
        showToast(Self.interruptText(outcome))
        switch outcome {
        case .promptGivenBack:
            typeMissionMessages()
        case .stopping(let promptAt):
            guard let transcript else { return }
            followInterrupt(transcript: transcript, offset: offset, sentAt: sentAt) { [weak self, weak column, weak pty] shown, read in
                guard let self, let column, let pty, column.pty === pty else { return false }
                guard shown else {
                    if read == Self.interruptReadsBeforeAnswer { self.showToast("Esc went in, but Claude shows no interrupt yet: see its terminal") }
                    guard read < Self.interruptReads else {
                        pty.noteInterruptIgnored(promptAt: promptAt)
                        self.updateSidebar()
                        return false
                    }
                    return true
                }
                // What its hooks said meanwhile.
                AgentHookCenter.shared.drain()
                guard pty.noteInterrupted(promptAt: promptAt) else { return false }
                self.typeMissionMessages()
                self.updateSidebar()
                return false
            }
        case .notSilent, .noProcesses, .refused:
            break
        }
    }

    /// Reads of the transcript, half a second apart, for an Esc Nirux sent:
    /// before saying it didn't take, and in all (a tool slow to stop).
    static let interruptReadsBeforeAnswer = 8
    static let interruptReads = 60

    /// Reads Claude's transcript for the interrupt an Esc Nirux sent at
    /// `sentAt` caused (Claude fires no Stop for it), every half second off
    /// the main thread: `onRead` gets each answer and its count on the main
    /// thread, and says whether to read again.
    func followInterrupt(
        transcript: String, offset: UInt64, sentAt: Date, read: Int = 1,
        onRead: @escaping @MainActor @Sendable (_ shown: Bool, _ read: Int) -> Bool
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            Self.offMain({ TranscriptLastMessage.showsInterrupt(path: transcript, since: sentAt, after: offset) }) { shown in
                guard onRead(shown, read) else { return }
                self?.followInterrupt(transcript: transcript, offset: offset, sentAt: sentAt, read: read + 1, onRead: onRead)
            }
        }
    }

    /// The column a stuck agent's button aims at, and its terminal; nil,
    /// with a toast, once either is gone.
    private func stuckAgentTerminal(workspaceIndex: Int, columnIndex: Int) -> (ColumnState, PtySession)? {
        guard workspaces.indices.contains(workspaceIndex),
              let column = workspaces[workspaceIndex].columns[safe: columnIndex]
        else {
            showToast("That agent’s column was closed")
            return nil
        }
        guard let pty = column.pty else {
            showToast("That column has no terminal")
            return nil
        }
        return (column, pty)
    }

    /// What Interrupt did, or why it pressed nothing.
    static func interruptText(_ outcome: SilentInterrupt) -> String {
        switch outcome {
        case .promptGivenBack: "Esc sent: your prompt is back in Claude’s box. Press Enter there to send it again"
        case .stopping: "Esc sent: Claude stops the turn. Tell it how to go on"
        case .notSilent: "Claude moved on: it isn’t silent any more"
        case .noProcesses: "Nirux couldn’t read the running processes: try again in a moment"
        case .refused(.alreadySent): "Esc already went into this turn"
        case .refused(.dialog): "A dialog waits in its terminal: answer it there"
        case .refused(.typed): "Keys were typed at its prompt since: press Esc in its terminal yourself"
        case .refused: "Press Esc in its terminal: Nirux can’t tell this turn is safe to interrupt"
        }
    }

    /// Why Resume sent nothing.
    static func resumeRefusalText(_ refusal: AgentResumeRefusal) -> String {
        switch refusal {
        case .notStopped: "The agent is no longer stopped on that error"
        case .notClaude: "That Claude session is no longer running"
        case .notAtPrompt: "Claude isn’t back at its prompt yet"
        case .userTyped: "There’s a draft at Claude’s prompt: send “continue” yourself"
        case .needsFix: "This error needs your fix first: see the terminal"
        case .alreadySent: "“continue” was just sent"
        }
    }

    /// Resume Session on an agent that died mid-turn: its conversation
    /// reopens with the flags it ran with, typed at the shell's own prompt
    /// — nothing else may run in front of it, and the user has not typed
    /// there since (typing dismisses the notice).
    func resumeExitedAgent(in workspace: WorkspaceState, column: ColumnState) {
        let snapshot = ProcessSnapshot()
        defer { updateSidebar(snapshot: snapshot) }
        guard let pty = column.pty, !pty.hasExited else { return showToast("That terminal has closed") }
        guard let exit = pty.agentMidTurnExit, exit.processName == "claude" else {
            return showToast("There’s no Claude session to resume there")
        }
        guard let shellPID = pty.shellPID, pty.foregroundInstance(snapshot: snapshot)?.pid == shellPID else {
            return showToast("Something else runs in that terminal now")
        }
        let command = Self.claudeCommand(
            resume: exit.sessionID.map { .session($0) } ?? .picker,
            mode: ClaudeLaunchMode.detect(arguments: exit.arguments) ?? .default,
            briefFile: spaceBriefInjection(for: workspace)?.claudePromptFile,
            settingsFile: claudeSpaceSettingsFile(for: workspace)
        )
        if let sessionID = exit.sessionID {
            column.prepareClaudeResume(sessionID: sessionID)
            sessionResume.noteLaunch(of: sessionID, in: column, now: ProcessInfo.processInfo.systemUptime)
        }
        column.dismissAgentExit()
        pty.sendRaw("\(command)\n")
    }
}
