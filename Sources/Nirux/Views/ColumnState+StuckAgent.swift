import AppKit

// MARK: - Agent that died mid-turn

extension ColumnState {
    /// Follow the agent in the foreground, to tell its exit from a suspend
    /// (Ctrl-Z keeps the process alive). Runs on every status refresh,
    /// before the status tick: the machine must still know whether a turn
    /// was in flight.
    func trackForegroundAgent(_ foregroundProcess: ForegroundProcess?, snapshot: ProcessSnapshot, now: TimeInterval) {
        guard let pty else { return }
        if let foregroundProcess, AgentStatusMachine.isRecognizedAgentProcess(foregroundProcess.name) {
            if pty.agentMidTurnExit != nil { pty.clearAgentMidTurnExit() }
            lastForegroundAgent = foregroundProcess
            return
        }
        // An empty snapshot can't tell: decide on the next one.
        guard let agent = lastForegroundAgent, !snapshot.isEmpty else { return }
        lastForegroundAgent = nil
        guard !snapshot.contains(agent.instance) else { return }
        pty.noteAgentExited(AgentMidTurnExit(
            processName: agent.name,
            exitedAt: now,
            sessionID: agent.name == "claude" ? lastConfirmedClaudeSessionID(of: agent.instance) : nil,
            arguments: agent.arguments
        ))
    }

    /// Show an agent's mid-turn exit over the terminal, or take the notice
    /// down (nil) once it no longer applies.
    func showAgentExit(_ exit: AgentMidTurnExit?) {
        guard let exit, pty?.hasExited == false, view.window != nil, let terminal = terminalView else {
            agentExitOverlay?.isHidden = true
            return
        }
        let content = ShellExitedOverlay.Content.agentExited(processName: exit.processName)
        let wasShowing = isShowingAgentExit
        if let overlay = agentExitOverlay {
            guard !wasShowing || overlay.content != content else { return }
            overlay.configure(content)
        } else {
            let overlay = ShellExitedOverlay(content: content)
            overlay.onRestart = { [weak self] in self?.onResumeExitedAgent?() }
            overlay.onDismiss = { [weak self] in self?.dismissAgentExit() }
            view.addSubview(overlay)
            agentExitOverlay = overlay
        }
        // Like the shell's overlay: the find bar would sit under it.
        if !wasShowing { closeFindBar() }
        agentExitOverlay?.frame = terminal.frame
        agentExitOverlay?.isHidden = false
    }

    /// The user dealt with the exit (Dismiss, or typing at the shell).
    func dismissAgentExit() {
        pty?.clearAgentMidTurnExit()
        agentExitOverlay?.isHidden = true
    }

    var isShowingAgentExit: Bool { agentExitOverlay?.isHidden == false }

    /// A keystroke for the terminal while the notice shows.
    func dismissAgentExitOnTyping() {
        if isShowingAgentExit { dismissAgentExit() }
    }
}
