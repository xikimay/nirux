import AppKit

/// Checks the AWS SSO sessions at launch, on each activation and every 5
/// minutes, and shows the expired ones on the title-bar badge. A check
/// reads ~/.aws/config and one small file per session; the network probe
/// only runs once a token is inside the CLI's refresh window: about once
/// an hour while online, at each check while offline.
@MainActor
final class AWSSSOMonitor {
    static let interval: TimeInterval = 5 * 60

    private let aws: String
    private let indicator: AWSSSOIndicator
    private var expired: [String: Date] = [:]
    private var isChecking = false

    /// Nil without the AWS CLI: there is nothing to log in with.
    static func start(window: NSWindow) -> AWSSSOMonitor? {
        guard let aws = AWSSSOStatus.installedAWSPath() else { return nil }
        let indicator = AWSSSOIndicator()
        window.addTitlebarAccessoryViewController(indicator)
        let monitor = AWSSSOMonitor(aws: aws, indicator: indicator)
        Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak monitor] _ in
            Task { @MainActor in monitor?.check() }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: NSApp, queue: .main
        ) { [weak monitor] _ in
            MainActor.assumeIsolated { monitor?.check() }
        }
        monitor.check()
        return monitor
    }

    private init(aws: String, indicator: AWSSSOIndicator) {
        self.aws = aws
        self.indicator = indicator
    }

    func check() {
        guard !isChecking else { return }
        isChecking = true
        let aws = aws
        let known = expired
        Task { [weak self] in
            let found = await Task.detached { AWSSSOStatus.expiredSessions(known: known, aws: aws) }.value
            guard let self else { return }
            isChecking = false
            expired = found
            indicator.update(expiredSessions: Array(found.keys))
        }
    }
}
