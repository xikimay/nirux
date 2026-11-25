import AppKit

// MARK: - Promote to Lead

/// A task whose conversation grew into the coordinator's becomes its space's
/// Lead: its Claude session resumes in the Lead's column, in the space's
/// checkout, and the current Lead's session ends (Session History keeps it).
/// The Lead's workspace and agent UUID stay, so its tasks and their questions
/// go on to the promoted conversation. The task keeps its worktree, branch
/// and pull request; its row stays, with no agent.
extension NiruxShellView {
    static let promoteToLeadTitle = "Promote to Lead…"

    /// How a promoted conversation's first prompt starts (`isLeadRestart`).
    nonisolated static let leadPromotionPrompt = "[Nirux] This conversation is now the space’s Lead. "

    /// A resumed Claude keeps the system prompt it recorded until it
    /// compacts: the prompt says where it works now.
    nonisolated static func leadPromotionPrompt(
        folder: String, task: String, worktree: String, branch: String?, pullRequest: Int?
    ) -> String {
        let place = [branch.map { "on \($0)" }, pullRequest.map { "pull request #\($0)" }].compactMap { $0 }
        return leadPromotionPrompt
            + "You now work in \(folder), the space’s checkout: never edit, commit or switch branches there. "
            + "The task “\(task)” keeps its work in \(worktree)\(place.isEmpty ? "" : " (" + place.joined(separator: ", ") + ")"): "
            + "start a task for what remains. Call list_tasks: Nirux kept the space’s tasks, their questions to the Lead and their results."
    }

    static let promotionNoticeLine = "Its conversation is now the Lead’s."

    /// The task row's ⋯ menu and ⌘P.
    func offersLeadPromotion(_ workspace: WorkspaceState) -> Bool {
        !workspace.isClosing && !workspace.isInactive && !workspace.startedOutsideNirux
            && Self.spaceCanHaveLead(workspace.profileID) && Self.isTask(workspace)
    }

    /// Promote to Lead, once the user confirms.
    func requestLeadPromotion(of task: WorkspaceState) {
        guard offersLeadPromotion(task), workspaces.contains(where: { $0 === task }) else { return }
        let spaceID = task.profileID
        _ = MissionStore.shared.ensureLoaded()
        let snapshot = ProcessSnapshot()
        let worker = promotionWorker(of: task, snapshot: snapshot)
        let lead = leadWorkspace(inSpace: spaceID)
        if let refusal = promotionRefusal(worker, of: task, lead: lead) { return showToast(refusal) }
        guard let (column, state) = worker else { return }
        let sessionID = state.sessionID
        let space = profiles.first { $0.id == spaceID }?.name ?? spaceID
        var details = [state.agent == .claude
            ? "Its conversation goes on as the Lead’s, in the space’s checkout. Its worktree, branch and pull request stay as they are."
            : "\(state.agent?.productName ?? "Its agent") can’t move its conversation: the Lead starts a new one with it, handed the task’s "
                + "request, progress and conversation. The task keeps working in its worktree."]
        if let leadColumn = lead?.leadTerminal {
            let leadPty = leadColumn.pty
            details.append("The current Lead’s session ends. Session History keeps it.")
            if let warning = Self.leadTurnWarning(leadColumn.liveAgent(snapshot: snapshot)) { details.append(warning) }
            if let program = leadPty?.foregroundProcess(snapshot: snapshot).flatMap({
                $0.interactiveAgent == nil && $0.instance.pid != leadPty?.shellPID ? $0.name : nil
            }) {
                details.append("\(program) runs in the Lead’s terminal: it ends too.")
            }
            if leadPty?.hasPromptDraft == true { details.append("The draft in the Lead’s prompt is lost.") }
        }
        guard confirmDestructiveClose(
            message: "Make “\(task.title)” the Lead of “\(space)”?", details: details, confirmTitle: "Promote to Lead"
        ) else { return }
        // Read again: the modal let the task's agent and the Lead go on.
        let latest = promotionWorker(of: task, snapshot: ProcessSnapshot())
        guard offersLeadPromotion(task), task.profileID == spaceID, leadWorkspace(inSpace: spaceID) === lead, latest?.column === column,
              latest?.state.sessionID == sessionID else { return showToast("The task or its Lead changed meanwhile. Nothing was promoted.") }
        if let refusal = promotionRefusal(latest, of: task, lead: lead) { return showToast(refusal) }
        if state.agent == .claude, let sessionID {
            promote(task, column: column, sessionID: sessionID, into: lead)
        } else if let agent = state.agent {
            promoteAfresh(task, column: column, agent: agent, into: lead)
        }
    }

