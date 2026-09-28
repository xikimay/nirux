import AppKit

// MARK: - Keep Mac Awake

extension NiruxApp {
    /// Before the session restore, so the first sidebar refresh after it
    /// already counts the restored agents.
    func setUpKeepAwake(window: NSWindow, shell: NiruxShellView) {
        let indicator = KeepAwakeIndicator()
        window.addTitlebarAccessoryViewController(indicator)
        let controller = KeepAwakeController(enabled: NiruxShellView.currentKeepMacAwakeEnabled())
        controller.onChange = { [weak controller, weak indicator] in
            guard let controller else { return }
            indicator?.update(isActive: controller.isActive, workingAgentCount: controller.workingAgentCount)
        }
        controller.onRefresh = { [weak shell] in
            shell?.refreshAgentStatusInBackground()
        }
        keepAwakeIndicator = indicator
        keepAwakeController = controller
        shell.keepAwake = controller
    }
}
