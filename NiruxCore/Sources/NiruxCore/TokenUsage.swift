import Foundation

/// Token counts of one model response, or their sum over responses.
public struct TokenCounts: Hashable, Sendable {
    /// Uncached input.
    public var input = 0
    public var output = 0
    public var cacheWrite = 0
    public var cacheRead = 0
    /// The part of `cacheWrite` kept an hour rather than 5 minutes.
    public var hourCacheWrite = 0

    public init(input: Int = 0, output: Int = 0, cacheWrite: Int = 0, cacheRead: Int = 0, hourCacheWrite: Int = 0) {
        self.input = input
        self.output = output
        self.cacheWrite = cacheWrite
        self.cacheRead = cacheRead
        self.hourCacheWrite = hourCacheWrite
    }

    /// What a request put in the context window. Claude Code's own "context
    /// used" counts these three and never the output.
    public var context: Int { input + cacheWrite + cacheRead }

    /// What the response would cost through the API, in Opus 5.5 input
    /// tokens. Cache writes cost 1.25× input for 5 minutes, 2× for an hour.
    public func weighted(model: String?) -> Double {
        let price = Self.price(model)
        let writes = 1.25 * Double(cacheWrite - hourCacheWrite) + 2 * Double(hourCacheWrite)
        return price.input * (Double(input) + writes) + price.cacheRead * Double(cacheRead) + price.output * Double(output)
    }

    /// List prices of each family's current model (2026-11), per Opus 5.5
    /// input token ($4/M); other agents' models price as Opus.
    static func price(_ model: String?) -> (input: Double, output: Double, cacheRead: Double) {
        let name = model?.lowercased() ?? ""
        if name.contains("fable") || name.contains("mythos") { return (2, 10, 0.05) }
        if name.contains("sonnet") { return (0.5, 2.5, 0.025) }
        if name.contains("haiku") { return (0.025, 0.125, 0.0025) }
        return (1, 5, 0.05)
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
            cacheRead: lhs.cacheRead + rhs.cacheRead,
            hourCacheWrite: lhs.hourCacheWrite + rhs.hourCacheWrite
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
            cacheRead: lhs.cacheRead - rhs.cacheRead,
            hourCacheWrite: lhs.hourCacheWrite - rhs.hourCacheWrite
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
    /// Nirux's own one-shot Claude runs (see `NiruxOneShotLog`).
    case nirux
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
