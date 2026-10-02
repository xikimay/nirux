import Foundation

/// Reads `ClaudeUsageLimitsFile` for the title bar while the indicator is
/// on: every `interval`, reloading only when the file was replaced. Each
/// tick also drops the windows that reset and refreshes the countdowns.
@MainActor
final class ClaudeUsageLimitsMonitor {
    static let interval: TimeInterval = 10

    /// The readings that still apply, or nil (off, nothing reported, all
    /// reset, or no status line of Nirux's to report them), and the time
    /// they were judged at.
    var onUpdate: ((ClaudeUsageLimits?, TimeInterval) -> Void)?
    private(set) var isEnabled = false

    private let url: URL
    /// Whether Claude Code's status line is Nirux's. Once the user sets one
    /// of their own (Claude Code's `/statusline`, say), no report comes:
    /// the last ones would stay on screen for up to a week.
    private let isReporting: () -> Bool
    private var loaded: ClaudeUsageLimits?
    /// What identified the file last loaded: each write replaces it (a new
    /// inode), so this changes even within one timestamp tick.
    private var loadedVersion: FileVersion?
    private var timer: Timer?

    private struct FileVersion: Equatable {
        let modified: Date?
        let inode: Int?
    }

    init(
        url: URL = ClaudeUsageLimitsFile.url,
        isReporting: @escaping () -> Bool = { AgentHookInstaller.claudeStatusLineState() == .nirux }
    ) {
        self.url = url
        self.isReporting = isReporting
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        guard enabled else {
            timer?.invalidate()
            timer = nil
            onUpdate?(nil, Date().timeIntervalSince1970)
            return
        }
        refresh()
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer.tolerance = 2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func refresh(now: Date = Date()) {
        guard isEnabled else { return }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let version = attributes.map {
            FileVersion(modified: $0[.modificationDate] as? Date, inode: ($0[.systemFileNumber] as? NSNumber)?.intValue)
        }
        if version != loadedVersion {
            loaded = version == nil ? nil : ClaudeUsageLimitsFile.load(from: url)
            loadedVersion = version
        }
        let time = now.timeIntervalSince1970
        onUpdate?(isReporting() ? loaded?.current(at: time) : nil, time)
    }
}
