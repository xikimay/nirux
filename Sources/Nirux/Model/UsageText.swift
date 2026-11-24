import Foundation

/// How Nirux writes token counts: "950", "142k", "4.2M", "31M", "1.05G".
enum UsageText {
    /// What spend is counted in (`TokenCounts.weighted`).
    static let unitNote = "in Opus 5.5 input tokens at list prices"

    static func tokens(_ value: Double) -> String {
        let value = value.isFinite ? max(0, value) : 0
        switch value {
        case ..<999.5: return "\(Int(value.rounded()))"
        case ..<999_500: return "\(Int((value / 1e3).rounded()))k"
        case ..<9_950_000: return String(format: "%.1fM", value / 1e6)
        case ..<999_500_000: return "\(Int((value / 1e6).rounded()))M"
        default: return String(format: "%.2fG", value / 1e9)
        }
    }

    static func tokens(_ value: Int) -> String { tokens(Double(value)) }

    /// "29%"; "0%" of nothing.
    static func share(_ part: Double, of whole: Double) -> String {
        whole > 0 ? "\(Int((part / whole * 100).rounded()))%" : "0%"
    }

    struct CodexWindow: Equatable {
        var name: String
        var percent: Int
        var resetsAt: TimeInterval?
    }

    /// Codex's windows that haven't reset since its report, shortest first.
    static func codexWindows(_ limits: CodexRateLimits, now: TimeInterval) -> [CodexWindow] {
        let current: [CodexRateLimits.Window] = [limits.primary, limits.secondary].compactMap { $0 }.filter { ($0.resetsAt ?? 0) > now }
        return current.sorted { ($0.minutes ?? 0) < ($1.minutes ?? 0) }.compactMap { limit -> CodexWindow? in
            guard let name = window(minutes: limit.minutes) else { return nil }
            return CodexWindow(name: name, percent: Int(limit.usedPercent.rounded()), resetsAt: limit.resetsAt)
        }
    }

    /// "5h", "7d", "3h": a Codex window by its length.
    static func window(minutes: Int?) -> String? {
        guard let minutes, minutes > 0 else { return nil }
        return minutes % 1_440 == 0 ? "\(minutes / 1_440)d" : "\(max(1, Int((Double(minutes) / 60).rounded())))h"
    }
}

extension ContextOffer {
    /// "Each message rereads 312k".
    var text: String {
        switch reason {
        case .heavy: "Each message rereads \(UsageText.tokens(contextTokens))"
        case .cold: "Cache expired: \(UsageText.tokens(contextTokens)) to write again"
        }
    }

    static let toolTip = """
        Compact: Claude sums up this conversation and goes on from the summary.
        Fresh start: a new conversation, handed the task's request, progress and next step.
        """
}

extension ContextOffer.Choice {
    var title: String {
        switch self {
        case .compact: "Compact"
        case .freshStart: "Fresh start"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .compact: "Compact: type /compact in claude's prompt"
        case .freshStart: "Fresh start: a new Claude conversation with a handover"
        }
    }
}

/// A task row's usage: its latest session's context, and what it spent
/// over the week (`UsageReport`).
struct SidebarTaskUsage: Hashable {
    var contextTokens: Int?
    var lastResponseAt: TimeInterval?
    var weekTokens: Double
    var subagentTokens: Double
    var heavyContextTokens: Double
    var coldRewrites: Int

    /// Nil for a task no agent spent on this week.
    init?(_ report: UsageReport, taskID: String) {
        let week = report.week.tasks[taskID]
        let latest = report.latestSessions[taskID]
        guard week != nil || latest != nil else { return nil }
        contextTokens = latest?.contextTokens
        lastResponseAt = latest?.lastResponseAt
        weekTokens = week?.weightedTokens ?? 0
        subagentTokens = week?.subagentWeightedTokens ?? 0
        heavyContextTokens = week?.heavyContextWeightedTokens ?? 0
        coldRewrites = week?.coldRewrites ?? 0
    }

    /// From there on, each message re-reads a context worth compacting.
    var isContextHeavy: Bool { (contextTokens ?? 0) >= UsageSummary.heavyContextTokens }

    /// "142k · 4.2M": the context, then the week's spend.
    var text: String {
        [contextTokens.map(UsageText.tokens), UsageText.tokens(weekTokens)].compactMap { $0 }.joined(separator: " · ")
    }

    func toolTip(now: TimeInterval) -> String {
        var lines: [String] = []
        if let contextTokens {
            lines.append("Context of its latest session: \(UsageText.tokens(contextTokens)) tokens")
            if isContextHeavy {
                lines.append("Past \(UsageText.tokens(UsageSummary.heavyContextTokens)): compacting, or a fresh start with a handover, costs less")
            }
            if let lastResponseAt, now - lastResponseAt >= UsageSummary.hourCacheLifetime {
                let idle = ClaudeUsageLimits.remainingText(now - lastResponseAt)
                lines.append("Idle for \(idle): its cache expired, the next message writes it again")
            }
        }
        lines.append("Last 7 days: \(UsageText.tokens(weekTokens)) tokens, \(UsageText.unitNote)")
        if subagentTokens > 0 { lines.append("Subagents: \(UsageText.share(subagentTokens, of: weekTokens))") }
        if heavyContextTokens > 0 {
            lines.append("Past \(UsageText.tokens(UsageSummary.heavyContextTokens)) of context: \(UsageText.share(heavyContextTokens, of: weekTokens))")
        }
        if coldRewrites > 0 { lines.append("Cold cache rewrites: \(coldRewrites)") }
        return lines.joined(separator: "\n")
    }
}
