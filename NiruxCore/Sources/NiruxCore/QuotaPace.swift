import Foundation

/// One reading of a plan usage limit: how full it was, when it resets, and
/// when an agent reported it.
public struct QuotaReading: Codable, Equatable, Sendable {
    public var time: TimeInterval
    /// 0…100, past 100 once over the limit.
    public var usedPercent: Double
    public var resetsAt: TimeInterval

    public init(time: TimeInterval, usedPercent: Double, resetsAt: TimeInterval) {
        self.time = time
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }
}

/// Where a limit is heading at the pace of its latest readings.
public enum QuotaForecast: Equatable, Sendable {
    /// Full until its reset.
    case reached
    /// Full before its reset, at this time.
    case runsOut(at: TimeInterval)
    /// Not full by its reset: about this much then.
    case atReset(percent: Int)
    /// No reading within the span: no agent in Nirux spends it.
    case quiet
    /// Too few readings to tell, or none of a window still running.
    case unknown
}

/// How many points of a window a weighted token is worth: the window's rise
/// over Claude's spend between its first reading and its latest
/// (`UsageReport.claudeMinutes`). An estimate: use elsewhere (claude.ai,
/// another Mac) counts in the readings, never in the spend.
public enum QuotaCalibration {
    /// Below this rise, the ratio is mostly rounding.
    public static let minimumRise = 3.0

    /// How much a limit rose each day from `dayStarts`: each reading's rise
    /// over the highest one of its window so far, on the reading's day.
    /// Readings of two windows can alternate (a session still reporting the
    /// last one after a reset, another account), so each window keeps its
    /// own; one first seen after the first reading climbed from 0 (a reset).
    public static func dailyRise(_ readings: [QuotaReading], dayStarts: [TimeInterval]) -> [Double] {
        var rise = Array(repeating: 0.0, count: dayStarts.count)
        var highest: [QuotaReading] = []
        for reading in readings.sorted(by: { $0.time < $1.time }) {
            let window = highest.firstIndex { abs($0.resetsAt - reading.resetsAt) <= QuotaPace.sameWindow }
            let from = window.map { highest[$0].usedPercent } ?? (highest.isEmpty ? reading.usedPercent : 0)
            if let window { highest[window].usedPercent = max(from, reading.usedPercent) } else { highest.append(reading) }
            guard reading.usedPercent > from, let day = dayStarts.lastIndex(where: { $0 <= reading.time }) else { continue }
            rise[day] += reading.usedPercent - from
        }
        return rise
    }

    public static func pointsPerToken(_ readings: [QuotaReading], minutes: [Int: Double]) -> Double? {
        guard let latest = readings.max(by: { $0.time < $1.time }) else { return nil }
        let window = readings.filter { abs($0.resetsAt - latest.resetsAt) <= QuotaPace.sameWindow }
        guard let first = window.min(by: { $0.time < $1.time }), latest.usedPercent - first.usedPercent >= minimumRise else { return nil }
        let tokens = minutes.reduce(0.0) { sum, entry in
            let time = Double(entry.key) * 60
            return time >= first.time && time < latest.time ? sum + entry.value : sum
        }
        return tokens > 0 ? (latest.usedPercent - first.usedPercent) / tokens : nil
    }
}

/// A plan limit as Nirux shows it: its latest reading and its forecast.
public struct QuotaLimit: Equatable, Sendable {
    public enum Agent: String, Sendable { case claude, codex }

    public var agent: Agent
    /// 5 hours, a week.
    public var length: TimeInterval
    public var latest: QuotaReading
    public var forecast: QuotaForecast

    /// Stable across readings: what `previous` forecasts are found by.
    public var id: String { "\(agent.rawValue).\(Int(length))" }

    /// Nil without a reading of a window still running at `now`.
    public init?(agent: Agent, length: TimeInterval, readings: [QuotaReading], now: TimeInterval, previous: QuotaForecast? = nil) {
        guard let latest = readings.filter({ $0.time <= now }).max(by: { $0.time < $1.time }), latest.resetsAt > now else { return nil }
        self.agent = agent
        self.length = length
        self.latest = latest
        forecast = QuotaPace.forecast(readings, span: QuotaPace.span(forWindowOf: length), now: now, previous: previous)
    }

    /// Full before its reset, or already: the agents will stop.
    public var runsOut: Bool {
        switch forecast {
        case .reached, .runsOut: true
        default: false
        }
    }

