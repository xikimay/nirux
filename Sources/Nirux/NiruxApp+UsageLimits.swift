import AppKit

// MARK: - Claude usage limits

extension NiruxApp {
    static func currentShowClaudeUsageLimits() -> Bool {
        Persistence.load()?.settings?.showClaudeUsageLimits == true
    }

    /// Before the keep-awake cup: the first trailing accessory takes the
    /// window's edge, so the cup comes and goes on its left.
    func setUpUsageLimits(window: NSWindow) {
        let indicator = ClaudeUsageIndicator()
        window.addTitlebarAccessoryViewController(indicator)
        let monitor = ClaudeUsageLimitsMonitor()
        monitor.onUpdate = { [weak indicator] limits in
            indicator?.update(limits: limits, now: Date().timeIntervalSince1970)
        }
        usageLimitsIndicator = indicator
        usageLimitsMonitor = monitor
        monitor.setEnabled(Self.currentShowClaudeUsageLimits())
    }

    /// Settings saved the option: install or take back the status line,
    /// then show or hide the indicator.
    func applyUsageLimits(enabled: Bool) {
        claudeStatusLineInstaller(enabled)
        usageLimitsMonitor?.setEnabled(enabled)
    }
}
