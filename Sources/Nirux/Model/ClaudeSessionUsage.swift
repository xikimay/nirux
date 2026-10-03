import Foundation

/// Token counts Claude Code records for API responses (`message.usage` in a
/// transcript), or their sum over a session.
struct ClaudeTokenCounts: Equatable, Sendable {
    var input = 0
    var output = 0
    /// `cache_creation_input_tokens`
    var cacheWrite = 0
    /// `cache_read_input_tokens`
    var cacheRead = 0

    /// What a request put in the context window. Claude Code's own "context
    /// used" counts these three and never the output.
    var context: Int { input + cacheWrite + cacheRead }

    static let fieldKeys = [
        "input_tokens", "output_tokens",
        "cache_creation_input_tokens", "cache_read_input_tokens"
    ]

    /// Nil unless the object carries at least one known count. Counts are
    /// clamped: a malformed value must not overflow the session sums.
    init?(usage: [String: Any]) {
        let fields = Self.fieldKeys.map { key -> Int? in
            guard let number = usage[key] as? NSNumber else { return nil }
            return min(max(0, number.intValue), Int(Int32.max))
        }
        guard fields.contains(where: { $0 != nil }) else { return nil }
        input = fields[0] ?? 0
        output = fields[1] ?? 0
        cacheWrite = fields[2] ?? 0
        cacheRead = fields[3] ?? 0
    }

    init(input: Int = 0, output: Int = 0, cacheWrite: Int = 0, cacheRead: Int = 0) {
        self.input = input
        self.output = output
        self.cacheWrite = cacheWrite
        self.cacheRead = cacheRead
    }

    static func + (lhs: Self, rhs: Self) -> Self {
        Self(
            input: lhs.input + rhs.input,
            output: lhs.output + rhs.output,
            cacheWrite: lhs.cacheWrite + rhs.cacheWrite,
            cacheRead: lhs.cacheRead + rhs.cacheRead
        )
    }

    static func += (lhs: inout Self, rhs: Self) {
        lhs = lhs + rhs
    }

    static func - (lhs: Self, rhs: Self) -> Self {
        Self(
            input: lhs.input - rhs.input,
            output: lhs.output - rhs.output,
            cacheWrite: lhs.cacheWrite - rhs.cacheWrite,
            cacheRead: lhs.cacheRead - rhs.cacheRead
        )
    }
}

/// One Claude session's token usage, as read from its transcript.
struct ClaudeSessionUsage: Equatable, Sendable {
    /// Context of the latest main-thread response. Nil before the first
    /// response, and after a compaction until the next one: the boundary's
    /// `postTokens` leaves out the system prompt and tools.
    var contextTokens: Int?
    /// Largest context a response of the current model carried: switching
    /// models (`/model`) may switch windows, so it starts over.
    var peakContextTokens = 0
    /// API model ID of the latest response (`claude-opus-5-5`).
    var model: String?
    /// Sum over the transcript's responses, each counted once. Subagents
    /// log to files of their own and are not included.
    var totals = ClaudeTokenCounts()
    var responses = 0

    /// Claude Code runs a 200k window unless it enables the 1M one, and
    /// which it picks depends on the model variant, the account and the
    /// provider — none of which the transcript records (`message.model` is
    /// the plain API ID, without the `[1m]` suffix).
    static let standardWindow = 200_000
    static let extendedWindow = 1_000_000

    /// The context window, only when the transcript shows it: a context
    /// past the standard window means the session runs the extended one.
    /// Nil otherwise — then only token counts are shown.
    var contextWindow: Int? {
        guard peakContextTokens > Self.standardWindow, !Self.mayHaveCustomWindow(model) else { return nil }
        return Self.extendedWindow
    }

    /// Models Claude Code may give another window: one between the two for
    /// `claude-sonnet-4-6` (remote configuration), any for IDs outside its
    /// model table (`CLAUDE_CODE_MAX_CONTEXT_TOKENS`). A context past 200k
    /// proves nothing about them.
    static func mayHaveCustomWindow(_ model: String?) -> Bool {
        guard let model, model.hasPrefix("claude-") else { return true }
        return model.hasPrefix("claude-sonnet-4-6")
    }

    /// Share of the context window in use, 0…1 (can exceed 1 only on a
    /// malformed transcript).
    var contextFraction: Double? {
        guard let contextTokens, let contextWindow else { return nil }
        return Double(contextTokens) / Double(contextWindow)
    }
}

/// Folds transcript lines into a `ClaudeSessionUsage`.
///
/// Claude Code writes one assistant line per content block of a response,
/// each repeating the response's usage (an early block may carry a partial
/// output count), so the lines of one `message.id` count once, the latest
/// winning. Subagent lines (`isSidechain`), synthetic and API-error
/// messages, and lines of any other shape are skipped, never errors.
/// Only counts and the model ID are kept — never message content.
struct ClaudeTranscriptUsageParser {
    private(set) var usage = ClaudeSessionUsage()
    /// Response whose later blocks may still come: its counts are in
    /// `usage.totals`, and a later line replaces them instead of adding.
    private var current: (id: String, counts: ClaudeTokenCounts)?
    /// Responses already counted, most recent last. Bounded: a repeat only
    /// ever follows its response closely.
    private var countedIDs: [String] = []
    private static let countedIDLimit = 64

    /// Keys a line must contain to matter; others skip JSON parsing.
    private static let usageMarker = Data("\"usage\"".utf8)
    private static let compactMarker = Data("compact_boundary".utf8)

