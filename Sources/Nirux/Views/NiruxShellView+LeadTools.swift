import AppKit

// MARK: - The Lead's tools (docs/spaces.md, "The Lead")

/// What the app does for each of the Lead's tools (see LeadTools), sent by
/// the MCP server through LeadChannel. A request is checked against the
/// app's own state first: it must come from a column of a space's Lead,
/// and it acts in that space only. Nothing here merges, removes a worktree
/// or a branch, or starts a merge queue.
extension NiruxShellView {
    typealias LeadAnswer = @MainActor (_ text: String, _ isError: Bool) -> Void

    func handleLeadRequest(_ request: LeadChannel.Request, answer: @escaping LeadAnswer) {
        guard let lead = workspaces.first(where: { $0.id == request.workspaceID && $0.isLead && !$0.isClosing }),
              lead.columns.contains(where: { $0.agentUUID == request.agentUUID }),
              let space = profiles.first(where: { $0.id == lead.profileID })
        else {
            return answer("Only a space's Lead can use this tool: this terminal isn't one, or its Lead was turned off.", true)
        }
        let arguments = request.argumentObject
        if let problem = LeadTools.problem(tool: request.tool, arguments: arguments) { return answer(problem, true) }
        let parent = NewTask.MissionParent(workspaceID: lead.id, agentUUID: request.agentUUID)
        switch request.tool {
        case LeadTools.startTask: leadStartTask(arguments, in: space, parent: parent, answer: answer)
        case LeadTools.listTasks: answer(leadTaskList(in: space), false)
        case LeadTools.tell: leadTell(arguments, in: space, answer: answer)
        case LeadTools.reply: leadReply(arguments, in: space, answer: answer)
        case LeadTools.askUser: leadAskUser(arguments, in: space, answer: answer)
        case LeadTools.queueMerge: leadQueueMerge(arguments, in: space, answer: answer)
        default: answer("Unknown tool: \(request.tool)", true)
        }
    }

    // MARK: start_task

