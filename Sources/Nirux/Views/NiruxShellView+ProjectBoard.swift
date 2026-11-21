import AppKit

// MARK: - Project Board (docs/design/project-board.md)

/// The board columns: opening one per project, feeding each the project's
/// workspaces, agents and merge queue, and running its buttons through the
/// flows that already exist (focus, open a workspace, clean up a worktree,
/// resume an agent, the queue's). `ProjectBoardController` reads the rest.
extension NiruxShellView {
    struct ProjectBoardLocation {
        let workspace: WorkspaceState
        let column: ColumnState
        let board: ProjectBoardController
    }

    /// Every board, in sidebar order.
    var projectBoardLocations: [ProjectBoardLocation] {
        workspaces.filter { !$0.isClosing }.flatMap { workspace in
            workspace.columns.compactMap { column in
                guard !column.isClosing, let board = column.projectBoard else { return nil }
                return ProjectBoardLocation(workspace: workspace, column: column, board: board)
            }
        }
    }

    func projectBoardLocation(projectID: String) -> ProjectBoardLocation? {
        projectBoardLocations.first { $0.board.projectID == projectID }
    }

    /// The palette's "Open Board": the board of the current
    /// workspace's project, next to its focused column. A project has one
    /// board: if it has one already, that one comes to the front.
    func openProjectBoard() {
        guard let workspace = activeWorkspace, !workspace.isClosing else { return }
        let projectID = workspace.profileID
        if let existing = projectBoardLocation(projectID: projectID) {
            focusProjectBoard(existing)
            return
        }
        guard !workspace.isWaitingTask else { return }
        let board = makeProjectBoard(projectID: projectID, offersSettings: true)
        workspace.addProjectBoardColumn(board)
        relayout(animated: false)
        updateSidebar()
        focusActiveTerminal(in: window)
        saveState()
        board.reload()
    }

    func focusProjectBoard(_ location: ProjectBoardLocation) {
        guard let columnIndex = location.workspace.columns.firstIndex(where: { $0 === location.column }) else { return }
        focusWorkspace(id: location.workspace.id, column: columnIndex)
    }

    /// A board wired to the shell, for a new column or a restored one. It
    /// reads nothing before `reload`.
    func makeProjectBoard(projectID: String, offersSettings: Bool) -> ProjectBoardController {
        observeBoardConfigSaves()
        let board = ProjectBoardController(projectID: projectID, client: projectBoardClient, offersSettings: offersSettings)
        board.workspaceFolders = { [weak self, weak board] in
            guard let self, let board else { return [] }
            return self.projectWorkspaces(of: board.projectID).map(\.cwd)
        }
        board.spaceAnchors = { [weak self, weak board] in
            guard let self, let board else { return [] }
            return self.profiles.first { $0.id == board.projectID }?.anchors ?? []
        }
        board.isOnScreen = { [weak self, weak board] in
            guard let self, let board else { return false }
            return self.isProjectBoardOnScreen(board)
        }
        board.isShown = { [weak self, weak board] in
            guard let self, let board else { return false }
            return self.isProjectBoardShown(board)
        }
        board.onRead = { [weak self, weak board] in
            guard let self, let board else { return }
            self.renderProjectBoard(board)
        }
        board.onNeedsSettings = { [weak self, weak board] in
            guard let self, let board, self.profiles.contains(where: { $0.id == board.projectID }) else { return }
            self.showBoardSettings(profileID: board.projectID)
        }
        board.view.onRefresh = { [weak board] in board?.reload() }
        board.view.onBoardSettings = { [weak self, weak board] in
            guard let self, let board else { return }
            self.showBoardSettings(of: board, repository: nil)
        }
        wireBoardStages(board)
        return board
    }

    /// Board Settings… of the board's space, on `repository` (a section's
    /// id) when given.
    func showBoardSettings(of board: ProjectBoardController, repository: String?) {
        showBoardSettings(profileID: board.projectID, repository: repository)
    }

