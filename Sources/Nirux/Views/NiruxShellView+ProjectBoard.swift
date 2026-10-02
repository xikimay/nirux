import AppKit

// MARK: - Project Board (docs/project-board.md)

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

    /// The palette's "Open Project Board": the board of the current
    /// workspace's project, next to its focused column. A project has one
    /// board: if it has one already, that one comes to the front.
    func openProjectBoard() {
        guard let workspace = activeWorkspace, !workspace.isClosing else { return }
        let projectID = workspace.profileID
        if let existing = projectBoardLocation(projectID: projectID) {
            focusProjectBoard(existing)
            return
        }
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
        board.isOnScreen = { [weak self, weak board] in
            guard let self, let board else { return false }
            return self.isProjectBoardOnScreen(board)
        }
        board.isShown = { [weak self, weak board] in
            guard let self, let board else { return false }
            return self.isProjectBoardShown(board)
        }
        board.projectExists = { [weak self, weak board] in
            guard let self, let board else { return false }
            return self.profiles.contains { $0.id == board.projectID }
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
            guard let self, let board, self.profiles.contains(where: { $0.id == board.projectID }) else {
                NSSound.beep()
                return
            }
            self.showBoardSettings(profileID: board.projectID)
        }
        board.view.onSelectProject = { [weak self, weak board] projectID in
            guard let self, let board else { return }
            self.switchProjectBoard(board, to: projectID)
        }
        board.view.onAction = { [weak self, weak board] action in
            guard let self, let board else { return }
            self.performProjectBoardAction(action, board: board)
        }
        board.view.onStartQueue = { [weak self, weak board] in
            guard let self, let board else { return }
            self.requestMergeQueueStart(board: board)
        }
        board.view.onStopQueue = { [weak self, weak board] in
            guard let self, let board else { return }
            self.stopMergeQueue(projectID: board.projectID)
        }
        return board
    }

    /// The header's project menu. A project that has a board already
    /// brings that one to the front, and this one keeps its project.
    func switchProjectBoard(_ board: ProjectBoardController, to projectID: String) {
        guard projectID != board.projectID else { return }
        if let existing = projectBoardLocation(projectID: projectID) {
            board.view.resetProjectMenu()
            focusProjectBoard(existing)
            return
        }
        board.switchProject(to: projectID)
        renderProjectBoard(board)
        saveState()
    }

    /// The project's workspaces in sidebar order: active ones, then inactive.
    func projectWorkspaces(of projectID: String) -> [WorkspaceState] {
        workspaceStore.visibleWorkspaceIndices(in: projectID).map { workspaces[$0] }.filter { !$0.isClosing }
    }

    /// A board is shown while its workspace is: the selected one, or any of
    /// the space's in Pilot Mode, in a window that isn't minimized.
    func isProjectBoardShown(_ board: ProjectBoardController) -> Bool {
        projectBoardLocations.first { $0.board === board }.map(isProjectBoardShown) ?? false
    }

    private func isProjectBoardShown(_ location: ProjectBoardLocation) -> Bool {
        guard let window, !window.isMiniaturized, location.workspace.profileID == activeProfileID else { return false }
        if isPilotMode {
            return visibleWorkspaceIndices.contains { workspaces[$0] === location.workspace }
        }
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

    /// At each status refresh: the boards shown draw their agents as they
    /// are now, and read what is due if they are on screen.
    /// `foregroundProcesses` is the sidebar's, by column.
    func refreshProjectBoards(
        snapshot: ProcessSnapshot,
        now: TimeInterval,
        foregroundProcesses: [ObjectIdentifier: ForegroundProcess]? = nil
    ) {
        let inFront = isInFront
        refreshMergeQueuesElsewhere()
        for location in projectBoardLocations where isProjectBoardShown(location) {
            location.board.tick(onScreen: inFront)
            renderProjectBoard(location.board, snapshot: snapshot, now: now, foregroundProcesses: foregroundProcesses)
        }
    }

    func renderProjectBoard(
        _ board: ProjectBoardController,
        snapshot: ProcessSnapshot? = nil,
        now: TimeInterval = Date().timeIntervalSince1970,
        foregroundProcesses: [ObjectIdentifier: ForegroundProcess]? = nil
    ) {
        let snapshot = snapshot ?? ProcessSnapshot()
        let members = projectWorkspaces(of: board.projectID)
        let inputs = members.map { workspace in
            ProjectBoard.Workspace(
                id: workspace.id,
                title: workspace.title,
                folder: board.comparableFolder(workspace.cwd),
                // Checked off the main thread when the worktrees are listed.
                folderIsGone: board.local?.missingFolders.contains(workspace.cwd) ?? false,
                isInactive: workspace.isInactive,
                agent: .mostUrgent(workspace.openColumns.map { column in
                    let foreground = foregroundProcesses.map { $0[ObjectIdentifier(column)] }
                        ?? column.pty?.foregroundProcess(snapshot: snapshot)
                    return projectBoardAgent(of: column, in: workspace, foreground: foreground, snapshot: snapshot, now: now)
                })
            )
        }
        // A workspace opened in a folder not listed yet: list them again.
        if let local = board.local, members.contains(where: { local.folders[$0.cwd] == nil }) {
            board.expireWorktrees()
        }
        let projects = profiles.map { ProjectBoardView.Project(id: $0.id, name: $0.name) }
        var content = board.content(workspaces: inputs, projects: projects)
        content.queue = projectBoardQueueState(board)
        board.view.show(content)
    }

    /// A worktree was cleaned up: the boards list their worktrees again.
    func expireProjectBoardWorktrees() {
        for location in projectBoardLocations {
            location.board.expireWorktrees()
            location.board.tick(onScreen: isProjectBoardShown(location.board))
        }
    }

    /// What the Agent column says of one column (see `ProjectBoard.agentState`),
    /// with the stuck states the sidebar shows.
    func projectBoardAgent(
        of column: ColumnState,
        in workspace: WorkspaceState,
        foreground: ForegroundProcess?,
        snapshot: ProcessSnapshot,
        now: TimeInterval
    ) -> ProjectBoard.Agent {
        guard let pty = column.pty else { return ProjectBoard.Agent() }
        let stuck = sidebarStuckState(of: column, foregroundProcess: foreground, snapshot: snapshot, now: now)
        let agentInFront = foreground.map { AgentStatusMachine.isRecognizedAgentProcess($0.name) } ?? false
        let state = ProjectBoard.agentState(
            stuck: stuck,
            hasAgent: agentInFront || pty.agentProcessName(snapshot: snapshot) != nil,
            agentInFront: agentInFront,
            status: pty.cachedAgentState,
            openDialog: pty.agentVisibleDialog(foreground: foreground)?.reason,
            workingFor: pty.agentTurnStartedAt.map { PilotSidebarRenderer.shortDuration(now - $0.timeIntervalSince1970) }
        )
        var failedAt: TimeInterval?
        if case .stoppedOnError(_, _, let at, _)? = stuck { failedAt = at }
        return ProjectBoard.Agent(state: state, workspaceID: workspace.id, columnID: column.id, failedAt: failedAt)
    }

    // MARK: Buttons

    func performProjectBoardAction(_ action: ProjectBoardView.Action, board: ProjectBoardController) {
        switch action {
        case .focus(let workspaceID, let columnID):
            guard let workspace = workspaces.first(where: { $0.id == workspaceID && !$0.isClosing }) else {
                return NSSound.beep()
            }
            let columnIndex = columnID.flatMap { id in workspace.columns.firstIndex { $0.id == id } }
            focusWorkspace(id: workspaceID, column: columnIndex)
        case .open(let path, let title):
            guard FileManager.default.fileExists(atPath: path) else {
                board.expireWorktrees()
                return NSSound.beep()
            }
            addWorkspace(title: title, cwd: path, profileID: board.projectID)
            saveState()
        case .cleanUp(let path):
            // The flow and confirmation of "Clean Up Worktree…", by folder.
            requestWorktreeCleanup(path: path)
        case .resumeFailed(let workspaceID, let columnID, let failedAt):
            // Not into a workspace or a column on its way out.
            guard let workspaceIndex = workspaces.firstIndex(where: { $0.id == workspaceID && !$0.isClosing }),
                  let columnIndex = workspaces[workspaceIndex].columns.firstIndex(where: { $0.id == columnID && !$0.isClosing })
            else { return NSSound.beep() }
            resumeFailedAgent(workspaceIndex: workspaceIndex, columnIndex: columnIndex, failedAt: failedAt)
        case .resumeExited(let workspaceID, let columnID):
            guard let workspace = workspaces.first(where: { $0.id == workspaceID && !$0.isClosing }),
                  let column = workspace.columns.first(where: { $0.id == columnID && !$0.isClosing })
            else { return NSSound.beep() }
            resumeExitedAgent(in: workspace, column: column)
        case .addToQueue(let number):
            addToMergeQueue(number, board: board)
        case .removeFromQueue(let number):
            removeFromMergeQueue(number, board: board)
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
