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

extension QuotaLimit {
    /// Claude's windows from its status line and readings log, Codex's from
    /// its rollouts; each forecast held from `previous` (`QuotaPace`).
    static func current(
        claude: ClaudeUsageLimits?, claudeReadings: [String: [QuotaReading]],
        codex: CodexRateLimits?, codexReadings: [Int: [QuotaReading]],
        previous: [QuotaLimit], now: TimeInterval
    ) -> [QuotaLimit] {
        // The current window joins the readings only when none of its own is
        // logged yet: logged ones come from responses, while the file also
        // takes a `/resume`'s old numbers.
        func limit(_ agent: Agent, _ length: TimeInterval, _ readings: [QuotaReading], _ latest: QuotaReading) -> QuotaLimit? {
            let held = previous.first { $0.agent == agent && $0.length == length }?.forecast
            let logged = readings.contains { abs($0.resetsAt - latest.resetsAt) <= QuotaPace.sameWindow }
            return QuotaLimit(agent: agent, length: length, readings: logged ? readings : readings + [latest], now: now, previous: held)
        }
        let claudeWindows = [("five_hour", 5 * 3_600.0, claude?.fiveHour), ("seven_day", 7 * 86_400.0, claude?.sevenDay)]
        let claudeLimits = claudeWindows.compactMap { name, length, window in
            window.flatMap { window in
                limit(.claude, length, claudeReadings[name] ?? [], QuotaReading(time: window.reportedAt, usedPercent: window.usedPercentage, resetsAt: window.resetsAt))
            }
        }
        let codexLimits = [codex?.primary, codex?.secondary].compactMap { window -> QuotaLimit? in
            guard let codex, let window, let minutes = window.minutes, let resetsAt = window.resetsAt else { return nil }
            return limit(.codex, Double(minutes) * 60, codexReadings[minutes] ?? [], QuotaReading(time: codex.reportedAt, usedPercent: window.usedPercent, resetsAt: resetsAt))
        }
        return claudeLimits + codexLimits
    }
}

extension UsageText {
    struct QuotaTitle: Equatable {
        enum Tone { case normal, warning, runsOut }
        var text: String
        var tone: Tone
    }

    /// "5h", "7d", "Codex 5h".
    static func name(of limit: QuotaLimit) -> String {
        (limit.agent == .codex ? "Codex " : "") + (window(minutes: Int(limit.length / 60)) ?? "")
    }

    /// The title bar's words for the binding limit: "5h 68% · ≈ 87%",
    /// "⚠︎ 5h full by 20:05", "⚠︎ 7d full until Fri 10:15". A forecast that
    /// holds needs no warning; without one, a warning from
    /// `nearLimitPercent`, like a nearly full context.
    static func title(_ limit: QuotaLimit, now: TimeInterval, calendar: Calendar) -> QuotaTitle {
        let name = name(of: limit)
        let used = Int(limit.latest.usedPercent.rounded())
        switch limit.forecast {
        case .reached:
            return QuotaTitle(text: "\(name) full until \(ClaudeUsageLimits.clockText(limit.latest.resetsAt, now: now, calendar: calendar))".asWarning, tone: .runsOut)
        case .runsOut(let at):
            return QuotaTitle(text: "\(name) full by \(ClaudeUsageLimits.clockText(at, now: now, calendar: calendar))".asWarning, tone: .runsOut)
        case .atReset(let percent) where percent > used:
            return QuotaTitle(text: "\(name) \(used)% · ≈ \(percent)%", tone: .normal)
        case .atReset:
            // Holding at a full 100 % still says so.
            return used >= 100 ? QuotaTitle(text: "\(name) \(used)%".asWarning, tone: .warning) : QuotaTitle(text: "\(name) \(used)%", tone: .normal)
        case .quiet, .unknown:
            let text = "\(name) \(used)%"
            return used >= ClaudeUsageLimits.nearLimitPercent ? QuotaTitle(text: text.asWarning, tone: .warning) : QuotaTitle(text: text, tone: .normal)
        }
    }