    /// A Board shows its workspace's space. One whose workspace went to
    /// another space shows that one, unless it has its Board already: then
    /// it closes. Moved by the user, the space's own Board comes to the
    /// front, with a toast; after a space deleted (from Space Settings,
    /// another space on screen), quietly. The store calls it, every way a
    /// workspace changes space (`WorkspaceStore.onWorkspacesChangedSpace`).
    func boardsFollowTheirWorkspaces(_ change: WorkspaceStore.SpaceChange) {
        // The next sidebar pass draws the one shown.
        for moved in projectBoardLocations where moved.board.projectID != moved.workspace.profileID {
            let space = moved.workspace.profileID
            // As the Boards are now: one moved before this one may have taken the space.
            if let existing = projectBoardLocation(projectID: space) {
                closeMovedBoard(moved)
                guard change == .moved else { continue }
                focusProjectBoard(existing)
                showToast("\(profiles.first { $0.id == space }?.name ?? "This space") has its Board already")
            } else {
                // Moved by the user, as one opened there: it may ask for the space's settings.
                moved.board.switchProject(to: space, offersSettings: change == .moved)
            }
        }
    }

    /// A workspace has a column at least: a Board alone in its own leaves a
    /// shell in its folder.
    private func closeMovedBoard(_ location: ProjectBoardLocation) {
        let workspace = location.workspace
        let isBoard = { (column: ColumnState) in column === location.column }
        guard workspace.columns.contains(where: isBoard) else { return }
        if workspace.openColumns.count == 1 { workspace.addColumn() }
        // Found again: the shell goes in beside the focused column.
        guard let index = workspace.columns.firstIndex(where: isBoard) else { return }
        workspace.closeColumn(at: index)
    }

    /// The project's workspaces in sidebar order: active ones, then inactive.
    func projectWorkspaces(of projectID: String) -> [WorkspaceState] {
        workspaceStore.visibleWorkspaceIndices(in: projectID).map { workspaces[$0] }.filter { !$0.isClosing }
    }

    /// A board is shown while its workspace is the selected one, in a
    /// window that isn't minimized.
    func isProjectBoardShown(_ board: ProjectBoardController) -> Bool {
        projectBoardLocations.first { $0.board === board }.map(isProjectBoardShown) ?? false
    }

    private func isProjectBoardShown(_ location: ProjectBoardLocation) -> Bool {
        guard let window, !window.isMiniaturized, location.workspace.profileID == activeProfileID else { return false }
        return location.workspace === activeWorkspace
    }

    /// Shown, with Nirux in front and its window not covered: the board's
    /// periodic reads run only then. In the background they pause, as the
    /// sidebar's pull request reads do (hook events still refresh the
    /// sidebar there).
    func isProjectBoardOnScreen(_ board: ProjectBoardController) -> Bool {
        isInFront && isProjectBoardShown(board)
    }

    private var isInFront: Bool {
        NSApp.isActive && window?.occlusionState.contains(.visible) == true
    }

    // MARK: Drawing

    /// What one sidebar pass read, which the Board's readings take as they
    /// are (`boardReadings`): reading them again would hand requests back,
    /// or note hand-offs twice.
    struct SidebarPassReadings {
        /// The rows the pass built: the space on screen's.
        var infos: [WorkspaceInfo]
        var foregroundProcesses: [ObjectIdentifier: ForegroundProcess]
        var approvalHolds: [ObjectIdentifier: PermissionApprovalHold]
        var missionQuestions: [ObjectIdentifier: SidebarMissionQuestion]
    }

    /// What a Board shows: its content, and what its clicks act on.
    typealias BoardShown = (content: BoardStagesView.Content, targets: ProjectBoardController.StagesTargets)

