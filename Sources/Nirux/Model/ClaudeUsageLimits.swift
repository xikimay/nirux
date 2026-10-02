import Foundation

/// The user's Claude plan usage limits, the 5-hour window and the weekly
/// limit, as Claude Code sessions in Nirux last reported them.
///
/// Claude Code reads them from its API responses and hands them to one
/// documented place only: the JSON its `statusLine` command receives
/// (`rate_limits`, Claude Code 2.1.80 or later, Pro and Max plans, absent
/// until a session's first response). Hooks don't carry them, `/usage` has
/// no non-interactive form, and nothing under ~/.claude stores them. So when
/// the user turns the indicator on, Nirux becomes Claude Code's status line
/// (see `AgentHookInstaller.installClaudeStatusLine`), and each run of
/// `Nirux --hook claude --statusline` folds its report into one file the
/// app reads (see `ClaudeUsageLimitsFile`).
struct ClaudeUsageLimits: Codable, Equatable, Sendable {
    struct Window: Codable, Equatable, Sendable {
        /// 0…100, past 100 once over the limit.
        var usedPercentage: Double
        /// Epoch seconds.
        var resetsAt: TimeInterval
        /// When a session in Nirux reported this reading (epoch seconds).
        var reportedAt: TimeInterval

        /// What the title bar shows, so that the color and the number agree.
        var displayedPercent: Int { Int(usedPercentage.rounded()) }
    }

    var fiveHour: Window?
    var sevenDay: Window?

    /// From 80% of either window, the indicator turns orange.
    static let nearLimitPercent = 80

    /// Two readings of one window name the same reset; a later window resets
    /// at least its length (5 hours) after the earlier one did. The margin
    /// absorbs a reset time that moves by a few seconds between responses.
    static let sameWindowTolerance: TimeInterval = 3600

    /// The latest reset Claude Code itself accepts: a year out.
    static let maximumResetDistance: TimeInterval = 366 * 24 * 3600

    /// Highest reading Nirux keeps: a malformed value must not print a
    /// ten-digit percentage.
    static let maximumPercentage: Double = 999

