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
        !workspace.isClosing && !workspace.isInactive && Self.spaceCanHaveLead(workspace.profileID) && Self.isTask(workspace)
    }

    /// Promote to Lead, once the user confirms.
    func requestLeadPromotion(of task: WorkspaceState) {
        guard offersLeadPromotion(task), workspaces.contains(where: { $0 === task }) else { return }
        let spaceID = task.profileID
        _ = MissionStore.shared.ensureLoaded()
        let snapshot = ProcessSnapshot()
        let worker = promotionWorker(of: task, snapshot: snapshot)
        let lead = leadWorkspace(inSpace: spaceID)
        if let refusal = promotionRefusal(worker?.state, of: task, lead: lead) { return showToast(refusal) }
        guard let (column, state) = worker, let sessionID = state.sessionID else { return }
        let space = profiles.first { $0.id == spaceID }?.name ?? spaceID
        var details = [
            "Its conversation goes on as the Lead’s, in the space’s checkout. Its worktree, branch and pull request stay as they are."
        ]
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
        guard offersLeadPromotion(task), leadWorkspace(inSpace: spaceID) === lead, latest?.column === column,
              latest?.state.sessionID == sessionID else { return showToast("The task or its Lead changed meanwhile. Nothing was promoted.") }
        if let refusal = promotionRefusal(latest?.state, of: task, lead: lead) { return showToast(refusal) }
        promote(task, column: column, sessionID: sessionID, into: lead)
    }

    private func promotionWorker(of task: WorkspaceState, snapshot: ProcessSnapshot) -> (column: ColumnState, state: LeadPromotion.Worker)? {
        guard let column = taskWorker(task, snapshot: snapshot), let pty = column.pty else { return nil }
        let foreground = pty.foregroundProcess(snapshot: snapshot)
        let agent = foreground?.interactiveAgent
        return (column, LeadPromotion.Worker(
            agent: agent,
            sessionID: foreground.flatMap { agent == .claude ? column.claudeSessionID(of: $0) : nil },
            isStarting: column.isRestartingShell || (!column.isAwaitingResume && pty.shellPID == nil && !pty.hasExited),
            isAtRest: column.liveAgent(snapshot: snapshot)?.status == .idle || pty.agentAttentionReason == .turnFinished,
            hasDialog: pty.pendingAgentDialog != nil || foreground.map { pty.agentVisibleDialog(foreground: $0) != nil } == true,
            hasDraft: pty.taskResumeDraft(foreground: foreground?.instance) != nil,
            otherProgram: foreground.flatMap { $0.interactiveAgent == nil && $0.instance.pid != pty.shellPID ? $0.name : nil }
        ))
    }

    private func promotionRefusal(_ worker: LeadPromotion.Worker?, of task: WorkspaceState, lead: WorkspaceState?) -> String? {
        let subtasks = workspaces.filter { $0.parentWorkspaceID == task.id && !$0.isClosing }.count
        if let refusal = LeadPromotion.refusal(worker, openSubtasks: subtasks) { return refusal }
        guard let column = lead?.leadTerminal else { return nil }
        if column.isRestartingShell || column.relaunchingLeadSessionID != nil { return "The Lead is restarting. Try again in a moment." }
        if !column.isAwaitingResume, let pty = column.pty, pty.shellPID == nil, !pty.hasExited {
            return "The Lead is starting. Try again in a moment."
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
            guard stillRunning.isEmpty else {
                self.showToast(
                    "The task’s agent didn’t stop within \(Int(Self.exitTimeout)) s (\(stillRunning.joined(separator: ", "))). "
                        + "Nothing was promoted.",
                    tone: .error
                )
                return false
            }
            let now = Date().timeIntervalSince1970
            self.sessionLedger.closeSessions(ofWorker: uuid, at: now)
            _ = MissionStore.shared.endChildMissions(workspaceID: task.id, agentUUID: uuid, at: now)
            task.noteConversationMovedToLead(at: now)
            self.saveState()
            self.handOver(sessionID, from: task, to: lead, spaceID: spaceID)
            return true
        }
    }

    private func handOver(_ sessionID: String, from task: WorkspaceState, to lead: WorkspaceState?, spaceID: String) {
        let lost = "“\(task.title)”’s conversation stopped, but the Lead didn’t take it. Resume it from Session History."
        let current = leadWorkspace(inSpace: spaceID)
        guard current === lead else { return showToast(lost, tone: .error) }
        let folder = current.map { $0.leadTerminal?.launchDirectory.flatMap(Self.existingDirectory) ?? $0.cwd } ?? defaultFolder(forSpace: spaceID)
        let prompt = Self.leadPromotionPrompt(
            folder: folder, task: task.title, worktree: task.cwd, branch: task.gitBranch, pullRequest: task.prInfo?.number
        )
        guard let current else { return startPromotedLead(spaceID: spaceID, sessionID: sessionID, prompt: prompt) }
        restartLead(current, agent: .claude, resuming: sessionID, resumePrompt: prompt) { [weak self] launched in
            if !launched { self?.showToast(lost, tone: .error) }
        }
    }

    /// A space with no Lead gets one, holding the promoted conversation.
    private func startPromotedLead(spaceID: String, sessionID: String, prompt: String) {
        startLead(spaceID: spaceID, startsAgent: false)
        guard let lead = leadWorkspace(inSpace: spaceID), let column = lead.leadTerminal,
              let launch = Self.launch(of: .claude, resume: .session(sessionID), in: lead) else { return }
        let file = claudeSpaceSettingsFile(for: lead)
        let command = freshAgentCommand(
            launch, in: lead, column: column, launchDirectory: lead.cwd, worktreeBranch: Self.leadTitle,
            handoverPrompt: prompt, settingsFiles: file.map { [lead.profileID: $0] } ?? [:]
        )
        prepareSessionResume(launch, in: column)
        sideEffects.launchAgent(column, command)
    }
}