    /// At each status refresh, before the rows draw: every Board, shown or
    /// not, reads its tasks from what it read and the sidebar's pass, and
    /// its tasks take their lines' stations (`noteTaskStations`). The shown
    /// ones read again (`tick`); what they draw is returned.
    func readProjectBoards(
        snapshot: ProcessSnapshot, now: TimeInterval, pass: SidebarPassReadings
    ) -> [(board: ProjectBoardController, stages: BoardShown)] {
        let inFront = isInFront
        refreshMergeQueuesElsewhere()
        taskStations = [:]
        var shown: [(board: ProjectBoardController, stages: BoardShown)] = []
        for location in projectBoardLocations {
            let isShown = isProjectBoardShown(location)
            if isShown { location.board.tick(onScreen: inFront) }
            let inputs = projectBoardInputs(location.board, isShown: isShown, snapshot: snapshot, now: now, pass: pass)
            let date = Date(timeIntervalSince1970: now)
            guard isShown else {
                // Its lines only give the rows their stations.
                noteTaskStations(of: location.board, content: location.board.keptStagesContent(inputs, now: date))
                continue
            }
            let stages = location.board.stagesContent(inputs, now: date)
            noteTaskStations(of: location.board, content: stages.content)
            shown.append((location.board, stages))
        }
        return shown
    }

    /// Draws what `readProjectBoards` read for the Boards shown.
    func drawProjectBoards(_ boards: [(board: ProjectBoardController, stages: BoardShown)], now: TimeInterval) {
        for (board, stages) in boards { showProjectBoard(board, stages, now: now) }
    }

    /// Draws the board between two passes (a read landing, a click): its
    /// tasks as the last pass read them. The rows follow its stations at
    /// once.
    func renderProjectBoard(_ board: ProjectBoardController, snapshot: ProcessSnapshot? = nil, now: TimeInterval = Date().timeIntervalSince1970) {
        let inputs = projectBoardInputs(board, isShown: true, snapshot: snapshot ?? ProcessSnapshot(), now: now, pass: nil)
        let stages = board.stagesContent(inputs, now: Date(timeIntervalSince1970: now))
        showProjectBoard(board, stages, now: now)
        guard noteTaskStations(of: board, content: stages.content) else { return }
        let infos = sidebar.lastInfos.map { info in
            var info = info
            info.station = taskStations[info.id]
            return info
        }
        sidebar.update(profiles: sidebar.lastProfiles, workspaces: infos)
        updateCommandBar(task: infos.first { $0.index == activeWSIndex }, waitingCount: requestsState.requests.count)
    }

    /// What the board's stages are built from: its tasks as the sidebar's
    /// pass read them (`pass`), else as the last pass did. A Board shown
    /// lists its worktrees again when its workspaces moved.
    private func projectBoardInputs(
        _ board: ProjectBoardController, isShown: Bool, snapshot: ProcessSnapshot, now: TimeInterval, pass: SidebarPassReadings?
    ) -> ProjectBoardController.StagesInputs {
        let members = projectWorkspaces(of: board.projectID)
        let foreground = pass?.foregroundProcesses ?? foregroundProcesses(of: members, snapshot: snapshot)
        let boardWorkspaces = projectBoardWorkspaces(members, of: board, snapshot: snapshot, now: now, foregroundProcesses: foreground)
        if isShown {
            // A workspace opened in a folder not listed yet, or one closed or moved away: list them again.
            board.expireWorktreesIfWorkspacesLeft(members.map(\.cwd))
            if let local = board.local, members.contains(where: { local.folders[$0.cwd] == nil }) {
                board.expireWorktrees()
            }
            board.reloadIfAnchorsChanged()
        }
        if let pass {
            board.stagesReadings = boardReadings(
                ofSpace: board.projectID, sidebarInfos: pass.infos, foregroundProcesses: pass.foregroundProcesses,
                approvalHolds: pass.approvalHolds, missionQuestions: pass.missionQuestions, snapshot: snapshot, now: now
            )
        }
        // Before the first pass: no hold, no question, the agents in front as the process table says.
        let readings = board.stagesReadings ?? boardReadings(
            ofSpace: board.projectID, foregroundProcesses: foreground, approvalHolds: [:], missionQuestions: [:], snapshot: snapshot,
            now: now
        )
        return stagesInputs(of: board, members: members, workspaces: boardWorkspaces, readings: readings, order: boardOrder)
    }

    private func showProjectBoard(_ board: ProjectBoardController, _ stages: BoardShown, now: TimeInterval) {
        let spaceName = profiles.first { $0.id == board.projectID }?.name ?? ""
        board.view.show(header: board.columnHeader(spaceName: spaceName, now: Date(timeIntervalSince1970: now)), stages: stages.content)
        // What the clicks act on is what the Board shows.
        board.stagesTargets = stages.targets
    }

