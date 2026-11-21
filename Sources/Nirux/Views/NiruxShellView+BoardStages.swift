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
            var reading = BoardStages.TaskReading(
                info,
                summary: workspace.lastSummaryIsManual ? WorkspaceInfo.oneRunOfWords(workspace.lastSummary) : nil,
                gitRoot: workspace.gitContext?.identity.resolvedRepositoryRoot,
                reviewsInFlight: Set(workspace.reviewsRunning.map(\.pass)),
                settledTurn: { column in
                    guard let terminal = workspace.columns.first(where: { $0.id == column.id }) else { return false }
                    if column.attentionReason == nil, column.openDialog == nil, column.questionAskedAt == nil,
                       column.processName == CodingAgent.codex.rawValue, let pty = terminal.pty,
                       pty.codexQueueRefusal(runningSince: now, snapshot: snapshot) == nil { return true }
                    guard let agent = terminal.agentUUID, let ended = column.questionAskedAt ?? terminal.pty?.agentLastTurnEndedAt,
                          ended > 0 else { return false }
                    return MissionStore.shared.missions.contains { mission in
                        mission.childWorkspaceID == workspace.id && mission.childAgentUUID == agent && mission.oneWay != true
                            && Self.settledTurn(ended, events: mission.events)
                    }
                },
                turnStartedAt: { id in
                    workspace.columns.first { $0.id == id }?.pty?.agentTurnStartedAt?.timeIntervalSince1970
                }
            )
            reading.terminalStatusKnown = !snapshot.isEmpty || workspace.openColumns.allSatisfy { $0.pty == nil }
            readings.tasks[workspace.id] = reading
        }
        return readings
    }

    /// A completion supersedes earlier turn-end notices. A response settles only the turn that asked its question.
    static func settledTurn(_ ended: TimeInterval, events: [MissionEvent]) -> Bool {
        if events.contains(where: { $0.kind == .completed && $0.timestamp >= ended }) { return true }
        guard let question = events.first(where: { $0.kind == .question && $0.timestamp == ended }) else { return false }
        return events.contains { $0.kind == .response && $0.inReplyTo == question.id }
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
            waiting: members.compactMap { workspace in
                workspace.waitingStart.flatMap { BoardStages.WaitingTask(id: workspace.id, title: workspace.title, wait: $0) }
            },
            missionStatusAvailable: board.stagesReadings != nil && MissionStore.shared.hasLoadedLedger,
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
