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
    /// reading them again would hand requests back or note hand-offs. The
    /// rows the sidebar just built (`sidebarInfos`, the space on screen's)
    /// are taken as they are. `comparable` gives a git root the rows' form
    /// of a path: the Board's own, which knows its paths without the disk
    /// (`ProjectBoardController.comparableFolder`). The Lead is
    /// read too: the space's header says it.
    func boardReadings(
        ofSpace spaceID: String,
        sidebarInfos: [WorkspaceInfo] = [],
        foregroundProcesses: [ObjectIdentifier: ForegroundProcess],
        approvalHolds: [ObjectIdentifier: PermissionApprovalHold],
        missionQuestions: [ObjectIdentifier: SidebarMissionQuestion],
        snapshot: ProcessSnapshot,
        now: TimeInterval,
        comparable: (String) -> String
    ) -> [String: BoardStages.TaskReading] {
        let built = Dictionary(sidebarInfos.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let parents = workspaceStore.activeParents(in: spaceID)
        var readings: [String: BoardStages.TaskReading] = [:]
        for index in workspaceStore.visibleWorkspaceIndices(in: spaceID) where !workspaces[index].isClosing {
            let workspace = workspaces[index]
            let info = built[workspace.id] ?? {
                let isActive = index == activeWSIndex
                let columns = workspace.columns.enumerated().map { colIndex, col in
                    let isUserFocused = colIndex == workspace.focusedIndex && isActive
                    return sidebarColumnInfo(
                        col, at: colIndex, isUserFocused: isUserFocused, agentStatus: col.pty?.cachedAgentState ?? .idle,
                        foregroundProcess: foregroundProcesses[ObjectIdentifier(col)], approvalHold: approvalHolds[ObjectIdentifier(col)],
                        missionQuestion: missionQuestions[ObjectIdentifier(col)], showsDialog: false, snapshot: snapshot, now: now
                    )
                }
                return sidebarWorkspaceInfo(
                    at: index, columns: columns, isActive: isActive, parentTitle: parents[index].map { workspaces[$0].title }
                )
            }()
            readings[workspace.id] = BoardStages.TaskReading(
                info,
                summary: workspace.lastSummaryIsManual ? WorkspaceInfo.oneRunOfWords(workspace.lastSummary) : nil,
                gitRoot: workspace.gitContext.map { comparable($0.identity.repositoryRoot) },
                reviewsInFlight: Set(workspace.reviewsRunning.map(\.pass)),
                turnStartedAt: { id in
                    workspace.columns.first { $0.id == id }?.pty?.agentTurnStartedAt?.timeIntervalSince1970
                }
            )
        }
        return readings
    }
}