    /// What runs in front in each open column of `members`, as the process table says.
    func foregroundProcesses(of members: [WorkspaceState], snapshot: ProcessSnapshot) -> [ObjectIdentifier: ForegroundProcess] {
        Dictionary(members.flatMap(\.openColumns).compactMap { column in
            column.pty?.foregroundProcess(snapshot: snapshot).map { (ObjectIdentifier(column), $0) }
        }, uniquingKeysWith: { first, _ in first })
    }

    /// The space's workspaces as the Board's rows take them: their folder
    /// as the worktrees were listed, and their most urgent agent column.
    /// `foregroundProcesses`: the sidebar pass's, by column, else the
    /// process table's (`foregroundProcesses(of:snapshot:)`).
    func projectBoardWorkspaces(
        _ members: [WorkspaceState], of board: ProjectBoardController, snapshot: ProcessSnapshot, now: TimeInterval,
        foregroundProcesses: [ObjectIdentifier: ForegroundProcess]
    ) -> [ProjectBoard.Workspace] {
        members.map { workspace in
            ProjectBoard.Workspace(
                id: workspace.id,
                title: workspace.title,
                folder: board.comparableFolder(workspace.cwd),
                // Checked off the main thread when the worktrees are listed.
                folderIsGone: !workspace.isWaitingTask && board.local?.missingFolders.contains(workspace.cwd) == true,
                isInactive: workspace.isInactive,
                agent: .mostUrgent(workspace.openColumns.map { column in
                    projectBoardAgent(
                        of: column, in: workspace, foreground: foregroundProcesses[ObjectIdentifier(column)], snapshot: snapshot, now: now
                    )
                })
            )
        }
    }

    /// Each section's queue, by section id, and the lines of the Board's
    /// foot: each queue that runs, here or in another Nirux, a section's
    /// (named after its repository, its anchor's name on a Board with
    /// anchors), then one left running on a repository no section has.
    func projectBoardQueues(
        _ board: ProjectBoardController
    ) -> (states: [String: ProjectBoard.QueueState], running: [BoardStagesView.RunningQueue]) {
        var states: [String: ProjectBoard.QueueState] = [:]
        for section in board.sections {
            states[section.id] = projectBoardQueueState(board, section: section)
        }
        let running = board.sections.compactMap { section in
            states[section.id].flatMap { state in
                let repository = board.repository(of: section)?.name
                let name = section.anchor == nil ? repository : board.displayNames[section.id]
                return BoardStagesView.runningQueue(
                    id: section.id, title: name ?? repository ?? "Repository", tooltip: repository, state: state
                )
            }
        } + projectBoardOrphanQueues(board).compactMap { orphan in
            BoardStagesView.runningQueue(
                id: Self.orphanSectionID(orphan), title: orphan.queueRepository.ownerAndName,
                tooltip: "Its queue runs, but it isn’t one of this board’s repositories now.",
                state: orphanQueueState(orphan)
            )
        }
        return (states, running)
    }

    /// A worktree was cleaned up: the boards list their worktrees again.
    func expireProjectBoardWorktrees() {
        for location in projectBoardLocations {
            location.board.expireWorktrees()
            location.board.tick(onScreen: isProjectBoardShown(location.board))
        }
    }

    /// What one column's agent does, for the Board's rows and the merge
    /// queue (see `ProjectBoard.agentState`), with the stuck states the
    /// sidebar shows.
    func projectBoardAgent(
        of column: ColumnState,
        in workspace: WorkspaceState,
        foreground: ForegroundProcess?,
        snapshot: ProcessSnapshot,
        now: TimeInterval
    ) -> ProjectBoard.Agent {
        guard let pty = column.pty else { return ProjectBoard.Agent() }
        let stuck = sidebarStuckState(of: column, foregroundProcess: foreground, snapshot: snapshot, now: now)
        let agentInFront = foreground?.agent != nil
        let state = ProjectBoard.agentState(
            stuck: stuck,
            hasAgent: agentInFront || pty.terminalAgent(snapshot: snapshot) != nil,
            agentInFront: agentInFront,
            status: pty.cachedAgentState,
            // A dialog only: the Merge Queue holds a pull request while its
            // agent waits there, not while it waits for an answer in prose.
            openDialog: pty.agentVisibleDialog(foreground: foreground)?.reason,
            workingFor: pty.agentTurnStartedAt.map { SidebarRenderer.shortDuration(now - $0.timeIntervalSince1970) }
        )
        var failedAt: TimeInterval?
        if case .stoppedOnError(_, _, let at, _)? = stuck { failedAt = at }
        return ProjectBoard.Agent(state: state, workspaceID: workspace.id, columnID: column.id, failedAt: failedAt)
    }

