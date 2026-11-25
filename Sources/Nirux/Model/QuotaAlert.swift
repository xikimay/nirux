import Foundation

/// A notification a plan limit earns, once per window each: "full by" when
/// its pace fills it at least `leadTime` before its reset, then "full" once
/// it is.
struct QuotaAlert: Equatable {
    enum Kind: String { case runsOut, reached }

    static let leadTime: TimeInterval = 20 * 60

    var kind: Kind
    var limit: QuotaLimit

    /// Once per window: the limit, its reset and the kind.
    var key: String { "\(limit.id) \(Int(limit.latest.resetsAt)) \(kind.rawValue)" }

    static func due(_ limits: [QuotaLimit], sent: Set<String>) -> [QuotaAlert] {
        limits.compactMap { limit -> QuotaAlert? in
            switch limit.forecast {
            case .runsOut(let at) where limit.latest.resetsAt - at >= leadTime: QuotaAlert(kind: .runsOut, limit: limit)
            case .reached: QuotaAlert(kind: .reached, limit: limit)
            default: nil
            }
        }.filter { !sent.contains($0.key) }
    }

    /// "Claude’s 5-hour window will be full by 20:05" and when it resets,
    /// then what spends it most.
    func text(burner: QuotaBurnRow?, now: TimeInterval, calendar: Calendar) -> (title: String, body: String) {
        let name = UsageText.longName(of: limit).replacingOccurrences(of: " · ", with: "’s ")
        let reset = ClaudeUsageLimits.resetText(limit.latest.resetsAt, now: now, calendar: calendar)
        let spender = burner.map { burner in
            " “\(burner.title)” spends the most" + (burner.cause.map { ": \($0.prefix(1).lowercased() + $0.dropFirst())." } ?? ".")
        } ?? ""
        switch (kind, limit.forecast) {
        case (.runsOut, .runsOut(let at)):
            return ("\(name) will be full by \(ClaudeUsageLimits.clockText(at, now: now, calendar: calendar))", "Then it \(reset)." + spender)
        default:
            return ("\(name) is full", "It \(reset)." + spender)
        }
    }
}

/// Posts each limit's alerts once per window, while the setting is on, with
/// what spends Claude's session most.
@MainActor
final class QuotaAlerter {
    struct Notice: Equatable {
        var title: String
        var body: String
        /// The task that spends most: a click opens it.
        var workspaceID: String?
        /// Its claude's column, when it offers Compact at turn end.
        var compactColumn: UUID?
    }

    private let isEnabled: () -> Bool
    private let burner: () -> QuotaBurnRow?
    private let post: (Notice) -> Void
    private(set) var sent: Set<String> = []

    init(isEnabled: @escaping () -> Bool, burner: @escaping () -> QuotaBurnRow?, post: @escaping (Notice) -> Void) {
        self.isEnabled = isEnabled
        self.burner = burner
        self.post = post
    }

    func check(_ limits: [QuotaLimit], now: TimeInterval, calendar: Calendar = .current) {
        let due = QuotaAlert.due(limits, sent: sent)
        guard !due.isEmpty, isEnabled() else { return }
        for alert in due {
            sent.insert(alert.key)
            let top = alert.limit.agent == .claude ? burner() : nil
            let text = alert.text(burner: top, now: now, calendar: calendar)
            let compact = top?.actions.lazy.compactMap { action -> UUID? in
                if case .compactAtTurnEnd(let column) = action { column } else { nil }
            }.first
            post(Notice(title: text.title, body: text.body, workspaceID: top?.workspaceID, compactColumn: compact))
        }
    }
}
