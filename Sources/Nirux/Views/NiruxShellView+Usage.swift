import AppKit

// MARK: - Token usage

extension NiruxShellView {
    /// Starts reading what the agents spend; `onReport` follows each read.
    func startUsageMonitor(onReport: @escaping (UsageReport) -> Void) {
        let monitor = UsageMonitor(
            sources: UsageSources(niruxOneShots: ClaudeOneShotRunner.usageFolder),
            catalog: { [weak self] in self?.usageCatalog() ?? UsageCatalog() }
        )
        refreshTaskBudgets()
        monitor.onReport = { [weak self] report in
            self?.refreshTaskBudgets()
            if let self, let window = usageWindow, window.window?.isVisible == true {
                window.update(report: report, names: usageNames())
            }
            self?.startColdLeadsAfresh(now: report.generatedAt)
            onReport(report)
        }
        usageMonitor = monitor
        monitor.start()
    }

    /// Each space's task budget, read as each usage report lands: the
    /// sidebar asks several times a second, and the setting is on disk.
    func refreshTaskBudgets() {
        taskBudgets = Dictionary(uniqueKeysWithValues: workspaceStore.profiles.compactMap { profile in
            SpaceDefaultsStore.defaults(forSpace: profile.id).weeklyTaskBudget.map { (profile.id, $0) }
        })
        updateSidebar()
    }

    /// Past its space's budget over 7 days (`SidebarTaskUsage.isOverBudget`).
    func isOverBudget(_ workspace: WorkspaceState) -> Bool {
        usageMonitor?.report.flatMap { SidebarTaskUsage($0, taskID: workspace.id, budget: taskBudgets[workspace.profileID]) }?.isOverBudget ?? false
    }