    // MARK: Buttons

    func performProjectBoardAction(_ action: ProjectBoard.Action, board: ProjectBoardController) {
        switch action {
        case .focus(let workspaceID, let columnID):
            guard let workspace = workspaces.first(where: { $0.id == workspaceID && !$0.isClosing }) else {
                return showToast("That workspace was closed")
            }
            let columnIndex = columnID.flatMap { id in workspace.columns.firstIndex { $0.id == id } }
            focusWorkspace(id: workspaceID, column: columnIndex)
        case .open(let path, let title):
            guard FileManager.default.fileExists(atPath: path) else {
                board.expireWorktrees()
                return showToast("That worktree’s folder is gone")
            }
            openRoutedWorkspace(title: title, cwd: path, startedFromSpaceID: board.projectID)
        case .cleanUp(let path):
            // The flow and confirmation of "Clean Up Worktree…", by folder.
            requestWorktreeCleanup(path: path)
        case .resumeFailed(let workspaceID, let columnID, let failedAt):
            // Not into a workspace or a column on its way out.
            guard let workspaceIndex = workspaces.firstIndex(where: { $0.id == workspaceID && !$0.isClosing }),
                  let columnIndex = workspaces[workspaceIndex].columns.firstIndex(where: { $0.id == columnID && !$0.isClosing })
            else { return showToast("That agent’s column was closed") }
            resumeFailedAgent(workspaceIndex: workspaceIndex, columnIndex: columnIndex, failedAt: failedAt)
        case .resumeExited(let workspaceID, let columnID):
            guard let workspace = workspaces.first(where: { $0.id == workspaceID && !$0.isClosing }),
                  let column = workspace.columns.first(where: { $0.id == columnID && !$0.isClosing })
            else { return showToast("That agent’s column was closed") }
            resumeExitedAgent(in: workspace, column: column)
        case .addToQueue(let number, let section):
            addToMergeQueue(number, board: board, section: section)
        case .removeFromQueue(let number, let section):
            removeFromMergeQueue(number, board: board, section: section)
        case .retarget(let number, let base, let section):
            // Changes GitHub: never from a dry-run build, like the queue.
            guard let target = board.section(id: section), let repository = board.repository(of: target)?.gitHub else { return }
            guard !mergeQueue(projectID: board.projectID, repository: repository).isDryRun else { return NSSound.beep() }
            board.retarget(number, onto: base, section: target.id)
        }
        renderProjectBoard(board)
    }

    // MARK: Config

    /// Boards read their board.json again each time it is saved.
    func observeBoardConfigSaves() {
        guard boardConfigSaveObserver == nil else { return }
        boardConfigSaveObserver = Self.observeBoardConfigSaves { [weak self] spaceID in
            guard let self else { return }
            for location in self.projectBoardLocations where location.board.projectID == spaceID {
                location.board.reload()
            }
        }
    }

    /// The notification comes on the thread that saved. The observer is
    /// made in this nonisolated function, so its block can't inherit the
    /// view's main-actor isolation (#48), and it hops to the main thread.
    nonisolated private static func observeBoardConfigSaves(
        _ handler: @escaping @MainActor @Sendable (String) -> Void
    ) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(
            forName: BoardConfigStore.didSaveNotification, object: nil, queue: nil
        ) { notification in
            guard let spaceID = notification.userInfo?["spaceID"] as? String else { return }
            DispatchQueue.main.async { @MainActor in
                handler(spaceID)
            }
        }
    }
}
