import AppKit

// MARK: - A task's tools (TaskTools)

/// What the app does for the tools of a task's agent: any workspace's
/// column but a Lead's (NiruxShellView+LeadTools hands the request over).
/// It acts on the sub-tasks that agent started only: it starts them under
/// its task, lists them, answers their questions. Two levels: a sub-task
/// has none of its own. Never in a workspace opened from outside Nirux.
extension NiruxShellView {
    func handleTaskRequest(_ request: LeadChannel.Request, from caller: WorkspaceState, answer: @escaping LeadAnswer) {
        guard TaskTools.names.contains(request.tool) else {
            return answer("Only a space's Lead can use \(request.tool).", true)
        }
        // Its agents act for whoever sent the link, not for the user: no
        // pre-allowed agents, no space environment or setup script.
        guard !caller.startedOutsideNirux else {
            return answer("This workspace was opened by a link from outside Nirux: its agents can't start or follow "
                + "sub-tasks. The user starts tasks with ⌘N.", true)
        }
        let arguments = request.argumentObject
        if let problem = LeadTools.problem(tool: request.tool, arguments: arguments) { return answer(problem, true) }
        let subtasks = subtasks(of: caller)
        let place = subtaskPlace(of: caller)
        if let refusal = subtaskRefusal(for: caller, place: place, subtasks: subtasks) { return answer(refusal, true) }
        let parent = NewTask.MissionParent(workspaceID: caller.id, agentUUID: request.agentUUID)
        switch request.tool {
        case LeadTools.startTask:
            taskStartSubtask(arguments, from: caller, place: place, subtasks: subtasks, parent: parent, answer: answer)
        case LeadTools.listTasks:
            answer(taskSubtaskList(of: caller, for: parent, subtasks: subtasks), false)
        case LeadTools.reply:
            taskReply(arguments, for: parent, answer: answer)
        default:
            answer("Unknown tool: \(request.tool)", true)
        }
    }

    /// The open sub-tasks of `task`, in the sidebar's order.
    func subtasks(of task: WorkspaceState) -> [WorkspaceState] {
        workspaceStore.visibleWorkspaceIndices(in: task.profileID).map { workspaces[$0] }
            .filter { $0.parentWorkspaceID == task.id && !$0.isClosing }
    }

    /// The sub-tasks (of `subtasks`, `task`'s) that count against
    /// `TaskTools.maxRunningSubtasks`: not archived, their latest Mission
    /// from `task` still active. One the user started under it, or that
    /// reports to someone else, never completes for it, and doesn't count.
    func runningSubtaskCount(of task: WorkspaceState, among subtasks: [WorkspaceState]? = nil) -> Int {
        _ = MissionStore.shared.ensureLoaded()
        let missions = MissionStore.shared.missions.filter { $0.parentWorkspaceID == task.id }
        return (subtasks ?? self.subtasks(of: task)).filter { subtask in
            guard !subtask.isInactive else { return false }
            let mission = missions.filter { $0.childWorkspaceID == subtask.id }.max { $0.createdAt < $1.createdAt }
            return mission?.status == .active
        }.count
    }

    /// A sub-task: its parent, a task, is still open. A Lead's tasks are
    /// the space's own list, and a plain workspace has no sub-tasks.
    func isSubtask(_ workspace: WorkspaceState) -> Bool {
        guard let parentID = workspace.parentWorkspaceID,
              let parent = workspaces.first(where: { $0.id == parentID && !$0.isClosing })
        else { return false }
        return Self.isTask(parent)
    }

    /// Why `caller` can't have sub-tasks; nil when it can (a task, or one
    /// that still has some, its folder gone). `place`: `subtaskPlace(of:)`.
    func subtaskRefusal(
        for caller: WorkspaceState, place: NewTaskPanel.ParentTask.Place?, subtasks: [WorkspaceState]
    ) -> String? {
        if isSubtask(caller) {
            return "This is a sub-task: it can't have sub-tasks of its own (two levels at most). Do the work here, "
                + "or tell the agent that started it what else is needed."
        }
        guard place != nil || !subtasks.isEmpty else {
            return "This workspace isn't a task (a worktree of one of its space's repositories, or a task's folder), "
                + "so it has no sub-tasks: to start a task from here, use the nirux-worktree skill."
        }
        return nil
    }

    // MARK: start_task

