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

    /// Nil unless the object carries at least one known count. Counts are
    /// clamped: a malformed value must not overflow the session sums.
    init?(usage: [String: Any]) {
        let fields = [
            "input_tokens", "output_tokens",
            "cache_creation_input_tokens", "cache_read_input_tokens"
        ].map { key -> Int? in
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
    /// response, and after a compaction until the next one: the transcript
    /// doesn't say what the compacted context weighs.
    var contextTokens: Int?
    /// Largest context any response of this transcript carried.
    var peakContextTokens = 0
    /// API model ID of the latest response (`claude-opus-5-5`).
    var model: String?
    /// Sum over the transcript's responses, each counted once.
    var totals = ClaudeTokenCounts()
    var responses = 0

    /// Claude Code runs a 200k window unless it enables the 1M one, and
    /// which it picks depends on the model variant, the account and the
    /// provider — none of which the transcript records (`message.model` is
    /// the plain API ID, without the `[1m]` suffix).
    static let standardWindow = 200_000
    static let extendedWindow = 1_000_000

    /// The context window, only when the transcript proves it: a context
    /// past the standard window means the session runs the extended one.
    /// Nil otherwise — then only token counts are shown.
    var contextWindow: Int? {
        peakContextTokens > Self.standardWindow ? Self.extendedWindow : nil
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
        usage.contextTokens = counts.context
        usage.peakContextTokens = max(usage.peakContextTokens, counts.context)
        if let model { usage.model = model }
    }
}

// MARK: - Display

extension ClaudeSessionUsage {
    /// From this share of the window on, the label turns orange.
    static let nearlyFullFraction = 0.8

    /// Column title-bar text: "ctx 62%" when the window is known, "ctx 124k"
    /// otherwise, "ctx —" right after a compaction. Nil before the first
    /// response.
    var titleBarText: String? {
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
                lines.append("\(tokens), \(Self.percent(contextFraction)) of the \(Self.groupedCount(contextWindow)) window")
            } else {
                lines.append("\(tokens) (window not known yet: 200k or 1M, depending on the model and account)")
            }
        } else {
            lines.append("Context: compacted, updated with the next response")
        }
        if let model { lines.append("Model: \(model)") }
        let responseCount = responses == 1 ? "1 response" : "\(responses) responses"
        lines.append(
            "Session (\(responseCount)): \(Self.compactCount(totals.output)) output · "
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
