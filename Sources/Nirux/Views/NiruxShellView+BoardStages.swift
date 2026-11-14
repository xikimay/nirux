import Foundation

// MARK: - What the Board as stages reads of a space (docs/design/board-stages.md, section 6)

extension NiruxShellView {
    /// What the Board says of each task of a space, by workspace id: its
    /// sidebar row as the sidebar builds it, for any space, the one on
    /// screen or another (`sidebarColumnInfo`), without ticking anything:
    /// the sidebar ticks every agent once a pass, a space off screen's too,
    /// and the Board reads that pass's status. Then what the row doesn't
    /// hold (`BoardStages.TaskReading.init(_:summary:gitRoot:...)`).
    /// `approvalHolds` and `missionQuestions` are the sidebar's pass's:
    /// reading them again would hand requests back or note hand-offs.
    func boardReadings(
        ofSpace spaceID: String,
        foregroundProcesses: [ObjectIdentifier: ForegroundProcess],
        approvalHolds: [ObjectIdentifier: PermissionApprovalHold],
        missionQuestions: [ObjectIdentifier: SidebarMissionQuestion],
        snapshot: ProcessSnapshot,
        now: TimeInterval
    ) -> [String: BoardStages.TaskReading] {
        let parents = workspaceStore.activeParents(in: spaceID)
        var readings: [String: BoardStages.TaskReading] = [:]
        for index in workspaceStore.visibleWorkspaceIndices(in: spaceID) where !workspaces[index].isClosing {
            let workspace = workspaces[index]
            let isActive = index == activeWSIndex
            let columns = workspace.columns.enumerated().map { colIndex, col in
                let isUserFocused = colIndex == workspace.focusedIndex && isActive
                return sidebarColumnInfo(
                    col, at: colIndex, isUserFocused: isUserFocused, agentStatus: col.pty?.cachedAgentState ?? .idle,
                    foregroundProcess: foregroundProcesses[ObjectIdentifier(col)], approvalHold: approvalHolds[ObjectIdentifier(col)],
                    missionQuestion: missionQuestions[ObjectIdentifier(col)], showsDialog: false, snapshot: snapshot, now: now
                )
            }
            let info = sidebarWorkspaceInfo(
                at: index, columns: columns, isActive: isActive, parentTitle: parents[index].map { workspaces[$0].title }
            )
            readings[workspace.id] = BoardStages.TaskReading(
                info,
                summary: workspace.lastSummaryIsManual ? Self.oneLine(workspace.lastSummary) : nil,
                gitRoot: workspace.gitContext.map { Self.comparablePath($0.identity.repositoryRoot) },
                reviewsInFlight: Self.reviewsInFlight(of: workspace),
                turnStartedAt: { id in
                    workspace.columns.first { $0.id == id }?.pty?.agentTurnStartedAt?.timeIntervalSince1970
                }
            )
        }
        return readings
    }

    /// The review passes running: each recorded at its turn's start, in a
    /// turn still running (a run kept from an earlier turn is done).
    nonisolated static func reviewsInFlight(runs: [ReviewPass: ReviewRun], turnsStartedAt: [TimeInterval]) -> Set<ReviewPass> {
        Set(runs.compactMap { pass, run in turnsStartedAt.contains { run.at >= $0 } ? pass : nil })
    }

    private static func reviewsInFlight(of workspace: WorkspaceState) -> Set<ReviewPass> {
        let turns = workspace.columns.compactMap { column -> TimeInterval? in
            guard let pty = column.pty, pty.cachedAgentState == .working else { return nil }
            return pty.agentTurnStartedAt?.timeIntervalSince1970
        }
        return reviewsInFlight(runs: workspace.reviewRuns, turnsStartedAt: turns)
    }

    /// What the user wrote, on one line; nil when empty.
    private static func oneLine(_ text: String?) -> String? {
        let words = (text ?? "").split(whereSeparator: \.isWhitespace)
        return words.isEmpty ? nil : words.joined(separator: " ")
    }
}
