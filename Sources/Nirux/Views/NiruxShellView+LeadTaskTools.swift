import AppKit

// MARK: - The Lead tidies its space's list (see LeadTools)

/// `close_task` and `move_task`: any task of the Lead's space, the user's
/// too. Closing runs Clean Up Worktree…'s checks and deletes the worktree
/// and its branch only when they all pass: the Lead's call stands in for
/// the alert's click.
extension NiruxShellView {
    /// The task of `space` named `name`, whoever started it.
    func spaceTask(_ name: String, in space: WorkspaceProfile) -> WorkspaceState? {
        namedWorkspace(name, among: workspaces.filter { $0.profileID == space.id && !$0.isLead && !$0.isClosing })
    }

    private func noSpaceTask(_ name: String, in space: WorkspaceProfile) -> String {
        "No task in \(space.name) is named “\(name)”, or several share that title: use its branch or title from list_tasks "
            + "(its folder, for a task without a repository)."
    }

    // MARK: close_task

    func leadCloseTask(_ arguments: [String: Any], in space: WorkspaceProfile, answer: @escaping LeadAnswer) {
        let name = LeadTools.string(arguments, "task") ?? ""
        guard let task = spaceTask(name, in: space) else { return answer(noSpaceTask(name, in: space), true) }
        let title = MissionPromptText.quoted(task.title)
        // A task whose folder is gone only closes (see finishLeadClose).
        guard Self.isTask(task) || !FileManager.default.fileExists(atPath: task.cwd) else {
            return answer("“\(title)” isn't a task (a worktree of one of the space's repositories, or a task's folder): "
                + "ask the user to close it.", true)
        }
        if let refusal = leadCloseRefusal(of: task) { return answer(refusal, true) }
        if let folder = task.taskFolder { return closeFolderTask(task, folder: folder, answer: answer) }
        guard let path = Self.worktreeCleanupPath(forCwd: task.cwd) else {
            closeLeadTask(task)
            return answer("Closed “\(title)”. Nirux found no worktree of it to clean up.", false)
        }
        let key = Self.comparablePath(path)
        guard worktreeCleanupsInFlight.insert(key).inserted else {
            return answer("A clean-up of “\(title)”'s worktree is already running: call again in a minute.", true)
        }
        let others = worktreeMembers(path).filter { $0 !== task }
        guard others.isEmpty else {
            worktreeCleanupsInFlight.remove(key)
            closeLeadTask(task)
            return answer(Self.closedKeeping(title, because: "Other workspaces are open in it: "
                + WorktreeCleanupCandidate.quotedList(others.map(\.title)) + "."), false)
        }
        let taskID = task.id
        Self.inspectWorktree(path, agentFolders: [task.cwd], tools: worktreeCleanupTools) { [weak self] inspection in
            self?.finishLeadClose(taskID: taskID, path: path, inspection: inspection, answer: answer)
        }
    }

    /// GitHub and git answered: cleans up when every check passed, else
    /// closes the task alone.
    private func finishLeadClose(
        taskID: String, path: String, inspection: WorktreeCleanup.Inspection, answer: @escaping LeadAnswer
    ) {
        let key = Self.comparablePath(path)
        guard let task = workspaces.first(where: { $0.id == taskID && !$0.isClosing }) else {
            worktreeCleanupsInFlight.remove(key)
            return answer("The task was closed meanwhile: nothing was cleaned up.", true)
        }
        // Its agent may have taken a prompt while GitHub answered.
        if let refusal = leadCloseRefusal(of: task) {
            worktreeCleanupsInFlight.remove(key)
            return answer(refusal, true)
        }
        let title = MissionPromptText.quoted(task.title)
        var candidate = worktreeCleanupCandidate(path: path)
        candidate.inspection = inspection
        let others = candidate.workspaces.filter { $0.id != taskID }
        let availability = others.isEmpty ? candidate.availability
            : .blocked(["Other workspaces are open in it: \(WorktreeCleanupCandidate.quotedList(others.map(\.title)))."])
        guard case .ready(let plan, _) = availability else {
            worktreeCleanupsInFlight.remove(key)
            switch availability {
            case .closeOnly:
                closeWorkspacesAfterCleanup(of: candidate)
                answer("Closed “\(title)”: its folder was already gone.", false)
            case .notMerged(let reason):
                closeLeadTask(task)
                answer(Self.closedKeeping(title, because: "It isn't merged (\(reason))."), false)
            case .blocked(let problems):
                closeLeadTask(task)
                answer(Self.closedKeeping(title, because: problems.joined(separator: " ")), false)
            case .checking, .ready:
                closeLeadTask(task)
                answer(Self.closedKeeping(title, because: "Nirux couldn't check it."), false)
            }
            return
        }
        executeWorktreeCleanup(plan, of: candidate) { [weak self] outcome in
            guard let self, let outcome else { return }
            self.worktreeCleanupsInFlight.remove(key)
            if outcome.succeeded {
                answer("Closed “\(title)” and cleaned it up (pull request #\(plan.pullRequest.number) merged): \(outcome.message).", false)
            } else if self.workspaces.contains(where: { $0.id == taskID && !$0.isClosing }) {
                answer("The clean-up of “\(title)” failed, so it stays open: \(outcome.message) Tell the user.", true)
            } else {
                answer("Closed “\(title)” and deleted its folder, but the clean-up stopped there: \(outcome.message)", false)
            }
        }
    }