    private func promotionWorker(of task: WorkspaceState, snapshot: ProcessSnapshot) -> (column: ColumnState, state: LeadPromotion.Worker)? {
        guard let column = taskWorker(task, snapshot: snapshot), let pty = column.pty else { return nil }
        let foreground = pty.foregroundProcess(snapshot: snapshot)
        let agent = foreground?.interactiveAgent
        return (column, LeadPromotion.Worker(
            agent: agent,
            sessionID: foreground.flatMap { process -> String? in
                guard agent == .claude, case .resume(let id)? = column.persistedClaudeRestore(foregroundProcess: process) else { return nil }
                return id
            },
            isStarting: column.isRestartingShell || (!column.isAwaitingResume && pty.shellPID == nil && !pty.hasExited),
            isAtRest: Self.isAtRest(column, pty: pty, foreground: foreground, snapshot: snapshot),
            hasDialog: pty.pendingAgentDialog != nil || foreground.map { pty.agentVisibleDialog(foreground: $0) != nil } == true,
            hasDraft: pty.taskResumeDraft(foreground: foreground?.instance) != nil,
            otherProgram: foreground.flatMap { $0.interactiveAgent == nil && $0.instance.pid != pty.shellPID ? $0.name : nil }
        ))
    }

    /// The task's rules, then what would keep the Lead from taking the
    /// conversation once the task's agent ended.
    /// As close_task reads it: what Codex and Antigravity report (OSC 7501),
    /// else the status machine; a finished turn rests too.
    private static func isAtRest(_ column: ColumnState, pty: PtySession, foreground: ForegroundProcess?, snapshot: ProcessSnapshot) -> Bool {
        let report = foreground?.interactiveAgent == nil ? nil : pty.programStatus(of: foreground)
        switch report?.state {
        case .working?, .blocked?, .error?: return false
        case .idle?, .done?: return true
        default: return column.liveAgent(snapshot: snapshot)?.status == .idle || pty.agentAttentionReason == .turnFinished
        }
    }

    private func promotionRefusal(_ worker: (column: ColumnState, state: LeadPromotion.Worker)?, of task: WorkspaceState, lead: WorkspaceState?) -> String? {
        let missions = MissionStore.shared.missions
        let isSubtask = task.parentWorkspaceID != nil
            || missions.contains { $0.childWorkspaceID == task.id && $0.status == .active && $0.reportsToTask == true }
        if let refusal = LeadPromotion.refusal(worker?.state, isSubtask: isSubtask) { return refusal }
        let leadColumn = lead?.leadTerminal
        if let leadColumn {
            if leadColumn.isRestartingShell || leadColumn.relaunchingLeadSessionID != nil { return "The Lead is restarting. Try again in a moment." }
            if !leadColumn.isAwaitingResume, let pty = leadColumn.pty, pty.shellPID == nil, !pty.hasExited {
                return "The Lead is starting. Try again in a moment."
            }
        }
        // Another agent's Lead starts afresh: nothing more to take over.
        guard let worker, let sessionID = worker.state.sessionID else { return nil }
        if let record = sessionLedger.session(agent: .claude, sessionID: sessionID), !AgentSessionResume.hasTranscript(for: record) {
            return SessionHistory.message(.transcriptGone, agent: .claude)
        }
        let others = agentSessionHolders(snapshot: ProcessSnapshot()).filter { $0.columnID != worker.column.id && $0.columnID != leadColumn?.id }
        if sessionResume.inFlight.contains(AgentSessionRecord.key(agent: CodingAgent.claude.rawValue, sessionID: sessionID))
            || HeldAgentSession.find(sessionID, in: others) != nil {
            return "Another column is holding or resuming this conversation."
        }
        if let lead, claudeSpaceSettingsFile(for: lead) == nil, currentLeadOptions(in: lead).safety != nil {
            return "Couldn’t prepare the space’s safety settings for the Lead."
        }
        return nil
    }

