import Foundation

/// Per-workspace rules for "open this dev server in a browser column?"
/// proposals. Pure state so the rules are unit-testable; probing, timers
/// and UI live in WorkspaceState+LocalServers.swift.
///
/// A detected URL becomes a proposal only once its port accepts
/// connections. There is at most one proposal per port, and a dismissed
/// port is never proposed again in the workspace. Opening a proposal isn't
/// sticky: after that browser column closes, a fresh print (a server
/// restart) proposes the port again.
struct LocalServerProposalBook<ColumnID: Hashable> {
    struct Proposal: Equatable {
        let url: LocalServerURL
        /// The terminal column that printed the URL; its title bar shows the chip.
        let column: ColumnID
    }

    struct PendingProbe: Equatable {
        let url: LocalServerURL
        let column: ColumnID
        var attempts: Int
    }

    enum ProbeDecision: Equatable {
        case proposed
        case retry(after: TimeInterval)
        case dropped
    }

    /// Delay before each listening probe. The first one doubles as the
    /// debounce; the retries cover servers that print their URL just
    /// before binding (Django's runserver).
    static var probeDelays: [TimeInterval] { [0.3, 1.0, 3.0] }

    /// Detected URLs awaiting a listening probe, by port.
    private(set) var pending: [Int: PendingProbe] = [:]
    /// Live proposals, most recent first.
    private(set) var proposals: [Proposal] = []
    private(set) var dismissedPorts: Set<Int> = []

    /// A terminal printed `url`. Returns true when the caller should run the
    /// first listening probe after `probeDelays[0]`.
    mutating func noteDetected(_ url: LocalServerURL, in column: ColumnID, browserPorts: Set<Int>) -> Bool {
        let port = url.port
        guard pending[port] == nil,
              !proposals.contains(where: { $0.url.port == port }),
              !dismissedPorts.contains(port),
              !browserPorts.contains(port)
        else { return false }
        pending[port] = PendingProbe(url: url, column: column, attempts: 0)
        return true
    }

    mutating func probeFinished(
        port: Int,
        isListening: Bool,
        browserPorts: Set<Int>,
        liveColumns: Set<ColumnID>
    ) -> ProbeDecision {
        guard var probe = pending.removeValue(forKey: port) else { return .dropped }
        guard !dismissedPorts.contains(port),
              !browserPorts.contains(port),
              liveColumns.contains(probe.column)
        else { return .dropped }
        if isListening {
            proposals.insert(Proposal(url: probe.url, column: probe.column), at: 0)
            return .proposed
        }
        probe.attempts += 1
        guard probe.attempts < Self.probeDelays.count else { return .dropped }
        pending[port] = probe
        return .retry(after: Self.probeDelays[probe.attempts])
    }

    /// The chip for a terminal column: the most recent proposal it printed.
    func proposal(for column: ColumnID) -> Proposal? {
        proposals.first { $0.column == column }
    }

    /// Proposals still worth offering given the current columns — what the
    /// ⌘B prompt lists, most recent first.
    func liveProposals(browserPorts: Set<Int>, liveColumns: Set<ColumnID>) -> [Proposal] {
        proposals.filter { !browserPorts.contains($0.url.port) && liveColumns.contains($0.column) }
    }

    mutating func dismiss(port: Int) {
        proposals.removeAll { $0.url.port == port }
        dismissedPorts.insert(port)
    }

    mutating func markOpened(port: Int) {
        proposals.removeAll { $0.url.port == port }
    }

    /// Drops proposals whose server stopped (`stoppedPorts` holds only
    /// ports that were probed), whose port a browser column now shows, or
    /// whose terminal column is gone. Returns true when anything changed.
    @discardableResult
    mutating func prune(stoppedPorts: Set<Int> = [], browserPorts: Set<Int>, liveColumns: Set<ColumnID>) -> Bool {
        let before = proposals.count
        proposals.removeAll {
            stoppedPorts.contains($0.url.port)
                || browserPorts.contains($0.url.port)
                || !liveColumns.contains($0.column)
        }
        return proposals.count != before
    }
}
