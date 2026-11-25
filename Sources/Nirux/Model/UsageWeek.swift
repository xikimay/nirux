import Foundation

/// Claude's week in points of its weekly limit: each day's rise
/// (`QuotaCalibration.dailyRise`) split between tasks by their share of
/// that day's Claude spend (`UsageReport.claudeDayTasks`), the busiest
/// `shownTasks` by name and the rest as one; and each task's points over
/// the week, at the week's points per token.
struct UsageWeek: Equatable {
    static let shownTasks = 4

    /// Task IDs, busiest first; "" is everything else.
    var tasks: [String]
    /// By day, then as `tasks`.
    var days: [[Double]]
    /// Points of the weekly limit per weighted token, over the days it rose.
    var pointsPerToken: Double?

    /// Nil without a rise to split (no readings of the weekly limit).
    init?(rise: [Double], dayTasks: [[String: Double]]) {
        guard rise.contains(where: { $0 > 0 }), rise.count == dayTasks.count else { return nil }
        var weekTokens: [String: Double] = [:]
        for day in dayTasks { for (task, tokens) in day where !task.isEmpty { weekTokens[task, default: 0] += tokens } }
        let top = weekTokens.sorted { $0.value > $1.value }.prefix(Self.shownTasks).map(\.key)
        tasks = top + [""]
        days = zip(rise, dayTasks).map { rise, spend in
            let total = spend.values.reduce(0, +)
            guard total > 0 else { return top.map { _ in 0 } + [rise] }
            let named = top.map { rise * (spend[$0] ?? 0) / total }
            return named + [rise - named.reduce(0, +)]
        }
        let risen = zip(rise, dayTasks).filter { $0.0 > 0 }
        let tokens = risen.reduce(0.0) { $0 + $1.1.values.reduce(0, +) }
        pointsPerToken = tokens > 0 ? risen.reduce(0.0) { $0 + $1.0 } / tokens : nil
    }
}
