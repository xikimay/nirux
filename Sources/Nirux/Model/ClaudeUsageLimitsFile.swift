import Foundation

/// One run of Claude Code's status line, as `Nirux --hook claude
/// --statusline` received it: the limits, and what tells news from a repeat.
struct ClaudeStatusLineReport: Equatable, Sendable {
    var limits: ClaudeUsageLimits
    /// `session_id`.
    var sessionID: String?
    /// `cost.total_api_duration_ms`: it grows with each API response of the
    /// session, and with nothing else.
    var apiDuration: Double?

    init(limits: ClaudeUsageLimits, sessionID: String? = nil, apiDuration: Double? = nil) {
        self.limits = limits
        self.sessionID = sessionID
        self.apiDuration = apiDuration
    }

    /// Nil without usable limits (see `ClaudeUsageLimits(statusLinePayload:)`).
    init?(payload: [String: Any], now: TimeInterval) {
        guard let limits = ClaudeUsageLimits(statusLinePayload: payload, now: now) else { return nil }
        self.limits = limits
        sessionID = payload["session_id"] as? String
        apiDuration = ((payload["cost"] as? [String: Any])?["total_api_duration_ms"] as? NSNumber)?.doubleValue
    }
}

/// `claude-usage-limits.json` in the state directory: the latest usage
/// limits Claude Code sessions in Nirux reported. Status line runs write it,
/// the app reads it.
enum ClaudeUsageLimitsFile {
    struct Contents: Codable, Equatable {
        var limits = ClaudeUsageLimits()
        /// Each session's last recorded report, by `session_id`.
        var sessions: [String: SessionMark] = [:]
    }

    struct SessionMark: Codable, Equatable {
        var apiDuration: Double?
        var fingerprint: String
        var reportedAt: TimeInterval
    }

    /// Sessions are forgotten a little after the weekly window they could
    /// have reported on, and beyond this many.
    static let sessionMemory: TimeInterval = 8 * 24 * 3600
    static let maximumSessions = 256

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

    /// Records `report` when it carries news: the latest news wins. A
    /// session's status line also runs while it is idle (its permission mode
    /// changes, its prompt cache expires), repeating what its last response
    /// said; such a repeat, same API time and same readings as the session's
    /// last report, would bring back numbers another session has since
    /// updated, so it is dropped. A session signed in to another account
    /// counts like any other: the latest response decides.
    ///
    /// Several sessions report at once, so the read-modify-write holds a
    /// lock; a writer that can't get it within `lockWait` gives up, and its
    /// session's next report counts instead. The file is replaced
    /// atomically: the app never reads half of one.
    @discardableResult
    static func record(_ report: ClaudeStatusLineReport, now: TimeInterval, at url: URL = url) -> Bool {
        let lockPath = url.path + ".lock"
        let lock = open(lockPath, O_RDWR | O_CREAT, 0o600)
        guard lock >= 0 else { return false }
        defer { close(lock) }
        guard acquire(lock) else { return false }
        defer { flock(lock, LOCK_UN) }

        let existing = loadContents(from: url) ?? Contents()
        var contents = existing
        let fingerprint = report.limits.fingerprint
        if let id = report.sessionID {
            if let last = contents.sessions[id], last.apiDuration == report.apiDuration, last.fingerprint == fingerprint {
                return true
            }
            contents.sessions[id] = SessionMark(apiDuration: report.apiDuration, fingerprint: fingerprint, reportedAt: now)
        }
        contents.limits = (contents.limits.current(at: now) ?? ClaudeUsageLimits()).updated(with: report.limits)
        contents.sessions = contents.sessions
            .filter { $0.value.reportedAt > now - sessionMemory }
            .sorted { $0.value.reportedAt > $1.value.reportedAt }
            .prefix(maximumSessions)
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
        return ClaudeUsageLimitsFile.record(report, now: now, at: url)
    }
}
