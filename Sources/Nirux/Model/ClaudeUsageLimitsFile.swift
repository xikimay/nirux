import Foundation

/// One run of Claude Code's status line, as `Nirux --hook claude
/// --statusline` received it: the limits, and what tells news from a repeat.
struct ClaudeStatusLineReport: Equatable, Sendable {
    var limits: ClaudeUsageLimits
    /// `cost.total_api_duration_ms`: it grows with each API response of the
    /// `claude` process, and with nothing else.
    var apiDuration: Double?

    init(limits: ClaudeUsageLimits, apiDuration: Double? = nil) {
        self.limits = limits
        self.apiDuration = apiDuration
    }

    /// Nil without usable limits (see `ClaudeUsageLimits(statusLinePayload:)`).
    init?(payload: [String: Any], now: TimeInterval) {
        guard let limits = ClaudeUsageLimits(statusLinePayload: payload, now: now) else { return nil }
        self.limits = limits
        apiDuration = ((payload["cost"] as? [String: Any])?["total_api_duration_ms"] as? NSNumber)?.doubleValue
    }
}

/// `claude-usage-limits.json` in the state directory: the latest usage
/// limits Claude Code sessions in Nirux reported. Status line runs write it,
/// the app reads it.
enum ClaudeUsageLimitsFile {
    struct Contents: Codable, Equatable {
        var limits = ClaudeUsageLimits()
        /// What each column's `claude` last reported, by NIRUX_AGENT_UUID.
        var columns: [String: ColumnMark] = [:]

        init() {}

        /// Without its marks (an older file), the readings still count.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            limits = try container.decode(ClaudeUsageLimits.self, forKey: .limits)
            columns = (try? container.decodeIfPresent([String: ColumnMark].self, forKey: .columns)) ?? [:]
        }
    }

    struct ColumnMark: Codable, Equatable {
        struct Reading: Codable, Equatable {
            var usedPercentage: Double
            var resetsAt: TimeInterval

            init?(_ window: ClaudeUsageLimits.Window?) {
                guard let window else { return nil }
                usedPercentage = window.usedPercentage
                resetsAt = window.resetsAt
            }
        }

        var apiDuration: Double?
        var fiveHour: Reading?
        var sevenDay: Reading?
        /// When the mark last changed.
        var changedAt: TimeInterval
    }

    /// A column is forgotten a little after the weekly window it could have
    /// reported on, and beyond this many.
    static let columnMemory: TimeInterval = 8 * 24 * 3600
    static let maximumColumns = 256

    /// The status line receiver writes here too: it inherits NIRUX_STATE_DIR
    /// from the terminal, like the hook receiver.
    static var url: URL {
        Persistence.stateDirectory.appendingPathComponent("claude-usage-limits.json")
    }

    static func load(from url: URL = url) -> ClaudeUsageLimits? {
        loadContents(from: url)?.limits
    }

    private static func loadContents(from url: URL) -> Contents? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Contents.self, from: data)
    }

    /// Records what `report` brings that is news; the latest news wins,
    /// whichever column brings it (a session signed in to another account
    /// counts like any other).
    ///
    /// A `claude`'s status line also runs while it is idle (its permission
    /// mode changes, its prompt cache expires, a window resets), and after
    /// `/clear` or `/resume`: each time it repeats the limits of its last
    /// response, which would bring back numbers another column has since
    /// updated. So a window counts only when the column's `claude` got an
    /// API response since its last report (its API time grew), or when the
    /// reading differs from the one the column last reported. `source` is
    /// the column's NIRUX_AGENT_UUID; without one, everything counts.
    ///
    /// Several sessions report at once, so the read-modify-write holds a
    /// lock; a writer that can't get it within `lockWait` gives up, and its
    /// session's next report counts instead. The file is replaced
    /// atomically: the app never reads half of one.
    @discardableResult
    static func record(_ report: ClaudeStatusLineReport, from source: String?, now: TimeInterval, at url: URL = url) -> Bool {
        let lockPath = url.path + ".lock"
        let lock = open(lockPath, O_RDWR | O_CREAT, 0o600)
        guard lock >= 0 else { return false }
        defer { close(lock) }
        guard acquire(lock) else { return false }
        defer { flock(lock, LOCK_UN) }

        let existing = loadContents(from: url) ?? Contents()
        var contents = existing
        var news = report.limits
        if let source {
            let last = contents.columns[source]
            if let last, (report.apiDuration ?? -1) <= (last.apiDuration ?? -1) {
                if ColumnMark.Reading(news.fiveHour) == last.fiveHour { news.fiveHour = nil }
                if ColumnMark.Reading(news.sevenDay) == last.sevenDay { news.sevenDay = nil }
            }
            var mark = ColumnMark(
                apiDuration: report.apiDuration,
                fiveHour: ColumnMark.Reading(report.limits.fiveHour) ?? last?.fiveHour,
                sevenDay: ColumnMark.Reading(report.limits.sevenDay) ?? last?.sevenDay,
                changedAt: last?.changedAt ?? now
            )
            if mark != last { mark.changedAt = now }
            contents.columns[source] = mark
        }
        contents.limits = (contents.limits.current(at: now) ?? ClaudeUsageLimits()).updated(with: news)
        contents.columns = contents.columns
            .filter { $0.value.changedAt > now - columnMemory }
            .sorted { $0.value.changedAt > $1.value.changedAt }
            .prefix(maximumColumns)
            .reduce(into: [:]) { $0[$1.key] = $1.value }
        guard contents != existing else { return true }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(contents) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    /// Turning the option off forgets what was reported.
    static func remove(at url: URL = url) {
        try? FileManager.default.removeItem(at: url)
    }

    static let lockWait: TimeInterval = 0.5

    private static func acquire(_ fd: Int32) -> Bool {
        let deadline = Date().addingTimeInterval(lockWait)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR, Date() < deadline else { return false }
            usleep(5_000)
        }
        return true
    }
}

/// Entry point for `Nirux --hook claude --statusline`, the `statusLine`
/// command Nirux installs in ~/.claude/settings.json while the usage limits
/// indicator is on. Claude Code runs it after each response (and on a few
/// other events) with the session's state on stdin. It records the
/// `rate_limits` and prints nothing, so the status line stays empty. Must be
/// quick and must never fail loudly.
enum ClaudeStatusLineCLI {
    /// Status line payloads are a few KB; read no more than this.
    static let maxPayloadBytes = 1 << 20

    static func run() -> Int32 {
        // Read the whole payload before anything else: Claude reports a
        // command that closes stdin early as failed.
        let data = readPayload(from: FileHandle.standardInput)
        record(payload: data, env: ProcessInfo.processInfo.environment, now: Date().timeIntervalSince1970)
        return 0
    }

    /// Drains stdin to its end, keeping at most `maxPayloadBytes`.
    static func readPayload(from handle: FileHandle) -> Data {
        var data = Data()
        while let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            if data.count < maxPayloadBytes { data.append(chunk.prefix(maxPayloadBytes - data.count)) }
        }
        return data
    }

    /// Records the payload's limits when it comes from a Nirux terminal
    /// (the installed command already checks; this covers manual runs).
    @discardableResult
    static func record(
        payload: Data,
        env: [String: String],
        now: TimeInterval,
        url: URL = ClaudeUsageLimitsFile.url
    ) -> Bool {
        guard AgentHookCLI.isFromNiruxTerminal(env: env),
              let object = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
              let report = ClaudeStatusLineReport(payload: object, now: now) else { return false }
        return ClaudeUsageLimitsFile.record(report, from: env["NIRUX_AGENT_UUID"], now: now, at: url)
    }
}
