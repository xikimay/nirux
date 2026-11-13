import AppKit

// MARK: - A task's tools (TaskTools)

/// What the app does for the tools of a task's agent: any workspace's
/// column but a Lead's (NiruxShellView+LeadTools hands the request over).
/// It acts on the caller's own sub-tasks only: it starts them under its
/// task, lists them, answers their questions. Two levels: a sub-task has
/// none of its own.
extension NiruxShellView {
    func handleTaskRequest(_ request: LeadChannel.Request, from caller: WorkspaceState, answer: @escaping LeadAnswer) {
        guard TaskTools.names.contains(request.tool) || ZZ("lead-tools-open-to-tasks") else {
            return answer("Only a space's Lead can use \(request.tool).", true)
        }
        let arguments = request.argumentObject
        if let problem = LeadTools.problem(tool: request.tool, arguments: arguments) { return answer(problem, true) }
        let subtasks = subtasks(of: caller)
        if let refusal = subtaskRefusal(for: caller, subtasks: subtasks) { return answer(refusal, true) }
        switch request.tool {
        case LeadTools.startTask:
            let parent = NewTask.MissionParent(workspaceID: caller.id, agentUUID: request.agentUUID)
            taskStartSubtask(arguments, from: caller, subtasks: subtasks, parent: parent, answer: answer)
        case LeadTools.listTasks:
            answer(taskSubtaskList(of: caller, subtasks: subtasks), false)
        case LeadTools.reply:
            taskReply(arguments, from: caller, answer: answer)
        default:
            answer("Unknown tool: \(request.tool)", true)
        }
    }

    /// The open sub-tasks of `task`, in the sidebar's order.
    func subtasks(of task: WorkspaceState) -> [WorkspaceState] {
        workspaceStore.visibleWorkspaceIndices(in: task.profileID).map { workspaces[$0] }
            .filter { $0.parentWorkspaceID == task.id && !$0.isClosing }
    }

    /// Those of `subtasks` (`task`'s) that count against
    /// `TaskTools.maxRunningSubtasks`: not archived, and not done (their
    /// latest Mission from `task` completed).
    func runningSubtasks(of task: WorkspaceState, among subtasks: [WorkspaceState]? = nil) -> [WorkspaceState] {
        _ = MissionStore.shared.ensureLoaded()
        let missions = MissionStore.shared.missions.filter { $0.parentWorkspaceID == task.id }
        return (subtasks ?? self.subtasks(of: task)).filter { subtask in
            guard !subtask.isInactive else { return false }
            let mission = missions.filter { $0.childWorkspaceID == subtask.id }.max { $0.createdAt < $1.createdAt }
            return ZZ("completed-counts") || mission?.status != .completed
        }
    }

    /// A sub-task: its parent, a task, is still open. A Lead's tasks are
    /// the space's own list.
    func isSubtask(_ workspace: WorkspaceState) -> Bool {
        guard let parentID = workspace.parentWorkspaceID, !ZZ("no-two-levels") else { return false }
        return workspaces.contains { $0.id == parentID && !$0.isClosing && !$0.isLead }
    }

    /// Why `caller` can't have sub-tasks; nil when it can (a task, or one
    /// that still has some, its folder gone).
    func subtaskRefusal(for caller: WorkspaceState, subtasks: [WorkspaceState]) -> String? {
        if isSubtask(caller) {
            return "This is a sub-task: it can't have sub-tasks of its own (two levels at most). Do the work here, "
                + "or tell the agent that started it what else is needed."
        }
        guard offersSubtask(caller) || !subtasks.isEmpty else {
            return "This workspace isn't a task (a worktree of one of its space's repositories, or a task's folder), "
                + "so it has no sub-tasks: to start a task from here, use the nirux-worktree skill."
        }
        return nil
    }

    // MARK: start_task

