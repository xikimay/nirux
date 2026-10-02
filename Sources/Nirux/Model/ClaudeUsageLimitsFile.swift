import Foundation

/// `claude-usage-limits.json` in the state directory: the usage limits
/// Claude Code sessions in Nirux reported, merged (see
/// `ClaudeUsageLimits.merging`). Status line runs write it, the app reads it.
enum ClaudeUsageLimitsFile {
    /// Pure path computation: the status line receiver writes here too, and
    /// inherits NIRUX_STATE_DIR from the terminal like the hook receiver.
    static var url: URL {
        Persistence.stateDirectory.appendingPathComponent("claude-usage-limits.json")
    }

    static func load(from url: URL = url) -> ClaudeUsageLimits? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ClaudeUsageLimits.self, from: data)
    }

    /// Folds `report` into the file. Several sessions report at once, so the
    /// read-merge-write holds a lock; a writer that can't get it within
    /// `lockWait` gives up, and its session's next report counts instead. The
    /// file is replaced atomically: the app never reads half of one.
    @discardableResult
    static func record(_ report: ClaudeUsageLimits, now: TimeInterval, at url: URL = url) -> Bool {
        let lockPath = url.path + ".lock"
        let lock = open(lockPath, O_RDWR | O_CREAT, 0o600)
        guard lock >= 0 else { return false }
        defer { close(lock) }
        guard acquire(lock) else { return false }
        defer { flock(lock, LOCK_UN) }

        let existing = load(from: url)?.current(at: now) ?? ClaudeUsageLimits()
        let merged = existing.merging(report)
        // Most reports change nothing: an idle session's, or a second
        // response before the usage moved.
        guard merged != existing else { return true }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(merged) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
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
              let report = ClaudeUsageLimits(statusLinePayload: object, now: now) else { return false }
        return ClaudeUsageLimitsFile.record(report, now: now, at: url)
    }
}
