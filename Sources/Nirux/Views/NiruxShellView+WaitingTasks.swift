import AppKit

extension NiruxShellView {

    func queueWaitingTask(
        _ start: MergeWait.PendingStart, after name: String, planLine: String? = nil, in space: WorkspaceProfile, answer: @escaping LeadAnswer
    ) {
        guard let title = start.options?.title ?? NewTask.workspaceTitle(description: start.description),
              !start.suggestedBranch.isEmpty
        else { return answer("Start the description with a few words that name the task and its branch.", true) }
        setDependency(of: nil, start: start, after: name, in: space, title: title, planLine: planLine, answer: answer)
    }

    func changeWaitingTask(_ arguments: [String: Any], in space: WorkspaceProfile, answer: @escaping LeadAnswer) {
        let name = LeadTools.string(arguments, "task") ?? ""
        guard let task = spaceTask(name, in: space) else { return answer(noSpaceTask(name, in: space), true) }
        guard let start = task.waitingStart?.pendingStart else { return answer("“\(task.title)” isn't a waiting task.", true) }
        guard !task.isStarting else { return answer("“\(task.title)” is starting.", true) }
        guard leadStartsTasksWithoutAsking(spaceID: space.id) else {
            return answer("Waiting tasks require Starts tasks without asking. The user can choose Start Now.", true)
        }
        if let after = LeadTools.string(arguments, "after") {
            setDependency(of: task, start: start, after: after, in: space, title: task.title, answer: answer)
        } else {
            startWaitingTask(task)
            if let failure = task.waitingStart?.failure { return answer(failure, true) }
            answer("Starting “\(task.title)”. Follow it with list_tasks.", false)
        }
    }

    private func setDependency(
        of task: WorkspaceState?, start: MergeWait.PendingStart, after name: String, in space: WorkspaceProfile,
        title: String, planLine: String? = nil, answer: @escaping LeadAnswer
    ) {
        guard let current = profiles.first(where: { $0.id == space.id }),
              current.anchors.contains(where: { $0.key == start.repositoryKey }),
              leadStartsTasksWithoutAsking(spaceID: current.id)
        else { return answer("The repository or the space's start permission changed. Check Space Settings.", true) }
        guard let awaited = spaceTask(name, in: current) else { return answer(noSpaceTask(name, in: current), true) }
        guard awaited.isWaitingTask || (!awaited.isFolderTask && Self.isTask(awaited)) else {
            return answer("“\(awaited.title)” has no repository pull request to wait for.", true)
        }
        let id = task?.id ?? UUID().uuidString
        var seen = Set([id])
        var ancestor: WorkspaceState? = awaited
        while let current = ancestor {
            guard seen.insert(current.id).inserted else { return answer("That dependency would make tasks wait on each other.", true) }
            ancestor = current.waitingStart.flatMap { wait in workspaces.first { $0.id == wait.awaited.workspaceID } }
        }
        let now = Date().timeIntervalSince1970
        var wait = MergeWait(id: UUID().uuidString, awaited: .init(workspaceID: awaited.id, title: awaited.title),
                             action: .start(start), createdAt: now)
        let step = wait.step(after: .read(awaited.prInfo))
        if case .fail(let failure) = step { return answer(wait.sentence(failure), true) }
        if step == .release { wait.mergedAt = now }
        let holder: WorkspaceState
        if let task, let index = task.mergeWaits.firstIndex(where: { $0.pendingStart != nil }) {
            task.mergeWaits[index] = wait
            holder = task
        } else {
            if let planLine, let problem = plannedSessionProblem(planLine, inSpace: current.id) { return answer(problem, true) }
            // A stable, uncreated path keeps a placeholder distinct from every real checkout.
            let placeholder = Persistence.stateDirectory.appendingPathComponent("waiting/\(id)").path
            addWorkspace(title: title, purpose: start.options?.goal, cwd: placeholder, profileID: current.id, workspaceID: id,
                         waitingStart: wait, activate: false)
            guard let created = workspaces.first(where: { $0.id == id }) else { return answer("The task couldn't be added.", true) }
            holder = created
            // The waiting row takes the planned session's place.
            if let planLine { linkPlanLine(planLine, toWorkspace: id, title: title, inSpace: current.id) }
        }
        saveState()
        updateSidebar()
        if step == .release {
            startWaitingTask(holder)
            answer("\(wait.awaitedLongName) is merged already. Follow “\(title)” (\(holder.leadTaskReference)) with list_tasks.", false)
        } else {
            answer("“\(title)” (\(holder.leadTaskReference)) waits for \(wait.awaitedLongName) to merge before it starts.", false)
        }
    }

    func failWaitingTask(_ task: WorkspaceState, reason: String) {
        guard let index = task.mergeWaits.firstIndex(where: { $0.pendingStart != nil }) else { return }
        task.mergeWaits[index].failure = reason
        task.mergeWaits[index].startingBranch = nil
        saveState()
        updateSidebar()
        noticeLead(of: task, "“\(task.title)” (\(task.leadTaskReference)) needs you: \(reason). Use set_task_after to start or re-point it, or close_task.")
    }

