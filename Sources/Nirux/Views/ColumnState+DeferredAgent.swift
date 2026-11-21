import AppKit

// MARK: - Restored agent waiting to resume

extension ColumnState {
    func taskAgentSelection(foreground: ForegroundProcess?) -> TaskAgentSelection? {
        if let foreground, let agent = foreground.interactiveAgent {
            return TaskAgentSelection(agent: agent, model: AgentModels.launchModel(arguments: foreground.arguments))
        }
        return deferredAgent.map { TaskAgentSelection(agent: $0.launch.agent, model: $0.launch.model) }
    }

    var isAwaitingResume: Bool { deferredAgent != nil }

    func runningOrDeferredAgent(snapshot: ProcessSnapshot) -> CodingAgent? {
        deferredAgent?.launch.agent ?? pty?.foregroundProcess(snapshot: snapshot)?.interactiveAgent
    }

    /// Where the agent will resume, while it waits to.
    var awaitingResumeDirectory: String? { isAwaitingResume ? launchDirectory : nil }

    /// Cover the terminal with what the column holds until its agent
    /// resumes. The terminal stays empty: no shell runs yet.
    func showDeferredAgentNotice(_ deferred: DeferredAgentLaunch) {
        let overlay = ShellExitedOverlay(content: .notResumed(
            processName: deferred.launch.agent.rawValue, summary: deferred.summary
        ))
        overlay.onRestart = { [weak self] in self?.onResumeDeferredAgent?() }
        if let terminal = terminalView { overlay.frame = terminal.frame }
        view.addSubview(overlay)
        deferredAgentOverlay = overlay
    }

    func hideDeferredAgentNotice() {
        deferredAgentOverlay?.removeFromSuperview()
        deferredAgentOverlay = nil
    }
}
