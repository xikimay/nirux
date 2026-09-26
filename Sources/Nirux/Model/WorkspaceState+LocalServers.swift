import AppKit

/// Dev-server proposal state owned by each WorkspaceState.
struct LocalServerTracking {
    var book = LocalServerProposalBook<UUID>()
    /// One-shot timer for the next listener scan. Armed only while a
    /// detection is pending or a proposal is live.
    var scanTimer: Timer?
    var scanInFlight = false
    /// A URL was detected while a scan ran — that scan predates it.
    var detectedDuringScan = false
}

// MARK: - Dev-server proposals

/// A terminal printed `http://localhost:5173/` → once the port has a
/// listening socket, its title bar offers to open it in a browser column
/// of this workspace, and ⌘B lists it first. The proposal goes away when
/// opened, dismissed, the server stops, or a browser column shows the port.
extension WorkspaceState {
    private typealias Book = LocalServerProposalBook<UUID>

    /// Detected URLs for the ⌘B prompt, most recent first.
    var detectedLocalServerURLs: [String] {
        localServers.book
            .liveProposals(browserPorts: localServerBrowserPorts, liveColumns: localServerTerminalColumns)
            .map(\.url.urlString)
    }

    func setupLocalServerDetection(for col: ColumnState) {
        col.onLocalServerURLDetected = { [weak self, weak col] url in
            guard let self, let col else { return }
            self.noteLocalServerURL(url, in: col)
        }
        col.onLocalServerChipOpen = { [weak self, weak col] url in
            guard let self, let col else { return }
            self.openLocalServer(url, from: col)
        }
        col.onLocalServerChipDismiss = { [weak self] url in
            guard let self else { return }
            self.localServers.book.markHandled(port: url.port)
            self.localServerProposalsChanged()
        }
    }

    /// Drop proposals made stale by the current columns (a browser column
    /// now shows the port, the printing terminal closed).
    func pruneLocalServerProposals() {
        let changed = localServers.book.prune(
            browserPorts: localServerBrowserPorts,
            liveColumns: localServerTerminalColumns
        )
        if changed { localServerProposalsChanged() }
    }

    // MARK: - Detection → scan → proposal

    private var localServerBrowserPorts: Set<Int> {
        Set(columns.compactMap { col in
            col.webViewColumn.flatMap { LocalServerURL.loopbackPort(of: $0.currentURL) }
        })
    }

    private var localServerTerminalColumns: Set<UUID> {
        Set(columns.filter { $0.pty != nil }.map(\.id))
    }

    private func noteLocalServerURL(_ url: LocalServerURL, in col: ColumnState) {
        guard columns.contains(where: { $0 === col }),
              localServers.book.noteDetected(
                url,
                in: col.id,
                browserPorts: localServerBrowserPorts,
                now: ProcessInfo.processInfo.systemUptime
              )
        else { return }
        if localServers.scanInFlight { localServers.detectedDuringScan = true }
        scheduleLocalServerScan(after: Book.firstScanDelay)
    }

    /// Arms the one-shot scan timer, keeping an earlier deadline if one is
    /// already set. While a scan runs, its completion re-arms instead.
    private func scheduleLocalServerScan(after delay: TimeInterval) {
        guard !localServers.scanInFlight else { return }
        if let timer = localServers.scanTimer, timer.isValid,
           timer.fireDate <= Date(timeIntervalSinceNow: delay) {
            return
        }
        localServers.scanTimer?.invalidate()
        localServers.scanTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.runLocalServerScan()
            }
        }
    }

    private func runLocalServerScan() {
        localServers.scanTimer = nil
        guard localServers.book.nextScanDelay != nil else { return }
        localServers.scanInFlight = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let listening = LocalListeners.listeningPorts()
            DispatchQueue.main.async { [weak self] in
                self?.applyLocalServerScan(listening)
            }
        }
    }

    private func applyLocalServerScan(_ listening: Set<Int>) {
        localServers.scanInFlight = false
        let changed = localServers.book.applyScan(
            listeningPorts: listening,
            browserPorts: localServerBrowserPorts,
            liveColumns: localServerTerminalColumns,
            now: ProcessInfo.processInfo.systemUptime
        )
        if localServers.detectedDuringScan {
            localServers.detectedDuringScan = false
            scheduleLocalServerScan(after: Book.firstScanDelay)
        }
        if changed {
            localServerProposalsChanged()
        } else if let delay = localServers.book.nextScanDelay {
            scheduleLocalServerScan(after: delay)
        }
    }

    // MARK: - Chip actions

    private func openLocalServer(_ url: LocalServerURL, from col: ColumnState) {
        localServers.book.markHandled(port: url.port)
        localServerProposalsChanged()
        // Never a second browser column for the same server.
        if let existing = columns.firstIndex(where: { column in
            column.webViewColumn.flatMap { LocalServerURL.loopbackPort(of: $0.currentURL) } == url.port
        }) {
            onRevealColumn?(self, existing)
            return
        }
        // New columns insert after the focused one: open it next to the
        // terminal that printed the URL.
        if let index = columns.firstIndex(where: { $0 === col }) {
            focusedIndex = index
        }
        onTerminalOpenURL?(self, url.urlString)
    }

    /// Sync every terminal's chip with the book, and stop scanning once
    /// nothing is pending or live.
    private func localServerProposalsChanged() {
        for col in columns where col.pty != nil {
            col.setLocalServerChip(localServers.book.proposal(for: col.id)?.url)
        }
        if let delay = localServers.book.nextScanDelay {
            scheduleLocalServerScan(after: delay)
        } else {
            localServers.scanTimer?.invalidate()
            localServers.scanTimer = nil
        }
    }
}
