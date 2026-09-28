import AppKit

// MARK: - Merge queue (docs/project-board.md, section 3.6; B2 has no entry point)

/// The shell owns each project's merge queue, so a queue outlives the
/// board that shows it. It also tells a queue which agents are busy in a
/// pull request's worktrees.
extension NiruxShellView {
    /// The project's merge queue, made the first time it is asked for.
    func mergeQueue(projectID: String) -> MergeQueueController {
        if let existing = mergeQueues[projectID] { return existing }
        let controller = MergeQueueController(
            projectID: projectID,
            client: mergeQueueClient,
            local: MergeQueueLocalAccess(
                folders: { [weak self] in self?.projectWorkspaces(of: projectID).map(\.cwd) ?? [] },
                busyAgents: { [weak self] worktrees, allWorktrees in
                    self?.mergeQueueBusyAgents(in: worktrees, allWorktrees: allWorktrees) ?? []
                }
            ),
            lockFolder: mergeQueueLockFolder
        )
        // One queue per repository in this Nirux; the lock covers the others.
        controller.isRepositoryBusy = { [weak self, weak controller] repository in
            guard let self else { return false }
            return self.mergeQueues.values.contains { $0 !== controller && $0.isRunning && $0.repository == repository }
        }
        mergeQueues[projectID] = controller
        return controller
    }

    /// The agents working or waiting on a dialog in these worktrees (paths
    /// comparable): in any workspace open there, as the board's row counts
    /// them, or in another workspace's shell inside one, as the worktree
    /// clean-up counts foreign agents. "claude working in “api”".
    func mergeQueueBusyAgents(in worktrees: [String], allWorktrees: [String]) -> [String] {
        let snapshot = ProcessSnapshot()
        let now = Date().timeIntervalSince1970
        let isInside = { (folder: String?) -> Bool in
            guard let folder else { return false }
            return MergeQueue.isInside(Self.comparablePath(folder), roots: worktrees, allWorktrees: allWorktrees)
        }
        var busy: [String] = []
        for workspace in workspaces where !workspace.isClosing {
            let isMember = isInside(workspace.cwd)
            for column in workspace.openColumns where isMember || isInside(column.pty?.childCwd) {
                let foreground = column.pty?.foregroundProcess(snapshot: snapshot)
                let agent = projectBoardAgent(of: column, in: workspace, foreground: foreground, snapshot: snapshot, now: now)
                guard let label = MergeQueue.busyLabel(agent.state) else { continue }
                let name = column.pty?.agentProcessName(snapshot: snapshot) ?? "an agent"
                busy.append("\(name) \(label) in “\(workspace.title)”")
            }
        }
        return busy
    }
}
