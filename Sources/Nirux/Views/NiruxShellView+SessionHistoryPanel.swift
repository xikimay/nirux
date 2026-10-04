import AppKit

// MARK: - Session History panel (⌘P › Session History…)

extension NiruxShellView {
    func showSessionHistory() {
        guard let window else { return }
        if sessionHistoryPanel == nil { sessionHistoryPanel = SessionHistoryPanel() }
        let spaceID = activeProfileID
        sessionHistoryPanel?.show(
            relativeTo: window,
            rows: sessionHistoryRows(spaceID: spaceID),
            plan: { [weak self] record, done in
                // After a worktree a Resume is bringing back, not halfway;
                // but read elsewhere, so a Resume never waits behind it.
                let queue = self?.sessionResume.queue(for: record) ?? .global(qos: .userInitiated)
                queue.async {
                    DispatchQueue.global(qos: .userInitiated).async {
                        let plan = AgentSessionResume.planOnDisk(for: record, now: Date().timeIntervalSince1970)
                        DispatchQueue.main.async { done(plan) }
                    }
                }
            },
            onPick: { [weak self] row in
                self?.window?.makeKey()
                // Where the session is now, not where it was listed.
                self?.resumeSession(row.record, spaceID: spaceID)
            }
        )
    }

    /// Every prompted session of the space, each with the column that
    /// holds it, read once as the panel opens: the filters work on these.
    func sessionHistoryRows(spaceID: String) -> [SessionHistoryRow] {
        let snapshot = ProcessSnapshot()
        let now = Date().timeIntervalSince1970
        let holders = agentSessionHolders(snapshot: snapshot)
        return SessionHistory.rows(
            sessionLedger.sessions(inSpace: spaceID),
            holder: { [self] record in
                HeldAgentSession.find(record.sessionID, in: holders) ?? recordedColumn(of: record)
            },
            place: { [self] held in column(of: held).map { columnPlace(workspace: $0.workspace, index: $0.index) } },
            liveState: { [self] record, held in
                guard held.state == .running, let column = column(of: held)?.column,
                      Self.frontAgent(of: column, snapshot: snapshot, runs: record.sessionID)
                else { return nil }
                let waits = quickSwitch.agentWait(column, snapshot, now).map { [$0] } ?? []
                return .summary(waits: waits, isWorking: column.pty?.cachedAgentState == .working)
            }
        )
    }

    /// The agent in front of the column runs that session: the column's
    /// state is its state, not that of a job stopped behind it.
    private static func frontAgent(of column: ColumnState, snapshot: ProcessSnapshot, runs sessionID: String) -> Bool {
        guard let foreground = column.pty?.foregroundProcess(snapshot: snapshot) else { return false }
        let confirmed = [
            column.confirmedClaudeSessionID(foregroundProcess: foreground), column.boundCodexSessionID(of: foreground.instance)
        ].compactMap { $0 }
        return confirmed.isEmpty
            ? AgentSessionHolder.mentions(sessionID, in: foreground.arguments)
            : confirmed.contains(sessionID)
    }

    private func column(of held: HeldAgentSession) -> (workspace: WorkspaceState, index: Int, column: ColumnState)? {
        guard let workspace = workspaces.first(where: { $0.id == held.workspaceID }),
              let index = workspace.columns.firstIndex(where: { $0.id == held.columnID })
        else { return nil }
        return (workspace, index, workspace.columns[index])
    }

    /// "workspace › column", as Search Everywhere names a terminal.
    func columnPlace(workspace: WorkspaceState, index: Int) -> String {
        let title = workspace.columns[safe: index]?.titleText ?? ""
        return "\(workspace.title) › \(title.isEmpty ? "Terminal \(index + 1)" : title)"
    }
}