    mutating func consume(line: Data) {
        guard line.range(of: Self.usageMarker) != nil || line.range(of: Self.compactMarker) != nil,
              let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              object["isSidechain"] as? Bool != true else { return }
        switch object["type"] as? String {
        case "assistant":
            consumeResponse(object)
        case "system" where object["subtype"] as? String == "compact_boundary":
            usage.contextTokens = nil
        default:
            return
        }
    }

    private mutating func consumeResponse(_ object: [String: Any]) {
        guard object["isApiErrorMessage"] as? Bool != true,
              let message = object["message"] as? [String: Any],
              let rawUsage = message["usage"] as? [String: Any],
              let counts = ClaudeTokenCounts(usage: rawUsage) else { return }
        let context = Self.contextCounts(usage: rawUsage, response: counts).context
        let model = (message["model"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        // Error placeholders Claude Code writes itself carry this model
        // and zero counts: no request was made.
        guard model != "<synthetic>", counts.context > 0 else { return }

        let id = (message["id"] as? String) ?? (object["requestId"] as? String)
        if let id, let current, current.id == id {
            usage.totals = usage.totals - current.counts + counts
            self.current = (id, counts)
        } else if let id, countedIDs.contains(id) {
            return // a stray repeat of a response already counted
        } else {
            usage.totals += counts
            usage.responses += 1
            current = id.map { ($0, counts) }
            if let id {
                countedIDs.append(id)
                if countedIDs.count > Self.countedIDLimit { countedIDs.removeFirst() }
            }
        }
        if let model, let previous = usage.model, model != previous { usage.peakContextTokens = 0 }
        usage.contextTokens = context
        usage.peakContextTokens = max(usage.peakContextTokens, context)
        if let model { usage.model = model }
    }

    /// What Claude Code measures the context from (its statusline's
    /// `used_percentage`): when a response ran several iterations (a
    /// server-side compaction, an advisor, a model fallback), the last one
    /// that isn't an advisor or compaction step — if it is a well-formed
    /// `message` or `fallback_message` — else the response's own counts.
    static func contextCounts(usage: [String: Any], response: ClaudeTokenCounts) -> ClaudeTokenCounts {
        guard response.context > 0, let iterations = usage["iterations"] as? [Any] else { return response }
        let last = iterations.last { iteration in
            let type = (iteration as? [String: Any])?["type"] as? String
            return type != "advisor_message" && type != "compaction"
        }
        guard let last = last as? [String: Any],
              ["message", "fallback_message"].contains(last["type"] as? String),
              ClaudeTokenCounts.fieldKeys.allSatisfy({ ((last[$0] as? NSNumber)?.doubleValue ?? -1) >= 0 }),
              let counts = ClaudeTokenCounts(usage: last), counts.context > 0 else { return response }
        return counts
    }
}

// MARK: - Display

extension ClaudeSessionUsage {
    /// From this share of the window on, the label turns orange.
    static let nearlyFullFraction = 0.8

    /// Column header text: "ctx 62%" when the window is known, "ctx 124k"
    /// otherwise, "ctx —" right after a compaction. Nil before the first
    /// response.
    var headerText: String? {
        guard responses > 0 else { return nil }
        guard let contextTokens else { return "ctx —" }
        if let contextFraction { return "ctx \(Self.percent(contextFraction))" }
        return "ctx \(Self.compactCount(contextTokens))"
    }

    var isNearlyFull: Bool {
        (contextFraction ?? 0) >= Self.nearlyFullFraction
    }

    var tooltip: String {
        var lines: [String] = []
        if let contextTokens {
            let tokens = "Context: \(Self.groupedCount(contextTokens)) tokens"
            if let contextWindow, let contextFraction {
                lines.append(
                    "\(tokens), \(Self.percent(contextFraction)) of a \(Self.groupedCount(contextWindow)) window "
                        + "(inferred: the context went past 200k)"
                )
            } else {
                lines.append("\(tokens) (window size unknown)")
            }
        } else if responses > 0 {
            lines.append("Context: compacted, updated with the next response")
        } else {
            lines.append("Context: no response yet")
        }
        if let model { lines.append("Model: \(model)") }
        let responseCount = responses == 1 ? "1 response" : "\(responses) responses"
        lines.append(
            "Session without subagents (\(responseCount)): \(Self.compactCount(totals.output)) output · "
                + "\(Self.compactCount(totals.input)) input · "
                + "\(Self.compactCount(totals.cacheRead)) cache read · "
                + "\(Self.compactCount(totals.cacheWrite)) cache write"
        )
        return lines.joined(separator: "\n")
    }

    /// "62%", "<1%" for a context too small to round to a percent.
    static func percent(_ fraction: Double) -> String {
        let rounded = Int((fraction * 100).rounded())
        return rounded == 0 && fraction > 0 ? "<1%" : "\(rounded)%"
    }

    /// 850, 8.4k, 124k, 1.2M.
    static func compactCount(_ count: Int) -> String {
        func trimmed(_ value: Double, _ unit: String) -> String {
            let text = String(format: "%.1f", value)
            return (text.hasSuffix(".0") ? String(text.dropLast(2)) : text) + unit
        }
        switch count {
        case ..<1_000: return "\(count)"
        case ..<9_950: return trimmed(Double(count) / 1_000, "k")
        case ..<999_500: return "\(Int((Double(count) / 1_000).rounded()))k"
        default: return trimmed(Double(count) / 1_000_000, "M")
        }
    }

    /// 212,400 — fixed separator, whatever the locale.
    static func groupedCount(_ count: Int) -> String {
        let digits = String(count.magnitude)
        var result = ""
        for (index, digit) in digits.enumerated() {
            if index > 0, (digits.count - index) % 3 == 0 { result.append(",") }
            result.append(digit)
        }
        return count < 0 ? "-" + result : result
    }
}
