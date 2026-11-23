import Foundation

/// Token counts of one model response, or their sum over responses.
public struct TokenCounts: Hashable, Sendable {
    /// Uncached input.
    public var input = 0
    public var output = 0
    public var cacheWrite = 0
    public var cacheRead = 0

    public init(input: Int = 0, output: Int = 0, cacheWrite: Int = 0, cacheRead: Int = 0) {
        self.input = input
        self.output = output
        self.cacheWrite = cacheWrite
        self.cacheRead = cacheRead
    }

    /// What a request put in the context window. Claude Code's own "context
    /// used" counts these three and never the output.
    public var context: Int { input + cacheWrite + cacheRead }

    /// Opus-equivalent tokens, from API price ratios: input 1, cache write
    /// 1.25, cache read 0.1, output 5; Sonnet costs 0.6 of Opus, Haiku 0.2.
    public func weighted(model: String?) -> Double {
        let tokens = Double(input) + 1.25 * Double(cacheWrite) + 0.1 * Double(cacheRead) + 5 * Double(output)
        let name = model?.lowercased() ?? ""
        return tokens * (name.contains("haiku") ? 0.2 : name.contains("sonnet") ? 0.6 : 1)
    }

    /// A count read from JSON: nil unless a number (a boolean isn't one),
    /// clamped so a malformed value can't overflow the sums.
    static func count(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let raw = number.doubleValue
        guard raw > 0 else { return 0 }
        return raw < Double(Int32.max) ? Int(raw) : Int(Int32.max)
    }

    public static func + (lhs: Self, rhs: Self) -> Self {
        Self(
            input: lhs.input + rhs.input,
            output: lhs.output + rhs.output,
            cacheWrite: lhs.cacheWrite + rhs.cacheWrite,
            cacheRead: lhs.cacheRead + rhs.cacheRead
        )
    }

    public static func += (lhs: inout Self, rhs: Self) {
        lhs = lhs + rhs
    }

    public static func - (lhs: Self, rhs: Self) -> Self {
        Self(
            input: lhs.input - rhs.input,
            output: lhs.output - rhs.output,
            cacheWrite: lhs.cacheWrite - rhs.cacheWrite,
            cacheRead: lhs.cacheRead - rhs.cacheRead
        )
    }
}

/// One model response: its counts, model and time, never its text.
public struct UsageEvent: Hashable, Sendable {
    /// Epoch seconds; 0 when the line had none.
    public var timestamp: TimeInterval
    public var model: String?
    public var counts: TokenCounts
    /// What the request put in the context window: Claude measures it from
    /// a response's last iteration, which can differ from `counts.context`.
    public var contextTokens: Int
    /// The Claude subagent that made it; nil for the session itself.
    public var subagentID: String?

    public init(
        timestamp: TimeInterval,
        model: String? = nil,
        counts: TokenCounts,
        contextTokens: Int? = nil,
        subagentID: String? = nil
    ) {
        self.timestamp = timestamp
        self.model = model
        self.counts = counts
        self.contextTokens = contextTokens ?? counts.context
        self.subagentID = subagentID
    }

    /// Epoch seconds of an ISO 8601 transcript timestamp, with or without
    /// fractional seconds; 0 for anything else.
    static func time(_ value: Any?) -> TimeInterval {
        guard let text = value as? String else { return 0 }
        let date = (try? fractionalTime.parse(text)) ?? (try? Date.ISO8601FormatStyle().parse(text))
        return date?.timeIntervalSince1970 ?? 0
    }

    private static let fractionalTime = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
}

public enum UsageAgent: String, Hashable, Sendable, CaseIterable {
    case claude, codex, agy
}

/// An agent session: Claude's and Codex's session ID, agy's conversation ID.
public struct UsageSessionKey: Hashable, Sendable {
    public var agent: UsageAgent
    public var id: String

    public init(_ agent: UsageAgent, _ id: String) {
        self.agent = agent
        self.id = id
    }
}