    init(fiveHour: Window? = nil, sevenDay: Window? = nil) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
    }

    /// The `rate_limits` of a status line payload. Nil when it has no window
    /// that resets in the future (a session before its first response, an
    /// API key or Bedrock session, a malformed payload).
    init?(statusLinePayload payload: [String: Any], now: TimeInterval) {
        guard let limits = payload["rate_limits"] as? [String: Any] else { return nil }
        fiveHour = Self.window(limits["five_hour"], now: now)
        sevenDay = Self.window(limits["seven_day"], now: now)
        guard fiveHour != nil || sevenDay != nil else { return nil }
    }

    private static func window(_ value: Any?, now: TimeInterval) -> Window? {
        guard let object = value as? [String: Any],
              let used = (object["used_percentage"] as? NSNumber)?.doubleValue,
              let resetsAt = (object["resets_at"] as? NSNumber)?.doubleValue,
              used.isFinite, resetsAt.isFinite,
              resetsAt > now, resetsAt < now + maximumResetDistance else { return nil }
        return Window(usedPercentage: min(max(0, used), maximumPercentage), resetsAt: resetsAt, reportedAt: now)
    }

    /// Without the windows that have reset by `now`; nil when none is left.
    func current(at now: TimeInterval) -> ClaudeUsageLimits? {
        let kept = ClaudeUsageLimits(
            fiveHour: fiveHour.flatMap { $0.resetsAt > now ? $0 : nil },
            sevenDay: sevenDay.flatMap { $0.resetsAt > now ? $0 : nil }
        )
        return kept.fiveHour == nil && kept.sevenDay == nil ? nil : kept
    }

    /// These readings updated with a session's `report`.
    func merging(_ report: ClaudeUsageLimits) -> ClaudeUsageLimits {
        ClaudeUsageLimits(
            fiveHour: Self.newer(fiveHour, report.fiveHour),
            sevenDay: Self.newer(sevenDay, report.sevenDay)
        )
    }

    /// Which of two readings of a window is the more recent. Each session
    /// knows only what its own last response said, and an idle one reports
    /// old numbers again (its status line runs again when its permission
    /// mode changes or its prompt cache expires). Within a window usage only
    /// grows, so the higher reading is the more recent one, and a reading
    /// of a later window replaces those of an earlier one. A tie keeps the
    /// existing reading: the report may be an idle session's.
    static func newer(_ existing: Window?, _ report: Window?) -> Window? {
        guard let existing else { return report }
        guard let report else { return existing }
        if report.resetsAt > existing.resetsAt + sameWindowTolerance { return report }
        if report.resetsAt < existing.resetsAt - sameWindowTolerance { return existing }
        return report.usedPercentage > existing.usedPercentage ? report : existing
    }

    /// Whether a window reached `nearLimitPercent`.
    var isNearLimit: Bool {
        [fiveHour, sevenDay].contains { ($0?.displayedPercent ?? 0) >= Self.nearLimitPercent }
    }

    /// "5h 42% · 7d 18%", with the windows Claude Code reported.
    var titleText: String {
        var parts: [String] = []
        if let fiveHour { parts.append("5h \(fiveHour.displayedPercent)%") }
        if let sevenDay { parts.append("7d \(sevenDay.displayedPercent)%") }
        return parts.joined(separator: " · ")
    }

    var accessibilityText: String {
        var parts: [String] = []
        if let fiveHour { parts.append("5-hour window \(fiveHour.displayedPercent)% used") }
        if let sevenDay { parts.append("weekly limit \(sevenDay.displayedPercent)% used") }
        return "Claude usage limits: " + parts.joined(separator: ", ")
    }

    /// The tooltip: each window with its reset, then when it was reported.
    func tooltip(now: TimeInterval, calendar: Calendar = .current) -> String {
        var lines = ["Claude plan usage limits"]
        if let fiveHour {
            lines.append("5-hour window: \(fiveHour.displayedPercent)% used, \(Self.resetText(fiveHour.resetsAt, now: now, calendar: calendar))")
        }
        if let sevenDay {
            lines.append("Weekly limit: \(sevenDay.displayedPercent)% used, \(Self.resetText(sevenDay.resetsAt, now: now, calendar: calendar))")
        }
        let reportedAt = max(fiveHour?.reportedAt ?? 0, sevenDay?.reportedAt ?? 0)
        let reported = Date(timeIntervalSince1970: reportedAt)
        let when = calendar.isDate(reported, inSameDayAs: Date(timeIntervalSince1970: now))
            ? Self.format(reported, template: "jmm", calendar: calendar)
            : Self.format(reported, template: "MMMdjmm", calendar: calendar)
        lines.append("Last reported at \(when) by a Claude session in Nirux.")
        lines.append("Use elsewhere (claude.ai, another Mac) counts from the next report.")
        return lines.joined(separator: "\n")
    }

    /// "resets at 17:30 (in 2h 10m)", "resets Tue 09:00 (in 4d 3h)".
    static func resetText(_ resetsAt: TimeInterval, now: TimeInterval, calendar: Calendar) -> String {
        let date = Date(timeIntervalSince1970: resetsAt)
        let today = Date(timeIntervalSince1970: now)
        let clock: String
        if calendar.isDate(date, inSameDayAs: today) {
            clock = "at " + format(date, template: "jmm", calendar: calendar)
        } else if resetsAt - now < 6 * 24 * 3600 {
            clock = format(date, template: "EEEjmm", calendar: calendar)
        } else {
            clock = format(date, template: "MMMdjmm", calendar: calendar)
        }
        return "resets \(clock) (in \(remainingText(resetsAt - now)))"
    }

    /// "45m", "2h 10m", "4d 3h": two units at most, never seconds.
    static func remainingText(_ interval: TimeInterval) -> String {
        let minutes = max(1, Int((interval / 60).rounded(.up)))
        let days = minutes / (24 * 60)
        let hours = minutes % (24 * 60) / 60
        let rest = minutes % 60
        if days > 0 { return hours > 0 ? "\(days)d \(hours)h" : "\(days)d" }
        if hours > 0 { return rest > 0 ? "\(hours)h \(rest)m" : "\(hours)h" }
        return "\(rest)m"
    }

    private static func format(_ date: Date, template: String, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = calendar.locale ?? .current
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }
}
