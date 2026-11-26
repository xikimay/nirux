import Foundation

/// What Nirux shows of the ledger: the last 24 hours and 7 days by source,
/// task and space, the week day by day, each task's latest context, and the
/// Codex limits: the latest, and each window's readings over the week.
public struct UsageReport: Equatable, Sendable {
    /// Who spent.
    public enum Source: String, CaseIterable, Sendable {
        /// A Claude session's own thread, then its subagents.
        case claude, subagents, codex, agy
        /// Nirux's own one-shot runs.
        case nirux

        init(_ session: UsageSession, _ event: UsageEvent) {
            switch session.key.agent {
            case .claude: self = event.subagentID == nil ? .claude : .subagents
            case .codex: self = .codex
            case .agy: self = .agy
            case .nirux: self = .nirux
            }
        }
    }

    public struct Period: Equatable, Sendable {
        public var since: TimeInterval
        public var total: UsageSummary
        public var sources: [Source: UsageSummary]
        public var tasks: [String: UsageSummary]
        public var spaces: [String: UsageSummary]

        init(_ sessions: [UsageSession], since: TimeInterval) {
            self.since = since
            total = sessions.summary(since: since)
            sources = sessions.summaries(since: since, by: Source.init)
            tasks = sessions.summaries(since: since) { session, _ in session.attribution.taskID }
            spaces = sessions.summaries(since: since) { session, _ in session.attribution.spaceID }
        }
    }

    public struct Day: Equatable, Sendable {
        public var start: TimeInterval
        /// Weighted tokens.
        public var sources: [Source: Double]
    }

    /// A task's latest agent session, the one its row speaks of.
    public struct LatestSession: Equatable, Sendable {
        public var key: UsageSessionKey
        /// Of its own thread, not its subagents'.
        public var contextTokens: Int?
        public var contextWindow: Int?
        public var lastResponseAt: TimeInterval
        /// The subagents it started.
        public var subagents = 0
    }

    public static let dayCount = 7

    public var generatedAt: TimeInterval
    public var day: Period
    /// Today and the 6 days before, from midnight.
    public var week: Period
    /// Oldest first.
    public var days: [Day]
    /// By task ID.
    public var latestSessions: [String: LatestSession]
    public var codexLimits: CodexRateLimits?
    /// By window length in minutes, oldest first.
    public var codexReadings: [Int: [QuotaReading]]
    /// Claude's weighted tokens (its sessions and their subagents) over the
    /// last day, by minute since 1970: what calibrates its plan's percentages
    /// (`QuotaCalibration`).
    public var claudeMinutes: [Int: Double]
    /// Claude's weighted tokens over the last `burnSpan`, by task ID; "" for
    /// sessions outside tasks.
    public var claudeBurn: [String: Double]
    /// Claude's weighted tokens day by day (as `days`), by task ID; "" for
    /// sessions outside tasks: how each day's rise of its weekly limit splits.
    public var claudeDayTasks: [[String: Double]]

    public static let burnSpan: TimeInterval = 30 * 60

    /// The earliest response a report counts at `now`: refresh the ledger
    /// since then.
    public static func since(now: TimeInterval, calendar: Calendar = .current) -> TimeInterval {
        dayStarts(now: now, calendar: calendar)[0]
    }

    public init(sessions: [UsageSession], now: TimeInterval, calendar: Calendar = .current) {
        generatedAt = now
        let starts = Self.dayStarts(now: now, calendar: calendar)
        day = Period(sessions, since: now - 86_400)
        week = Period(sessions, since: starts[0])

        struct DaySource: Hashable { let day: Int, source: Source }
        let byDay = sessions.summaries(since: starts[0]) { session, event in
            starts.lastIndex { $0 <= event.timestamp }.map { DaySource(day: $0, source: Source(session, event)) }
        }
        days = starts.indices.map { index in
            Day(start: starts[index], sources: Dictionary(uniqueKeysWithValues: Source.allCases.compactMap { source in
                byDay[DaySource(day: index, source: source)].map { (source, $0.weightedTokens) }
            }))
        }

        var latest: [String: LatestSession] = [:]
        for session in sessions {
            guard let task = session.attribution.taskID,
                  let last = session.events.lazy.filter({ $0.subagentID == nil }).map(\.timestamp).max(),
                  last > latest[task]?.lastResponseAt ?? -.infinity else { continue }
            latest[task] = LatestSession(
                key: session.key, contextTokens: session.contextTokens, contextWindow: session.contextWindow, lastResponseAt: last,
                subagents: session.subagents
            )
        }
        latestSessions = latest
        codexLimits = sessions.compactMap(\.rateLimits).max { $0.reportedAt < $1.reportedAt }
        codexReadings = CodexRateLimits.quotaReadings(sessions.flatMap(\.rateLimitReadings).filter { $0.reportedAt >= starts[0] })
        var minutes: [Int: Double] = [:]
        var burn: [String: Double] = [:]
        for session in sessions where session.key.agent == .claude {
            for event in session.events where event.timestamp >= now - 86_400 && event.timestamp <= now {
                let weighted = event.counts.weighted(model: event.model)
                minutes[Int(event.timestamp / 60), default: 0] += weighted
                if event.timestamp >= now - Self.burnSpan { burn[session.attribution.taskID ?? "", default: 0] += weighted }
            }
        }
        claudeMinutes = minutes
        claudeBurn = burn
        var dayTasks = Array(repeating: [String: Double](), count: starts.count)
        for session in sessions where session.key.agent == .claude {
            for event in session.events where event.timestamp >= starts[0] {
                guard let index = starts.lastIndex(where: { $0 <= event.timestamp }) else { continue }
                dayTasks[index][session.attribution.taskID ?? "", default: 0] += event.counts.weighted(model: event.model)
            }
        }
        claudeDayTasks = dayTasks
    }

    private static func dayStarts(now: TimeInterval, calendar: Calendar) -> [TimeInterval] {
        let today = calendar.startOfDay(for: Date(timeIntervalSince1970: now))
        return (0..<dayCount).reversed().map { back in
            (calendar.date(byAdding: .day, value: -back, to: today) ?? today).timeIntervalSince1970
        }
    }
}
