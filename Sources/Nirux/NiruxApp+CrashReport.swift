import AppKit

// MARK: - Crash Report Notice

/// At launch, a crash of an earlier session shows in the status bar with
/// its summary one click away. Reads the local crash reports only: nothing
/// is sent anywhere.
extension NiruxApp {
    /// ReportCrash writes the report some 30 s after the crash, so a
    /// relaunch right after it finds nothing yet: look again a minute
    /// later, then five minutes after that.
    static let crashReportRecheckDelays: [TimeInterval] = [60, 300]

    func checkForCrashReports(rechecks: ArraySlice<TimeInterval> = crashReportRecheckDelays[...]) {
        guard let scanner = CrashReportScanner.forRunningApp() else { return }
        Self.runOffMain {
            let notice = scanner.check()
            DispatchQueue.main.async { @MainActor [weak self] in
                guard let self else { return }
                if let notice { self.showCrashNotice(notice) }
                // Even after a notice: the report of the crash right before
                // this launch may not be written yet.
                if let delay = rechecks.first {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { @MainActor [weak self] in
                        self?.checkForCrashReports(rechecks: rechecks.dropFirst())
                    }
                }
            }
        }
    }

    /// A notice still on screen absorbs the one a recheck found.
    func showCrashNotice(_ notice: CrashNotice) {
        guard let shell else { return }
        let notice = shell.statusBar.crashNotice.map { $0.merged(with: notice) } ?? notice
        shell.statusBar.onCrashAction = { [weak shell] action in
            guard let notice = shell?.statusBar.crashNotice else { return }
            switch action {
            case .copySummary: CrashNoticeActions.copySummary(of: notice)
            case .openReport: CrashNoticeActions.openReport(of: notice)
            }
        }
        shell.statusBar.showCrash(notice)
    }

    /// Runs `work` on a background queue, never on the main actor: the
    /// parameter is `@Sendable`, so a closure written in this `@MainActor`
    /// type does not inherit its isolation (see #48).
    nonisolated private static func runOffMain(_ work: @escaping @Sendable () -> Void) {
        DispatchQueue.global(qos: .utility).async(execute: work)
    }
}

@MainActor
enum CrashNoticeActions {
    static func copySummary(of notice: CrashNotice, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(notice.summary, forType: .string)
    }

    /// Opens the report in Console; reveals it in Finder when Console can't
    /// open it, or its folder when the report is gone.
    static func openReport(of notice: CrashNotice) {
        let url = notice.reportURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
            return
        }
        guard let console = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Console") else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return
        }
        open(url, with: console)
    }

    /// Nonisolated with a `@Sendable` completion: NSWorkspace calls it on a
    /// background queue.
    nonisolated private static func open(_ url: URL, with application: URL) {
        NSWorkspace.shared.open(
            [url], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration()
        ) { @Sendable _, error in
            guard error != nil else { return }
            DispatchQueue.main.async { @MainActor in
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }
}
