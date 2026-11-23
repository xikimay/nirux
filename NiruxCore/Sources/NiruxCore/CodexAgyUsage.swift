import Foundation

/// Folds a Codex rollout (`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`)
/// into its responses and latest rate limits. Never keeps text.
public struct CodexRolloutUsageParser: TranscriptLineParser, Sendable {
    public private(set) var sessionID: String?
    public private(set) var cwd: String?
    public private(set) var model: String?
    public private(set) var contextWindow: Int?
    public private(set) var rateLimits: CodexRateLimits?
    public private(set) var events: [UsageEvent] = []
    /// Codex repeats a `token_count` without a new response: same total.
    private var lastTotal: TokenCounts?

    private static let markers = ["\"session_meta\"", "\"turn_context\"", "\"token_count\""].map { Data($0.utf8) }

    public init() {}

    public mutating func consume(line: Data) {
        guard Self.markers.contains(where: { line.contains($0) }),
              let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let payload = object["payload"] as? [String: Any] else { return }
        switch (object["type"] as? String, payload["type"] as? String) {
        case ("session_meta", _):
            sessionID = payload["id"] as? String ?? sessionID
            cwd = payload["cwd"] as? String ?? cwd
        case ("turn_context", _):
            model = payload["model"] as? String ?? model
            cwd = cwd ?? payload["cwd"] as? String
        case ("event_msg", "token_count"):
            consumeTokenCount(payload, timestamp: UsageEvent.time(object["timestamp"]))
        default:
            return
        }
    }

    private mutating func consumeTokenCount(_ payload: [String: Any], timestamp: TimeInterval) {
        if let limits = payload["rate_limits"] as? [String: Any] {
            rateLimits = CodexRateLimits(limits, reportedAt: timestamp) ?? rateLimits
        }
        guard let info = payload["info"] as? [String: Any] else { return }
        contextWindow = TokenCounts.count(info["model_context_window"]) ?? contextWindow
        let total = (info["total_token_usage"] as? [String: Any]).flatMap(TokenCounts.init(codexUsage:))
        guard let last = (info["last_token_usage"] as? [String: Any]).flatMap(TokenCounts.init(codexUsage:)),
              last.context + last.output > 0, total == nil || total != lastTotal else { return }
        lastTotal = total
        events.append(UsageEvent(timestamp: timestamp, model: model, counts: last))
    }
}

extension TokenCounts {
    /// Codex's `input_tokens` include the cached ones, and its
    /// `output_tokens` the reasoning.
    init?(codexUsage usage: [String: Any]) {
        guard let input = Self.count(usage["input_tokens"]) else { return nil }
        let cacheRead = Self.count(usage["cached_input_tokens"]) ?? 0
        let cacheWrite = Self.count(usage["cache_write_input_tokens"]) ?? 0
        self.init(
            input: max(0, input - cacheRead - cacheWrite),
            output: Self.count(usage["output_tokens"]) ?? 0,
            cacheWrite: cacheWrite,
            cacheRead: cacheRead
        )
    }
}

/// The share of Codex's plan windows in use, as its rollouts report them.
public struct CodexRateLimits: Equatable, Sendable {
    public struct Window: Equatable, Sendable {
        public var usedPercent: Double
        public var minutes: Int?
        /// Epoch seconds.
        public var resetsAt: TimeInterval?
    }

    /// As Codex names them: `minutes` says which window each is (a plan
    /// can report the week as `primary`).
    public var primary: Window?
    public var secondary: Window?
    public var reportedAt: TimeInterval

    init?(_ limits: [String: Any], reportedAt: TimeInterval) {
        func window(_ key: String) -> Window? {
            guard let raw = limits[key] as? [String: Any],
                  let used = (raw["used_percent"] as? NSNumber)?.doubleValue, used.isFinite else { return nil }
            return Window(
                usedPercent: min(max(0, used), 100),
                minutes: TokenCounts.count(raw["window_minutes"]),
                resetsAt: (raw["resets_at"] as? NSNumber)?.doubleValue
            )
        }
        primary = window("primary")
        secondary = window("secondary")
        guard primary != nil || secondary != nil else { return nil }
        self.reportedAt = reportedAt
    }
}

/// Folds an Antigravity CLI (`agy`) transcript
/// (`brain/<conversation>/.system_generated/logs/transcript_full.jsonl`)
/// into its responses. Never keeps text.
public struct AgyTranscriptUsageParser: TranscriptLineParser, Sendable {
    public private(set) var events: [UsageEvent] = []

    private static let marker = Data("\"PLANNER_RESPONSE\"".utf8)

    public init() {}

    public mutating func consume(line: Data) {
        guard line.contains(Self.marker),
              let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              object["type"] as? String == "PLANNER_RESPONSE" else { return }
        // `input_tokens` leave out the cached input.
        let counts = TokenCounts(
            input: TokenCounts.count(object["input_tokens"]) ?? 0,
            output: TokenCounts.count(object["output_tokens"]) ?? 0,
            cacheRead: TokenCounts.count(object["cache_read_tokens"]) ?? 0
        )
        guard counts.context + counts.output > 0 else { return }
        events.append(UsageEvent(timestamp: UsageEvent.time(object["created_at"]), model: object["model"] as? String, counts: counts))
    }
}
