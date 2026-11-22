import AppKit

// MARK: - The Lead (docs/design/spaces.md, "The Lead")

/// One optional Lead per space: a workspace pinned at the top of the space,
/// in its default repository's main checkout, with its agent and the space's
/// Board. The user talks to it; it starts tasks and follows them. Its
/// tools are scoped to the Lead workspace (`NIRUX_LEAD=1` in its
/// shells, see `WorkspaceState.isLead`), and its tasks are Missions whatever
/// the Mission handoffs setting (`Mission.reportsToLead`). A Lead started
/// again is a new parent: the earlier tasks' questions come to the user.
extension NiruxShellView {
    static let leadTitle = "Lead"

    /// Any space but General, which takes what no other space claims.
    static func spaceCanHaveLead(_ spaceID: String) -> Bool {
        spaceID != WorkspaceProfile.defaultID
    }

    /// The space's Lead, unless it is closing.
    func leadWorkspace(inSpace spaceID: String) -> WorkspaceState? {
        workspaceStore.leadWorkspace(inSpace: spaceID)
    }

    /// "Start a Lead" (New Space…, Space Settings › Lead, ⌃⌘L): its
    /// workspace opens on top of the space and takes the focus, its agent
    /// started, the Board beside it unless the space shows its Board in
    /// another workspace (one Board per space). One Lead per space: a space
    /// that has one focuses it.
    func startLead(spaceID: String) {
        guard Self.spaceCanHaveLead(spaceID), profiles.contains(where: { $0.id == spaceID }) else { return }
        if let lead = leadWorkspace(inSpace: spaceID) { return focusLead(lead) }
        addWorkspace(
            title: Self.leadTitle,
            cwd: defaultFolder(forSpace: spaceID),
            agent: SpaceDefaultsStore.defaults(forSpace: spaceID).preferredLeadAgent,
            profileID: spaceID,
            // Names its Claude session "Lead · <space>" (see SessionName).
            worktreeBranch: Self.leadTitle,
            isLead: true
        )
        if let lead = leadWorkspace(inSpace: spaceID), projectBoardLocation(projectID: spaceID) == nil {
            // Not `openProjectBoard`: a space without board settings would
            // open Space Settings › Board over the Lead and take its
            // keyboard. The Board asks for them when the user clicks it.
            let board = makeProjectBoard(projectID: spaceID, offersSettings: false)
            lead.addProjectBoardColumn(board)
            // The agent keeps the keyboard; the Board sits to its right.
            lead.focusedIndex = 0
            relayout(animated: false)
            updateSidebar()
            focusActiveTerminal(in: window)
            board.reload()
        }
        saveState()
        refreshSpaceSettingsLead()
    }

    /// Turning the Lead off closes its workspace, asking first when an agent
    /// runs there, as Close Workspace does: nothing else closes it. The
    /// tasks it followed stay; their questions come to the user once their
    /// parent is gone.
    func stopLead(spaceID: String) {
        guard let lead = leadWorkspace(inSpace: spaceID),
              let index = workspaces.firstIndex(where: { $0 === lead })
        else { return }
        requestCloseWorkspace(at: index, turningLeadOff: true)
        refreshSpaceSettingsLead()
    }

    static let leadStaysText = "The Lead stays open. Restart it from the Space menu, or turn it off in Space Settings › Lead."

    /// A close aimed at the Lead or its agent column: it stays.
    func refuseClosingLead() {
        showToast(Self.leadStaysText)
    }

    static let restartLeadTitle = "Restart Lead…"

    /// The first prompt of a restarted Lead.
    nonisolated static let leadRestartPrompt = "[Nirux] You were restarted in a fresh conversation. Call list_tasks: "
        + "Nirux kept the tasks, their questions to you and their results."

    nonisolated static func leadRestartPrompt(for agent: CodingAgent) -> String {
        agent == .agy ? agyLeadPrompt : leadRestartPrompt
    }

