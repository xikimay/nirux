import AppKit

extension NiruxShellView {
    func taskWorker(_ task: WorkspaceState, snapshot: ProcessSnapshot) -> ColumnState? {
        let terminals = task.columns.filter { $0.pty != nil && !$0.isClosing }
        if let missionID = task.missionID {
            guard let mission = MissionStore.shared.missions.first(where: { $0.id == missionID && $0.childWorkspaceID == task.id })
            else { return nil }
            return terminals.first { $0.agentUUID == mission.childAgentUUID }
        }
        let agents = terminals.filter { $0.missionAgent(snapshot: snapshot) != nil }
        if agents.count == 1 { return agents.first }
        return terminals.count == 1 ? terminals.first : nil
    }

    func showResumeTask(_ task: WorkspaceState) {
        let snapshot = ProcessSnapshot()
        _ = MissionStore.shared.ensureLoaded()
        let current = taskWorker(task, snapshot: snapshot)?.missionAgent(snapshot: snapshot)
        let agents = CodingAgent.launchable.filter { $0 != current }
        let picker = NSPopUpButton(frame: .zero, pullsDown: false)
        picker.addItems(withTitles: agents.map(\.productName))
        picker.setAccessibilityLabel("CLI")
        let model = NSTextField()
        model.placeholderString = "Model ID (CLI default if blank)"
        model.setAccessibilityLabel("Model ID")
        let fields = NSStackView(views: [picker, model])
        fields.orientation = .vertical
        fields.alignment = .leading
        fields.spacing = 8
        fields.frame.size = NSSize(width: 310, height: 60)
        model.widthAnchor.constraint(equalToConstant: 310).isActive = true
        let alert = NSAlert()
        alert.messageText = "Resume “\(task.title)” with another CLI?"
        alert.informativeText = "The current worker ends. Its replacement gets the handover in the same terminal. "
            + "The previous conversation stays in Session History."
        alert.accessoryView = fields
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Resume")
        guard runModal(alert) == .alertSecondButtonReturn, let agent = agents[safe: picker.indexOfSelectedItem] else { return }
        switch TaskAgentChoice.parse(["agent": agent.rawValue, "model": model.stringValue]) {
        case .failure(let problem): showToast(problem.localizedDescription, tone: .error)
        case .success(let choice):
            resumeTask(task, with: choice, interactive: true) { [weak self] message, failed in
                self?.showToast(message, tone: failed ? .error : .info)
            }
        }
    }

