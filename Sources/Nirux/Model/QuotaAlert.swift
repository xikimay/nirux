import Foundation

/// A notification a plan limit earns, once per window each: "full by" when
/// its pace fills it at least `leadTime` before its reset, then "full" once
/// it is.
struct QuotaAlert: Equatable {
    enum Kind: String { case runsOut, reached }

    static let leadTime: TimeInterval = 20 * 60

    var kind: Kind
    var limit: QuotaLimit

    /// The limit and the kind: `QuotaAlerter.sent` holds the reset of the
    /// window each went out for.
    var key: String { "\(limit.id).\(kind.rawValue)" }

    /// `sent`: by `key`, the reset of the window it went out for; a reset
    /// within `QuotaPace.sameWindow` is the same window.
    static func due(_ limits: [QuotaLimit], sent: [String: TimeInterval]) -> [QuotaAlert] {
        limits.compactMap { limit -> QuotaAlert? in
            switch limit.forecast {
            case .runsOut(let at) where limit.latest.resetsAt - at >= leadTime: QuotaAlert(kind: .runsOut, limit: limit)
            case .reached: QuotaAlert(kind: .reached, limit: limit)
            default: nil
            }
        }.filter { alert in
            sent[alert.key].map { abs($0 - alert.limit.latest.resetsAt) <= QuotaPace.sameWindow } != true
        }
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

/// Where the alerts sent wait between launches: an update, a crash or a
/// quit within a window must not post them again.
struct QuotaAlertStore {
    var url = Persistence.stateDirectory.appendingPathComponent("quota-alerts.json")

    func load() -> [String: TimeInterval] {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: TimeInterval].self, from: $0) } ?? [:]
    }

    func save(_ sent: [String: TimeInterval]) {
        try? JSONEncoder().encode(sent).write(to: url, options: .atomic)
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
    /// Whether it went out: none while Nirux is the active app. It builds
    /// the notice (`burner` reads the process table) only to post it.
    private let post: (() -> Notice) -> Bool
    private let store: QuotaAlertStore
    /// By `QuotaAlert.key`, the reset of the window it went out for.
    private(set) var sent: [String: TimeInterval]

    init(isEnabled: @escaping () -> Bool, burner: @escaping () -> QuotaBurnRow?, post: @escaping (() -> Notice) -> Bool, store: QuotaAlertStore = QuotaAlertStore()) {
        self.isEnabled = isEnabled
        self.burner = burner
        self.post = post
        self.store = store
        sent = store.load()
    }

    func check(_ limits: [QuotaLimit], now: TimeInterval, calendar: Calendar = .current) {
        // A window past its reset never comes back.
        var sent = self.sent.filter { $0.value > now }
        let due = QuotaAlert.due(limits, sent: sent)
        if !due.isEmpty {
            // Off, they count as handled: the setting isn't read again until the next window.
            let enabled = isEnabled()
            for alert in due where !enabled || post({ notice(for: alert, now: now, calendar: calendar) }) {
                sent[alert.key] = alert.limit.latest.resetsAt
            }
        }
        guard sent != self.sent else { return }
        self.sent = sent
        store.save(sent)
    }

    private func notice(for alert: QuotaAlert, now: TimeInterval, calendar: Calendar) -> Notice {
        let top = alert.limit.agent == .claude ? burner() : nil
        let text = alert.text(burner: top, now: now, calendar: calendar)
        let compact = top?.actions.lazy.compactMap { action -> UUID? in
            if case .compactAtTurnEnd(let column) = action { column } else { nil }
        }.first
        return Notice(title: text.title, body: text.body, workspaceID: top?.workspaceID, compactColumn: compact)
    }
}