    func showUsageWindow() {
        let controller = usageWindow ?? UsageWindowController()
        usageWindow = controller
        controller.update(report: usageMonitor?.report, names: usageNames())
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    /// Nirux's spaces and tasks, for the ledger to credit each session: a
    /// session Nirux recorded goes to its task, another by its folder. A
    /// task's folder is the one Nirux made for it, else its repository's
    /// root (its worktree, the Lead's checkout); Leads come first, so a
    /// checkout's sessions go to its Lead.
    func usageCatalog() -> UsageCatalog {
        let profiles = workspaceStore.profiles
        let tasks = workspaces.sorted { $0.isLead && !$1.isLead }.compactMap { workspace in
            (workspace.taskFolder ?? workspace.gitContext?.identity.repositoryRoot).map {
                UsageCatalog.Task(id: workspace.id, spaceID: workspace.profileID, folder: $0)
            }
        }
        let recorded = profiles.flatMap { sessionLedger.sessions(inSpace: $0.id) }.compactMap { record in
            record.workspaceID.flatMap { workspaceID in
                UsageAgent(rawValue: record.agent.rawValue).map { (UsageSessionKey($0, record.sessionID), workspaceID) }
            }
        }
        return UsageCatalog(
            spaces: profiles.map { profile in
                UsageCatalog.Space(
                    id: profile.id,
                    repositories: profile.anchors.compactMap { anchor in
                        if case .gitRepository = anchor.kind { anchor.folder } else { nil }
                    },
                    folders: profile.anchors.compactMap { anchor in
                        if case .folder(let path) = anchor.kind { path } else { nil }
                    }
                )
            },
            tasks: tasks,
            sessionTasks: Dictionary(recorded) { first, _ in first }
        )
    }

    /// The offer under a Claude column at rest whose session is its task's
    /// latest (`ContextOffer`). Fresh start where it hands the work over:
    /// the Lead's terminal, a Nirux task's worker.
    func contextOffer(
        for column: ColumnState, in workspace: WorkspaceState, foreground: ForegroundProcess?, atRest: Bool,
        snapshot: ProcessSnapshot, now: TimeInterval
    ) -> ContextOffer? {
        ContextOffer(
            usageMonitor?.report?.latestSessions[workspace.id],
            ofSession: foreground.flatMap { $0.interactiveAgent == .claude ? column.claudeSessionID(of: $0) : nil },
            atRest: atRest,
            startsFresh: workspace.isLead
                ? column === workspace.leadTerminal
                : Self.isTask(workspace) && workspace.missionID != nil && taskWorker(workspace, snapshot: snapshot) === column,
            now: now
        )
    }

    /// A Claude Lead cold with a heavy context starts a new conversation
    /// where its space allows (`ColdLead`), handed its previous one: its
    /// next message would write the whole context again.
    func startColdLeadsAfresh(now: TimeInterval) {
        let snapshot = ProcessSnapshot()
        for lead in workspaces where lead.isLead && startsFresh(lead, snapshot: snapshot, now: now) {
            let context = usageMonitor?.report?.latestSessions[lead.id]?.contextTokens ?? 0
            leadHandover(lead) { [weak self] handover in
                // Read again: the user may have typed meanwhile.
                guard let self, self.startsFresh(lead, snapshot: ProcessSnapshot(), now: Date().timeIntervalSince1970) else { return }
                self.restartLead(lead, agent: .claude, handover: handover, focus: false) { [weak self] launched in
                    guard launched, let self else { return }
                    let space = self.profiles.first { $0.id == lead.profileID }?.name ?? lead.title
                    self.showToast("The Lead of “\(space)” started a new conversation: idle for an hour with \(UsageText.tokens(context)) of context.")
                }
            }
        }
    }

    private func startsFresh(_ lead: WorkspaceState, snapshot: ProcessSnapshot, now: TimeInterval) -> Bool {
        guard !lead.isClosing, let column = lead.leadTerminal, !column.isRestartingShell, let pty = column.pty,
              let foreground = pty.foregroundProcess(snapshot: snapshot), foreground.interactiveAgent == .claude else { return false }
        return ColdLead.startsFresh(
            latest: usageMonitor?.report?.latestSessions[lead.id], sessionID: column.claudeSessionID(of: foreground),
            runningSince: foreground.instance.startedAt, now: now,
            spaceAllows: SpaceDefaultsStore.defaults(forSpace: lead.profileID).leadStartsFreshWhenCold,
            holdings: leadHoldings(lead, column: column, pty: pty, foreground: foreground, snapshot: snapshot)
        )
    }

    func leadHoldings(
        _ lead: WorkspaceState, column: ColumnState, pty: PtySession, foreground: ForegroundProcess, snapshot: ProcessSnapshot
    ) -> LeadHoldings {
        let status = column.liveAgent(snapshot: snapshot)?.status
        return LeadHoldings(
            isBusy: status != .idle,
            hasDialog: pty.pendingAgentDialog != nil || pty.agentVisibleDialog(foreground: foreground) != nil,
            hasQuestion: pty.agentQuestion(foreground: foreground) != nil
                || Self.sidebarTurnQuestion(of: column, status: status ?? .working, foreground: foreground) != nil,
            hasDraft: pty.hasPromptDraft,
            owesMissionReply: MissionStore.shared.missions.contains { $0.awaitsReply(from: lead.id) },
            runsItsQueue: mergeQueues.contains { key, queue in
                key.projectID == lead.profileID && queue.isRunning && queue.engine?.startedByLead == true
            }
        )
    }

    /// What a fresh Lead is handed after its restart prompt: its previous
    /// conversation's last entry and where to read the rest. Read off the
    /// main thread.
    func leadHandover(_ lead: WorkspaceState, then done: @escaping @MainActor @Sendable ([String]) -> Void) {
        let previous = lead.leadAgentUUID.flatMap { previousSession(of: lead, agentUUID: $0) }
        let (id, spaceID) = (lead.id, lead.profileID)
        Self.offMain({ TaskResumeHandover.localContext(workspaceID: id, spaceID: spaceID, previous: previous) }) { context in
            done(Self.leadHandoverLines(previous: previous, context: context))
        }
    }

    nonisolated static func leadHandoverLines(previous: AgentSessionRecord?, context: [String]) -> [String] {
        guard let previous else { return context }
        return context + [
            "Previous conversation in Session History: \(previous.agent.rawValue) \(previous.sessionID). "
                + "Before acting, look there (history_search) for open threads, promises and decisions."
        ]
    }

    /// Compact types /compact as the user would, never after a draft. Fresh
    /// start asks to restart the Lead, or resumes a task's worker on Claude,
    /// on its model, in a new conversation with a handover.
    func takeContextOffer(_ choice: ContextOffer.Choice, workspaceIndex: Int, columnIndex: Int) {
        guard let workspace = workspaces[safe: workspaceIndex], let column = workspace.columns[safe: columnIndex],
              let uuid = column.agentUUID, let pty = column.pty else { return }
        let foreground = pty.foregroundProcess(snapshot: ProcessSnapshot())
        let action = ContextOfferAction.of(
            choice, hasDraft: pty.hasPromptDraft, isLead: workspace.isLead,
            workerModel: foreground.flatMap { AgentModels.launchModel(arguments: $0.arguments) }
        )
        switch action {
        case .refuse(let message):
            showToast(message, tone: .error)
        case .typeCompact:
            guard case .sent = sendTypedPrompt(agentUUID: uuid, prompt: "/compact") else {
                return showToast("Couldn’t type /compact: claude’s prompt isn’t free.", tone: .error)
            }
        case .confirmLeadRestart:
            let spaceID = workspace.profileID
            leadHandover(workspace) { [weak self] handover in
                self?.requestRestartLead(spaceID: spaceID, handover: handover)
            }
        case .resumeTask(let model):
            resumeTask(workspace, with: TaskAgentChoice(agent: .claude, model: model), interactive: true, freshStart: true) { [weak self] message, failed in
                self?.showToast(message, tone: failed ? .error : .info)
            }
        }
    }

    func usageNames() -> UsageNames {
        UsageNames(
            tasks: Dictionary(workspaces.map { ($0.id, UsageNames.Task(title: $0.title, isLead: $0.isLead)) }) { first, _ in first },
            spaces: Dictionary(workspaceStore.profiles.map { ($0.id, $0.name) }) { first, _ in first }
        )
    }
}
