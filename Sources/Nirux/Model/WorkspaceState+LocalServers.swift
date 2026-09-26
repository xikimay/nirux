import AppKit

/// Dev-server proposal state owned by each WorkspaceState.
struct LocalServerTracking {
    var book = LocalServerProposalBook<ObjectIdentifier>()
    /// Runs only while at least one proposal is live.
    var livenessTimer: Timer?
    var livenessProbeInFlight = false
}

// MARK: - Dev-server proposals

/// A terminal printed `http://localhost:5173/` → once the port accepts
/// connections, its title bar offers to open it in a browser column of
/// this workspace, and ⌘B lists it first. The proposal goes away when
/// opened, dismissed, the server stops, or a browser column shows the port.
extension WorkspaceState {
    static let localServerLivenessInterval: TimeInterval = 3

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
            self.localServers.book.dismiss(port: url.port)
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

    // MARK: - Detection → probe → proposal

    private var localServerBrowserPorts: Set<Int> {
        Set(columns.compactMap { col in
            col.webViewColumn.flatMap { LocalServerURL.loopbackPort(of: $0.currentURL) }
        })
    }

    private var localServerTerminalColumns: Set<ObjectIdentifier> {
        Set(columns.filter { $0.pty != nil }.map(ObjectIdentifier.init))
    }

    private func noteLocalServerURL(_ url: LocalServerURL, in col: ColumnState) {
        guard columns.contains(where: { $0 === col }),
              localServers.book.noteDetected(url, in: ObjectIdentifier(col), browserPorts: localServerBrowserPorts)
        else { return }
        probeLocalServer(url, after: LocalServerProposalBook<ObjectIdentifier>.probeDelays[0])
    }

    private func probeLocalServer(_ url: LocalServerURL, after delay: TimeInterval) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [weak self] in
            let isListening = LocalPortProbe.isListening(url)
            DispatchQueue.main.async { [weak self] in
                self?.applyLocalServerProbe(url, isListening: isListening)
            }
        }
    }

    private func applyLocalServerProbe(_ url: LocalServerURL, isListening: Bool) {
        let decision = localServers.book.probeFinished(
            port: url.port,
            isListening: isListening,
            browserPorts: localServerBrowserPorts,
            liveColumns: localServerTerminalColumns
        )
        switch decision {
        case .proposed:
            localServerProposalsChanged()
        case .retry(let delay):
            probeLocalServer(url, after: delay)
        case .dropped:
            break
        }
    }

    // MARK: - Chip actions

    private func openLocalServer(_ url: LocalServerURL, from col: ColumnState) {
        localServers.book.markOpened(port: url.port)
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

    // MARK: - Chips + liveness

    private func localServerProposalsChanged() {
        for col in columns where col.pty != nil {
            col.setLocalServerChip(localServers.book.proposal(for: ObjectIdentifier(col))?.url)
        }
        updateLocalServerLivenessTimer()
    }

    /// One-shot timer, re-armed after each probe round: rounds never
    /// overlap, and nothing keeps firing once the workspace is gone.
    private func updateLocalServerLivenessTimer() {
        guard !localServers.book.proposals.isEmpty else {
            localServers.livenessTimer?.invalidate()
            localServers.livenessTimer = nil
            return
        }
        guard localServers.livenessTimer == nil, !localServers.livenessProbeInFlight else { return }
        localServers.livenessTimer = Timer.scheduledTimer(
            withTimeInterval: Self.localServerLivenessInterval,
            repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.localServers.livenessTimer = nil
                self.checkLocalServerLiveness()
            }
        }
    }

    private func checkLocalServerLiveness() {
        let urls = localServers.book.proposals.map(\.url)
        guard !urls.isEmpty else { return }
        localServers.livenessProbeInFlight = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let stopped = Set(urls.filter { !LocalPortProbe.isListening($0) }.map(\.port))
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.localServers.livenessProbeInFlight = false
                let changed = self.localServers.book.prune(
                    stoppedPorts: stopped,
                    browserPorts: self.localServerBrowserPorts,
                    liveColumns: self.localServerTerminalColumns
                )
                if changed {
                    self.localServerProposalsChanged()
                } else {
                    self.updateLocalServerLivenessTimer()
                }
            }
        }
    }
}