    private func taskStartSubtask(
        _ arguments: [String: Any], from caller: WorkspaceState, place: NewTaskPanel.ParentTask.Place?,
        subtasks: [WorkspaceState], parent: NewTask.MissionParent, answer: @escaping LeadAnswer
    ) {
        guard let place, let space = profiles.first(where: { $0.id == caller.profileID }) else {
            return answer("Nirux can't start a sub-task here any more: this task's folder or repository isn't there.", true)
        }
        let running = runningSubtaskCount(of: caller, among: subtasks) + pendingSubtaskStarts[caller.id, default: 0]
        guard running < TaskTools.maxRunningSubtasks else {
            return answer("This task already runs \(running) sub-tasks, the most it may: wait until one completes, "
                + "or ask the user to archive one.", true)
        }
        let description = LeadTools.string(arguments, "description") ?? ""
        let templateName = LeadTools.string(arguments, "template")
        guard leadStartsTasksWithoutAsking(spaceID: space.id) else {
            return taskProposeSubtask(description, templateName: templateName, under: caller, parent: parent, answer: answer)
        }
        let folder: NewTask.Place?
        let repository: NewTaskPanel.Repository?
        switch place {
        case .folder(let path):
            folder = .folder(parent: path, name: NewTask.suggestedFolderName(description: description), makesParent: false)
            repository = nil
        case .repository(let key):
            folder = nil
            repository = newTaskRepositories(of: space).first { $0.key == key }
            guard repository != nil else {
                return answer("Nirux can't tell which repository this task works in: ask the user to start the sub-task with ⌘N.", true)
            }
        }
        let agent = defaultTaskAgent(forSpace: space.id)
        let callerID = caller.id
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
            guard let self else { return answer("Nirux is closing: nothing was started.", true) }
            // It lists under the task, reports to its agent with Missions
            // off, and opens behind what the user is doing.
            self.startAgentTask(
                description, templateName: templateName, info: info, agent: agent, spaceID: space.id, parent: parent,
                folder: folder, repository: repository, configure: { request in
                    request.parentWorkspaceID = callerID
                    request.reportsToTask = true
                    request.startedByTaskAgent = true
                }, answer: answer
            )
        }
    }

    /// "Starts tasks without asking" off: the New Sub-task sheet under the
    /// task, filled in, now or once the sheet up closes (as a Lead's
    /// proposal waits); the sub-task reports to the agent if the user
    /// starts it as a sub-task, and the agent hears what the user did.
    private func taskProposeSubtask(
        _ description: String, templateName: String?, under caller: WorkspaceState, parent: NewTask.MissionParent,
        answer: @escaping LeadAnswer
    ) {
        let proposal = LeadProposal(
            spaceID: caller.profileID, repository: .spaceDefault, description: description, templateName: templateName,
            parent: parent, subtaskOf: caller.id
        )
        let followUp = "If they start it under your task, it reports to you; either way, a line tells you what they did."
        if pendingLeadProposals.isEmpty, showLeadProposal(proposal) {
            return answer("Proposed to the user in the New Sub-task sheet (the space’s setting “Starts tasks without asking” is off). "
                + followUp, false)
        }
        pendingLeadProposals.append(proposal)
        scheduleLeadProposals()
        let ahead = pendingLeadProposals.count - 1
        answer("Queued for the user: the New Sub-task sheet shows it once "
            + "\(ahead == 0 ? "the sheet open now closes" : "\(ahead) proposal(s) ahead are done"). " + followUp, false)
    }

    /// A line for the agent that proposed a sub-task (`parent`), typed into
    /// its prompt once it is free, as a Lead's notices are.
    func tellProposer(_ parent: NewTask.MissionParent, _ text: String) {
        pendingLeadNotices.append(LeadNotice(
            workspaceID: parent.workspaceID, agentUUID: parent.agentUUID,
            text: "\(MissionPromptText.prefix) \(text)", queuedAt: Date().timeIntervalSince1970
        ))
        typeLeadNotices()
    }

    // MARK: list_tasks

    /// The task's sub-tasks, as the Lead's list gives its tasks; the
    /// questions and results of those `parent` (this agent) started.
    func taskSubtaskList(of caller: WorkspaceState, for parent: NewTask.MissionParent, subtasks: [WorkspaceState]) -> String {
        guard let space = profiles.first(where: { $0.id == caller.profileID }) else { return "This task's space is gone." }
        let snapshot = ProcessSnapshot()
        let store = MissionStore.shared
        _ = store.ensureLoaded()
        var lines: [String] = []
        for subtask in subtasks {
            var line = taskListHead(subtask, in: space, parentTitle: nil, snapshot: snapshot)
            let mission = store.missions.filter { $0.childWorkspaceID == subtask.id && $0.parentWorkspaceID == caller.id }
                .max { $0.createdAt < $1.createdAt }
            if let mission, mission.parentAgentUUID == parent.agentUUID {
                line += taskListMissionLine(mission, of: subtask, store: store)
            } else {
                line += mission == nil ? " · doesn't report to you (the user started it)" : " · reports to another agent of this task"
            }
            line += taskListStatusLine(subtask)
            lines.append(line)
        }
        let running = runningSubtaskCount(of: caller, among: subtasks)
        let title = MissionPromptText.quoted(caller.title)
        let header = subtasks.isEmpty
            ? "“\(title)” has no sub-task."
            : "“\(title)”: \(subtasks.count == 1 ? "1 sub-task" : "\(subtasks.count) sub-tasks"), "
                + "\(running) running of \(TaskTools.maxRunningSubtasks) at most."
        return ([header] + lines).joined(separator: "\n")
    }

    // MARK: reply

    private func taskReply(_ arguments: [String: Any], for parent: NewTask.MissionParent, answer: @escaping LeadAnswer) {
        let questionID = LeadTools.string(arguments, "question") ?? ""
        let message = LeadTools.string(arguments, "message") ?? ""
        let store = MissionStore.shared
        _ = store.ensureLoaded()
        // Typed into this agent's prompt: another column's isn't its to answer.
        guard let mission = store.missions.first(where: { mission in
            mission.parentWorkspaceID == parent.workspaceID && mission.parentAgentUUID == parent.agentUUID
                && mission.events.contains { $0.id == questionID && $0.kind == .question }
        }) else {
            return answer("No question “\(questionID)” from one of your sub-tasks: copy its id from the [Nirux Mission] message "
                + "or list_tasks.", true)
        }
        sendReply(message, to: questionID, in: mission, answer: answer)
    }
}