    // agy's --settings rejects mcpServers. Its mcp add command changes user configuration.
    nonisolated static let agyLeadPrompt = """
        You are the Lead of this Nirux space. Follow its tasks and answer their Mission questions using "$NIRUX_CLI_PATH" --mission reply. \
        Leave decisions you cannot settle to the user. Keep to this space. Never edit this checkout, merge a pull request, \
        or remove a worktree or branch. Ask the user to use Nirux for task management when Lead tools are unavailable.
        """

    /// Restart Lead, once the user confirms: its current agent ends, and a new
    /// conversation starts in its column as a new Lead's does, with the
    /// space's launch options now. The same agent UUID keeps it its tasks'
    /// Mission parent.
    func requestRestartLead(spaceID: String, stillApplies: () -> Bool = { true }) {
        guard let lead = leadWorkspace(inSpace: spaceID) else { return }
        guard lead.leadTerminal?.isRestartingShell != true else { return showToast("The Lead is restarting.") }
        let space = profiles.first { $0.id == spaceID }?.name ?? spaceID
        let snapshot = ProcessSnapshot()
        let pty = lead.leadTerminal?.pty
        let foreground = pty?.foregroundProcess(snapshot: snapshot)
        let next = SpaceDefaultsStore.defaults(forSpace: spaceID).preferredLeadAgent
        let mode: String? = switch next {
        case .claude: Self.claudeLaunchMode(for: lead).displayName
        case .codex: Self.codexLaunchMode(for: lead).displayName
        default: nil
        }
        guard confirmDestructiveClose(
            message: "Restart the Lead of “\(space)”?",
            details: Self.leadRestartDetails(
                next: next, mode: mode, agent: lead.leadTerminal?.liveAgent(snapshot: snapshot),
                otherProgram: foreground.flatMap { $0.interactiveAgent == nil && $0.instance.pid != pty?.shellPID ? $0.name : nil }
            ),
            confirmTitle: "Restart Lead"
        ), leadWorkspace(inSpace: spaceID) === lead, stillApplies() else { return }
        restartLead(lead)
    }

    /// `otherProgram`: what runs in its terminal in place of the Lead agent.
    static func leadRestartDetails(next: CodingAgent, mode: String?, agent: WorkspaceClosePolicy.LiveAgent?, otherProgram: String? = nil) -> [String] {
        let option = mode?.components(separatedBy: " (").first.map { " with the space’s launch mode (\($0))" } ?? ""
        var details = [
            "The current session ends. \(next.productName) starts a fresh conversation\(option).",
            "Nirux keeps the tasks, their questions, the rules and the brief. "
                + "This conversation stays in Session History."
        ]
        if let warning = leadTurnWarning(agent) { details.append(warning) }
        if let otherProgram { details.append("\(otherProgram) runs in its terminal: it ends too.") }
        return details
    }

    static func leadTurnWarning(_ agent: WorkspaceClosePolicy.LiveAgent?) -> String? {
        guard let agent else { return nil }
        return switch agent.status {
        case .working: "\(agent.agent.name) is working: its turn stops."
        case .needsAttention: "\(agent.agent.name) is waiting for you: that goes unanswered."
        default: nil
        }
    }