    private func leadStartTask(
        _ arguments: [String: Any], in space: WorkspaceProfile, parent: NewTask.MissionParent, answer: @escaping LeadAnswer
    ) {
        let description = LeadTools.string(arguments, "description") ?? ""
        let repositories = newTaskRepositories(of: space)
        guard !repositories.isEmpty else {
            return answer("\(space.name) has no repository yet: ask the user to add one (Space Settings › General).", true)
        }
        let repository: NewTaskPanel.Repository
        if let name = LeadTools.string(arguments, "repo") {
            guard let named = repositories.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
                return answer("No repository named “\(name)” in \(space.name): \(repositories.map(\.name).joined(separator: ", ")).", true)
            }
            repository = named
        } else {
            repository = repositories.first { $0.key == space.anchors.defaultAnchor?.key } ?? repositories[0]
        }
        let templateName = LeadTools.string(arguments, "template")
        guard SpaceDefaultsStore.defaults(forSpace: space.id).leadStartsTasksWithoutAsking else {
            return leadProposeTask(description, repository: repository, templateName: templateName, in: space, parent: parent, answer: answer)
        }
        let agent = defaultTaskAgent(forSpace: space.id)
        Self.readNewTaskInfo(
            spaceID: space.id, folder: repository.folder, anchors: space.anchors, stateDirectory: Persistence.stateDirectory
        ) { [weak self] info in
            guard let self else { return }
            guard let target = info.target else {
                return answer("\(repository.name) isn’t a git repository Nirux can start a task in.", true)
            }
            if let templateName, !info.templates.contains(where: { $0.name.caseInsensitiveCompare(templateName) == .orderedSame }) {
                let names = info.templates.map(\.name)
                return answer("No template named “\(templateName)”" + (names.isEmpty ? "." : ": \(names.joined(separator: ", ")).") , true)
            }
            let template = templateName.flatMap { name in info.templates.first { $0.name.caseInsensitiveCompare(name) == .orderedSame } }
            let suggested = NewTask.suggestedBranch(description: description, templateName: template?.name)
            guard !suggested.isEmpty else {
                return answer("No branch name comes out of that description: start it with a few words that name the task.", true)
            }
            Self.unusedBranch(suggested, repository: target.repository) { [weak self] branch in
                guard let self else { return }
                let request = NewTask.Request(
                    description: description, template: template, agent: agent, projectID: space.id,
                    branch: branch, target: target, fetchesFirst: true, reportsTo: parent
                )
                self.startTask(request) { outcome in
                    switch outcome {
                    case .opened:
                        let title = NewTask.workspaceTitle(description: description) ?? branch
                        let from = target.remoteBranchName.map { "from \($0), fetched" } ?? "from the checkout’s HEAD"
                        answer("Started “\(title)” on \(branch) in \(repository.name), \(from), with \(agent.rawValue). "
                            + "It reports to you: its questions and its result come to your prompt.", false)
                    case .failed(let message):
                        answer("The task didn’t start: \(message)", true)
                    case .fetchFailed(let message):
                        answer("Couldn’t fetch \(target.remoteBranchName ?? "origin"): \(message) Nothing was created; tell the user.", true)
                    }
                }
            }
        }
    }

    /// The first of `branch`, `branch-2`, `branch-3`… no local or remote
    /// branch has (in any case, which the filesystem doesn't tell apart).
    nonisolated private static func unusedBranch(
        _ branch: String, repository: String, completion: @escaping @MainActor @Sendable (String) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            var candidate = branch
            var suffix = 2
            while GitWorktree.localBranchExistsIgnoringCase(candidate, repoRoot: repository)
                || GitWorktree.existingBranch(candidate, repoRoot: repository).remote, suffix < 100 {
                candidate = "\(branch)-\(suffix)"
                suffix += 1
            }
            let chosen = candidate
            DispatchQueue.main.async { @MainActor in completion(chosen) }
        }
    }

    /// "Starts tasks without asking" off: the New sheet, filled in, in the
    /// Lead's space; the task reports to the Lead if the user starts it.
    private func leadProposeTask(
        _ description: String, repository: NewTaskPanel.Repository, templateName: String?,
        in space: WorkspaceProfile, parent: NewTask.MissionParent, answer: @escaping LeadAnswer
    ) {
        if let panel = newTaskPanel, !panel.isHidden {
            return answer("The user hasn’t closed the last New sheet yet: wait, then propose this task again.", true)
        }
        guard let panel = showNewPanel(spaceID: space.id, selectedKey: repository.key) else {
            return answer("Another sheet is open in Nirux: wait for the user, then propose this task again.", true)
        }
        panel.reportsTo = parent
        panel.prefill(description: description, templateName: templateName)
        answer("Proposed to the user in the New sheet (the space’s setting “Starts tasks without asking” is off). "
            + "If they start it, it reports to you.", false)
    }

    // MARK: list_tasks

    /// One paragraph per task of the space, the Lead aside, then its
    /// repositories.
    func leadTaskList(in space: WorkspaceProfile) -> String {
        let snapshot = ProcessSnapshot()
        let store = MissionStore.shared
        _ = store.ensureLoaded()
        let tasks = workspaceStore.visibleWorkspaceIndices(in: space.id).map { workspaces[$0] }
            .filter { !$0.isLead && !$0.isClosing }
        var lines: [String] = []
        for task in tasks {
            var line = "- “\(task.title)”"
            if let branch = task.gitBranch { line += " · branch \(branch)" }
            if task.isInactive { line += " · inactive" }
            line += " · " + leadAgentState(of: task, snapshot: snapshot)
            if let pr = task.prInfo {
                line += " · PR #\(pr.number) \(pr.isDraft ? "draft" : pr.state.lowercased())"
                if let ci = pr.ciStatus { line += ", checks \(ci.lowercased())" }
            }
            let missions = store.missions.filter { $0.childWorkspaceID == task.id }
            if let mission = missions.max(by: { $0.createdAt < $1.createdAt }) {
                if let question = store.waitingQuestion(childWorkspaceID: task.id, childAgentUUID: mission.childAgentUUID)?.event {
                    let holder = question.handedToUserBecause == nil ? "asks you" : "asks the user (you handed it over)"
                    line += "\n  \(holder), question \(question.id): \(question.message)"
                } else if mission.status == .completed,
                          let result = mission.events.last(where: { $0.kind == .completed }) {
                    line += "\n  completed: \(result.message)"
                }
            }
            lines.append(line)
        }
        let repositories = space.anchors.filter(\.isKnown).map { anchor in
            anchor.name + (anchor.isDefault ? " (default)" : "")
        }
        let header = "\(space.name): \(tasks.isEmpty ? "no task" : tasks.count == 1 ? "1 task" : "\(tasks.count) tasks")."
        let repositoryLine = repositories.isEmpty
            ? "No repository: tasks can't start until the user adds one."
            : "Repositories: \(repositories.joined(separator: ", "))."
        return ([header] + lines + [repositoryLine]).joined(separator: "\n")
    }

    /// What its agents do: working, needs the user (and for what), idle.
    private func leadAgentState(of workspace: WorkspaceState, snapshot: ProcessSnapshot) -> String {
        var agents: [(name: String, status: AgentStatus, dialog: String?)] = []
        for column in workspace.columns {
            guard let pty = column.pty, let foreground = pty.foregroundProcess(snapshot: snapshot),
                  ["claude", "codex"].contains(foreground.name) else { continue }
            let dialog: String? = pty.agentVisibleDialog(foreground: foreground)?.reason.shortLabel
            agents.append((name: foreground.name, status: pty.cachedAgentState, dialog: dialog))
        }
        guard let first = agents.first else { return "no agent running" }
        if let waiting = agents.first(where: { $0.status == AgentStatus.needsAttention }) {
            return "\(waiting.name) needs the user" + (waiting.dialog.map { ": \($0)" } ?? "")
        }
        if let working = agents.first(where: { $0.status == AgentStatus.working }) { return "\(working.name) working" }
        return "\(first.name) idle"
    }

    // MARK: tell, reply, ask_user

    /// The task named by its branch or title, among the space's workspaces,
    /// and its latest Mission that reports to a Lead of the space.
    private func leadTask(_ name: String, in space: WorkspaceProfile) -> (workspace: WorkspaceState, mission: Mission)? {
        _ = MissionStore.shared.ensureLoaded()
        let candidates = workspaces.filter { $0.profileID == space.id && !$0.isLead && !$0.isClosing }
        let matches = candidates.filter { $0.gitBranch == name }
            + candidates.filter { $0.title.caseInsensitiveCompare(name) == .orderedSame && $0.gitBranch != name }
        for workspace in matches {
            if let mission = MissionStore.shared.missions
                .filter({ $0.childWorkspaceID == workspace.id && $0.reportsToLead == true })
                .max(by: { $0.createdAt < $1.createdAt }) {
                return (workspace, mission)
            }
        }
        return nil
    }

    private func noLeadTask(_ name: String) -> String {
        "No task of yours is named “\(name)”: use its branch or title from list_tasks. A task the user started "
            + "without you doesn't report to you."
    }

    private func leadTell(_ arguments: [String: Any], in space: WorkspaceProfile, answer: @escaping LeadAnswer) {
        let name = LeadTools.string(arguments, "task") ?? ""
        let message = LeadTools.string(arguments, "message") ?? ""
        guard let (workspace, mission) = leadTask(name, in: space) else { return answer(noLeadTask(name), true) }
        guard mission.childAgentKind == NiruxApp.WorkspaceAgent.claude.rawValue else {
            return answer("Nirux types messages only into a Claude Code task; “\(workspace.title)” runs \(mission.childAgentKind).", true)
        }
        let instruction = MissionEvent(
            id: UUID().uuidString, missionID: mission.id,
            childWorkspaceID: mission.childWorkspaceID, childAgentUUID: mission.childAgentUUID,
            parentWorkspaceID: mission.parentWorkspaceID, parentAgentUUID: mission.parentAgentUUID,
            kind: .instruction, message: message, timestamp: Date().timeIntervalSince1970
        )
        guard case .accepted = MissionStore.shared.process(instruction, enabled: Self.currentMissionHandoffsEnabled()) else {
            return answer("Nirux couldn’t record the message: try again.", true)
        }
        typeMissionMessages()
        answer("Nirux types it into “\(workspace.title)”’s prompt once its turn is over, within the hour.", false)
    }

    private func leadReply(_ arguments: [String: Any], in space: WorkspaceProfile, answer: @escaping LeadAnswer) {
        let questionID = LeadTools.string(arguments, "question") ?? ""
        let message = LeadTools.string(arguments, "message") ?? ""
        let store = MissionStore.shared
        _ = store.ensureLoaded()
        let spaceWorkspaces = Set(workspaces.filter { $0.profileID == space.id }.map(\.id))
        guard let mission = store.missions.first(where: { mission in
            mission.reportsToLead == true && spaceWorkspaces.contains(mission.childWorkspaceID)
                && mission.events.contains { $0.id == questionID && $0.kind == .question }
        }) else {
            return answer("No question “\(questionID)” from one of your tasks: copy its id from the [Nirux Mission] message or list_tasks.", true)
        }
        guard store.response(to: questionID) == nil, mission.status == .active else {
            return answer("That question was already answered (perhaps by the user), or its task completed. Don't send it again.", true)
        }
        let response = MissionEvent(
            id: UUID().uuidString, missionID: mission.id,
            childWorkspaceID: mission.childWorkspaceID, childAgentUUID: mission.childAgentUUID,
            parentWorkspaceID: mission.parentWorkspaceID, parentAgentUUID: mission.parentAgentUUID,
            kind: .response, message: message, inReplyTo: questionID, timestamp: Date().timeIntervalSince1970
        )
        guard case .accepted(let accepted) = store.process(response, enabled: Self.currentMissionHandoffsEnabled()) else {
            return answer("Nirux couldn’t record the answer: try again.", true)
        }
        if let accepted, handleMissionEvent(accepted.mission, event: accepted.event) {
            store.markDelivered(eventID: accepted.event.id)
        }
        typeMissionMessages()
        updateSidebar()
        let title = workspaces.first { $0.id == mission.childWorkspaceID }?.title ?? mission.branch
        answer("Answer sent: Nirux types it into “\(title)”’s prompt once its turn is over.", false)
    }

    private func leadAskUser(_ arguments: [String: Any], in space: WorkspaceProfile, answer: @escaping LeadAnswer) {
        let name = LeadTools.string(arguments, "task") ?? ""
        let why = LeadTools.string(arguments, "why") ?? ""
        guard let (workspace, mission) = leadTask(name, in: space) else { return answer(noLeadTask(name), true) }
        guard let question = MissionStore.shared.waitingQuestion(
            childWorkspaceID: mission.childWorkspaceID, childAgentUUID: mission.childAgentUUID
        )?.event else {
            return answer("“\(workspace.title)” has no question waiting: ask the user here, in this conversation.", true)
        }
        guard MissionStore.shared.handToUser(questionID: question.id, because: why) != nil else {
            return answer("Nirux couldn’t hand the question over: try again.", true)
        }
        updateSidebar()
        answer("Handed to the user: “\(workspace.title)”’s row is amber with your reason. Their answer goes to the task, "
            + "and a line comes to you.", false)
    }

    // MARK: queue_merge

    /// The confirmation sheet of one repository's merge queue, with these
    /// pull requests in this order. Never starts it.
    private func leadQueueMerge(_ arguments: [String: Any], in space: WorkspaceProfile, answer: @escaping LeadAnswer) {
        let numbers = LeadTools.pullRequestNumbers(arguments) ?? []
        guard let board = projectBoardLocation(projectID: space.id)?.board else {
            return answer("\(space.name)'s Board isn't open: ask the user to open it (⌃⌘B), then try again.", true)
        }
        guard board.loaded != nil else { return answer("The Board is still loading: try again in a moment.", true) }
        let sections = board.sections.compactMap { section in board.repository(of: section).map { (section, $0) } }
        guard !sections.isEmpty else {
            return answer("The Board has no GitHub repository set up: ask the user to open Board Settings.", true)
        }
        let chosen: (BoardSections.Section, (name: String, gitHub: GitHubRepository))
        if let name = LeadTools.string(arguments, "repo") {
            guard let match = sections.first(where: { section in
                section.1.name.caseInsensitiveCompare(name) == .orderedSame
                    || section.1.gitHub.ownerAndName.caseInsensitiveCompare(name) == .orderedSame
            }) else {
                return answer("No repository “\(name)” on the Board: \(sections.map(\.1.name).joined(separator: ", ")).", true)
            }
            chosen = match
        } else {
            guard sections.count == 1 else {
                return answer("Say which repository: \(sections.map(\.1.name).joined(separator: ", ")). One queue per repository.", true)
            }
            chosen = sections[0]
        }
        if mergeQueueConfirmation != nil {
            return answer("A merge queue's confirmation sheet is already open: wait for the user.", true)
        }
        let controller = mergeQueue(projectID: space.id, repository: chosen.1.gitHub)
        guard !controller.isRunning, !controller.runsElsewhere else {
            return answer("\(chosen.1.name)'s merge queue is running: propose these once it ends.", true)
        }
        for number in controller.selection(for: chosen.1.gitHub) where !numbers.contains(number) {
            controller.removeFromSelection(number)
        }
        for number in numbers { controller.addToSelection(number, repository: chosen.1.gitHub) }
        requestMergeQueueStart(board: board, section: chosen.0.id)
        guard mergeQueueConfirmation != nil else {
            return answer("Nirux couldn't open the merge queue's sheet (the Board may need its settings): tell the user.", true)
        }
        answer("The confirmation sheet of \(chosen.1.name)'s merge queue is open with "
            + numbers.map { "#\($0)" }.joined(separator: ", ") + ". Nothing merges until the user clicks Start.", false)
    }
}