    /// A task without a repository: its folder goes to the Trash, where
    /// the user can put it back, unless someone still works in it.
    private func closeFolderTask(_ task: WorkspaceState, folder: String, answer: @escaping LeadAnswer) {
        let title = MissionPromptText.quoted(task.title)
        guard FileManager.default.fileExists(atPath: folder) else {
            closeLeadTask(task)
            return answer("Closed “\(title)”: its folder was already gone.", false)
        }
        let candidate = worktreeCleanupCandidate(path: folder)
        let others = candidate.workspaces.filter { $0.id != task.id }
        let problems = (others.isEmpty ? [] : ["Other workspaces are open in it: \(WorktreeCleanupCandidate.quotedList(others.map(\.title)))."])
            + candidate.inUseProblems
        closeLeadTask(task)
        guard problems.isEmpty else {
            return answer("Closed “\(title)”. Its folder stays (\(folder)): " + problems.joined(separator: " "), false)
        }
        Self.moveToTrash(folder, tools: worktreeCleanupTools) { problem in
            answer(problem.map { "Closed “\(title)”, but its folder couldn't go to the Trash (\($0)): it stays at \(folder)." }
                ?? "Closed “\(title)” and moved its folder to the Trash (\(folder)): the user can put it back from there.", false)
        }
    }

    /// `folder` to the Trash off the main thread; `completion` on it,
    /// with why not, or nil.
    nonisolated static func moveToTrash(
        _ folder: String, tools: WorktreeCleanup.Tools, completion: @escaping @MainActor @Sendable (String?) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let problem: String?
            do {
                _ = try tools.trash(URL(fileURLWithPath: folder))
                problem = nil
            } catch {
                problem = error.localizedDescription
            }
            DispatchQueue.main.async { completion(problem) }
        }
    }

    private static func closedKeeping(_ title: String, because reason: String) -> String {
        "Closed “\(title)”. Its worktree and branch stay: \(reason)"
    }

    /// Why the Lead may not close `task` now, nil when it may: closing
    /// would end work, or drop what the user hasn't settled.
    func leadCloseRefusal(of task: WorkspaceState) -> String? {
        let title = MissionPromptText.quoted(task.title)
        let snapshot = ProcessSnapshot()
        let readings = agentReadings(of: task, snapshot: snapshot)
        // A turn that just ended reads "needs the user" until they look:
        // only what they must answer counts.
        if let dialog = readings.lazy.compactMap(\.dialog).first {
            return "“\(title)” waits for the user (\(dialog)): leave it to them."
        }
        if readings.contains(where: { $0.status == .working }) {
            return "“\(title)”'s agent is working: wait for its turn to end, then close it."
        }
        // Idle is only known from Claude's hooks (see WorkspaceClosePolicy).
        if let unknown = task.openColumns.compactMap({ $0.liveAgent(snapshot: snapshot) }).first(where: { $0.status == nil }) {
            return "Nirux can't tell whether “\(title)”'s \(unknown.displayName) is done: ask the user to close it."
        }
        let store = MissionStore.shared
        _ = store.ensureLoaded()
        let handedOver = task.columns.contains { column in
            column.agentUUID.flatMap { store.waitingQuestion(childWorkspaceID: task.id, childAgentUUID: $0) }?
                .event.handedToUserBecause != nil
        }
        if handedOver {
            return "“\(title)” waits for the user's answer to the question you handed them: close it once they answered."
        }
        if task.columns.contains(where: { !($0.editorColumn?.unsavedPaths.isEmpty ?? true) }) {
            return "“\(title)” has unsaved editor changes: ask the user to save or discard them first."
        }
        let subtasks = subtasks(of: task)
        if !subtasks.isEmpty {
            return "“\(title)” still has sub-tasks (\(WorktreeCleanupCandidate.quotedList(subtasks.map(\.title)))): "
                + "close them or move them out first."
        }
        return nil
    }

    /// Closes `task` as Close Workspace does once confirmed, and saves
    /// once it's gone.
    private func closeLeadTask(_ task: WorkspaceState) {
        guard let index = workspaces.firstIndex(where: { $0 === task }) else { return }
        closeWorkspace(at: index)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.saveState()
        }
    }

    // MARK: move_task

    func leadMoveTask(_ arguments: [String: Any], in space: WorkspaceProfile, answer: @escaping LeadAnswer) {
        let name = LeadTools.string(arguments, "task") ?? ""
        let position = LeadTools.positiveInteger(arguments["position"]) ?? 1
        guard let task = spaceTask(name, in: space), let index = workspaces.firstIndex(where: { $0 === task }) else {
            return answer(noSpaceTask(name, in: space), true)
        }
        let moved = workspaceStore.moveWorkspace(at: index, toPosition: position - 1)
        if moved { refreshAfterWorkspaceMutation(refocusing: false) }
        guard let now = workspaces.firstIndex(where: { $0 === task }), let (siblings, place) = workspaceStore.siblingGroup(of: now)
        else { return answer("Nirux lost “\(MissionPromptText.quoted(task.title))” in the sidebar: call list_tasks.", true) }
        let parent = workspaceStore.activeParents(in: space.id)[now].map { MissionPromptText.quoted(workspaces[$0].title) }
        let group = task.isInactive ? "the archived tasks" : parent.map { "the sub-tasks of “\($0)”" } ?? "the tasks of \(space.name)"
        answer("“\(MissionPromptText.quoted(task.title))” is \(place + 1) of \(siblings.count) among \(group)"
            + (moved ? "." : ", as it was."), false)
    }
}
