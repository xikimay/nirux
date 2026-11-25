import Foundation

/// Keeps the token usage ledger (NiruxCore's `UsageLedger`) read off the
/// main thread, and hands each new `UsageReport` to the main actor: the
/// task rows, the space picker, the title bar and the Usage window.
@MainActor
final class UsageMonitor {
    /// A refresh with nothing new takes tens of milliseconds.
    static let refreshInterval: TimeInterval = 20

    /// The latest read's; a flow sets its own.
    var report: UsageReport?
    var onReport: ((UsageReport) -> Void)?
    private let reader: Reader
    private let catalog: () -> UsageCatalog
    private var timer: Timer?
    private var isRefreshing = false

    /// `catalog` is asked before each refresh.
    init(sources: UsageSources, catalog: @escaping () -> UsageCatalog) {
        reader = Reader(ledger: UsageLedger(sources: sources))
        self.catalog = catalog
    }

    func start() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    /// The first one reads the whole week: seconds.
    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        let asked = catalog()
        let reader = reader
        reader.queue.async {
            let report = reader.read(catalog: asked, now: Date().timeIntervalSince1970)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.isRefreshing = false
                    self.report = report
                    self.onReport?(report)
                    // Tasks found during a long read (git contexts after the
                    // restore): credited now, not at the next tick.
                    if self.catalog() != asked { self.refresh() }
                }
            }
        }
    }

    /// The ledger, touched on `queue` only.
    private final class Reader: @unchecked Sendable {
        let queue = DispatchQueue(label: "Nirux.UsageMonitor", qos: .utility)
        private var ledger: UsageLedger

        init(ledger: UsageLedger) {
            self.ledger = ledger
        }

        func read(catalog: UsageCatalog, now: TimeInterval) -> UsageReport {
            if ledger.catalog != catalog { ledger.catalog = catalog }
            let since = UsageReport.since(now: now)
            while !ledger.refresh(since: since) {}
            return UsageReport(sessions: ledger.sessions, now: now)
        }
    }
}
