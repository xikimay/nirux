import AppKit

/// What resuming recorded sessions keeps on the shell (see
/// `resumeSession`).
@MainActor
final class SessionResumeState {
    /// Sessions a Resume is under way for (git reads, the confirmation,
    /// the worktree coming back): picking one again meanwhile does nothing.
    var inFlight: Set<String> = []

    /// One serial queue per repository: a Resume plans, and brings its
    /// worktree back, after the one before it in the same repository. Two
    /// `git worktree add` on one path break each other inside git, and a
    /// plan made meanwhile would open a folder still being checked out.
    /// Other repositories don't wait.
    private var queues: [String: DispatchQueue] = [:]

    func queue(for record: AgentSessionRecord) -> DispatchQueue {
        guard let repository = record.checkout.map({ $0.mainCheckout ?? $0.worktreeRoot }) else {
            return .global(qos: .userInitiated)
        }
        if let queue = queues[repository] { return queue }
        let queue = DispatchQueue(label: "nirux.session-resume", qos: .userInitiated)
        queues[repository] = queue
        return queue
    }

    /// A column a Resume typed its agent into. Weak: a closed column holds
    /// nothing.
    private struct Launch {
        weak var column: ColumnState?
        let sessionID: String
        let at: TimeInterval
    }

    private var launches: [Launch] = []
    /// Until its agent shows as a process (the launch line is typed a
    /// second after the shell starts, and the agent takes a moment to
    /// start), the column holds the session for this long.
    static let launchGrace: TimeInterval = 30

    func noteLaunch(of sessionID: String, in column: ColumnState, now: TimeInterval) {
        launches.removeAll { $0.column == nil || $0.column === column || now - $0.at > Self.launchGrace }
        launches.append(Launch(column: column, sessionID: sessionID, at: now))
    }

    func launchedSession(in column: ColumnState, now: TimeInterval) -> String? {
        launches.last { $0.column === column && now - $0.at <= Self.launchGrace }?.sessionID
    }
}

// MARK: - Past sessions in ⌘P, and Resume

extension NiruxShellView {
    /// The current space's ended sessions, the most recently active first,
    /// left out when a column holds them (its workspace's row leads there).
    /// Picking one resumes it.
    func sessionsPaletteSection(snapshot: ProcessSnapshot, now: TimeInterval) -> PaletteSection {
        let spaceID = activeProfileID
        let holders = agentSessionHolders(snapshot: snapshot)
        let records = sessionLedger.sessions(inSpace: spaceID, matching: AgentSessionLedger.Query(state: .ended))
            .lazy
            .filter { Self.isResumable($0) && HeldAgentSession.find($0.sessionID, in: holders) == nil }
            .prefix(SessionHistory.paletteLimit)
        let rows = records.map { record in
            PaletteAction(
                icon: .agent(record.agent.rawValue),
                title: SessionHistory.title(of: record),
                subtitle: SessionHistory.subtitle(of: record, now: now) { $0.abbreviatedPath() },
                shortcut: nil,
                ranking: SessionHistory.candidate(of: record)
            ) { [weak self] in
                self?.resumeSession(record, spaceID: spaceID)
            }
        }
        return PaletteSection(title: SessionHistory.paletteSectionTitle, rows: Array(rows))
    }

    /// Claude and Codex name sessions with UUIDs, as restores require: an
    /// id from a hand-edited history must not reach a launch line, where
    /// `--resume -x` would read as an option.
    static func isResumable(_ record: AgentSessionRecord) -> Bool {
        UUID(uuidString: record.sessionID) != nil
    }