    func restartLead(_ lead: WorkspaceState, resuming sessionID: String? = nil) {
        let agent = sessionID == nil ? SpaceDefaultsStore.defaults(forSpace: lead.profileID).preferredLeadAgent : .claude
        let file = agent == .claude ? claudeSpaceSettingsFile(for: lead) : nil
        if sessionID != nil, file == nil, currentLeadOptions(in: lead).safety != nil {
            return showToast("Couldn’t prepare the space’s safety settings. The Lead is still running.", tone: .error)
        }
        guard let launch = Self.launch(of: agent, resume: sessionID.map(AgentResumeTarget.session), in: lead) else { return }
        let command = freshAgentCommand(
            launch, in: lead, launchDirectory: lead.leadTerminal?.launchDirectory ?? lead.cwd, worktreeBranch: Self.leadTitle,
            handoverPrompt: sessionID == nil ? Self.leadRestartPrompt(for: agent) : Self.leadRelaunchPrompt,
            settingsFiles: file.map { [lead.profileID: $0] } ?? [:]
        )
        defer {
            focusLead(lead)
            updateSidebar()
            scheduleMetadataRefresh()
        }
        guard let column = lead.leadTerminal else {
            // Its agent column closed before a Lead kept it: a new one, with
            // the agent UUID its tasks report to.
            let reportedTo = MissionStore.shared.missions.filter { $0.parentWorkspaceID == lead.id && $0.status == .active }
                .max { $0.createdAt < $1.createdAt }?.parentAgentUUID
            lead.addColumn(agentUUID: lead.leadAgentUUID ?? reportedTo ?? UUID().uuidString)
            guard let column = lead.columns[safe: lead.focusedIndex] else { return }
            lead.leadAgentUUID = column.agentUUID
            relayout(animated: false)
            column.recordLeadSafety(file: file)
            return sideEffects.launchAgent(column, command)
        }
        if !column.isAwaitingResume, let pty = column.pty, pty.shellPID == nil, !pty.hasExited {
            return showToast("The Lead is starting: restart it in a moment.")
        }
        if let sessionID {
            guard !column.isRestartingShell, column.relaunchingLeadSessionID == nil, column.launchDirectory != nil,
                  canRelaunchLeadSession(sessionID, in: column) else { return }
            column.relaunchingLeadSessionID = sessionID
        }
        refreshLaunch(of: column, in: lead)
        sideEffects.restartTerminal(column, command) { [weak self, weak lead, weak column] stillRunning in
            defer { column?.relaunchingLeadSessionID = nil }
            // Turned off meanwhile: nothing starts in its column.
            guard let self, let lead, let column, self.leadWorkspace(inSpace: lead.profileID) === lead, column === lead.leadTerminal else { return false }
            guard stillRunning.isEmpty else {
                self.showToast(
                    "The Lead’s previous session didn’t stop within \(Int(Self.exitTimeout)) s (\(stillRunning.joined(separator: ", "))): "
                        + "nothing was launched. Once it stops, choose Restart Lead again.",
                    tone: .error
                )
                return false
            }
            if let sessionID {
                guard self.canRelaunchLeadSession(sessionID, in: column) else { return false }
                column.prepareClaudeResume(sessionID: sessionID)
                self.sessionResume.noteLaunch(of: sessionID, in: column, now: ProcessInfo.processInfo.systemUptime)
            }
            column.recordLeadSafety(file: file)
            return true
        }
    }

    /// ⌃⌘L: the active space's Lead, its agent focused; a space without
    /// one starts it.
    func focusOrStartLead() {
        guard Self.spaceCanHaveLead(activeProfileID) else { return }
        if let lead = leadWorkspace(inSpace: activeProfileID) {
            focusLead(lead)
        } else {
            startLead(spaceID: activeProfileID)
        }
    }

    /// The Lead's workspace, on its agent column.
    func focusLead(_ lead: WorkspaceState) {
        let column = lead.columns.firstIndex { $0 === lead.leadTerminal }
        focusWorkspace(id: lead.id, column: column)
    }

    // MARK: - Space Settings › Lead

    func spaceSettingsLeadModel(for space: WorkspaceProfile) -> SpaceSettingsLeadPane.Model {
        let lead = leadWorkspace(inSpace: space.id)
        let defaults = SpaceDefaultsStore(spaceID: space.id)?.load()
        return SpaceSettingsLeadPane.Model(
            spaceName: space.name,
            isGeneral: !Self.spaceCanHaveLead(space.id),
            hasLead: lead != nil,
            place: leadPlace(in: space, leadFolder: lead?.cwd),
            startsTasks: leadStartsTasksWithoutAsking(spaceID: space.id),
            agent: defaults?.defaults.preferredLeadAgent ?? .claude,
            dailyPass: defaults?.defaults.dailyPassIsOn ?? false,
            dailyPassHour: defaults?.defaults.dailyPassHour ?? DailyPass.defaultHour,
            lastPass: lastDailyPassText(inSpace: space.id),
            canChangeDefaults: defaults?.isWritable ?? false
        )
    }

