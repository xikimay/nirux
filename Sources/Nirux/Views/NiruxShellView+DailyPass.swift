import AppKit

// MARK: - The daily pass (docs/design/daily-pass.md)

/// The Lead's `record_review` and `daily_pass`: what its reviews found,
/// kept for the space (ReviewFindings), and what happened in the space
/// since its last pass (DailyPass), from Nirux's own records and GitHub;
/// the daily line Nirux types into each Lead once its pass is due, and the
/// note its row shows after.
extension NiruxShellView {
    /// Any task of the space, as `set_task_context` reaches them.
    func leadRecordReview(_ arguments: [String: Any], in space: WorkspaceProfile, lead leadID: String, answer: @escaping LeadAnswer) {
        let name = LeadTools.string(arguments, "task") ?? ""
        guard let task = spaceTask(name, in: space) else { return answer(noSpaceTask(name, in: space), true) }
        let title = MissionPromptText.quoted(task.title)
        if leadMission(of: task, lead: leadID) == nil, let refusal = leadRefusal(for: task, title: title) { return answer(refusal, true) }
        guard ReviewFindings.lines.fileURL(spaceID: space.id) != nil else { return answer("This space can’t keep review findings.", true) }
        let findings: [ReviewFindings.Finding]
        switch ReviewFindings.findings(arguments["findings"]) {
        case .success(let read): findings = read
        case .failure(let refusal): return answer(refusal.reason, true)
        }
        let review = ReviewFindings.Review(
            findings: findings, workspace: task.id, missionBranch: (leadMission(of: task, lead: leadID) ?? ownMission(of: task))?.branch,
            task: task.gitBranch ?? task.taskFolder ?? task.title, pullRequest: task.prInfo?.number,
            repository: repositoryAnchor(of: task, in: space)?.folder
        )
        ReviewFindings.record(review, spaceID: space.id) { outcome in
            switch outcome {
            case .recorded(let entry, let kinds): answer(ReviewFindings.answer(for: entry, title: title, kinds: kinds), false)
            case .notRecorded(let reason): answer("Nothing was recorded. " + reason, true)
            }
        }
    }

    /// Reads GitHub off the main thread, then answers the digest, marks
    /// its window read (unless GitHub may answer next time), and keeps the
    /// note the Lead's row shows.
    func leadDailyPass(in space: WorkspaceProfile, lead: WorkspaceState, answer: @escaping LeadAnswer) {
        let (window, next) = dailyPassState(inSpace: space.id).reading(now: Date().timeIntervalSince1970)
        gatherDailyPassFacts(in: space, lead: lead, window: window) { [weak self] facts in
            guard let self, let facts else { return answer("This space keeps no daily pass.", true) }
            let digest = DailyPass.digest(facts)
            // On what holds now: a check may have saved meanwhile.
            let saved = self.dailyPassState(inSpace: space.id)
                .afterReading(next, readsAgain: facts.readsAgain, note: facts.note(at: window.end), readUntil: digest.readUntil)
            self.saveDailyPassState(saved, spaceID: space.id)
            answer(digest.text, false)
        }
    }

    /// Writes a space's pass and shows it, unless the space was deleted
    /// meanwhile. One that can't be written stays as it was, and the
    /// checks wait `DailyPass.retryAfter` before trying again.
    @discardableResult
    func saveDailyPassState(_ state: DailyPassState, spaceID: String, now: TimeInterval = Date().timeIntervalSince1970) -> Bool {
        guard profiles.contains(where: { $0.id == spaceID }) else { return false }
        do {
            try state.save(spaceID: spaceID)
        } catch {
            NiruxDebugLog.log("Daily pass: couldn't record the pass: \(error)")
            dailyPassRetryAt[spaceID] = now + DailyPass.retryAfter
            return false
        }
        dailyPassStates[spaceID] = state
        updateSidebar()
        refreshSpaceSettingsLead()
        return true
    }

    /// What happened in the space in the window, read off the main thread
    /// for GitHub; nil for a space that keeps no pass.
    func gatherDailyPassFacts(
        in space: WorkspaceProfile, lead: WorkspaceState, window: DailyPass.Window,
        completion: @escaping @MainActor @Sendable (DailyPass.Facts?) -> Void
    ) {
        guard let briefURL = SpaceBrief.briefURL(spaceID: space.id) else { return completion(nil) }
        // Its workspaces closed since, by the sessions they held, too; not
        // one open in another space now.
        let open = workspaces.filter { $0.profileID == space.id }.map(\.id)
        let elsewhere = Set(workspaces.filter { $0.profileID != space.id }.map(\.id))
        let members = Set(open).union(sessionLedger.sessions(inSpace: space.id).compactMap(\.workspaceID).filter { !elsewhere.contains($0) })
        _ = MissionStore.shared.ensureLoaded()
        let missions = MissionStore.shared.missions.filter { mission in
            mission.parentWorkspaceID == lead.id || members.contains(mission.childWorkspaceID) || members.contains(mission.parentWorkspaceID)
        }
        let ciStore = ciTriageCenter.store
        let base = DailyPass.Facts(
            spaceName: space.name, window: window, findings: [], repositories: [], triagedRuns: [], flakyTests: [],
            missions: DailyPass.missionFacts(missions, window: window),
            proposals: RuleProposalStore(spaceID: space.id)?.load().proposals ?? [],
            briefRules: LearnedRules.learnedRules(in: LearnedRules.briefText(at: briefURL))
        )
        let folders = BoardSections.repositoryAnchors(space.anchors).compactMap(\.folder)
        let spaceID = space.id
        Self.readDailyPassSources(folders: folders, spaceID: spaceID, window: window) { repositories, findings in
            var facts = base
            facts.findings = findings
            facts.repositories = repositories
            (facts.triagedRuns, facts.flakyTests) = DailyPass.ciFacts(ciStore, repositories: repositories.map(\.name), window: window)
            completion(facts)
        }
    }