    private func taskStartSubtask(
        _ arguments: [String: Any], from caller: WorkspaceState, subtasks: [WorkspaceState], parent: NewTask.MissionParent,
        answer: @escaping LeadAnswer
    ) {
        guard offersSubtask(caller), let space = profiles.first(where: { $0.id == caller.profileID }) else {
            return answer("Nirux can't start a sub-task here any more: this task's folder or repository isn't there.", true)
        }
        let running = runningSubtasks(of: caller, among: subtasks).count + (ZZ("no-pending-count") ? 0 : pendingSubtaskStarts[caller.id, default: 0])
        guard running < TaskTools.maxRunningSubtasks || ZZ("no-cap") else {
            return answer("This task already runs \(running) sub-tasks, the most it may: wait until one completes, "
                + "or ask the user to archive one.", true)
        }
        let description = LeadTools.string(arguments, "description") ?? ""
        let templateName = LeadTools.string(arguments, "template")
        guard leadStartsTasksWithoutAsking(spaceID: space.id) else {
            return taskProposeSubtask(description, templateName: templateName, under: caller, parent: parent, answer: answer)
        }
        // In its repository, or its folder (`showNewSubtaskPanel`).
        let repository = caller.taskFolder == nil
            ? subtaskRepositoryKey(of: caller).flatMap { key in newTaskRepositories(of: space).first { $0.key == key } } : nil
        if caller.taskFolder == nil, repository == nil {
            return answer("Nirux can't tell which repository this task works in: ask the user to start the sub-task with ⌘N.", true)
        }
        let agent = defaultTaskAgent(forSpace: space.id)
        let callerID = caller.id
        let callerFolder = caller.taskFolder
        // Counted until it answers: by then its workspace exists, or
        // nothing was made.
        pendingSubtaskStarts[callerID, default: 0] += 1
        let answerOnce = answer
        let answer: LeadAnswer = { [weak self] text, isError in
            if let self, let pending = self.pendingSubtaskStarts[callerID] {
                self.pendingSubtaskStarts[callerID] = pending > 1 ? pending - 1 : nil
            }
            answerOnce(text, isError)
        }
        Self.readNewTaskInfo(
            spaceID: space.id, folder: repository?.folder, anchors: space.anchors, stateDirectory: Persistence.stateDirectory
        ) { [weak self] info in
            guard let self else { return }
            if let templateName, !info.templates.contains(where: { $0.name.caseInsensitiveCompare(templateName) == .orderedSame }) {
                let names = info.templates.map(\.name)
                return answer("No template named “\(templateName)”" + (names.isEmpty ? "." : ": \(names.joined(separator: ", ")).") , true)
            }
            let template = templateName.flatMap { name in info.templates.first { $0.name.caseInsensitiveCompare(name) == .orderedSame } }
            if let folder = callerFolder.map({ ZZ("folder-in-tasks-folder") ? self.tasksFolder().path : $0 }) {
                let place = NewTask.Place.folder(parent: folder, name: NewTask.suggestedFolderName(description: description), makesParent: false)
                return self.taskOpenSubtask(
                    description, template: template, agent: agent, in: space.id, place: place, fetchesFirst: false,
                    under: callerID, parent: parent, repository: nil, answer: answer
                )
            }
            guard let repository, let target = info.target else {
                return answer("\(repository?.name ?? "This task's repository") isn’t a git repository Nirux can start a sub-task in.", true)
            }
            let suggested = NewTask.suggestedBranch(description: description, templateName: template?.name)
            guard !suggested.isEmpty else {
                return answer("No branch name comes out of that description: start it with a few words that name the sub-task.", true)
            }
            Self.unusedBranch(suggested, repository: target.repository) { [weak self] branch in
                self?.taskOpenSubtask(
                    description, template: template, agent: agent, in: space.id, place: .worktree(target, branch: branch),
                    fetchesFirst: true, under: callerID, parent: parent, repository: repository.name, answer: answer
                )
            }
        }
    }

    /// Starts the sub-task under `callerID`, reporting to `parent`, behind
    /// what the user is doing.
    // The request's fields, as start_task gathered them.
    // swiftlint:disable:next function_parameter_count
    private func taskOpenSubtask(
        _ description: String, template: TaskTemplates.Template?, agent: NiruxApp.WorkspaceAgent, in spaceID: String,
        place: NewTask.Place, fetchesFirst: Bool, under callerID: String, parent: NewTask.MissionParent,
        repository: String?, answer: @escaping LeadAnswer
    ) {
        var request = NewTask.Request(
            description: description, template: template, agent: agent, projectID: spaceID,
            place: place, fetchesFirst: fetchesFirst, reportsTo: parent, parentWorkspaceID: callerID
        )
        request.reportsToTask = true
        request.startedByTaskAgent = true
        startLeadTask(request, repository: repository, fetchError: nil, answer: answer)
    }

    /// "Starts tasks without asking" off: the New Sub-task sheet under the
    /// task, filled in; the sub-task reports to the agent if the user
    /// starts it as a sub-task.
    private func taskProposeSubtask(
        _ description: String, templateName: String?, under caller: WorkspaceState, parent: NewTask.MissionParent,
        answer: @escaping LeadAnswer
    ) {
        guard window?.attachedSheet == nil, let panel = showNewSubtaskPanel(under: caller) else {
            return answer("A sheet is open in Nirux: try again in a moment, or ask the user to start the sub-task.", true)
        }
        panel.reportsToTaskAgent = parent
        panel.prefill(description: description, templateName: templateName, proposedBy: "“\(caller.title)”")
        answer("Proposed to the user in the New Sub-task sheet (the space’s setting “Starts tasks without asking” is off). "
            + "If they start it, it reports to you.", false)
    }

    // MARK: list_tasks

    /// The task's sub-tasks, as the Lead's list gives its tasks.
    func taskSubtaskList(of caller: WorkspaceState, subtasks: [WorkspaceState]) -> String {
        guard let space = profiles.first(where: { $0.id == caller.profileID }) else { return "This task's space is gone." }
        let snapshot = ProcessSnapshot()
        let store = MissionStore.shared
        _ = store.ensureLoaded()
        var lines: [String] = []
        for subtask in subtasks {
            var line = taskListHead(subtask, in: space, parentTitle: nil, snapshot: snapshot)
            let missions = store.missions.filter { $0.childWorkspaceID == subtask.id && $0.parentWorkspaceID == caller.id }
            if let mission = missions.max(by: { $0.createdAt < $1.createdAt }) {
                line += taskListMissionLine(mission, of: subtask, store: store)
            } else {
                line += " · doesn't report to you (the user started it)"
            }
            line += taskListStatusLine(subtask)
            lines.append(line)
        }
        let running = runningSubtasks(of: caller, among: subtasks).count
        let title = MissionPromptText.quoted(caller.title)
        let header = subtasks.isEmpty
            ? "“\(title)” has no sub-task."
            : "“\(title)”: \(subtasks.count == 1 ? "1 sub-task" : "\(subtasks.count) sub-tasks"), "
                + "\(running) running of \(TaskTools.maxRunningSubtasks) at most."
        return ([header] + lines).joined(separator: "\n")
    }

    // MARK: reply

    private func taskReply(_ arguments: [String: Any], from caller: WorkspaceState, answer: @escaping LeadAnswer) {
        let questionID = LeadTools.string(arguments, "question") ?? ""
        let message = LeadTools.string(arguments, "message") ?? ""
        let store = MissionStore.shared
        _ = store.ensureLoaded()
        guard let mission = store.missions.first(where: { mission in
            (mission.parentWorkspaceID == caller.id || ZZ("reply-any-parent")) && mission.events.contains { $0.id == questionID && $0.kind == .question }
        }) else {
            return answer("No question “\(questionID)” from one of your sub-tasks: copy its id from the [Nirux Mission] message "
                + "or list_tasks.", true)
        }
        sendReply(message, to: questionID, in: mission, answer: answer)
    }
}
