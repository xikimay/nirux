import AppKit

// MARK: - Token usage

extension NiruxShellView {
    /// Starts reading what the agents spend; `onReport` follows each read.
    func startUsageMonitor(onReport: @escaping (UsageReport) -> Void) {
        let monitor = UsageMonitor(
            sources: UsageSources(niruxOneShots: ClaudeOneShotRunner.usageFolder),
            catalog: { [weak self] in self?.usageCatalog() ?? UsageCatalog() }
        )
        monitor.onReport = { [weak self] report in
            if let self, let window = usageWindow, window.window?.isVisible == true {
                window.update(report: report, names: usageNames())
            }
            self?.startColdLeadsAfresh(now: report.generatedAt)
            onReport(report)
        }
        usageMonitor = monitor
        monitor.start()
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
    /// latest (`ContextOffer`).
    func contextOffer(
        for column: ColumnState, in workspace: WorkspaceState, foreground: ForegroundProcess?, status: AgentStatus, now: TimeInterval
    ) -> ContextOffer? {
        guard status != .working, let foreground, foreground.interactiveAgent == .claude,
              let id = column.claudeSessionID(of: foreground),
              let session = usageMonitor?.report?.latestSessions[workspace.id], session.key == UsageSessionKey(.claude, id)
        else { return nil }
        return ContextOffer(session, now: now)
    }

    /// A Claude Lead at rest past its cache with a heavy context starts a
    /// new conversation where its space allows (`ContextOffer.restartsLead`):
    /// its next message would write the whole context again. Never over a
    /// draft, a dialog or a turn.
    func startColdLeadsAfresh(now: TimeInterval) {
        let snapshot = ProcessSnapshot()
        for lead in workspaces where lead.isLead && !lead.isClosing {
            guard let column = lead.leadTerminal, !column.isRestartingShell, let pty = column.pty,
                  let foreground = pty.foregroundProcess(snapshot: snapshot), foreground.interactiveAgent == .claude,
                  let id = column.claudeSessionID(of: foreground),
                  let session = usageMonitor?.report?.latestSessions[lead.id], session.key == UsageSessionKey(.claude, id),
                  ContextOffer.restartsLead(session, runningSince: foreground.instance.startedAt, now: now),
                  column.liveAgent(snapshot: snapshot)?.status == .idle, !pty.hasPromptDraft,
                  SpaceDefaultsStore.defaults(forSpace: lead.profileID).leadStartsFreshWhenCold
            else { continue }
            restartLead(lead, agent: .claude, focus: false)
            let space = profiles.first { $0.id == lead.profileID }?.name ?? lead.title
            showToast("The Lead of “\(space)” started a new conversation: idle for an hour with \(UsageText.tokens(session.contextTokens ?? 0)) of context.")
        }
    }

    /// Compact types /compact as the user would. Fresh start restarts the
    /// Lead, or resumes a task on Claude in a new conversation with a
    /// handover.
    func takeContextOffer(_ choice: ContextOffer.Choice, workspaceIndex: Int, columnIndex: Int) {
        guard let workspace = workspaces[safe: workspaceIndex], let column = workspace.columns[safe: columnIndex],
              let uuid = column.agentUUID else { return }
        switch choice {
        case .compact:
            guard case .sent = sendTypedPrompt(agentUUID: uuid, prompt: "/compact") else {
                return showToast("Couldn’t type /compact: claude’s prompt isn’t free.", tone: .error)
            }
        case .freshStart where workspace.isLead:
            restartLead(workspace, agent: .claude)
        case .freshStart:
            resumeTask(workspace, with: TaskAgentChoice(agent: .claude, model: nil), interactive: true, freshStart: true) { [weak self] message, failed in
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
