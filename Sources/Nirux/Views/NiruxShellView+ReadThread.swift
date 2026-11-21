import Foundation

extension NiruxShellView {
    func threadContext(of task: WorkspaceState) -> TaskThread.Context {
        let urls = sessionLedger.pullRequestURLs(workspaceID: task.id)
        return TaskThread.Context(
            goal: task.purpose, next: task.nextStep, blocker: task.blocker,
            status: task.lastSummaryIsManual || task.lastSummaryIsStatus ? task.lastSummary : nil,
            urls: urls, pullRequest: task.prInfo, observedAt: task.pullRequestReadAt
        )
    }

    func leadReadThread(_ arguments: [String: Any], in space: WorkspaceProfile, answer: @escaping LeadAnswer) {
        let name = LeadTools.string(arguments, "task") ?? ""
        let task = workspaces.first { $0.profileID == space.id && $0.id == name && !$0.isClosing }
            ?? spaceTask(name, in: space)
        if let task, task.startedOutsideNirux || !keepsThread(task) {
            return answer("This workspace has no thread available to the Lead.", true)
        }
        let directory = Persistence.stateDirectory
        let id: String
        if let task {
            id = task.id
        } else if let archive = TaskThread.Store.fileURL(workspaceID: name, spaceID: space.id, stateDirectory: directory),
                  FileManager.default.fileExists(atPath: archive.path) {
            id = name
        } else {
            if workspaces.contains(where: { !$0.isClosing && Self.answers($0, to: name) && $0.profileID == space.id }) {
                return answer(noSpaceTask(name, in: space), true)
            }
            let matches = sessionLedger.sessions(inSpace: space.id, matching: .init(includesUnprompted: true)).filter {
                $0.checkout?.branch == name || $0.workspaceTitle?.caseInsensitiveCompare(name) == .orderedSame
            }
            let ids = Set(matches.compactMap(\.workspaceID))
            guard ids.count <= 1 else { return answer("Several archived tasks match. Use the workspace ID.", true) }
            id = ids.first ?? name
        }
        if task == nil, workspaces.contains(where: { $0.id == id && !$0.isClosing }) {
            return answer(noSpaceTask(name, in: space), true)
        }
        let title = task?.title ?? name
        readTaskThread(workspaceID: id, spaceID: space.id, render: { events, context in
            TaskThread.summary(events, title: title, context: context)
        }) { text in
            guard let text else { return answer("No readable thread for this task in this space.", true) }
            answer(text, false)
        }
    }

    /// Resolve by identity before starting I/O and verify the space again at delivery.
    func readTaskThread<Value: Sendable>(
        workspaceID id: String, spaceID: String,
        render: @escaping @Sendable ([TaskThread.Event], TaskThread.Context) -> Value,
        completion: @escaping @MainActor (Value?) -> Void
    ) {
        let directory = Persistence.stateDirectory
        let task = workspaces.first { $0.id == id && !$0.isClosing }
        if let task, task.profileID != spaceID || task.startedOutsideNirux || !keepsThread(task) {
            return completion(nil)
        }
        guard let file = TaskThread.Store.fileURL(workspaceID: id, spaceID: spaceID, stateDirectory: directory) else {
            return completion(nil)
        }
        let context = task.map(threadContext) ?? TaskThread.Context(urls: sessionLedger.pullRequestURLs(workspaceID: id))
        let loaded = MissionStore.shared.ensureLoaded()
        let sources = threadSources(workspaceID: id, spaceID: spaceID, urls: context.urls, reviews: task?.reviewRuns ?? [:], directory: directory)
        let active = task != nil
        Self.offMain({
            let recorded = TaskThread.Store.queue.sync {
                active ? TaskThread.Store.load(workspaceID: id, stateDirectory: directory) : TaskThread.Store.load(from: file)
            }
            guard active || TaskThread.canReadArchive(recorded) else { return nil as Value? }
            if recorded.contains(where: { $0.kind == .closed }) {
                return render(TaskThread.ordered(recorded), .init())
            }
            guard loaded else { return nil }
            let events = TaskThread.thread(recorded: recorded + context.pullRequestEvents, joining: sources())
            return render(events, context)
        }) { [weak self] result in
            guard let self, !workspaces.contains(where: { $0.id == id && $0.profileID != spaceID }) else {
                return completion(nil)
            }
            completion(result)
        }
    }
}
