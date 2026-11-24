import AppKit

// MARK: - Keep Mac Awake

extension NiruxApp {
    /// Before the session restore, so the first sidebar refresh after it
    /// already counts the restored agents.
    func setUpKeepAwake(window: NSWindow, shell: NiruxShellView) {
        let indicator = KeepAwakeIndicator()
        window.addTitlebarAccessoryViewController(indicator)
        let controller = KeepAwakeController(
            enabled: NiruxShellView.currentKeepMacAwakeEnabled(),
            waitsForChecks: NiruxShellView.currentKeepMacAwakeForChecksEnabled()
        )
        controller.onChange = { [weak controller, weak indicator] in
            guard let controller else { return }
            let held = controller.heldFor
            indicator?.update(
                isActive: controller.isActive, workingAgentCount: held.agents,
                isMergeQueueRunning: held.queue, isAwaitingChecks: held.checks
            )
        }
        controller.onRefresh = { [weak shell] in
            shell?.refreshAgentStatusInBackground()
        }
        keepAwakeIndicator = indicator
        keepAwakeController = controller
        shell.keepAwake = controller
    }
}