    func startWaitingTask(_ task: WorkspaceState) {
        guard !task.isClosing, !task.isStarting,
              let index = task.mergeWaits.firstIndex(where: { $0.pendingStart != nil }),
              let start = task.mergeWaits[index].pendingStart else { return }
        let wait = task.mergeWaits[index]
        guard let space = profiles.first(where: { $0.id == task.profileID }),
              let repository = newTaskRepositories(of: space).first(where: { $0.key == start.repositoryKey })
        else { return failWaitingTask(task, reason: "The repository “\(start.repository)” left the space") }
        guard leadMissionParent(inSpace: space.id) != nil else {
            return failWaitingTask(task, reason: "The space needs a Lead to receive this task’s questions and result")
        }
        let suggested = start.suggestedBranch
        task.mergeWaits[index].failure = nil
        task.mergeWaits[index].startingBranch = suggested
        saveState()
        updateSidebar()
        Self.resolveWaitingBranch(suggested, in: repository, space: space, stateDirectory: Persistence.stateDirectory) { [weak self] target, branch in
            guard let self, self.workspaces.contains(where: { $0 === task }),
                  let index = task.mergeWaits.firstIndex(where: { $0.id == wait.id }) else { return }
            guard let target else {
                return self.failWaitingTask(task, reason: "No base branch of origin could be fetched for “\(repository.name)”")
            }
            guard self.ownsWaitingRepository(task, spaceID: space.id, key: start.repositoryKey) else {
                return self.failWaitingTask(task, reason: "The repository left the space")
            }
            task.mergeWaits[index].startingBranch = branch
            self.saveState()
            let note = wait.mergedAt == nil ? "" : "\n\nStarted after \(wait.awaitedLongName) merged."
            var request = NewTask.Request(description: start.description + note, template: start.template,
                                          agent: start.selection?.agent ?? self.defaultTaskAgent(forSpace: space.id),
                                          model: start.selection?.model, projectID: space.id,
                                          place: .worktree(target, branch: branch), fetchesFirst: true)
            request.title = task.title
            request.goal = task.purpose
            self.createTask(request) { [weak self] result in
                guard let self, self.workspaces.contains(where: { $0 === task }), task.waitingStart?.id == wait.id else { return }
                switch result {
                case .fetchFailed(let error):
                    self.failWaitingTask(task, reason: "Couldn’t fetch \(target.remoteBranchName ?? "origin"): \(error)")
                case .failed(let error):
                    self.failWaitingTask(task, reason: error)
                case .created(let created):
                    self.finishWaitingTask(task, repositoryKey: start.repositoryKey, request: request, created: created)
                }
            }
        }
    }

    private static func resolveWaitingBranch(
        _ suggested: String, in repository: NewTaskPanel.Repository, space: WorkspaceProfile, stateDirectory: URL,
        completion: @escaping @MainActor @Sendable (NewTask.Target?, String) -> Void
    ) {
        readNewTaskInfo(spaceID: space.id, folder: repository.folder, anchors: space.anchors, stateDirectory: stateDirectory) { info in
            guard let target = info.target, target.remoteBranch != nil else { return completion(nil, suggested) }
            unusedBranch(suggested, repository: target.repository) { completion(target, $0) }
        }
    }

    private func ownsWaitingRepository(_ task: WorkspaceState, spaceID: String, key: String) -> Bool {
        task.profileID == spaceID && profiles.first(where: { $0.id == spaceID })?.anchors.contains(where: { $0.key == key }) == true
    }

    private func finishWaitingTask(_ task: WorkspaceState, repositoryKey: String, request: NewTask.Request, created: CreatedTask) {
        if let problem = created.gitWarning ?? created.handoverError?.explanation {
            return failWaitingTask(task, reason: "Check the worktree at \(created.path): \(problem)")
        }
        guard ownsWaitingRepository(task, spaceID: request.projectID, key: repositoryKey)
        else { return failWaitingTask(task, reason: "The space or repository changed. Check the worktree at \(created.path)") }
        let agentID = UUID().uuidString
        let mission = leadMissionParent(inSpace: task.profileID).flatMap {
            createMission(parent: $0, childWorkspaceID: task.id, childAgentUUID: agentID, agent: request.agent, branch: request.name)
        }
        guard mission != nil else {
            return failWaitingTask(task, reason: "Couldn’t link the task to the space’s Lead. Check the worktree at \(created.path)")
        }
        let decision = decideSpace(identity: created.identity, parentWorkspaceID: task.id, startedFromSpaceID: task.profileID)
        task.mergeWaits.removeAll { $0.pendingStart != nil }
        task.beginTask(at: created.workingDirectory, mission: mission)
        task.addColumn(agentUUID: agentID, cwd: created.workingDirectory)
        task.closeColumn(at: 0)
        relayout(animated: false)
        saveState()
        launchAgent(request.agent, model: request.model, in: task, deliveredHandover: true, worktreeBranch: created.checkedOutBranch,
                    setupScript: decision.spaceID == task.profileID ? setupScript(for: decision) : nil)
        updateSidebar()
        if task === activeWorkspace { focusActiveTerminal(in: window) }
    }
}
