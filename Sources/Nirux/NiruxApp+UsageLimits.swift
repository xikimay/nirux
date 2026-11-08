import AppKit

// MARK: - Claude usage limits

extension NiruxApp {
    static func currentShowClaudeUsageLimits() -> Bool {
        Persistence.load()?.settings?.showClaudeUsageLimits == true
    }

    /// What the launch install applies: the saved option, or nil (leave the
    /// status line as it is) when there is no saved state to read, say a
    /// state file that can't be decoded.
    static func savedClaudeStatusLineOption() -> Bool? {
        Persistence.load()?.settings?.showClaudeUsageLimits
    }

    /// After the title bar's buttons, before the keep-awake cup: trailing
    /// accessories line up from the window's edge in the order they're
    /// added, so the cup comes and goes on the limits' left.
    func setUpUsageLimits(window: NSWindow) {
        let indicator = ClaudeUsageIndicator()
        window.addTitlebarAccessoryViewController(indicator)
        let monitor = ClaudeUsageLimitsMonitor()
        monitor.onUpdate = { [weak indicator] limits, now in
            indicator?.update(limits: limits, now: now)
        }
        usageLimitsIndicator = indicator
        usageLimitsMonitor = monitor
        monitor.setEnabled(Self.currentShowClaudeUsageLimits())
    }

    /// Settings turned the option on or off: install or take back the
    /// status line, then show or hide the indicator. Off, what was reported
    /// is forgotten: turned on again days later, the indicator waits for a
    /// new report rather than show an old one.
    func applyUsageLimits(enabled: Bool) {
        claudeStatusLineInstaller(enabled)
        if !enabled { ClaudeUsageLimitsFile.remove() }
        usageLimitsMonitor?.setEnabled(enabled)
    }
}