    /// `freshStart`: the same CLI may take over, in a new conversation.
    func resumeTask(
        _ task: WorkspaceState, with choice: TaskAgentChoice, interactive: Bool = false, freshStart: Bool = false,
        answer: @escaping LeadAnswer
    ) {
        guard !task.isClosing, !task.isInactive, workspaces.contains(where: { $0 === task }), Self.isTask(task),
              Self.existingDirectory(task.cwd) != nil else { return answer("The task or its folder is no longer open.", true) }
        guard !resumingTasks.contains(task.id) else { return answer("This task is already switching CLI.", true) }
        let store = MissionStore.shared
        let snapshot = ProcessSnapshot()
        guard store.ensureLoaded(),
              let column = taskWorker(task, snapshot: snapshot), let uuid = column.agentUUID, let pty = column.pty
        else { return answer("Nirux couldn’t identify the task’s worker terminal and Mission.", true) }
        guard !column.isRestartingShell, pty.shellPID != nil || pty.hasExited || column.isAwaitingResume else {
            return answer("The terminal is starting. Try again once it opens.", true)
        }
        let foreground = pty.foregroundProcess(snapshot: snapshot)
        let current = column.missionAgent(snapshot: snapshot)
        if let refusal = Self.taskSwitchRefusal(
            current: current, choice: choice.agent, awaitingResume: column.isAwaitingResume, freshStart: freshStart
        ) {
            return answer(refusal, true)
        }
        guard !snapshot.isEmpty || column.isAwaitingResume || pty.hasExited else {
            return answer("Nirux couldn’t read the terminal’s running processes. Try again.", true)
        }
        if let foreground, foreground.instance.pid != pty.shellPID, current == nil {
            return answer("The worker terminal runs \(foreground.name). Finish it before switching CLI.", true)
        }

        let (id, spaceID) = (task.id, task.profileID)
        resumingTasks.insert(id)
        let finish: LeadAnswer = { [self] message, failed in
            resumingTasks.remove(id)
            typeMissionMessages()
            answer(message, failed)
        }
        guard hooksReadBeforeTyping(), MissionEventCenter.shared.drain() else {
            return finish("Nirux is reading the latest Mission events. Try again.", true)
        }
        let draftRefusal = "“\(task.title)” has an unsent draft. The user can send it from the terminal before you retry, "
            + "or choose Resume with… on the task to discard it explicitly."
        let approvedDraft = pty.taskResumeDraft(foreground: foreground?.instance)
        if approvedDraft != nil {
            guard interactive else { return finish(draftRefusal, true) }
            guard confirmDestructiveClose(message: "Discard the draft in “\(task.title)”?",
                                          details: ["Its unsent text will be lost when the CLI switches."],
                                          confirmTitle: "Discard Draft and Resume")
            else { return finish("Kept the draft and the current worker.", false) }
        }
        let previous = previousSession(of: task, agentUUID: uuid)
        Self.offMain({
            TaskResumeHandover.localContext(workspaceID: id, spaceID: spaceID, previous: previous)
        }) { [self] context in
            let latest = ProcessSnapshot()
            guard !task.isClosing, !task.isInactive, task.profileID == spaceID, workspaces.contains(where: { $0 === task }),
                  taskWorker(task, snapshot: latest) === column, column.pty === pty, !column.isRestartingShell,
                  pty.foregroundProcess(snapshot: latest)?.instance == foreground?.instance,
                  Self.existingDirectory(task.cwd) != nil else { return finish("The task changed before the switch. Try again.", true) }
            let prompt = TaskResumeHandover.prompt(task: task, previous: previous, agent: choice.agent, missions: store.missions, thread: context)
            guard let agentLaunch = Self.launch(of: choice.agent, resume: nil, model: choice.model, in: task) else {
                return finish("Choose a CLI Nirux can launch.", true)
            }
            let command = freshAgentCommand(
                agentLaunch, in: task, column: column, launchDirectory: task.cwd,
                worktreeBranch: task.gitBranch, handoverPrompt: prompt
            )
            sideEffects.restartTaskTerminal(column, command + " || exit 1", {
                if let draft = pty.taskResumeDraft(foreground: foreground?.instance), draft != approvedDraft {
                    finish(draftRefusal, true)
                    return false
                }
                column.setLaunch(directory: task.cwd, environment: task.terminalEnvironment(agentUUID: uuid))
                return true
            }) { [self] remaining in
                guard remaining.isEmpty else {
                    finish("The previous worker still has running processes (\(remaining.joined(separator: ", "))). Retry after they exit.", true)
                    return false
                }
                guard !task.isClosing, !task.isInactive, task.profileID == spaceID, workspaces.contains(where: { $0 === task }),
                      task.columns.contains(where: { $0 === column && !$0.isClosing }), Self.existingDirectory(task.cwd) != nil,
                      MissionEventCenter.shared.drain()
                else {
                    finish("The task closed or Nirux couldn’t record the worker’s Mission. The replacement did not launch.", true)
                    return false
                }
                // A quit during launch must restore the stopped terminal, never its previous worker.
                saveState()
                guard store.resumeWorker(workspaceID: id, agentUUID: uuid, missionID: task.missionID, as: choice.agent) else {
                    finish("Nirux couldn’t save the new Mission route. Retry the switch.", true)
                    return false
                }
                sessionLedger.closeSessions(ofWorker: uuid, at: Date().timeIntervalSince1970)
                DispatchQueue.main.async {
                    self.confirmTaskLaunch(choice, in: task, column: column, deadline: .now() + 12, answer: finish)
                }
                return true
            }
        }
    }

