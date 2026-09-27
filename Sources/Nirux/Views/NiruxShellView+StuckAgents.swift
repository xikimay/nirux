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

    /// Where a column sits on a status refresh. `isWatched`: the column the
    /// user looks at, whose stuck state needs no alert while Nirux is in
    /// front.
    struct StuckAgentPlace {
        let workspace: WorkspaceState
        let columnIndex: Int
        let isWatched: Bool
    }

    /// One column on a status refresh: follow its foreground agent, send
    /// the alert a stuck state owes (once), and show or take down the
    /// notice of an agent that died mid-turn.
    func refreshStuckAgent(
        _ column: ColumnState,
        at place: StuckAgentPlace,
        foregroundProcess: ForegroundProcess?,
        snapshot: ProcessSnapshot,
        now: TimeInterval
    ) {
        let workspace = place.workspace
        column.trackForegroundAgent(foregroundProcess, snapshot: snapshot, now: now)
        guard let pty = column.pty else { return }
        let foregroundName = foregroundProcess?.name
        if let reason = pty.takeAgentStuckAlert(
            now: now, waitThreshold: stuckAgentWaitThreshold, foregroundName: foregroundName
        ), !(place.isWatched && NSApp.isActive) {
            column.notifyAgentAttention(reason: reason)
            ActivityStore.shared.record(ActivityEntry(
                category: .attention,
                agentKind: pty.agentMidTurnExit?.processName ?? "claude",
                agentUUID: column.agentUUID,
                workspaceID: workspace.id,
                columnIndex: place.columnIndex,
                workspaceTitle: workspace.title,
                detail: reason.activitySummary,
                timestamp: now
            ))
        }
        let stuck = pty.agentStuckState(now: now, waitThreshold: stuckAgentWaitThreshold, foregroundName: foregroundName)
        if case .exitedMidTurn(let exit)? = stuck {
            column.showAgentExit(exit)
        } else {
            column.showAgentExit(nil)
        }
    }

    /// What the column's row shows of a stuck agent.
    func sidebarStuckState(
        of column: ColumnState,
        foregroundProcess: ForegroundProcess?,
        snapshot: ProcessSnapshot,
        now: TimeInterval
    ) -> SidebarStuckState? {
        guard let pty = column.pty else { return nil }
        switch pty.agentStuckState(now: now, waitThreshold: stuckAgentWaitThreshold, foregroundName: foregroundProcess?.name) {
        case .waiting(let reason, let since)?:
            return .waiting(reason, duration: PilotSidebarRenderer.shortDuration(now - since))
        case .stoppedOnError(let failure)?:
            let resume: SidebarStuckState.Resume
            switch pty.agentResumeRefusal(snapshot: snapshot, now: now) {
            case nil: resume = .offered
            case .alreadySent?: resume = .sending
            case .notStopped?, .notClaude?, .notAtPrompt?: resume = .unavailable
            }
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
              let pty = workspaces[workspaceIndex].columns[safe: columnIndex]?.pty,
              pty.agentTurnFailure?.failedAt == failedAt,
              pty.resumeFailedTurn(snapshot: snapshot, now: Date().timeIntervalSince1970) == nil else {
            NSSound.beep()
            return
        }
    }

    /// Resume Session on an agent that died mid-turn: its conversation
    /// reopens with the flags it ran with, typed at the shell's own prompt
    /// — nothing else may run in front of it, and the user has not typed
    /// there since (typing dismisses the notice).
    func resumeExitedAgent(in workspace: WorkspaceState, column: ColumnState) {
        let snapshot = ProcessSnapshot()
        defer { updateSidebar(snapshot: snapshot) }
        guard let pty = column.pty, !pty.hasExited,
              let exit = pty.agentMidTurnExit, exit.processName == "claude",
              let shellPID = pty.shellPID,
              pty.foregroundInstance(snapshot: snapshot)?.pid == shellPID else {
            NSSound.beep()
            return
        }
        let command = Self.claudeCommand(
            resume: exit.sessionID.map { .session($0) } ?? .picker,
            mode: ClaudeLaunchMode.detect(arguments: exit.arguments) ?? .default,
            briefFile: spaceBriefInjection(for: workspace)?.claudePromptFile
        )
        if let sessionID = exit.sessionID { column.prepareClaudeResume(sessionID: sessionID) }
        column.dismissAgentExit()
        pty.sendRaw("\(command)\n")
    }
}