    // MARK: The daily line

    /// Whether a Lead's agent column may take the daily line now, and
    /// typing it there: tests replace them.
    typealias DailyPassQuietCheck = @MainActor (ColumnState) -> Bool
    typealias DailyPassSend = @MainActor (ColumnState, String) -> Void

    /// Once a minute on the app's shell; the user's absence counts from
    /// the Mac's last wake, its screens' wake or their unlock at the
    /// earliest: one of them may mean the user is back, in another app.
    func startDailyPassWatch() {
        guard dailyPassTimer == nil else { return }
        dailyPassTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkDailyPasses() }
        }
        let system = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        let wakes: [(NotificationCenter, Notification.Name)] = [
            (system, NSWorkspace.didWakeNotification), (system, NSWorkspace.screensDidWakeNotification),
            (distributed, Notification.Name("com.apple.screenIsUnlocked"))
        ]
        dailyPassWakeObservers = wakes.map { center, name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dailyPassWokeAt = Date().timeIntervalSince1970 }
            }
        }
    }

    /// For each space whose Lead has the daily pass on and due, once it is
    /// quiet: reads what happened, then types the daily line if anything
    /// did, else marks the pass checked. Quiet is asked again after the
    /// read: GitHub takes seconds.
    func checkDailyPasses(
        now: TimeInterval = Date().timeIntervalSince1970, isQuiet: DailyPassQuietCheck? = nil, send: DailyPassSend? = nil
    ) {
        let quiet = isQuiet ?? { [weak self] column in self?.dailyPassIsQuiet(column) == true }
        for lead in workspaces where lead.isLead && !lead.isClosing && !dailyPassChecks.contains(lead.profileID) {
            guard let space = profiles.first(where: { $0.id == lead.profileID }), dailyPassIsDue(inSpace: space.id, now: now),
                  let column = dailyPassColumn(of: lead), quiet(column)
            else { continue }
            dailyPassChecks.insert(space.id)
            let window = dailyPassState(inSpace: space.id).reading(now: now, extending: false).window
            gatherDailyPassFacts(in: space, lead: lead, window: window) { [weak self] facts in
                guard let self else { return }
                self.dailyPassChecks.remove(space.id)
                // Read again: the user, a pass or the Lead's end may have come meanwhile.
                guard let facts, self.dailyPassIsDue(inSpace: space.id, now: now),
                      self.workspaces.contains(where: { $0 === lead && !$0.isClosing }), self.dailyPassColumn(of: lead) === column
                else { return }
                var next = self.dailyPassState(inSpace: space.id)
                if facts.readsAgain && !facts.hasNews {
                    self.dailyPassRetryAt[space.id] = now + DailyPass.retryAfter
                } else if !facts.hasNews {
                    // The window is read: the next pass starts there.
                    (next.start, next.end, next.checkedAt) = (window.start, window.end, now)
                    self.saveDailyPassState(next, spaceID: space.id, now: now)
                } else if quiet(column) {
                    next.typedAt = now
                    // Never read yet: the next pass starts where this one did.
                    if next.end == nil { (next.start, next.end) = (window.start, window.start) }
                    // Recorded first: one that can't be would be typed again.
                    guard self.saveDailyPassState(next, spaceID: space.id, now: now) else { return }
                    if let send { send(column, DailyPass.prompt) } else { self.typeDailyPassLine(into: column) }
                }
            }
        }
    }

    /// The space's pass is on and due, and not waiting to retry.
    private func dailyPassIsDue(inSpace spaceID: String, now: TimeInterval) -> Bool {
        guard let defaults = SpaceDefaultsStore(spaceID: spaceID)?.load().defaults, defaults.dailyPassIsOn,
              (dailyPassRetryAt[spaceID] ?? 0) <= now
        else { return false }
        return DailyPass.isDue(dailyPassState(inSpace: spaceID), hour: defaults.dailyPassHour, now: now)
    }

    /// The column the Lead's Claude runs in.
    private func dailyPassColumn(of lead: WorkspaceState) -> ColumnState? {
        let agentUUID = leadMissionParent(inSpace: lead.profileID)?.agentUUID
        return lead.columns.first { !$0.isClosing && $0.agentUUID != nil && $0.agentUUID == agentUUID }
    }

    /// The Lead's prompt free with no question for the user, its last hook
    /// event `DailyPass.leadIdle` ago, nothing waiting to be typed into it
    /// (a Mission message, a Lead notice, a rule decision), the user away
    /// since the Mac woke, at least.
    func dailyPassIsQuiet(_ column: ColumnState) -> Bool {
        guard let pty = column.pty, let lead = workspaces.first(where: { $0.columns.contains { $0 === column } }) else { return false }
        let now = Date().timeIntervalSince1970
        let snapshot = ProcessSnapshot()
        let free = pty.acceptsMissionMessage(runningSince: now, snapshot: snapshot)
            && pty.agentQuestion(foreground: pty.foregroundProcess(snapshot: snapshot)) == nil
        let proposals = ruleProposals(inSpace: lead.profileID)
        let waiting = MissionStore.shared.pendingPromptDeliveries(now: now).contains { missionRecipient(of: $0) === column }
            || pendingLeadNotices.contains { notice in
                notice.workspaceID == lead.id && notice.agentUUID == column.agentUUID
                    && now - notice.queuedAt < MissionEventCLI.parentMessageLifetime
            }
            // Decisions a newer Nirux's file keeps are never told.
            || proposals.readOnlyReason == nil && !proposals.toTell.isEmpty
        return DailyPass.isQuiet(
            promptFree: free, lastHookAt: pty.lastAgentHookAt, messageWaiting: waiting,
            awaySince: catchUpState.tracker.awaySince.map { max($0, dailyPassWokeAt) }, now: now
        )
    }

    private func typeDailyPassLine(into column: ColumnState) {
        guard let input = TypedPromptSanitizer.terminalInput(for: DailyPass.prompt) else { return }
        column.pty?.sendRaw(input)
        missionWaits.noteTyped(into: column, at: Date().timeIntervalSince1970)
    }

    // MARK: The note

    /// The Lead row's line for a day after its space's last pass: its
    /// counts, and the rules proposed since.
    func dailyPassNote(inSpace spaceID: String, now: TimeInterval = Date().timeIntervalSince1970) -> String? {
        guard let note = dailyPassState(inSpace: spaceID).note, now - note.at < DailyPass.noteLifetime else { return nil }
        return "Daily pass · " + dailyPassCounts(note, spaceID: spaceID)
    }

    /// Space Settings › Lead's "Last pass" line; nil before any.
    func lastDailyPassText(inSpace spaceID: String) -> String? {
        let state = dailyPassState(inSpace: spaceID)
        if let note = state.note, note.at >= state.checkedAt ?? 0 {
            return "Last pass: \(DailyPass.clock(note.at)) · " + dailyPassCounts(note, spaceID: spaceID)
        }
        return state.checkedAt.map { "Last pass: \(DailyPass.clock($0)) · nothing had happened" }
    }

    /// A space's pass, read once, then kept by `saveDailyPassState` (the
    /// sidebar asks several times a second).
    func dailyPassState(inSpace spaceID: String) -> DailyPassState {
        if let state = dailyPassStates[spaceID] { return state }
        let state = DailyPassState.load(spaceID: spaceID)
        dailyPassStates[spaceID] = state
        return state
    }

    private func dailyPassCounts(_ note: DailyPass.Note, spaceID: String) -> String {
        let proposed = ruleProposals(inSpace: spaceID).proposals.filter { $0.proposedAt >= note.at }.count
        return DailyPass.noteCounts(note, rulesProposed: proposed)
    }

    // MARK: Space Settings › Lead

    func setDailyPass(_ on: Bool, spaceID: String) {
        changeSpaceDefaults(spaceID: spaceID) { $0.leadDailyPass = on ? nil : false }
        refreshSpaceSettingsLead()
    }

    func setDailyPassHour(_ hour: Int, spaceID: String) {
        changeSpaceDefaults(spaceID: spaceID) { $0.leadDailyPassHour = hour == DailyPass.defaultHour ? nil : hour }
        refreshSpaceSettingsLead()
    }

    /// The space's GitHub repositories (each repository's base remote) and
    /// what GitHub says of them in the window, and its recorded reviews.
    nonisolated private static func readDailyPassSources(
        folders: [String], spaceID: String, window: DailyPass.Window,
        completion: @escaping @MainActor @Sendable ([DailyPass.RepositoryReport], [ReviewFindings.Entry]) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let remotes = DailyPass.repositories(from: folders.map { ($0, GitHubBaseRemote.read(at: $0)) })
            var reports = DailyPass.readGitHub(remotes.gitHub.map(\.name), window: window, read: DailyPass.installedGitHub)
            for index in reports.indices { reports[index].folders = remotes.gitHub[index].folders }
            reports += remotes.unread
            let findings = ReviewFindings.lines.queue.sync {
                ReviewFindings.lines.trim(spaceID: spaceID)
                return ReviewFindings.lines.load(spaceID: spaceID)
            }
            DispatchQueue.main.async { @MainActor in completion(reports, findings) }
        }
    }
}
