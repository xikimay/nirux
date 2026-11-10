import AppKit

// MARK: - Restored agents that resume on demand

/// A restored layout brings its agent columns back without their agents
/// (see `DeferredAgentLaunch`). Each agent starts once its column has
/// stayed a moment in the workspace on screen (its focus included), when
/// the user clicks Resume on its column or its sidebar row, or with Resume
/// All Agents. Settings can start them all with the window instead, as
/// before.
extension NiruxShellView {
    static func currentAgentResumeOnLaunch() -> AgentResumeOnLaunch {
        Persistence.load()?.settings?.agentResumeOnLaunch ?? .defaultValue
    }

    /// Agent columns, in every space, whose agent hasn't started yet.
    var deferredAgentCount: Int {
        workspaces.reduce(0) { count, workspace in count + workspace.columns.filter(\.isAwaitingResume).count }
    }

    /// Start a column's deferred agent with the flags it ran with, in the
    /// directory it ran in. False when it has none (already resumed).
    /// `liveSessions`: `liveSessionIDs`, when the caller resumes several.
    @discardableResult
    func resumeDeferredAgent(_ column: ColumnState, in workspace: WorkspaceState, liveSessions: [String]? = nil) -> Bool {
        guard workspace.columns.contains(where: { $0 === column }),
              let deferred = column.takeDeferredAgent() else { return false }
        // Its folder may be gone since the restore (a removed worktree): the
        // workspace's then, as at restore. Its environment is the one a new
        // terminal gets now: the workspace may have moved to another space,
        // Settings may have changed.
        if let agentUUID = column.agentUUID {
            column.setLaunch(
                directory: column.launchDirectory.flatMap(Self.existingDirectory) ?? workspace.cwd,
                environment: workspace.terminalEnvironment(agentUUID: agentUUID)
            )
        }
        let command = resumeLaunchCommand(
            deferred.agent.openingElsewhere(liveSessions ?? Self.liveSessionIDs(in: workspaces)), in: workspace, column: column
        )
        sideEffects.startRestoredAgent(column, command)
        scheduleMetadataRefresh()
        return true
    }

    /// How long a column stays on screen before its agent resumes on its
    /// own: moving through workspaces (⌘↓ ⌘↓ ⌘↓) must not start the agents
    /// of every workspace on the way. The shell then starts 0.5 s later
    /// (see `ColumnState`).
    static let onScreenResumeDelay: TimeInterval = 0.4

    /// The agents the workspace on screen shows resume once they have
    /// stayed there `onScreenResumeDelay`. A layout (what is on screen may
    /// have changed) starts the wait again; the metadata refresh, which a
    /// working agent's title spinner runs several times a second, only
    /// makes sure one is on its way.
    func scheduleDeferredAgentsOnScreen(restartingWait: Bool = true) {
        guard restartingWait || !isOnScreenResumeScheduled, deferredColumnsOnScreen() != nil else { return }
        NSObject.cancelPreviousPerformRequests(
            withTarget: self, selector: #selector(resumeDeferredAgentsOnScreen), object: nil
        )
        perform(#selector(resumeDeferredAgentsOnScreen), with: nil, afterDelay: Self.onScreenResumeDelay)
        isOnScreenResumeScheduled = true
    }

    /// The deferred agents the workspace on screen shows resume.
    @objc func resumeDeferredAgentsOnScreen() {
        isOnScreenResumeScheduled = false
        guard let (workspace, columns) = deferredColumnsOnScreen() else { return }
        let liveSessions = Self.liveSessionIDs(in: workspaces)
        for column in columns {
            resumeDeferredAgent(column, in: workspace, liveSessions: liveSessions)
        }
    }

    /// The waiting columns the workspace on screen shows, its focused one
    /// first; nil for none. Only the active workspace counts.
    private func deferredColumnsOnScreen() -> (workspace: WorkspaceState, columns: [ColumnState])? {
        guard let workspace = activeWorkspace, workspace.columns.contains(where: \.isAwaitingResume) else { return nil }
        let focused = workspace.focusedIndex
        let viewportWidth = workspace.containerView.frame.width
        let columns = ([focused] + workspace.columns.indices.filter { $0 != focused }).compactMap { index -> ColumnState? in
            guard let column = workspace.columns[safe: index], column.isAwaitingResume else { return nil }
            let frame = column.view.frame
            let shows = index == focused || Self.showsColumn(
                left: frame.minX, width: frame.width, cameraX: workspace.attentionCameraX, viewportWidth: viewportWidth
            )
            return shows ? column : nil
        }
        return columns.isEmpty ? nil : (workspace, columns)
    }

    /// Below this, the part of a column in the viewport is an edge sliver
    /// that doesn't show the agent.
    static let minimumShownColumnWidth: CGFloat = 120

    /// Whether a column laid out at `left` shows: enough of it, or all of a
    /// narrower one, is inside the viewport.
    static func showsColumn(left: CGFloat, width: CGFloat, cameraX: CGFloat, viewportWidth: CGFloat) -> Bool {
        let shown = min(left + width, cameraX + viewportWidth) - max(left, cameraX)
        return width > 0 && shown >= min(width, minimumShownColumnWidth)
    }

    func wireDeferredAgentResume() {
        sidebar.onDeferredAgentResume = { [weak self] wsIndex, colIndex, columnID in
            self?.resumeDeferredAgent(workspaceIndex: wsIndex, columnIndex: colIndex, columnID: columnID)
        }
    }

    /// Resume All Agents (palette, Workspaces menu). True when one started.
    @discardableResult
    func resumeAllDeferredAgents() -> Bool {
        var resumed = false
        let liveSessions = Self.liveSessionIDs(in: workspaces)
        for workspace in workspaces {
            for column in workspace.columns where column.isAwaitingResume {
                resumed = resumeDeferredAgent(column, in: workspace, liveSessions: liveSessions) || resumed
            }
        }
        if resumed { updateSidebar() }
        return resumed
    }

    /// Resume clicked on a sidebar row, aimed at the column `columnID`: it
    /// starts where it is, the workspace on screen stays.
    func resumeDeferredAgent(workspaceIndex: Int, columnIndex: Int, columnID: UUID) {
        guard let workspace = workspaces[safe: workspaceIndex],
              let column = workspace.columns[safe: columnIndex], column.id == columnID,
              resumeDeferredAgent(column, in: workspace) else {
            NSSound.beep()
            return
        }
        updateSidebar()
    }

    /// The sessions columns run now, as far as their agents' launch lines
    /// (in front, stopped with ^Z or under a wrapper) or the agent in
    /// front's own reports tell: a session resumed there while a column
    /// waited is theirs. A waiting column runs nothing.
    static func liveSessionIDs(in workspaces: [WorkspaceState]) -> [String] {
        agentSessionHolders(in: workspaces, snapshot: ProcessSnapshot()).flatMap(\.liveText)
    }

    /// What a column row shows of an agent that hasn't resumed.
    static func sidebarDeferredAgent(of column: ColumnState) -> SidebarDeferredAgent? {
        column.deferredAgent.map {
            SidebarDeferredAgent(processName: $0.processName, summary: $0.summary, columnID: column.id)
        }
    }
}