    /// The task's Claude ends first, so one process holds its conversation
    /// at a time; then the Lead's column resumes it.
    private func promote(_ task: WorkspaceState, column: ColumnState, sessionID: String, into lead: WorkspaceState?) {
        guard let uuid = column.agentUUID, let pty = column.pty else { return }
        let spaceID = task.profileID
        let foreground = pty.foregroundProcess(snapshot: ProcessSnapshot())?.instance
        let notice = "printf '%s\\n' " + Self.shellQuotedArgument(Self.promotionNoticeLine)
        sideEffects.restartTaskTerminal(column, notice, { [weak self] in
            guard pty.foregroundProcess(snapshot: ProcessSnapshot())?.instance == foreground,
                  pty.taskResumeDraft(foreground: foreground) == nil else {
                self?.showToast("The task’s agent took input meanwhile. Nothing was promoted.")
                return false
            }
            column.setLaunch(directory: task.cwd, environment: task.terminalEnvironment(agentUUID: uuid))
            return true
        }) { [weak self, weak task] stillRunning in
            guard let self, let task else { return false }
            // What its Bash tool left in the background may run on; its agent
            // must not, holding the conversation.
            guard !stillRunning.contains(where: { CodingAgent(launchable: $0) != nil }) else {
                self.showToast(
                    "The task’s agent didn’t stop within \(Int(Self.exitTimeout)) s (\(stillRunning.joined(separator: ", "))). "
                        + "Nothing was promoted.",
                    tone: .error
                )
                return false
            }
            let now = Date().timeIntervalSince1970
            self.sessionResume.forgetLaunch(in: column)
            self.sessionLedger.closeSessions(ofWorker: uuid, at: now)
            _ = MissionStore.shared.endChildMissions(workspaceID: task.id, agentUUID: uuid, at: now)
            task.noteConversationMovedToLead(at: now)
            self.handOver(sessionID, from: task, workerUUID: uuid, to: lead, spaceID: spaceID)
            // After the hand-over: the Lead's column saves the conversation it
            // resumes, even while its previous session ends.
            self.saveState()
            return true
        }
    }

    private func handOver(_ sessionID: String, from task: WorkspaceState, workerUUID: String, to lead: WorkspaceState?, spaceID: String) {
        let lost = "“\(task.title)”’s conversation stopped, but the Lead didn’t take it. Resume it from Session History."
        let current = leadWorkspace(inSpace: spaceID)
        guard current === lead else { return showToast(lost, tone: .error) }
        let folder = current.map { $0.leadTerminal?.launchDirectory.flatMap(Self.existingDirectory) ?? $0.cwd } ?? defaultFolder(forSpace: spaceID)
        let prompt = Self.leadPromotionPrompt(
            folder: folder, task: task.title, worktree: task.cwd, branch: task.gitBranch, pullRequest: task.prInfo?.number
        )
        guard let current else {
            startPromotedLead(spaceID: spaceID, launch: { Self.launch(of: .claude, resume: .session(sessionID), in: $0) }, prompt: prompt)
            if let started = leadWorkspace(inSpace: spaceID) { moveSubtasks(of: task, workerUUID: workerUUID, to: started) }
            return
        }
        moveSubtasks(of: task, workerUUID: workerUUID, to: current)
        restartLead(current, agent: .claude, resuming: sessionID, resumePrompt: prompt) { [weak self] launched in
            if !launched { self?.showToast(lost, tone: .error) }
        }
    }