    /// "Claude · 5-hour window", "Codex · week".
    static func longName(of limit: QuotaLimit) -> String {
        let minutes = Int(limit.length / 60)
        let window = minutes == 10_080 ? "week"
            : minutes % 1_440 == 0 ? "\(minutes / 1_440)-day window" : "\(max(1, Int((Double(minutes) / 60).rounded())))-hour window"
        return "\(limit.agent == .claude ? "Claude" : "Codex") · \(window)"
    }

    /// A limit's line in the popover: its pace, then its reset.
    static func detail(_ limit: QuotaLimit, now: TimeInterval, calendar: Calendar) -> QuotaTitle {
        let resetsAt = limit.latest.resetsAt
        let reset = ClaudeUsageLimits.resetText(resetsAt, now: now, calendar: calendar)
        switch limit.forecast {
        case .reached:
            return QuotaTitle(text: "Full: it \(reset)".asWarning, tone: .runsOut)
        case .runsOut(let at):
            let clock = ClaudeUsageLimits.clockText(at, now: now, calendar: calendar)
            let resetClock = ClaudeUsageLimits.clockText(resetsAt, now: now, calendar: calendar)
            let before = ClaudeUsageLimits.remainingText(resetsAt - at)
            let sameDay = calendar.isDate(Date(timeIntervalSince1970: resetsAt), inSameDayAs: Date(timeIntervalSince1970: now))
            return QuotaTitle(text: "Full by \(clock), \(before) before it resets \(sameDay ? "at " : "")\(resetClock)".asWarning, tone: .runsOut)
        case .atReset(let percent) where percent > Int(limit.latest.usedPercent.rounded()):
            return QuotaTitle(text: "≈ \(percent)% when it \(reset)", tone: .normal)
        case .atReset:
            return QuotaTitle(text: reset.prefix(1).uppercased() + reset.dropFirst(), tone: .normal)
        case .quiet:
            return QuotaTitle(text: "No agent in Nirux spent it lately; it \(reset)", tone: .normal)
        case .unknown:
            return QuotaTitle(text: reset.prefix(1).uppercased() + reset.dropFirst(), tone: .normal)
        }
    }