    /// "Starts tasks without asking", saved in the space's defaults.json
    /// (on is the default, so it writes nothing).
    func setLeadStartsTasks(_ on: Bool, spaceID: String) {
        changeSpaceDefaults(spaceID: spaceID) { $0.leadStartsTasks = on ? nil : false }
        refreshSpaceSettingsLead()
    }

    /// Saves `change` to the space's defaults.json at once. An unreadable
    /// file is replaced (set aside first) even when nothing changes: what
    /// it held reads as unset until then.
    func changeSpaceDefaults(spaceID: String, _ change: (inout SpaceDefaults) -> Void) {
        guard let store = SpaceDefaultsStore(spaceID: spaceID) else { return }
        let loaded = store.load()
        var defaults = loaded.defaults
        change(&defaults)
        if defaults != loaded.defaults || loaded.status == .unreadable,
           case .failure(let error) = store.save(defaults, replacing: loaded) {
            showToast(error.message, tone: .error)
        }
        leadWorkspace(inSpace: spaceID)?.leadOptionsCache = nil
        // The Defaults tab shows the file as it is now, under the variables
        // being typed.
        if let settings = spaceSettings, settings.spaceID == spaceID {
            let saved = store.load()
            if settings.defaults.hasUnsavedRows { settings.defaults.rebase(on: saved) } else { settings.defaults.show(saved) }
        }
    }

    /// Whether the space's Lead starts tasks itself. A defaults.json Nirux
    /// can't read asks first: off is the safe side (`SpaceDefaults.switches`).
    func leadStartsTasksWithoutAsking(spaceID: String) -> Bool {
        SpaceDefaultsStore(spaceID: spaceID)?.load().defaults.leadStartsTasksWithoutAsking ?? false
    }

    /// Where the running Lead works (`leadFolder`), else where a new one
    /// would start (`defaultFolder(forSpace:)`).
    private func leadPlace(in space: WorkspaceProfile, leadFolder: String?) -> SpaceSettingsLeadPane.Place {
        let firstRepository = space.anchors.first { anchor in
            if case .gitRepository = anchor.kind { return anchor.folder != nil }
            return false
        }?.name
        func place(of anchor: SpaceAnchor) -> SpaceSettingsLeadPane.Place {
            if case .gitRepository = anchor.kind { return .repository(anchor.name) }
            return .folder(anchor.name, repository: firstRepository)
        }
        let start = defaultFolderAnchor(forSpace: space.id)
        guard let leadFolder else { return start.map(place(of:)) ?? .home }
        let standardized = { (path: String) in URL(fileURLWithPath: path).standardizedFileURL.path }
        if let anchor = space.anchors.first(where: { $0.folder.map(standardized) == standardized(leadFolder) }) {
            return place(of: anchor)
        }
        if standardized(leadFolder) == standardized(sideEffects.homeDirectory()), start == nil { return .home }
        let repository = start.flatMap { anchor -> String? in
            if case .gitRepository = anchor.kind { return anchor.name }
            return nil
        }
        return .elsewhere(path: leadFolder, repository: repository)
    }

    /// The Lead tab again, after the Lead started or closed.
    func refreshSpaceSettingsLead() {
        guard let settings = spaceSettings, let space = profiles.first(where: { $0.id == settings.spaceID }) else { return }
        let model = spaceSettingsLeadModel(for: space)
        if model != settings.lead.model { settings.lead.update(model) }
    }
}

extension WorkspaceState {
    /// The restart prompt belongs to the launched Claude. A later Claude
    /// started by hand in the same terminal has its own conversation.
    func runsRestartedLead(_ process: ForegroundProcess) -> Bool {
        isLead && [.claude, .codex].contains(process.interactiveAgent)
            && (process.arguments.last == NiruxShellView.leadRestartPrompt || process.arguments.last == NiruxShellView.leadRelaunchPrompt)
    }

    /// A Lead's agent column, by its agent UUID.
    var leadTerminal: ColumnState? {
        guard isLead, let leadAgentUUID else { return nil }
        return columns.first { $0.agentUUID == leadAgentUUID && !$0.isClosing }
    }
}
