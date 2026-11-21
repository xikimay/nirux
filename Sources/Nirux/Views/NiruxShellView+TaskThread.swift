import AppKit

// MARK: - Task threads (docs/design/task-thread.md)

extension NiruxShellView {
    func wireThread(_ workspace: WorkspaceState) {
        workspace.onThreadEvent = { [weak self, weak workspace] event in
            guard let self, let workspace, self.keepsThread(workspace) else { return }
            self.recordThread([event], of: workspace)
        }
    }

    /// A task, or a workspace whose thread exists already: a worktree
    /// removed under its task leaves it a task.
    func keepsThread(_ workspace: WorkspaceState) -> Bool {
        !workspace.isLead
            && (Self.isTask(workspace) || TaskThread.Store.locate(workspaceID: workspace.id, stateDirectory: Persistence.stateDirectory) != nil)
    }

    func recordThread(_ events: [TaskThread.Event], of workspace: WorkspaceState) {
        guard !events.isEmpty else { return }
        let (id, space, directory) = (workspace.id, workspace.profileID, Persistence.stateDirectory)
        TaskThread.Store.queue.async {
            TaskThread.Store.append(events, workspaceID: id, spaceID: space, stateDirectory: directory)
        }
    }

    /// What the task was asked, at its birth (`bornAt`, before anything
    /// else of it can be recorded).
    func recordRequest(_ request: NewTask.Request, of workspace: WorkspaceState, bornAt: Date) {
        let author: TaskThread.Author = request.startedByLead ? .lead : request.startedByTaskAgent ? .parentTask : .user
        recordThread([TaskThread.Event(
            time: bornAt.timeIntervalSince1970, kind: .request, by: author, text: request.description, detail: request.template?.name
        )], of: workspace)
    }

    /// A closing task's thread takes what the files say of it, then its
    /// pull requests' history once GitHub answers. Not while the Missions
    /// can't be read: its thread then stays open, joined at each read.
    func freezeThread(of workspace: WorkspaceState) {
        guard keepsThread(workspace) else { return }
        guard MissionStore.shared.ensureLoaded() else {
            return NiruxDebugLog.log("TaskThread: \(workspace.id) not frozen: the Missions can't be read")
        }
        let (id, space, directory) = (workspace.id, workspace.profileID, Persistence.stateDirectory)
        let spaceIDs = profiles.map(\.id)
        // The ledger's, not the live pull request's: that one follows the
        // focused column, which may be another checkout.
        let urls = sessionLedger.pullRequestURLs(workspaceID: id)
        let missions = MissionStore.shared.missions.filter { $0.childWorkspaceID == id }
        let reviewRuns = workspace.reviewRuns
        let isSingleRepository = (profiles.first { $0.id == space }?.anchors.count ?? 0) <= 1
        let open = Set(workspaces.filter { !$0.isClosing }.map(\.id))
        let now = Date().timeIntervalSince1970
        TaskThread.Store.queue.async {
            let sources = TaskThread.Sources.load(
                workspaceID: id, missions: missions, reviewRuns: reviewRuns, pullRequestURLs: urls,
                spaceID: space, spaceIDs: spaceIDs, isSingleRepository: isSingleRepository, stateDirectory: directory
            )
            let frozen = TaskThread.frozen(sources, closedAt: now, pullRequests: urls)
            TaskThread.Store.append(frozen, workspaceID: id, spaceID: space, stateDirectory: directory)
            TaskThread.Store.pruneAll(keeping: open, now: now, stateDirectory: directory)
        }
        guard !urls.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            let history = urls.sorted().flatMap { url in
                let result = GitHub.CLI.run(.init(["pr", "view", url, "--json", TaskThread.pullRequestFields])).flatMap(\.result)
                return (try? result.get()).flatMap(TaskThread.pullRequestHistory) ?? []
            }
            guard !history.isEmpty else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let open = Set(self.workspaces.filter { !$0.isClosing }.map(\.id))
                TaskThread.Store.queue.async {
                    TaskThread.Store.appendHistory(history, workspaceID: id, spaceID: space, keeping: open, stateDirectory: directory)
                }
            }
        }
    }

    /// The threads no open task owns, past their time or their space's budget.
    func pruneThreads() {
        let (open, directory, now) = (Set(workspaces.map(\.id)), Persistence.stateDirectory, Date().timeIntervalSince1970)
        TaskThread.Store.queue.async {
            TaskThread.Store.pruneAll(keeping: open, now: now, stateDirectory: directory)
        }
    }
}
