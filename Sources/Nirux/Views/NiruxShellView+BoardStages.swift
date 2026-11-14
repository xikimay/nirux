import AppKit

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

    /// What the shell holds of a Board's space for its stages, beside what
    /// the Board read: the space, its tasks in the sidebar's order (the
    /// Lead apart), each sub-task's parent, each section's queue and the
    /// queues left on a repository no section has, the clean-ups running.
    func stagesInputs(
        of board: ProjectBoardController, workspaces: [ProjectBoard.Workspace], readings: [String: BoardStages.TaskReading],
        order: BoardStages.Order
    ) -> ProjectBoardController.StagesInputs {
        let spaceID = board.projectID
        let members = workspaceStore.visibleWorkspaceIndices(in: spaceID).filter { !self.workspaces[$0].isClosing }
        let parents = workspaceStore.activeParents(in: spaceID).map { (self.workspaces[$0.key].id, self.workspaces[$0.value].id) }
        var queues: [String: ProjectBoard.QueueState] = [:]
        for section in board.sections { queues[section.id] = projectBoardQueueState(board, section: section) }
        return ProjectBoardController.StagesInputs(
            space: profiles.first { $0.id == spaceID }.map { profile in
                ProjectBoardController.StagesInputs.Space(name: profile.name, color: NSColor.niruxColor(hex: profile.colorHex) ?? Theme.Color.accent)
            },
            workspaces: workspaces,
            tasks: members.filter { !self.workspaces[$0].isLead }.map { self.workspaces[$0].id },
            parents: Dictionary(parents, uniquingKeysWith: { first, _ in first }),
            lead: members.first { self.workspaces[$0].isLead }.map { self.workspaces[$0].id },
            readings: readings,
            queues: queues,
            orphanQueues: projectBoardOrphanQueues(board).compactMap { orphan in
                BoardStagesView.runningQueue(
                    id: Self.orphanSectionID(orphan), title: orphan.queueRepository.ownerAndName,
                    tooltip: "Its queue runs, but it isn’t one of this board’s repositories now.", state: orphanQueueState(orphan)
                )
            },
            cleaningUp: worktreeCleanupsInFlight,
            order: order
        )
    }
}
