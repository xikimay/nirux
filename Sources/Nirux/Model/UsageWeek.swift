import Foundation

/// Claude's week in points of its weekly limit: each day's rise
/// (`QuotaCalibration.dailyRise`) split between tasks by their share of
/// that day's Claude spend (`UsageReport.claudeDayTasks`); the
/// `shownTasks` with the most points by name and the rest as one, and each
/// task's points over the week. The chart and the table both read it.
struct UsageWeek: Equatable {
    static let shownTasks = 4

    /// Task IDs, most points first; "" is everything else.
    var tasks: [String]
    /// By day, then as `tasks`.
    var days: [[Double]]
    /// Each task's share of each day's rise, summed: a day without a rise
    /// (before the readings began, say) gives nothing.
    var points: [String: Double]

    /// Nil without a rise to split (no readings of the weekly limit).
    init?(rise: [Double], dayTasks: [[String: Double]]) {
        guard rise.contains(where: { $0 > 0 }), rise.count == dayTasks.count else { return nil }
        // A rise without Claude spending in Nirux (claude.ai alone) goes to no task.
        let shares = zip(rise, dayTasks).map { rise, spend in
            let total = spend.values.reduce(0, +)
            return total > 0 && rise > 0 ? spend.mapValues { rise * $0 / total } : [:]
        }
        points = shares.reduce(into: [:]) { sum, day in
            for (task, points) in day where !task.isEmpty { sum[task, default: 0] += points }
        }
        let top = points.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(Self.shownTasks).map(\.key)
        tasks = top + [""]
        days = zip(rise, shares).map { rise, share in
            let named = top.map { share[$0] ?? 0 }
            return named + [rise - named.reduce(0, +)]
        }
    }
}
