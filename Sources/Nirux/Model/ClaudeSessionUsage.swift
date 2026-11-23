import Foundation

extension ClaudeSessionUsage {
    /// From this share of the window on, the label says it as a warning.
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
