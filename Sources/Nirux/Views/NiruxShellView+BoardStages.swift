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
    /// are taken as they are. A task's git root is compared with its row's
    /// worktree resolved, as git lists it
    /// (`GitIdentity.resolvedRepositoryRoot`). The Lead is read too: the
    /// space's header says it.
    func boardReadings(
        ofSpace spaceID: String,
        sidebarInfos: [WorkspaceInfo] = [],
        foregroundProcesses: [ObjectIdentifier: ForegroundProcess],
        approvalHolds: [ObjectIdentifier: PermissionApprovalHold],
        missionQuestions: [ObjectIdentifier: SidebarMissionQuestion],
        snapshot: ProcessSnapshot,
        now: TimeInterval
    ) -> ProjectBoardController.StagesReadings {
        let built = Dictionary(sidebarInfos.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let parents = workspaceStore.activeParents(in: spaceID)
        var readings = ProjectBoardController.StagesReadings()
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
            if workspace.isLead {
                let status = boardLeadStatus(of: workspace, columns: info.columns, foreground: foregroundProcesses, snapshot: snapshot, now: now)
                readings.lead = (workspace.id, status)
                continue
            }
            readings.tasks[workspace.id] = BoardStages.TaskReading(
                info,
                summary: workspace.lastSummaryIsManual ? WorkspaceInfo.oneRunOfWords(workspace.lastSummary) : nil,
                gitRoot: workspace.gitContext?.identity.resolvedRepositoryRoot,
                reviewsInFlight: Set(workspace.reviewsRunning.map(\.pass)),
                turnStartedAt: { id in
                    workspace.columns.first { $0.id == id }?.pty?.agentTurnStartedAt?.timeIntervalSince1970
                }
            )
        }
        return readings
    }

    /// What the shell holds of a Board's space for its stages, beside what
    /// the Board read: the space, its tasks (`members`, the space's
    /// workspaces in the sidebar's order) with the Lead apart, each
    /// sub-task's parent, each section's queue and the queues that run (the
    /// Board's foot), the clean-ups running.
    func stagesInputs(
        of board: ProjectBoardController, members: [WorkspaceState], workspaces: [ProjectBoard.Workspace],
        readings: ProjectBoardController.StagesReadings, order: BoardStages.Order
    ) -> ProjectBoardController.StagesInputs {
        let spaceID = board.projectID
        let queues = projectBoardQueues(board)
        let lead = members.first { $0.isLead }?.id
        return ProjectBoardController.StagesInputs(
            space: profiles.first { $0.id == spaceID }.map { profile in
                ProjectBoardController.StagesInputs.Space(name: profile.name, color: NSColor.niruxColor(hex: profile.colorHex) ?? Theme.Color.accent)
            },
            workspaces: workspaces,
            tasks: members.filter { !$0.isLead }.map(\.id),
            // Ids as restored: two the same must not trap.
            parents: Dictionary(workspaceStore.activeParents(in: spaceID).map {
                (self.workspaces[$0.key].id, self.workspaces[$0.value].id)
            }, uniquingKeysWith: { first, _ in first }),
            lead: lead,
            leadStatus: readings.lead?.id == lead ? readings.lead?.status : nil,
            readings: readings.tasks,
            queues: queues.states,
            runningQueues: queues.running,
            cleaningUp: worktreeCleanupsInFlight,
            order: order
        )
    }
}
