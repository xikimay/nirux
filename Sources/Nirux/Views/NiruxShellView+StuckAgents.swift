import AppKit

// MARK: - Stuck agents: long waits, failed turns, mid-turn exits

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
        guard workspaces.indices.contains(workspaceIndex),
              let column = workspaces[workspaceIndex].columns[safe: columnIndex]
        else { return showToast("That agent’s column was closed") }
        guard let pty = column.pty else { return showToast("That column has no terminal") }
        let refusal = pty.agentTurnFailure?.failedAt == failedAt
            ? pty.resumeFailedTurn(snapshot: snapshot, now: Date().timeIntervalSince1970)
            : .notStopped
        if let refusal { showToast(Self.resumeRefusalText(refusal)) }
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
            briefFile: spaceBriefInjection(for: workspace)?.claudePromptFile
        )
        if let sessionID = exit.sessionID {
            column.prepareClaudeResume(sessionID: sessionID)
            sessionResume.noteLaunch(of: sessionID, in: column, now: ProcessInfo.processInfo.systemUptime)
        }
        column.dismissAgentExit()
        pty.sendRaw("\(command)\n")
    }
}