    /// What each column still open holds (see `HeldAgentSession`).
    func agentSessionHolders(snapshot: ProcessSnapshot) -> [AgentSessionHolder] {
        let now = ProcessInfo.processInfo.systemUptime
        let open = workspaces.filter { !$0.isClosing }
        let columns = Dictionary(open.flatMap(\.columns).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return Self.agentSessionHolders(in: open, snapshot: snapshot).compactMap { holder in
            guard let column = columns[holder.columnID], !column.isClosing else { return nil }
            var holder = holder
            holder.launchedSessionID = sessionResume.launchedSession(in: column, now: now)
            return holder
        }
    }

    /// Every column's agents: the sessions their hooks confirmed, else the
    /// arguments they run with (the session a launch resumes); the session
    /// a restored column will resume; the one an agent died on mid-turn.
    static func agentSessionHolders(in workspaces: [WorkspaceState], snapshot: ProcessSnapshot) -> [AgentSessionHolder] {
        workspaces.flatMap { workspace in
            workspace.columns.map { column in
                var holder = AgentSessionHolder(workspaceID: workspace.id, columnID: column.id)
                holder.deferredSessionID = column.deferredAgent?.agent.sessionID
                guard let pty = column.pty else { return holder }
                if let exit = pty.agentMidTurnExit, exit.processName == "claude" { holder.exitedSessionID = exit.sessionID }
                guard let shellPID = pty.shellPID else { return holder }
                let agentNames: Set<String> = ["claude", "codex"]
                let foreground = pty.foregroundProcess(snapshot: snapshot)
                let confirmed = foreground.map {
                    [column.confirmedClaudeSessionID(foregroundProcess: $0), column.boundCodexSessionID(of: $0.instance)]
                        .compactMap { $0 }
                } ?? []
                if confirmed.isEmpty {
                    holder.liveText = snapshot.descendantArguments(of: shellPID, named: agentNames).flatMap { $0 }
                        + (foreground?.arguments ?? [])
                } else {
                    // After `/clear` or `/resume`, the job in front left the
                    // session its arguments name. One stopped behind it
                    // with ^Z still holds its own.
                    holder.liveText = snapshot.descendantArguments(of: shellPID, named: agentNames, outsideForegroundJob: true)
                        .flatMap { $0 } + confirmed
                }
                return holder
            }
        }
    }

    /// Resume a recorded session of `spaceID`. A column that holds it gets
    /// the focus instead (a restored one, or one whose agent died on it,
    /// resumes it then). Otherwise `AgentSessionResume.plan` picks the
    /// folder, off the main thread; a plan with a warning asks first; a
    /// removed worktree comes back; then the agent resumes in a new column
    /// of the session's workspace, else of a workspace open on that folder,
    /// else of a new workspace.
    func resumeSession(_ record: AgentSessionRecord, spaceID: String) {
        guard Self.isResumable(record) else { return showToast("This session’s id can’t be resumed", tone: .error) }
        if goToHeldSession(record) { return }
        guard sessionResume.inFlight.insert(record.key).inserted else {
            return showToast("Already resuming “\(SessionHistory.title(of: record))”…")
        }
        planResume(record, spaceID: spaceID)
    }

    private func planResume(_ record: AgentSessionRecord, spaceID: String) {
        sessionResume.queue(for: record).async {
            let plan = AgentSessionResume.plan(for: record, probe: .onDisk()).map { plan in
                let elsewhere = AgentSessionResume.transcriptChangedElsewhere(record, now: Date().timeIntervalSince1970)
                let warning = [plan.warning, elsewhere].compactMap { $0 }.joined(separator: " ")
                return AgentSessionResume.Plan(place: plan.place, directory: plan.directory, warning: warning.isEmpty ? nil : warning)
            }
            DispatchQueue.main.async { [weak self] in
                self?.continueResume(record, spaceID: spaceID, plan: plan)
            }
        }
    }

    private func continueResume(
        _ record: AgentSessionRecord,
        spaceID: String,
        plan: Result<AgentSessionResume.Plan, AgentSessionResume.Unavailable>
    ) {
        switch plan {
        case .failure(let reason):
            sessionResume.inFlight.remove(record.key)
            showToast(SessionHistory.message(reason, agent: record.agent), tone: .error)
        case .success(let plan):
            guard let warning = plan.warning else { return performResume(record, spaceID: spaceID, plan: plan) }
            // An app-modal alert, from the run loop rather than from this
            // main-queue block: the main queue would run no other block
            // until the alert is answered.
            RunLoop.main.perform(inModes: [.default]) { [weak self] in
                // On the main thread, which Swift 6.1 doesn't infer for this block.
                MainActor.assumeIsolated {
                    self?.confirmResume(record, spaceID: spaceID, plan: plan, warning: warning)
                }
            }
        }
    }

    private func confirmResume(
        _ record: AgentSessionRecord, spaceID: String, plan: AgentSessionResume.Plan, warning: String
    ) {
        // Return and Escape cancel: the alert comes after the git reads,
        // under keys meant for a terminal.
        guard confirmDestructiveClose(
            message: "Resume “\(SessionHistory.title(of: record))”?", details: [warning], confirmTitle: "Resume"
        ) else {
            sessionResume.inFlight.remove(record.key)
            return
        }
        performResume(record, spaceID: spaceID, plan: plan)
    }

    private func performResume(_ record: AgentSessionRecord, spaceID: String, plan: AgentSessionResume.Plan) {
        guard case .recreatedWorktree(let mainCheckout, let ref) = plan.place else {
            sessionResume.inFlight.remove(record.key)
            return openResumedSession(record, spaceID: spaceID, directory: plan.directory)
        }
        let path = plan.directory
        // Checkout hooks and large repositories can take a while.
        showToast("Bringing the worktree back at \(path.abbreviatedPath())…")
        sessionResume.queue(for: record).async {
            let recreation = AgentSessionResume.recreateWorktree(at: path, ref: ref, mainCheckout: mainCheckout)
            // A failing post-checkout hook leaves the worktree behind.
            let isBack = FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent(".git"))
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                switch recreation {
                case .alreadyBack:
                    // It appeared after the plan, while the question was up:
                    // plan from what is there now (its branch may differ).
                    return planResume(record, spaceID: spaceID)
                case .done:
                    showToast("The worktree is back at \(path.abbreviatedPath())")
                case .failed(let error):
                    guard isBack else {
                        sessionResume.inFlight.remove(record.key)
                        return showToast("Couldn’t bring the worktree back: \(error)", tone: .error)
                    }
                    showToast("The worktree is back, but git reported: \(error)", tone: .error)
                }
                sessionResume.inFlight.remove(record.key)
                openResumedSession(record, spaceID: spaceID, directory: path)
            }
        }
    }

    /// The agent resumes in `directory`: in a new column of the workspace
    /// it ran in, else of a workspace of `spaceID` open on that folder,
    /// else of a new workspace.
    private func openResumedSession(_ record: AgentSessionRecord, spaceID: String, directory: String) {
        // Resumed meanwhile, by a restored column or another Resume.
        if goToHeldSession(record) { return }
        let open = workspaces.filter { !$0.isClosing }
        let workspace: WorkspaceState
        let column: ColumnState
        if let existing = open.first(where: { $0.id == record.workspaceID })
            ?? open.first(where: { $0.profileID == spaceID && AgentSessionResume.isSamePath($0.cwd, directory) }) {
            existing.addColumn(cwd: directory)
            guard let added = existing.columns[safe: existing.focusedIndex] else { return }
            (workspace, column) = (existing, added)
            focusWorkspace(id: existing.id, column: existing.focusedIndex)
        } else {
            addWorkspace(title: SessionHistory.title(of: record), cwd: directory, profileID: spaceID)
            guard let added = activeWorkspace, let first = added.columns.first else { return }
            (workspace, column) = (added, first)
        }
        let agent: DeferredAgentLaunch.Agent = switch record.agent {
        case .claude: .claude(resume: .session(record.sessionID), mode: Self.currentClaudeLaunchMode())
        case .codex: .codex(resume: .session(record.sessionID), mode: Self.currentCodexLaunchMode())
        }
        sideEffects.launchAgent(column, resumeLaunchCommand(agent, workingDirectory: directory, in: workspace, column: column))
        updateSidebar()
        focusActiveTerminal(in: window)
    }

    /// The launch line that resumes `agent` in `column`, with the space's
    /// brief: restores and Resume share it. A resumed conversation keeps
    /// the system prompt it recorded until it compacts, then rebuilds it
    /// from the flags of this launch. `workingDirectory` tells Codex the
    /// folder, which it would otherwise ask about when the one it recorded
    /// differs. The column then holds the session (see
    /// `SessionResumeState`), and the id in the agent's arguments proves it
    /// until its hooks do.
    func resumeLaunchCommand(
        _ agent: DeferredAgentLaunch.Agent, workingDirectory: String? = nil, in workspace: WorkspaceState, column: ColumnState
    ) -> String {
        let brief = spaceBriefInjection(for: workspace)
        if let sessionID = agent.sessionID {
            sessionResume.noteLaunch(of: sessionID, in: column, now: ProcessInfo.processInfo.systemUptime)
        }
        switch agent {
        case .claude(let resume, let mode):
            if let sessionID = agent.sessionID { column.prepareClaudeResume(sessionID: sessionID) }
            return Self.claudeCommand(resume: resume, mode: mode, briefFile: brief?.claudePromptFile)
        case .codex(let resume, let mode):
            if let sessionID = agent.sessionID { column.prepareCodexResume(sessionID: sessionID) }
            return Self.codexCommand(
                resume: resume,
                workingDirectory: workingDirectory,
                mode: mode,
                briefFile: Self.codexBriefFile(
                    from: brief, launchDirectory: workingDirectory ?? column.launchDirectory ?? workspace.cwd
                )
            )
        }
    }

    /// Brings forward the column that holds the session: a restored one
    /// resumes it then, as does one whose agent died on it. False when no
    /// column holds it.
    @discardableResult
    private func goToHeldSession(_ record: AgentSessionRecord) -> Bool {
        guard let held = HeldAgentSession.find(record.sessionID, in: agentSessionHolders(snapshot: ProcessSnapshot())),
              let workspace = workspaces.first(where: { $0.id == held.workspaceID }),
              let index = workspace.columns.firstIndex(where: { $0.id == held.columnID })
        else { return false }
        focusWorkspace(id: workspace.id, column: index)
        let column = workspace.columns[index]
        switch held.state {
        case .running:
            break
        case .restored:
            if resumeDeferredAgent(column, in: workspace) { updateSidebar() }
        case .exited:
            resumeExitedAgent(in: workspace, column: column)
        }
        return true
    }
}
