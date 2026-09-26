import Foundation

/// Per-workspace rules for "open this dev server in a browser column?"
/// proposals. Pure state so the rules are unit-testable; scanning, timers
/// and UI live in WorkspaceState+LocalServers.swift.
///
/// A detected URL waits for listener scans (see `LocalListeners`) and
/// becomes a proposal once its port is listening. One proposal per port:
/// a port the user opened or dismissed is never proposed again in the
/// workspace — TUIs like Claude Code repaint old URLs constantly, so
/// anything less would bring a handled chip straight back.
struct LocalServerProposalBook<ColumnID: Hashable> {
    struct Proposal: Equatable {
        let url: LocalServerURL
        /// The terminal column that printed the URL; its title bar shows the chip.
        let column: ColumnID
        /// When scans stopped finding a listener (nil while listening).
        var missingSince: TimeInterval?
    }

    struct PendingDetection: Equatable {
        let url: LocalServerURL
        let column: ColumnID
        let detectedAt: TimeInterval
    }

    /// First scan after a detection — also the debounce that lets the
    /// server finish binding.
    static var firstScanDelay: TimeInterval { 0.3 }
    /// Rescan cadence while detections are pending.
    static var pendingScanInterval: TimeInterval { 1 }
    /// How long a detection may wait for its port to start listening
    /// (Django prints its URL before binding).
    static var pendingWindow: TimeInterval { 4 }
    /// Rescan cadence while proposals are live, to notice stopped servers.
    static var livenessScanInterval: TimeInterval { 3 }
    /// A proposal survives its port being unbound this long: restarts
    /// (Django autoreload, Vite config reload) briefly unbind it without
    /// reprinting the URL. In seconds, not scans — scans run faster while
    /// a detection is pending.
    static var removalGrace: TimeInterval { 3 }
    /// Output listing hundreds of ports shouldn't queue hundreds of detections.
    static var maxPending: Int { 16 }

    /// Detections waiting for a scan, by port.
    private(set) var pending: [Int: PendingDetection] = [:]
    /// Live proposals, most recent first.
    private(set) var proposals: [Proposal] = []
    /// Ports opened or dismissed from a proposal.
    private(set) var handledPorts: Set<Int> = []

    /// When the next listener scan should run, relative to now; nil when
    /// nothing needs one.
    var nextScanDelay: TimeInterval? {
        if !pending.isEmpty { return Self.pendingScanInterval }
        if !proposals.isEmpty { return Self.livenessScanInterval }
        return nil
    }

    /// A terminal printed `url`. Returns true when it is now waiting for a
    /// scan — the caller should scan within `firstScanDelay`.
    mutating func noteDetected(
        _ url: LocalServerURL,
        in column: ColumnID,
        browserPorts: Set<Int>,
        now: TimeInterval
    ) -> Bool {
        let port = url.port
        guard pending[port] == nil,
              pending.count < Self.maxPending,
              !proposals.contains(where: { $0.url.port == port }),
              !handledPorts.contains(port),
              !browserPorts.contains(port)
        else { return false }
        pending[port] = PendingDetection(url: url, column: column, detectedAt: now)
        return true
    }

    /// Apply one listener scan to pending detections and live proposals.
    /// Returns true when the proposals changed.
    @discardableResult
    mutating func applyScan(
        listeningPorts: Set<Int>,
        browserPorts: Set<Int>,
        liveColumns: Set<ColumnID>,
        now: TimeInterval
    ) -> Bool {
        let before = proposals.map(\.url)
        for index in proposals.indices {
            if listeningPorts.contains(proposals[index].url.port) {
                proposals[index].missingSince = nil
            } else if proposals[index].missingSince == nil {
                proposals[index].missingSince = now
            }
        }
        proposals.removeAll {
            $0.missingSince.map { now - $0 >= Self.removalGrace } == true
                || browserPorts.contains($0.url.port)
                || !liveColumns.contains($0.column)
        }
        // Oldest detections first, so the newest ends up first in `proposals`.
        for detection in pending.values.sorted(by: { $0.detectedAt < $1.detectedAt }) {
            let port = detection.url.port
            if browserPorts.contains(port) || !liveColumns.contains(detection.column) {
                pending[port] = nil
            } else if listeningPorts.contains(port) {
                pending[port] = nil
                proposals.insert(Proposal(url: detection.url, column: detection.column), at: 0)
            } else if now - detection.detectedAt >= Self.pendingWindow {
                pending[port] = nil
            }
        }
        return proposals.map(\.url) != before
    }

    /// Drops what the current columns made stale (a browser column now
    /// shows the port, the printing terminal closed) without a scan.
    @discardableResult
    mutating func prune(browserPorts: Set<Int>, liveColumns: Set<ColumnID>) -> Bool {
        pending = pending.filter { !browserPorts.contains($0.key) && liveColumns.contains($0.value.column) }
        let before = proposals.count
        proposals.removeAll { browserPorts.contains($0.url.port) || !liveColumns.contains($0.column) }
        return proposals.count != before
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

    /// The user opened or dismissed the proposal for `port`.
    mutating func markHandled(port: Int) {
        proposals.removeAll { $0.url.port == port }
        pending[port] = nil
        handledPorts.insert(port)
    }
}