    /// The limit that stops the agents first: a full one (the one back last),
    /// then the one running out first, then the fullest by its reset (a limit
    /// without a forecast by its use now).
    public static func binding(_ limits: [QuotaLimit]) -> QuotaLimit? {
        func rank(_ limit: QuotaLimit) -> (Int, Double) {
            switch limit.forecast {
            case .reached: (0, -limit.latest.resetsAt)
            case .runsOut(let at): (1, at)
            case .atReset(let percent): (2, -Double(percent))
            case .quiet, .unknown: (2, -limit.latest.usedPercent)
            }
        }
        return limits.min { rank($0) < rank($1) }
    }
}

/// The pace of a limit: the slope of its readings over a recent span, drawn
/// as a straight line to its reset. A forecast that jumps loses trust, so it
/// waits for enough readings, rounds its time and holds it until it moves
/// by more than `steadiness`.
public enum QuotaPace {
    /// The slope's span for a window of up to `sessionWindow` (Claude's and
    /// Codex's 5 hours), and for longer ones (the week).
    public static let sessionSpan: TimeInterval = 30 * 60
    public static let weekSpan: TimeInterval = 24 * 3600
    static let sessionWindow: TimeInterval = 6 * 3600
    public static let minimumReadings = 3
    /// From its first reading in the span to its last.
    public static let minimumSpan: TimeInterval = 15 * 60
    /// A "runs out" time is rounded down to this.
    public static let rounding: TimeInterval = 5 * 60
    /// A new "runs out" time within this of the previous one keeps it.
    public static let steadiness: TimeInterval = 10 * 60
    /// Past this without a reading, the silence counts as a reading at `now`
    /// holding the latest percentage: the pace drops when spending stops.
    public static let silence: TimeInterval = 5 * 60
    /// Readings of one window share its reset, give or take this.
    public static let sameWindow: TimeInterval = 5 * 60

    public static func span(forWindowOf length: TimeInterval) -> TimeInterval {
        length <= sessionWindow ? sessionSpan : weekSpan
    }

    /// How much of a window of `length` has gone by, 0…1.
    public static func elapsed(resetsAt: TimeInterval, length: TimeInterval, now: TimeInterval) -> Double {
        guard length > 0 else { return 0 }
        return min(1, max(0, 1 - (resetsAt - now) / length))
    }

    /// `previous` is the forecast this limit showed last.
    public static func forecast(
        _ readings: [QuotaReading], span: TimeInterval, now: TimeInterval, previous: QuotaForecast? = nil
    ) -> QuotaForecast {
        guard let latest = readings.filter({ $0.time <= now }).max(by: { $0.time < $1.time }), latest.resetsAt > now else {
            return .unknown
        }
        if latest.usedPercent >= 100 { return .reached }
        let recent = readings
            .filter { abs($0.resetsAt - latest.resetsAt) <= sameWindow && $0.time >= now - span && $0.time <= now }
            .sorted { $0.time < $1.time }
        guard let first = recent.first else { return .quiet }
        guard recent.count >= minimumReadings, latest.time - first.time >= minimumSpan else { return .unknown }
        let held = now - latest.time >= silence ? QuotaReading(time: now, usedPercent: latest.usedPercent, resetsAt: latest.resetsAt) : latest
        let rate = max(0, slope(held == latest ? recent : recent + [held]))
        let atReset = held.usedPercent + rate * (held.resetsAt - held.time)
        // 100 % shows only as running out.
        guard rate > 0, atReset >= 100 else { return .atReset(percent: min(99, Int(atReset.rounded()))) }
        let full = held.time + (100 - held.usedPercent) / rate
        // Never a time already gone while the limit isn't full yet, nor one past its reset.
        let rounded = max((full / rounding).rounded(.down) * rounding, now)
        if case .runsOut(let shown) = previous, abs(shown - rounded) <= steadiness, shown > now, shown < latest.resetsAt {
            return .runsOut(at: shown)
        }
        return .runsOut(at: rounded)
    }

    /// Least squares, in percent per second.
    static func slope(_ readings: [QuotaReading]) -> Double {
        let count = Double(readings.count)
        let meanTime = readings.reduce(0) { $0 + $1.time } / count
        let meanUsed = readings.reduce(0) { $0 + $1.usedPercent } / count
        let spread = readings.reduce(0) { $0 + ($1.time - meanTime) * ($1.time - meanTime) }
        guard spread > 0 else { return 0 }
        return readings.reduce(0) { $0 + ($1.time - meanTime) * ($1.usedPercent - meanUsed) } / spread
    }
}
