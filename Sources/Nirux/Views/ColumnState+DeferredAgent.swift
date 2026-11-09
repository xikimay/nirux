import AppKit

// MARK: - Restored agent waiting to resume

extension ColumnState {
    var isAwaitingResume: Bool { deferredAgent != nil }

    /// Its terminal runs, or will in a moment, yet was never given a size:
    /// it has no surface then, and what it prints is lost (see
    /// `NiruxShellView.sizeRunningTerminalsOffScreen`). A column whose
    /// agent waits to resume runs nothing; a shell restored at launch can
    /// wait to be shown (`isRestoredShell`).
    var runsWithoutSize: Bool {
        guard let terminalView, !isAwaitingResume, !isRestoredShell else { return false }
        return terminalView.frame.isEmpty
    }

    /// Where the agent will resume, while it waits to.
    var awaitingResumeDirectory: String? { isAwaitingResume ? launchDirectory : nil }

    /// Cover the terminal with what the column holds until its agent
    /// resumes. The terminal stays empty: no shell runs yet.
    func showDeferredAgentNotice(_ agent: DeferredAgentLaunch) {
        let overlay = ShellExitedOverlay(content: .notResumed(
            processName: agent.processName, summary: agent.summary
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