    /// The pace in a tooltip's words: "full by 20:05, before its reset at 20:21".
    static func pace(_ limit: QuotaLimit, now: TimeInterval, calendar: Calendar) -> String {
        let reset = ClaudeUsageLimits.clockText(limit.latest.resetsAt, now: now, calendar: calendar)
        switch limit.forecast {
        case .reached: return "full until its reset at \(reset)"
        case .runsOut(let at): return "full by \(ClaudeUsageLimits.clockText(at, now: now, calendar: calendar)), before its reset at \(reset)"
        case .atReset(let percent): return "about \(percent)% at its reset at \(reset)"
        case .quiet: return "no agent in Nirux spent it lately"
        case .unknown: return "too few readings yet to tell its pace"
        }
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
    /// Its latest session's.
    var subagents: Int
    /// Its space's 7-day budget (`SpaceDefaults.weeklyTaskBudget`).
    var budget: Int?
    /// Its share of Claude's spend over the last `UsageReport.burnSpan`.
    var recentShare: Double?
    /// A Lead's: its space's share of the week's spend.
    var spaceWeekShare: Double?
    /// Idle past Claude Code's cache, as the report found it, with a context
    /// worth writing again: a newer report flips it, so the row redraws.
    var isCold: Bool

    /// From this many subagents in a session, the row warns: separate work
    /// goes to a task, which starts with a context of its own.
    static let subagentSoftCap = 5

    /// Nil for a task no agent spent on this week.
    init?(_ report: UsageReport, taskID: String, budget: Int? = nil) {
        let week = report.week.tasks[taskID]
        let latest = report.latestSessions[taskID]
        guard week != nil || latest != nil else { return nil }
        contextTokens = latest?.contextTokens
        lastResponseAt = latest?.lastResponseAt
        weekTokens = week?.weightedTokens ?? 0
        subagentTokens = week?.subagentWeightedTokens ?? 0
        heavyContextTokens = week?.heavyContextWeightedTokens ?? 0
        coldRewrites = week?.coldRewrites ?? 0
        subagents = latest?.subagents ?? 0
        self.budget = budget
        isCold = latest.map { latest in
            (latest.contextTokens ?? 0) >= ContextOffer.coldContextTokens && report.generatedAt - latest.lastResponseAt >= UsageSummary.hourCacheLifetime
        } ?? false
        let burn = report.claudeBurn.values.reduce(0, +)
        recentShare = burn > 0 ? report.claudeBurn[taskID].map { $0 / burn } : nil
    }

    /// From there on, each message re-reads a context worth compacting.
    var isContextHeavy: Bool { (contextTokens ?? 0) >= UsageSummary.heavyContextTokens }

    var isFanningOut: Bool { subagents >= Self.subagentSoftCap }

    /// Past its budget: its pull request's follow-ups wait.
    var isOverBudget: Bool { budget.map { weekTokens >= Double($0) } ?? false }

    /// What the row says as a warning.
    var isWarning: Bool { isContextHeavy || isFanningOut || isOverBudget }

    /// Why it spends, for the popover: "Each message rereads 612k · 6 subagents".
    func burnCause(compactsAtTurnEnd: Bool) -> String? {
        var parts: [String] = []
        if isOverBudget, let budget { parts.append("past its \(UsageText.tokens(budget)) budget") }
        if isContextHeavy, let contextTokens { parts.append("each message rereads \(UsageText.tokens(contextTokens))") }
        if isFanningOut { parts.append("\(subagents) subagents") }
        if compactsAtTurnEnd { parts.append("compacts at turn end") }
        if parts.isEmpty, let contextTokens { parts.append("\(UsageText.tokens(contextTokens)) of context") }
        guard let text = parts.first.map({ ([$0] + parts.dropFirst()).joined(separator: " · ") }) else { return nil }
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    /// What the row says, only once the task spends: why, in a word or a
    /// number ("Budget", "612k", "6 subagents") as a warning, or "Cold";
    /// nil otherwise. The numbers are in its tooltip.
    var chip: (text: String, isWarning: Bool)? {
        if isOverBudget { return ("Budget", true) }
        if isContextHeavy, let contextTokens { return (UsageText.tokens(contextTokens), true) }
        if isFanningOut { return ("\(subagents) subagents", true) }
        if isCold { return ("Cold", false) }
        return nil
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
        if isFanningOut {
            lines.append("\(subagents) subagents in its latest session: from the \(Self.subagentSoftCap)th, separate work costs less as a task")
        }
        lines.append("Last 7 days: \(UsageText.tokens(weekTokens)) tokens, \(UsageText.unitNote)")
        if isOverBudget, let budget {
            lines.append("Past its budget of \(UsageText.tokens(budget)): its pull request's follow-ups wait (Space Settings › Defaults)")
        }
        if subagentTokens > 0 { lines.append("Subagents: \(UsageText.share(subagentTokens, of: weekTokens))") }
        if heavyContextTokens > 0 {
            lines.append("Past \(UsageText.tokens(UsageSummary.heavyContextTokens)) of context: \(UsageText.share(heavyContextTokens, of: weekTokens))")
        }
        if coldRewrites > 0 { lines.append("Cold cache rewrites: \(coldRewrites)") }
        if let recentShare, recentShare > 0 { lines.append("Last 30 minutes: \(UsageText.share(recentShare, of: 1)) of Claude’s spend in Nirux") }
        if let spaceWeekShare { lines.append("Its space: \(UsageText.share(spaceWeekShare, of: 1)) of the week’s spend in Nirux") }
        return lines.joined(separator: "\n")
    }
}