    /// The task's sub-tasks become the Lead's: their Missions report to its
    /// agent, and they list among its tasks. Whether it had any.
    @discardableResult
    private func moveSubtasks(of task: WorkspaceState, workerUUID: String, to lead: WorkspaceState) -> Bool {
        guard let leadAgentUUID = lead.leadAgentUUID else { return false }
        let had = workspaces.contains { $0.parentWorkspaceID == task.id } || MissionStore.shared.missions.contains {
            $0.parentWorkspaceID == task.id && $0.parentAgentUUID == workerUUID && $0.oneWay != true
        }
        _ = MissionStore.shared.reparentMissions(
            fromWorkspace: task.id, agentUUID: workerUUID, toLead: lead.id, leadAgentUUID: leadAgentUUID, at: Date().timeIntervalSince1970
        )
        for subtask in workspaces where subtask.parentWorkspaceID == task.id { subtask.parentWorkspaceID = nil }
        saveState()
        updateSidebar()
        return had
    }

    static let subtasksMovedLine = "Your sub-tasks now report to the space’s Lead, which took over coordinating them. Keep to your own work here."

    /// A worker that stays in its task hears, in one line, that it no longer
    /// follows its sub-tasks.
    private func tellSubtasksMoved(_ task: WorkspaceState, to lead: WorkspaceState) {
        guard let agentUUID = lead.leadAgentUUID else { return }
        tellTask(Self.subtasksMovedLine, to: task, lead: NewTask.MissionParent(workspaceID: lead.id, agentUUID: agentUUID)) { [weak self] message, failed in
            if failed { self?.showToast(message, tone: .error) }
        }
    }

    /// Codex can't be told the Lead's role on a resumed thread, and an
    /// Antigravity conversation keeps working in its first folder: the Lead
    /// starts afresh with the task's agent, handed its request, progress and
    /// conversation. The task keeps its worker; its sub-tasks go to the Lead.
    private func promoteAfresh(_ task: WorkspaceState, column: ColumnState, agent: CodingAgent, into lead: WorkspaceState?) {
        guard let uuid = column.agentUUID else { return }
        let spaceID = task.profileID
        let previous = previousSession(of: task, agentUUID: uuid)
        let (id, title, worktree) = (task.id, task.title, task.cwd)
        Self.offMain({ TaskResumeHandover.localContext(workspaceID: id, spaceID: spaceID, previous: previous) }) { [weak self, weak task] context in
            guard let self, let task else { return }
            guard self.leadWorkspace(inSpace: spaceID) === lead, task.profileID == spaceID else {
                return self.showToast("The task or its Lead changed meanwhile. Nothing was promoted.")
            }
            let handover = ["You take over as the Lead from the task “\(title)”, which keeps working in \(worktree)."]
                + Self.leadHandoverLines(previous: previous, context: context)
            guard let lead else {
                let model = SpaceDefaultsStore.defaults(forSpace: spaceID).leadModel(for: agent)
                self.startPromotedLead(
                    spaceID: spaceID, launch: { Self.launch(of: agent, resume: nil, model: model, in: $0) },
                    prompt: ([Self.leadRestartPrompt(for: agent)] + handover).joined(separator: "\n")
                )
                if let started = self.leadWorkspace(inSpace: spaceID), self.moveSubtasks(of: task, workerUUID: uuid, to: started) {
                    self.tellSubtasksMoved(task, to: started)
                }
                return
            }
            let moved = self.moveSubtasks(of: task, workerUUID: uuid, to: lead)
            self.restartLead(lead, agent: agent, handover: handover)
            if moved { self.tellSubtasksMoved(task, to: lead) }
        }
    }

    /// A space with no Lead gets one, launched as `launch` says.
    private func startPromotedLead(spaceID: String, launch: (WorkspaceState) -> AgentLaunch?, prompt: String) {
        startLead(spaceID: spaceID, startsAgent: false)
        guard let lead = leadWorkspace(inSpace: spaceID), let column = lead.leadTerminal, let launch = launch(lead) else { return }
        let file = launch.agent == .claude ? claudeSpaceSettingsFile(for: lead) : nil
        let command = freshAgentCommand(
            launch, in: lead, column: column, launchDirectory: lead.cwd, worktreeBranch: Self.leadTitle,
            handoverPrompt: prompt, settingsFiles: file.map { [lead.profileID: $0] } ?? [:]
        )
        prepareSessionResume(launch, in: column)
        column.handedClaudeSessionID = launch.agent == .claude ? launch.sessionID : nil
        sideEffects.launchAgent(column, command)
    }
}
