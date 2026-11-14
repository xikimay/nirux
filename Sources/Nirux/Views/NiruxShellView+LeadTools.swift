import AppKit

// MARK: - The Lead's tools (docs/design/spaces.md, "The Lead")

/// What the app does for each of the Lead's tools (see LeadTools), sent by
/// the MCP server through LeadChannel. A request is checked against the
/// app's own state first: it must come from a column of a space's Lead,
/// and it acts in that space only. One from another workspace's column
/// goes to that task's tools (NiruxShellView+TaskTools). Nothing here
/// merges, removes a worktree or a branch, or starts a merge queue.
extension NiruxShellView {
    typealias LeadAnswer = @MainActor (_ text: String, _ isError: Bool) -> Void

    func handleLeadRequest(_ request: LeadChannel.Request, answer: @escaping LeadAnswer) {
        if let caller = workspaces.first(where: { $0.id == request.workspaceID && !$0.isLead && !$0.isClosing }),
           caller.columns.contains(where: { $0.agentUUID == request.agentUUID }) {
            return handleTaskRequest(request, from: caller, answer: answer)
        }
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
        case LeadTools.listTasks: answer(leadTaskList(in: space, lead: lead.id), false)
        case LeadTools.tell: leadTell(arguments, in: space, lead: lead.id, answer: answer)
        case LeadTools.reply: leadReply(arguments, in: space, lead: lead.id, answer: answer)
        case LeadTools.askUser: leadAskUser(arguments, in: space, lead: lead.id, answer: answer)
        case LeadTools.queueMerge: leadQueueMerge(arguments, in: space, answer: answer)
        case LeadTools.setTaskContext: leadSetTaskContext(arguments, in: space, lead: lead.id, answer: answer)
        case LeadTools.proposeRule: leadProposeRule(arguments, in: space, parent: parent, answer: answer)
        default: answer("Unknown tool: \(request.tool)", true)
        }
    }

    // MARK: start_task

    private func leadStartTask(
        _ arguments: [String: Any], in space: WorkspaceProfile, parent: NewTask.MissionParent, answer: @escaping LeadAnswer
    ) {
        let description = LeadTools.string(arguments, "description") ?? ""
        let repositories = newTaskRepositories(of: space)
        let repository: NewTaskPanel.Repository?
        var asksNoRepository = false
        if let name = LeadTools.string(arguments, "repo") {
            if let named = repositories.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                repository = named
            } else if name.caseInsensitiveCompare(LeadTools.noRepository) == .orderedSame {
                repository = nil
                asksNoRepository = true
            } else {
                let names = (repositories.map(\.name) + ["\"\(LeadTools.noRepository)\" (a new folder, no repository)"])
                return answer("No repository named “\(name)” in \(space.name): \(names.joined(separator: ", ")).", true)
            }
        } else {
            // A space without a repository starts its tasks in folders.
            repository = repositories.first { $0.key == space.anchors.defaultAnchor?.key } ?? repositories.first
        }
        let templateName = LeadTools.string(arguments, "template")
        guard leadStartsTasksWithoutAsking(spaceID: space.id) else {
            return leadProposeTask(
                description, repository: repository, withoutRepository: asksNoRepository, templateName: templateName,
                in: space, parent: parent, answer: answer
            )
        }
        let agent = defaultTaskAgent(forSpace: space.id)
        Self.readNewTaskInfo(
            spaceID: space.id, folder: repository?.folder, anchors: space.anchors, stateDirectory: Persistence.stateDirectory
        ) { [weak self] info in
            guard let self else { return }
            var folder: NewTask.Place?
            if repository == nil || info.target == nil {
                // No repository, or a folder of the space surely outside
                // git: a folder of its own, as ⌘N makes.
                if let repository, !(repository.isFolder && info.isOutsideGit) {
                    return answer("\(repository.name) isn’t a git repository Nirux can start a task in.", true)
                }
                let tasksFolder = self.tasksFolder()
                folder = .folder(
                    parent: repository?.folder ?? tasksFolder.path,
                    name: NewTask.suggestedFolderName(description: description),
                    makesParent: repository == nil && tasksFolder.isDefault
                )
            }
            // It opens behind what the user is doing.
            self.startAgentTask(
                description, templateName: templateName, info: info, agent: agent, spaceID: space.id, parent: parent,
                folder: folder, repository: repository, configure: { $0.startedByLead = true }, answer: answer
            )
        }
    }

    /// What a Lead's start_task and a task's do once the space's templates
    /// and the repository's info are read: the template asked for, then the
    /// task in `folder`, or on a new branch of `repository` named after the
    /// description. `configure` marks the request as the caller's.
    // The request's fields, as start_task gathered them.
    // swiftlint:disable:next function_parameter_count
    func startAgentTask(
        _ description: String, templateName: String?, info: NewTaskPanel.ProjectInfo, agent: NiruxApp.WorkspaceAgent,
        spaceID: String, parent: NewTask.MissionParent, folder: NewTask.Place?, repository: NewTaskPanel.Repository?,
        configure: @escaping @MainActor @Sendable (inout NewTask.Request) -> Void, answer: @escaping LeadAnswer
    ) {
        if let templateName, !info.templates.contains(where: { $0.name.caseInsensitiveCompare(templateName) == .orderedSame }) {
            let names = info.templates.map(\.name)
            return answer("No template named “\(templateName)”" + (names.isEmpty ? "." : ": \(names.joined(separator: ", ")).") , true)
        }
        let template = templateName.flatMap { name in info.templates.first { $0.name.caseInsensitiveCompare(name) == .orderedSame } }
        if let folder {
            var request = NewTask.Request(
                description: description, template: template, agent: agent, projectID: spaceID,
                place: folder, fetchesFirst: false, reportsTo: parent
            )
            configure(&request)
            return startLeadTask(request, repository: nil, fetchError: nil, answer: answer)
        }
        guard let repository, let target = info.target else {
            return answer("\(repository?.name ?? "This repository") isn’t a git repository Nirux can start a task in.", true)
        }
        let suggested = NewTask.suggestedBranch(description: description, templateName: template?.name)
        guard !suggested.isEmpty else {
            return answer("No branch name comes out of that description: start it with a few words that name the task.", true)
        }
        Self.unusedBranch(suggested, repository: target.repository) { [weak self] branch in
            guard let self else { return }
            var request = NewTask.Request(
                description: description, template: template, agent: agent, projectID: spaceID,
                place: .worktree(target, branch: branch), fetchesFirst: true, reportsTo: parent
            )
            configure(&request)
            self.startLeadTask(request, repository: repository.name, fetchError: nil, answer: answer)
        }
    }

    /// Starts the task; a failed fetch starts it again from origin's base as
    /// last fetched, once, as ⌘N's "Start Without Fetching". Answers once
    /// the workspace and its Mission exist. `repository` is nil for a
    /// folder. A Lead's task, or a task's sub-task (`reportsToTask`).
    func startLeadTask(
        _ request: NewTask.Request, repository: String?, fetchError: String?, answer: @escaping LeadAnswer
    ) {
        startTask(request, completion: { [weak self] outcome in
            switch outcome {
            case .opened:
                // `opened` answers, once the workspace is there.
                break
            case .failed(let message):
                answer("The task didn’t start: \(message)", true)
            case .fetchFailed(let message):
                guard let self, request.fetchesFirst, let target = request.target, target.remoteBranch != nil else {
                    return answer("Couldn’t fetch \(request.target?.remoteBranchName ?? "origin"): \(message) Nothing was created; tell the user.", true)
                }
                var retry = request
                retry.fetchesFirst = false
                self.startLeadTask(retry, repository: repository, fetchError: message, answer: answer)
            }
        }, opened: { [weak self] workspaceID, created in
            guard let self else { return }
            let label = created.checkedOutBranch ?? created.folderName ?? request.name
            let title = NewTask.workspaceTitle(description: request.description) ?? label
            let place: String
            if let repository, let target = request.target {
                let base = target.remoteBranchName
                let from = fetchError.map { "from \(base ?? "origin") as last fetched (the fetch failed: \($0))" }
                    ?? base.map { "from \($0), fetched" } ?? "from the checkout’s HEAD"
                place = "on \(label) in \(repository), \(from)"
            } else {
                place = "in \(created.path), a new folder without a repository"
                    + " (its agent may first ask the user to trust that folder: its row then reads Needs you)"
            }
            let reports = MissionStore.shared.missions.contains { mission in
                mission.parentWorkspaceID == request.reportsTo?.workspaceID && mission.childWorkspaceID == workspaceID
            }
            // Why it doesn't: the asking terminal went, or the ledger.
            let requester = request.reportsTo.flatMap { self.requestingTerminal(workspaceID: $0.workspaceID, agentUUID: $0.agentUUID) }
            let alone = request.reportsToTask
                ? (requester == nil ? "your terminal closed meanwhile" : "Nirux couldn’t record its Mission")
                : (requester?.workspace.isLead == true ? "Nirux couldn’t record its Mission" : "your Lead changed meanwhile")
            answer("Started “\(title)” \(place), with \(request.agent.rawValue). "
                + (reports ? "It reports to you: its questions and its result come to your prompt."
                    : "It doesn’t report to you (\(alone)): the user follows it."), false)
        })
    }

    /// The first of `branch`, `branch-2`, `branch-3`… no local or remote
    /// branch has (in any case, which the filesystem doesn't tell apart).
    nonisolated static func unusedBranch(
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
    /// One sheet at a time: the others wait their turn.
    private func leadProposeTask(
        _ description: String, repository: NewTaskPanel.Repository?, withoutRepository: Bool, templateName: String?,
        in space: WorkspaceProfile, parent: NewTask.MissionParent, answer: @escaping LeadAnswer
    ) {
        let proposal = LeadProposal(
            spaceID: space.id,
            repository: repository.map { .named(key: $0.key) } ?? (withoutRepository ? .noRepository : .spaceDefault),
            description: description, templateName: templateName, parent: parent
        )
        if pendingLeadProposals.isEmpty, showLeadProposal(proposal) {
            return answer("Proposed to the user in the New sheet (the space’s setting “Starts tasks without asking” is off). "
                + "If they start it, it reports to you.", false)
        }
        pendingLeadProposals.append(proposal)
        scheduleLeadProposals()
        let ahead = pendingLeadProposals.count - 1
        answer("Queued for the user: the New sheet shows it once \(ahead == 0 ? "the sheet open now closes" : "\(ahead) proposal(s) ahead are done"). "
            + "If they start it, it reports to you.", false)
    }

    /// Shows a proposal when no sheet is up and its Lead is still there; a
    /// task's (`subtaskOf`) under its task, which hears what the user did.
    func showLeadProposal(_ proposal: LeadProposal) -> Bool {
        guard window?.attachedSheet == nil else { return false }
        if let taskID = proposal.subtaskOf {
            guard let task = workspaces.first(where: { $0.id == taskID && !$0.isClosing }),
                  let panel = showNewSubtaskPanel(under: task)
            else { return false }
            panel.reportsToTaskAgent = proposal.parent
            panel.prefill(description: proposal.description, templateName: proposal.templateName, proposedBy: "“\(task.title)”")
            let firstLine = NewTask.workspaceTitle(description: proposal.description) ?? proposal.description
            panel.onDeclineProposal = { [weak self] in
                self?.tellProposer(proposal.parent, "The user closed the New Sub-task sheet you proposed (“\(MissionPromptText.quoted(firstLine))”): "
                    + "nothing was started.")
            }
            return true
        }
        guard let panel = showNewPanel(
                  spaceID: proposal.spaceID, selectedKey: proposal.repository.key, withoutRepository: proposal.repository == .noRepository
              )
        else { return false }
        panel.reportsTo = proposal.parent
        panel.prefill(description: proposal.description, templateName: proposal.templateName)
        return true
    }

    /// Once a second, while proposals wait: the next one shows when no
    /// sheet is up; one whose Lead went is dropped, or whose task can't
    /// have sub-tasks any more.
    func scheduleLeadProposals() {
        guard leadProposalTimer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.showNextLeadProposal() }
        }
        RunLoop.main.add(timer, forMode: .common)
        leadProposalTimer = timer
    }

    func showNextLeadProposal() {
        pendingLeadProposals.removeAll { proposal in
            if let taskID = proposal.subtaskOf {
                return !workspaces.contains { $0.id == taskID && !$0.isClosing && offersSubtask($0) }
            }
            return !workspaces.contains { $0.id == proposal.parent.workspaceID && $0.isLead && !$0.isClosing }
        }
        if let next = pendingLeadProposals.first, showLeadProposal(next) { pendingLeadProposals.removeFirst() }
        if pendingLeadProposals.isEmpty {
            leadProposalTimer?.invalidate()
            leadProposalTimer = nil
        }
    }

    // MARK: list_tasks

    /// One paragraph per task of the space, the Lead aside, then its
    /// repositories.
    func leadTaskList(in space: WorkspaceProfile, lead leadID: String) -> String {
        let snapshot = ProcessSnapshot()
        let store = MissionStore.shared
        _ = store.ensureLoaded()
        let tasks = workspaceStore.visibleWorkspaceIndices(in: space.id).map { workspaces[$0] }
            .filter { !$0.isLead && !$0.isClosing }
        // As the sidebar lists them.
        let parentTitles = Dictionary(
            workspaceStore.activeParents(in: space.id).map { (workspaces[$0.key].id, workspaces[$0.value].title) },
            uniquingKeysWith: { first, _ in first }
        )
        var lines: [String] = []
        for task in tasks {
            var line = taskListHead(task, in: space, parentTitle: parentTitles[task.id], snapshot: snapshot)
            // Only what its own tasks sent it: another agent's Mission
            // isn't its to answer.
            let missions = store.missions.filter { $0.childWorkspaceID == task.id && $0.parentWorkspaceID == leadID }
            if missions.isEmpty {
                line += task.startedByAgent ? " · not yours (another agent started it)" : " · not yours (started by the user)"
            } else if let mission = missions.max(by: { $0.createdAt < $1.createdAt }) {
                line += taskListMissionLine(mission, of: task, store: store)
            }
            // Only where set_task_context reaches: its own tasks.
            for field in WorkspaceState.ContextField.allCases where missions.contains(where: { $0.reportsToLead == true }) {
                guard let text = Self.leadContextText(task.contextText(field)) else { continue }
                let name = field == .nextStep ? "next step" : "blocker"
                let owner = task.contextIsFromLead(field) ? "" : " (the user wrote it)"
                line += "\n  \(name)\(owner): “\(text)”"
            }
            line += taskListStatusLine(task)
            lines.append(line)
        }
        let repositories = space.anchors.filter(\.isKnown).map { anchor in
            anchor.name + (anchor.isDefault ? " (default)" : "")
        }
        let header = "\(space.name): \(tasks.isEmpty ? "no task" : tasks.count == 1 ? "1 task" : "\(tasks.count) tasks")."
        let folderLine = "a new folder of its own in \(tasksFolder().path), no git"
        let repositoryLine = repositories.isEmpty
            ? "No repository: each task starts in \(folderLine)."
            : "Repositories: \(repositories.joined(separator: ", ")); \"\(LeadTools.noRepository)\" starts a task in \(folderLine)."
        return ([header] + lines + [repositoryLine]).joined(separator: "\n")
    }

    /// A task's line in list_tasks, up to its pull request: what it is,
    /// where it works, and what its agents do.
    func taskListHead(_ task: WorkspaceState, in space: WorkspaceProfile, parentTitle: String?, snapshot: ProcessSnapshot) -> String {
        var line = "- “\(MissionPromptText.quoted(task.title))”"
        if let parentTitle { line += " · sub-task of “\(MissionPromptText.quoted(parentTitle))”" }
        if let branch = task.gitBranch { line += " · branch \(MissionPromptText.quoted(branch))" }
        if let folder = task.taskFolder {
            line += " · no repository · folder \(MissionPromptText.quoted(folder))"
        } else if let repository = leadRepositoryName(of: task, in: space) {
            line += " · \(repository)"
        }
        if task.isInactive { line += " · inactive" }
        line += " · " + leadAgentState(of: task, snapshot: snapshot)
        if let pr = task.prInfo {
            line += " · PR #\(pr.number) \(pr.isDraft ? "draft" : pr.state.lowercased())"
            if let ci = pr.ciStatus { line += ", checks \(ci.lowercased())" }
        }
        return line
    }

    /// The question `mission`'s child waits on, or the result it sent, on
    /// a line of its own; "" for neither.
    func taskListMissionLine(_ mission: Mission, of task: WorkspaceState, store: MissionStore) -> String {
        if let question = store.waitingQuestion(childWorkspaceID: task.id, childAgentUUID: mission.childAgentUUID)?.event {
            let holder = question.handedToUserBecause == nil ? "asks you" : "asks the user (you handed it over)"
            return "\n  \(holder), question \(question.id): \(MissionPromptText.quoted(question.message))"
        }
        if mission.status == .completed, let result = mission.events.last(where: { $0.kind == .completed }) {
            return "\n  completed: \(MissionPromptText.quoted(result.message))"
        }
        return ""
    }

    /// Where a task stands, as its row says it: a model's reading of its
    /// last turn's message, or the user's own summary; "" for neither.
    func taskListStatusLine(_ task: WorkspaceState) -> String {
        guard turnStatusEnabled, let status = Self.leadContextText(task.statusLine) else { return "" }
        let source = task.lastSummaryIsManual ? "summary (the user wrote it)" : "last turn, as Sonnet read it"
        return "\n  \(source): “\(status)”"
    }

    /// The space's repository a task works in, by name: its folder is the
    /// main checkout, in it, or one of the worktrees Nirux places beside it
    /// (`<checkout>.<branch>`, see `GitWorktree.create`). No git: a guess.
    private func leadRepositoryName(of task: WorkspaceState, in space: WorkspaceProfile) -> String? {
        let folder = URL(fileURLWithPath: task.cwd).standardizedFileURL.path
        return space.anchors.first { anchor in
            guard let anchorFolder = anchor.folder.map({ URL(fileURLWithPath: $0).standardizedFileURL.path }) else { return false }
            return folder == anchorFolder || folder.hasPrefix(anchorFolder + "/") || folder.hasPrefix(anchorFolder + ".")
        }?.name
    }

    /// What its agents do: working, needs the user (and for what), idle.
    private func leadAgentState(of workspace: WorkspaceState, snapshot: ProcessSnapshot) -> String {
        var agents: [(name: String, status: AgentStatus, dialog: String?)] = []
        for column in workspace.columns {
            guard let pty = column.pty, let foreground = pty.foregroundProcess(snapshot: snapshot),
                  ["claude", "codex"].contains(foreground.name) else { continue }
            // A question its last turn ended on waits on the user too.
            let dialog: String? = (pty.agentVisibleDialog(foreground: foreground)?.reason
                ?? pty.agentAskedQuestion(foreground: foreground))?.shortLabel
                ?? pty.agentTrustPrompt(foreground: foreground).map { _ in "whether to trust its folder (in its terminal)" }
            // A turn end found done (or still being read) asks nothing.
            let status = pty.isQuietTurnEnd ? AgentStatus.idle : pty.cachedAgentState
            agents.append((name: foreground.name, status: status, dialog: dialog))
        }
        guard let first = agents.first else { return "no agent running" }
        if let waiting = agents.first(where: { $0.status == AgentStatus.needsAttention || $0.dialog != nil }) {
            return "\(waiting.name) needs the user" + (waiting.dialog.map { ": \($0)" } ?? "")
        }
        if let working = agents.first(where: { $0.status == AgentStatus.working }) { return "\(working.name) working" }
        return "\(first.name) idle"
    }

    // MARK: tell, reply, ask_user

    /// The task named by its branch or title, among the space's workspaces,
    /// and its latest Mission whose parent is this Lead: a Lead started
    /// again doesn't take the former one's tasks over.
    private func leadTask(_ name: String, in space: WorkspaceProfile, lead leadID: String) -> (workspace: WorkspaceState, mission: Mission)? {
        _ = MissionStore.shared.ensureLoaded()
        let candidates = workspaces.filter { $0.profileID == space.id && !$0.isLead && !$0.isClosing }
        func mission(of workspace: WorkspaceState) -> Mission? {
            MissionStore.shared.missions
                .filter { $0.childWorkspaceID == workspace.id && $0.parentWorkspaceID == leadID && $0.reportsToLead == true }
                .max(by: { $0.createdAt < $1.createdAt })
        }
        func named(_ matches: (WorkspaceState) -> Bool) -> [(WorkspaceState, Mission)] {
            candidates.filter(matches).compactMap { workspace in mission(of: workspace).map { (workspace, $0) } }
        }
        if let first = named({ $0.gitBranch == name }).first { return first }
        // A task without a repository has its folder instead, by path as
        // list_tasks shows it.
        if let first = named({ $0.taskFolder == name }).first { return first }
        // Then a title, or a folder's name, only one task having it: a
        // title and a folder's name naming two tasks is no answer.
        let byTitle = named { $0.title.caseInsensitiveCompare(name) == .orderedSame }
        let byFolderName = named { $0.taskFolder.map { ($0 as NSString).lastPathComponent == name } ?? false }
        let found = Dictionary((byTitle + byFolderName).map { ($0.0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return found.count == 1 ? found.values.first : nil
    }

    private func noLeadTask(_ name: String) -> String {
        "No task of yours is named “\(name)”, or several share that title: use its branch or title from list_tasks "
            + "(its folder, for a task without a repository). "
            + "A task the user started without you doesn't report to you."
    }

    private func leadTell(_ arguments: [String: Any], in space: WorkspaceProfile, lead leadID: String, answer: @escaping LeadAnswer) {
        let name = LeadTools.string(arguments, "task") ?? ""
        let message = LeadTools.string(arguments, "message") ?? ""
        guard let (workspace, mission) = leadTask(name, in: space, lead: leadID) else { return answer(noLeadTask(name), true) }
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

    private func leadReply(_ arguments: [String: Any], in space: WorkspaceProfile, lead leadID: String, answer: @escaping LeadAnswer) {
        let questionID = LeadTools.string(arguments, "question") ?? ""
        let message = LeadTools.string(arguments, "message") ?? ""
        let store = MissionStore.shared
        _ = store.ensureLoaded()
        let spaceWorkspaces = Set(workspaces.filter { $0.profileID == space.id }.map(\.id))
        guard let mission = store.missions.first(where: { mission in
            mission.reportsToLead == true && mission.parentWorkspaceID == leadID && spaceWorkspaces.contains(mission.childWorkspaceID)
                && mission.events.contains { $0.id == questionID && $0.kind == .question }
        }) else {
            return answer("No question “\(questionID)” from one of your tasks: copy its id from the [Nirux Mission] message or list_tasks.", true)
        }
        sendReply(message, to: questionID, in: mission, answer: answer)
    }

    /// Answers `questionID`, a question of `mission`'s child, for its
    /// parent: a Lead's reply, or a task's.
    func sendReply(_ message: String, to questionID: String, in mission: Mission, answer: @escaping LeadAnswer) {
        let store = MissionStore.shared
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

    private func leadAskUser(_ arguments: [String: Any], in space: WorkspaceProfile, lead leadID: String, answer: @escaping LeadAnswer) {
        let name = LeadTools.string(arguments, "task") ?? ""
        let why = LeadTools.string(arguments, "why") ?? ""
        guard let (workspace, mission) = leadTask(name, in: space, lead: leadID) else { return answer(noLeadTask(name), true) }
        // Its own Mission's question only.
        guard let question = mission.events.filter({ question in
            question.kind == .question && !mission.events.contains { $0.kind == .response && $0.inReplyTo == question.id }
                && mission.status == .active
        }).min(by: { $0.timestamp < $1.timestamp }) else {
            return answer("“\(workspace.title)” has no question waiting: ask the user here, in this conversation.", true)
        }
        guard MissionStore.shared.handToUser(questionID: question.id, because: why) != nil else {
            return answer("Nirux couldn’t hand the question over: try again.", true)
        }
        updateSidebar()
        answer("Handed to the user: “\(workspace.title)”’s row is amber with your reason. Their answer goes to the task, "
            + "and a line comes to you.", false)
    }

    // MARK: set_task_context

    /// The next step and blocker of a task of the Lead's: what the user
    /// wrote by hand stays theirs.
    private func leadSetTaskContext(
        _ arguments: [String: Any], in space: WorkspaceProfile, lead leadID: String, answer: @escaping LeadAnswer
    ) {
        let name = LeadTools.string(arguments, "task") ?? ""
        guard let (workspace, _) = leadTask(name, in: space, lead: leadID) else { return answer(noLeadTask(name), true) }
        var done: [String] = []
        var kept: [String] = []
        var changed = false
        for (field, key, label) in [(WorkspaceState.ContextField.nextStep, "next_step", "next step"), (.blocker, "blocker", "blocker")] {
            guard case let text?? = LeadTools.contextText(arguments, key) else { continue }
            switch workspace.setContextByLead(field, text) {
            case .set(let value):
                changed = true
                done.append("\(label) set to “\(MissionPromptText.quoted(value))”")
            case .cleared:
                changed = true
                done.append("\(label) cleared")
            case .unchanged: done.append("\(label) unchanged")
            case .keptUsers(let value): kept.append("\(label) (“\(Self.leadContextText(value) ?? "")”)")
            }
        }
        if changed {
            updateSidebar()
            saveState()
        }
        let title = MissionPromptText.quoted(workspace.title)
        var text = done.isEmpty ? "" : "“\(title)”: " + done.joined(separator: ", ") + "."
        if !kept.isEmpty {
            text += (text.isEmpty ? "" : " ") + "The user wrote “\(title)”’s " + kept.joined(separator: " and ")
                + " by hand: Nirux keeps theirs until they clear it. Don't send it again; if it's out of date, tell them here."
        }
        answer(text, !changed && !kept.isEmpty)
    }

    /// A next step or blocker for the Lead's prompt: one line, the user's
    /// as long as they typed it, cut at the tool's limit.
    static func leadContextText(_ text: String?) -> String? {
        text.flatMap { AgentText.clean(MissionPromptText.quoted($0), maxLength: LeadTools.maxContextLength) }
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
        // Nothing changes before the sheet can open: Board Settings ready
        // for this repository.
        guard let settings = board.loaded(for: chosen.0)?.queueSettings, settings.gitHubRepository == chosen.1.gitHub else {
            let problem = board.loaded(for: chosen.0)?.queueStartProblems.first ?? "Board Settings aren't set up for it yet."
            return answer("\(chosen.1.name)'s merge queue can't start: \(problem) Tell the user.", true)
        }
        if let open = board.reads[chosen.0.id]?.openPullRequests.map({ Set($0.map(\.number)) }) {
            let unknown = numbers.filter { !open.contains($0) }
            guard unknown.isEmpty else {
                return answer(unknown.map { "#\($0)" }.joined(separator: ", ") + " isn't an open pull request of \(chosen.1.name).", true)
            }
        }
        let controller = mergeQueue(projectID: space.id, repository: chosen.1.gitHub)
        guard !controller.isRunning, !controller.runsElsewhere else {
            return answer("\(chosen.1.name)'s merge queue is running: propose these once it ends.", true)
        }
        // The user's own list stays theirs; a Lead's earlier one is its own.
        let current = controller.selection(for: chosen.1.gitHub)
        let proposalKey = space.id + " " + chosen.1.gitHub.ownerAndName
        guard current.isEmpty || Set(current) == Set(numbers) || current == leadQueueProposals[proposalKey] else {
            return answer("The user is preparing \(chosen.1.name)'s queue (" + current.map { "#\($0)" }.joined(separator: ", ")
                + "): suggest yours to them in this conversation instead.", true)
        }
        controller.proposeSelection(numbers, repository: chosen.1.gitHub)
        leadQueueProposals[proposalKey] = numbers
        requestMergeQueueStart(board: board, section: chosen.0.id)
        guard mergeQueueConfirmation != nil else {
            return answer("Nirux couldn't open the merge queue's sheet (the Board may need its settings): tell the user.", true)
        }
        answer("The confirmation sheet of \(chosen.1.name)'s merge queue is open with "
            + numbers.map { "#\($0)" }.joined(separator: ", ") + ". Nothing merges until the user clicks Start.", false)
    }
}

/// A task a Lead proposes (see `NiruxShellView.pendingLeadProposals`).
struct LeadProposal: Equatable {
    enum Repository: Equatable {
        case named(key: String)
        /// `repo: "none"`: No Repository, a folder of its own.
        case noRepository
        /// The space had none: the sheet picks its default when it shows
        /// (one may have been added meanwhile).
        case spaceDefault

        var key: String? {
            if case .named(let key) = self { return key }
            return nil
        }
    }

    let spaceID: String
    let repository: Repository
    let description: String
    let templateName: String?
    let parent: NewTask.MissionParent
    /// A task's agent proposed it, a sub-task of this task (its
    /// workspace's id); nil for a Lead's proposal.
    var subtaskOf: String?
}