    /// Why a task's worker can't switch to `choice`: it runs that CLI
    /// already, unless it waits for its resume or starts afresh.
    static func taskSwitchRefusal(current: CodingAgent?, choice: CodingAgent, awaitingResume: Bool, freshStart: Bool) -> String? {
        guard current == choice, !awaitingResume, !freshStart else { return nil }
        return "This task already runs \(choice.rawValue). Choose another CLI."
    }

    /// The latest conversation `agentUUID` had in `workspace`.
    func previousSession(of workspace: WorkspaceState, agentUUID: String) -> AgentSessionRecord? {
        profiles.flatMap { sessionLedger.sessions(inSpace: $0.id) }
            .filter { $0.workspaceID == workspace.id && $0.agentUUID == agentUUID }.max { $0.lastActivityAt < $1.lastActivityAt }
    }

    private func confirmTaskLaunch(
        _ choice: TaskAgentChoice, in task: WorkspaceState, column: ColumnState, deadline: DispatchTime, answer: @escaping LeadAnswer
    ) {
        guard !task.isClosing, workspaces.contains(where: { $0 === task }), task.columns.contains(where: { $0 === column && !$0.isClosing })
        else { return answer("The task’s terminal closed during the switch.", true) }
        let snapshot = ProcessSnapshot()
        if column.missionAgent(snapshot: snapshot) == choice.agent {
            saveState(snapshot: snapshot)
            updateSidebar()
            return answer("Resumed “\(task.title)” with \(choice.agent.rawValue)\(choice.model.map { " (\($0))" } ?? "").", false)
        }
        guard column.pty?.hasExited != true, DispatchTime.now() < deadline else {
            return answer("Nirux couldn’t confirm \(choice.agent.rawValue) started. Check the task’s terminal, then retry the switch.", true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            self.confirmTaskLaunch(choice, in: task, column: column, deadline: deadline, answer: answer)
        }
    }
}

extension TaskResumeHandover {
    @MainActor static func prompt(
        task: WorkspaceState, previous: AgentSessionRecord?, agent: CodingAgent, missions: [Mission], thread: [String]
    ) -> String {
        var lines = ["Continue the existing Nirux task “\(MissionAnswerContext.clipped(task.title, 160))” in this checkout. Preserve work in progress."]
        lines += thread
        for (label, value) in [("Goal", task.purpose), ("Last update", task.lastSummary), ("Next step", task.nextStep), ("Blocker", task.blocker)] {
            if let value, let text = AgentText.clean(value, maxLength: 600) { lines.append("\(label): \(text)") }
        }
        if let pr = task.prInfo { lines.append("Pull request #\(pr.number)") }
        if let previous { lines.append("Previous conversation in Session History: \(previous.agent.rawValue) \(previous.sessionID).") }
        if let mission = missions.first(where: { $0.id == task.missionID }) {
            if let answers = MissionAnswerContext.text(for: mission, among: missions) { lines.append(answers) }
            for event in mission.events.filter({ ($0.kind == .instruction && $0.childConsumedAt != nil) || $0.kind == .completed }).suffix(3) {
                lines.append("\(event.kind == .completed ? "Last result" : "Parent instruction"): \(MissionAnswerContext.clipped(event.message, 400))")
            }
            lines.append(agent == .claude ? NiruxShellView.typedAnswerMission : NiruxShellView.waitingMission)
        }
        if task.nextStep == nil {
            lines.append("Check the current changes and the latest instructions before continuing. Ask about any missing decision.")
        }
        return lines.joined(separator: "\n")
    }
}
