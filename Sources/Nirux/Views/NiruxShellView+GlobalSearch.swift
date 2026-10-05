import AppKit

// MARK: - Search Everywhere (⌥⌘F)

extension NiruxShellView {
    func showGlobalSearch() {
        guard let window else { return }
        if globalSearchPanel == nil { globalSearchPanel = GlobalSearchPanel() }
        globalSearchPanel?.show(
            relativeTo: window,
            targets: { [weak self] in self?.globalSearchTargets() ?? [] },
            sessions: { [weak self] in self?.globalSearchSessions() ?? [] },
            onPick: { [weak self] pick in self?.revealSearchMatch(pick) },
            onPickSession: { [weak self] session in
                self?.window?.makeKey()
                self?.resumeSession(session.record, spaceID: session.spaceID)
            }
        )
    }

    /// Sessions one search may try, before the files that are gone are
    /// skipped (see `GlobalTerminalSearch.maxSearchedTranscripts`).
    static let maxTranscriptCandidates = 1000

    /// The Claude sessions of every space whose transcript the history
    /// knows, the most recently active first, the current space's first
    /// among equals. Running ones too: a no-flicker conversation has no
    /// scrollback to search.
    func globalSearchSessions() -> [GlobalSearchPanel.Session] {
        let spaces = [activeProfileID] + profiles.map(\.id).filter { $0 != activeProfileID }
        let records = spaces.enumerated().flatMap { rank, spaceID in
            sessionLedger.sessions(inSpace: spaceID, matching: AgentSessionLedger.Query(agent: .claude))
                .filter { $0.transcriptPath != nil }
                .map { (record: $0, spaceID: spaceID, rank: rank) }
        }
        return records
            .sorted { ($0.record.lastActivityAt, -$0.rank) > ($1.record.lastActivityAt, -$1.rank) }
            .prefix(Self.maxTranscriptCandidates)
            .compactMap { entry in
                entry.record.transcriptPath.map {
                    GlobalSearchPanel.Session(
                        record: entry.record, spaceID: entry.spaceID,
                        title: SessionHistory.title(of: entry.record), transcriptPath: $0
                    )
                }
            }
    }

    /// Every terminal column of every workspace: the active workspace's
    /// first, then the rest of its project in sidebar order, then the
    /// other projects'. Columns read left to right. A terminal whose shell
    /// exited is left out: its restart overlay hides the find bar.
    func globalSearchTargets() -> [GlobalSearchPanel.Target] {
        let visible = visibleWorkspaceIndices
        let order = [activeWSIndex]
            + visible.filter { $0 != activeWSIndex }
            + workspaces.indices.filter { $0 != activeWSIndex && !visible.contains($0) }
        return order.compactMap { workspaces[safe: $0] }
            .filter { !$0.isClosing }
            .flatMap { workspace in
                workspace.columns.enumerated().compactMap { index, column -> GlobalSearchPanel.Target? in
                    guard !column.isClosing, column.terminalView != nil,
                          let pty = column.pty, !pty.hasExited
                    else { return nil }
                    let session = pty.terminalSession
                    return GlobalSearchPanel.Target(
                        column: column,
                        place: columnPlace(workspace: workspace, index: index),
                        read: { TerminalScreenText.read(session) }
                    )
                }
            }
    }

    /// Brings the picked match's column forward, wherever it is now, and
    /// opens its find bar on the match, found again in the terminal's
    /// text: output may have been printed and old lines dropped since the
    /// search.
    func revealSearchMatch(_ pick: GlobalSearchPanel.Pick) {
        let column = pick.column
        guard let workspace = workspaces.first(where: { $0.columns.contains { $0 === column } }),
              let columnIndex = workspace.columns.firstIndex(where: { $0 === column }),
              let session = column.pty?.terminalSession
        else { return NSSound.beep() }
        window?.makeKey()
        focusWorkspace(id: workspace.id, column: columnIndex)
        guard let mark = column.showFindBar(searching: pick.needle) else { return }
        let (fromBottom, total) = (pick.match.fromBottom, pick.total)
        GlobalTerminalSearch.relocate(pick.match, of: pick.needle, read: { TerminalScreenText.read(session) }) { [weak column] found in
            let delay = TerminalSearchSession.pickDelay(textBytes: found?.textBytes ?? 0)
            column?.selectFindMatch(
                fromBottom: found?.fromBottom ?? fromBottom, of: found?.total ?? total, after: delay, since: mark
            )
        }
    }
}
