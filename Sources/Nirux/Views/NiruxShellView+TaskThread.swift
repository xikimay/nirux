import AppKit

// MARK: - Task threads (docs/design/task-thread.md)

extension NiruxShellView {
    func wireThread(_ workspace: WorkspaceState) {
        workspace.onThreadEvent = { [weak self, weak workspace] event in
            guard let self, let workspace, !workspace.isClosing, !workspace.isLead, Self.isTask(workspace) else { return }
            self.recordThread([event], of: workspace)
        }
    }

    func recordThread(_ events: [TaskThread.Event], of workspace: WorkspaceState) {
        let (id, space, directory) = (workspace.id, workspace.profileID, Persistence.stateDirectory)
        TaskThread.Store.queue.async {
            TaskThread.Store.append(events, workspaceID: id, spaceID: space, stateDirectory: directory)
        }
    }

    /// What the task was asked, at its birth.
    func recordRequest(_ request: NewTask.Request, of workspace: WorkspaceState) {
        let author: TaskThread.Author = request.startedByLead ? .lead : request.startedByTaskAgent ? .parentTask : .user
        recordThread([TaskThread.Event(
            time: Date().timeIntervalSince1970, kind: .request, by: author, text: request.description,
            detail: request.template?.name
        )], of: workspace)
    }

    /// A closing task's thread takes what the files say of it, then its
    /// pull requests' history once GitHub answers.
    func freezeThread(of workspace: WorkspaceState) {
        guard !workspace.isLead, Self.isTask(workspace) else { return }
        let (id, space, directory) = (workspace.id, workspace.profileID, Persistence.stateDirectory)
        let missions = MissionStore.shared.missions.filter { $0.childWorkspaceID == id }
        let reviewRuns = workspace.reviewRuns
        let recordedURLs = sessionLedger.sessions(inSpace: space).filter { $0.workspaceID == id }.compactMap(\.pullRequest?.url)
        let urls = Set(recordedURLs + [workspace.prInfo?.url].compactMap { $0 })
        let open = Set(workspaces.filter { !$0.isClosing }.map(\.id))
        let now = Date().timeIntervalSince1970
        TaskThread.Store.queue.async {
            let sources = TaskThread.Sources.load(
                workspaceID: id, spaceID: space, missions: missions, reviewRuns: reviewRuns, pullRequestURLs: urls
            )
            TaskThread.Store.append(TaskThread.frozen(sources, closedAt: now), workspaceID: id, spaceID: space, stateDirectory: directory)
            TaskThread.Store.prune(spaceID: space, keeping: open, now: now, stateDirectory: directory)
        }
        guard !urls.isEmpty, let gh = PRDetect.installedGHPath() else { return }
        DispatchQueue.global(qos: .utility).async {
            let history = urls.sorted().flatMap { url in
                GitHubCLIBoardClient.runGH(gh, arguments: ["pr", "view", url, "--json", TaskThread.pullRequestFields], timeout: 30)
                    .flatMap { $0.terminationStatus == 0 ? TaskThread.pullRequestHistory($0.standardOutput) : nil } ?? []
            }
            TaskThread.Store.queue.async {
                TaskThread.Store.append(history, workspaceID: id, spaceID: space, stateDirectory: directory)
            }
        }
    }

    /// The threads no open task owns, past their time or the space's budget.
    func pruneThreads() {
        let (spaces, open, directory) = (profiles.map(\.id), Set(workspaces.map(\.id)), Persistence.stateDirectory)
        let now = Date().timeIntervalSince1970
        TaskThread.Store.queue.async {
            for space in spaces { TaskThread.Store.prune(spaceID: space, keeping: open, now: now, stateDirectory: directory) }
        }
    }
}
