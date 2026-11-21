import AppKit
import os

// MARK: - PR auto follow-up (docs/design/pr-follow-up.md)

/// What the shell keeps for the follow-up besides each pull request's entry
/// (`PRFollowUpStore`): when reads started, when failures were first seen,
/// the remotes of the repositories pull requests target.
@MainActor
final class PRFollowUpCenter {
    let file = FileBackedValue(url: PRFollowUpStore.url, read: { PRFollowUpStore.load(from: $0) }, write: { $0.save(to: $1) })
    /// When this Nirux started following.
    let trackedSince: TimeInterval
    /// By workspace: when the read that gave its PR feedback started.
    var feedbackReadAt: [String: TimeInterval] = [:]
    /// By workspace: the failure a round may take
    /// (`PRFollowUp.failureSignature`), and when Nirux first saw it.
    var redSince: [String: (signature: String, since: TimeInterval)] = [:]
    /// By repository root: the remote of each GitHub repository its remotes
    /// name, by lowercased `owner/name`, and when that was read.
    var remotes: [String: (byRepository: [String: String], readAt: TimeInterval)] = [:]
    var readingRemotes: Set<String> = []
    /// Workspaces whose checkout is being read before a round.
    var checking: Set<String> = []
    /// By space: the setting, read again when its defaults.json changes.
    var settings: [String: FileBackedValue<Bool>] = [:]
    /// By workspace: the last decision logged.
    var logged: [String: String] = [:]

    /// A checkout whose remotes named no repository is read again after
    /// this: a remote may have been added since.
    static let remotesLifetime: TimeInterval = 10 * 60

    init(trackedSince: TimeInterval = Date().timeIntervalSince1970) {
        self.trackedSince = trackedSince
    }

    /// Changes the entry of `url` (a new one follows from where its space's
    /// follow-up starts) and drops the quiet entries of pull requests not
    /// `open` (`PRFollowUpStore.prune`); returns the entry.
    @discardableResult
    func updateEntry(
        _ url: String, space: String, now: TimeInterval, open: Set<String>, _ change: (inout PRFollowUp.Entry) -> Void
    ) -> PRFollowUp.Entry {
        file.update { store in
            store.noteLaunch(at: trackedSince)
            store.update(url, now: now, since: store.followedSince(space: space), change)
            store.prune(now: now, keeping: open.union([url]))
            return store.pullRequests[url] ?? PRFollowUp.Entry()
        }
    }

    /// What became of the round of `url` Nirux typed. None of it went in:
    /// it never was. Some or all of it stayed in the prompt unsent: it
    /// counts (Claude gets it if someone presses Enter), but no turn of the
    /// agent is its, so it neither holds other tasks nor is judged.
    func noteTyped(_ typed: NiruxShellView.TypedMessage, round: PRFollowUp.Round, url: String, now: TimeInterval) {
        guard typed != .sent else { return }
        file.update { store in
            store.update(url, now: now) { entry in
                guard let last = entry.rounds.indices.last, entry.rounds[last].typedAt == round.typedAt else { return }
                guard typed != .left else { return entry.cancelRound() }
                entry.rounds[last].endedAt = entry.rounds[last].endedAt ?? now
                entry.rounds[last].settledAt = entry.rounds[last].settledAt ?? now
            }
        }
    }

    /// Where a space's follow-up starts (`PRFollowUpStore.followedSince`),
    /// this launch kept as the first one of the follow-up if none was.
    func followedSince(space: String) -> TimeInterval? {
        file.update { store in
            store.noteLaunch(at: trackedSince)
            return store.followedSince(space: space)
        }
    }
}

extension NiruxShellView {
    static let followUpLogger = Logger(subsystem: "com.xikimay.nirux", category: "followUp")

    /// Space Settings › Defaults, "Follow up on pull requests".
    func followsUpPullRequests(inSpace spaceID: String) -> Bool {
        if let setting = prFollowUpCenter.settings[spaceID] { return setting.value }
        guard let store = SpaceDefaultsStore(spaceID: spaceID) else { return SpaceDefaults().followsUpPullRequests }
        let setting = FileBackedValue(url: store.fileURL, read: { _ in store.load().defaults.followsUpPullRequests }, write: { _, _ in })
        prFollowUpCenter.settings[spaceID] = setting
        return setting.value
    }

    /// At each turn end: a round may go now, or one may have ended.
    func followUpPullRequests() {
        let followed = workspaces.filter { $0.prInfo != nil && isFollowedTask($0) }
        guard !followed.isEmpty else { return }
        let snapshot = ProcessSnapshot()
        for workspace in followed { followUpPullRequest(of: workspace, snapshot: snapshot) }
    }

    /// After each read of a task's pull request or its feedback, and each
    /// turn end: runs the decision (`PRFollowUp`), and types the round it
    /// gives once the checkout, read now, says go. Without an agent to
    /// type into, the decision still settles rounds and clears stops.
    func followUpPullRequest(of workspace: WorkspaceState, snapshot given: ProcessSnapshot? = nil) {
        guard let pullRequest = workspace.prInfo, !pullRequest.url.isEmpty else { return }
        let center = prFollowUpCenter
        guard pullRequest.state.uppercased() == "OPEN" else {
            // Merged or closed: nothing more to follow.
            if center.file.value.pullRequests[pullRequest.url] != nil {
                center.file.update { $0.pullRequests[pullRequest.url] = nil }
            }
            return
        }
        guard isFollowedTask(workspace) else { return }
        let now = Date().timeIntervalSince1970
        let snapshot = given ?? ProcessSnapshot()
        let target = followUpTarget(in: workspace, pullRequest: pullRequest, snapshot: snapshot)
        let facts = followUpFacts(for: workspace, pullRequest: pullRequest, target: target, snapshot: snapshot, now: now)
        let decided = decideFollowUp(of: workspace, pullRequest: pullRequest, target: target, facts: facts, snapshot: snapshot)
        // With the checkout unknown, nothing types: does everything else
        // say go?
        var probe = decided.entry
        var ready = facts
        ready.hasTrackedChanges = false
        guard target.column != nil, case .wait = decided.action, case .type = PRFollowUp.next(&probe, ready),
              !isFollowUpRoundRunning(besides: pullRequest.url, now: now),
              let root = workspace.gitContext?.identity.repositoryRoot,
              center.checking.insert(workspace.id).inserted
        else { return }
        let workspaceID = workspace.id
        DispatchQueue.global(qos: .utility).async {
            let head = GitDetect.head(at: root)
            let hasTrackedChanges = GitDetect.hasTrackedChanges(at: root)
            DispatchQueue.main.async { [weak self, weak workspace] in
                self?.prFollowUpCenter.checking.remove(workspaceID)
                guard let self, let workspace else { return }
                self.typeFollowUpRound(of: workspace, head: head, hasTrackedChanges: hasTrackedChanges)
            }
        }
    }

    /// Decides again with the checkout as git says it now, and types the
    /// round if one goes: through the Mission typing path, Enter only when
    /// nothing was typed meanwhile. A round none of which went in is
    /// dropped; one left in the prompt counts, and the user hears of it.
    private func typeFollowUpRound(of workspace: WorkspaceState, head: String?, hasTrackedChanges: Bool?) {
        // Hooks still in the queue may say the agent started working.
        AgentHookCenter.shared.drain()
        guard let pullRequest = workspace.prInfo, pullRequest.state.uppercased() == "OPEN", isFollowedTask(workspace) else { return }
        let now = Date().timeIntervalSince1970
        let snapshot = ProcessSnapshot()
        let target = followUpTarget(in: workspace, pullRequest: pullRequest, snapshot: snapshot)
        guard let column = target.column, !isFollowUpRoundRunning(besides: pullRequest.url, now: now) else { return }
        var facts = followUpFacts(for: workspace, pullRequest: pullRequest, target: target, snapshot: snapshot, now: now)
        facts.localHead = head
        facts.hasTrackedChanges = hasTrackedChanges
        let untracked = hasTrackedChanges == false && workspace.gitContext?.identity.isDirty == true
        let decided = decideFollowUp(
            of: workspace, pullRequest: pullRequest, target: target, facts: facts, snapshot: snapshot,
            note: untracked ? "untracked files don't block" : nil
        )
        guard case .type(let round, let prompt) = decided.action else { return }
        guard let pty = column.pty, let paste = TypedPromptSanitizer.bracketedPaste(for: prompt) else {
            prFollowUpCenter.noteTyped(.left, round: round, url: pullRequest.url, now: now)
            return scheduleMetadataRefresh()
        }
        let title = MissionPromptText.quoted(workspace.title)
        typeMissionPrompt(paste, into: pty, keepingInFront: pty.foregroundProcess(snapshot: snapshot)?.instance) { [weak self] typed in
            Self.followUpLogger.log(
                "#\(pullRequest.number, privacy: .public) round \(round.kind.rawValue, privacy: .public): \(String(describing: typed), privacy: .public)"
            )
            guard let self else { return }
            self.prFollowUpCenter.noteTyped(typed, round: round, url: pullRequest.url, now: Date().timeIntervalSince1970)
            self.reportUnsent(typed, what: "an automatic follow-up round", for: title, telling: nil)
            self.scheduleMetadataRefresh()
        }
        scheduleMetadataRefresh()
    }

    /// The pull requests open in a workspace, followed or not: their entries
    /// outlive a quiet month.
    private var openPullRequests: Set<String> {
        Set(workspaces.compactMap { $0.isClosing || $0.prInfo?.state.uppercased() != "OPEN" ? nil : $0.prInfo?.url })
    }

    /// A task of a space that follows its pull requests.
    private func isFollowedTask(_ workspace: WorkspaceState) -> Bool {
        Self.isTask(workspace) && !workspace.isInactive && !workspace.isClosing && followsUpPullRequests(inSpace: workspace.profileID)
    }

    /// The column whose Claude the decision reads: the one the open round
    /// went to while it is there, else the task's Claude in the pull
    /// request's checkout, running with Nirux's hooks. `roundAgentLeft`:
    /// the open round's Claude is gone (its column closed, it quit, another
    /// one started there), so its turn is over.
    private func followUpTarget(
        in workspace: WorkspaceState, pullRequest: PRInfo, snapshot: ProcessSnapshot
    ) -> (column: ColumnState?, index: Int, roundAgentLeft: Bool) {
        let open = prFollowUpCenter.file.value.pullRequests[pullRequest.url]?.rounds.last
            .flatMap { $0.endedAt == nil && $0.settledAt == nil ? $0 : nil }
        if let open, let agent = open.agent {
            guard let index = workspace.columns.firstIndex(where: { $0.agentUUID == agent }) else { return (nil, 0, true) }
            let column = workspace.columns[index]
            let refusal = column.pty?.missionPromptRefusal(runningSince: open.typedAt, snapshot: snapshot) ?? .noClaude
            return (column, index, refusal == .noClaude || refusal == .restarted)
        }
        guard let target = pullRequestAgent(in: workspace, snapshot: snapshot), let column = workspace.columns[safe: target.columnIndex],
              let pty = column.pty, let foreground = pty.foregroundProcess(snapshot: snapshot),
              pty.agentTookPrompt(since: foreground) != nil
        else { return (nil, 0, false) }
        return (column, target.columnIndex, false)
    }

    /// Runs the decision on the pull request's entry, after ending its open
    /// round when its turn is over and noting a stop the user took; a stop
    /// it raises marks the task.
    private func decideFollowUp(
        of workspace: WorkspaceState, pullRequest: PRInfo, target: (column: ColumnState?, index: Int, roundAgentLeft: Bool),
        facts: PRFollowUp.Facts, snapshot: ProcessSnapshot, note: String? = nil
    ) -> (action: PRFollowUp.Action, entry: PRFollowUp.Entry) {
        let pty = target.column?.pty
        var action = PRFollowUp.Action.none
        var raised = false
        let entry = prFollowUpCenter.updateEntry(
            pullRequest.url, space: workspace.profileID, now: facts.now, open: openPullRequests
        ) { entry in
            if let last = entry.rounds.last, last.endedAt == nil {
                if target.roundAgentLeft {
                    entry.endRound(at: facts.now)
                } else if let pty, pty.finishedTurn(afterTypingAt: last.typedAt),
                          pty.missionPromptRefusal(runningSince: facts.now, snapshot: snapshot) != .failedTurn {
                    // A session end sets no turn end of its own.
                    entry.endRound(at: max(pty.agentLastTurnEndedAt, last.typedAt))
                }
            }
            let before = entry.stop
            action = PRFollowUp.next(&entry, facts)
            raised = entry.stop != nil && entry.stop?.at != before?.at
            if let stop = entry.stop, stop.seenAt == nil, Self.lastUserPrompt(in: workspace) > stop.at {
                entry.stop?.seenAt = facts.now
            }
        }
        logFollowUp(action, of: workspace, pullRequest: pullRequest, note: note)
        if raised {
            if !(NSApp.isActive && workspace === activeWorkspace) { workspace.raiseNotification(.waiting) }
            scheduleMetadataRefresh()
        }
        return (action, entry)
    }

    private func followUpFacts(
        for workspace: WorkspaceState, pullRequest: PRInfo, target: (column: ColumnState?, index: Int, roundAgentLeft: Bool),
        snapshot: ProcessSnapshot, now: TimeInterval
    ) -> PRFollowUp.Facts {
        let center = prFollowUpCenter
        let signature = PRFollowUp.failureSignature(pullRequest)
        if signature.isEmpty {
            center.redSince[workspace.id] = nil
        } else if center.redSince[workspace.id]?.signature != signature {
            center.redSince[workspace.id] = (signature, now)
        }
        let gate = target.column.map {
            PRFollowUp.gate(followUpAgentState($0, index: target.index, in: workspace, snapshot: snapshot, now: now), now: now)
        } ?? ("no Claude with Nirux's hooks in the checkout", false)
        return PRFollowUp.Facts(
            pullRequest: pullRequest, feedback: workspace.prFeedback,
            followedSince: center.followedSince(space: workspace.profileID), feedbackReadAt: center.feedbackReadAt[workspace.id],
            triage: followUpTriage(of: workspace, pullRequest: pullRequest), redSince: center.redSince[workspace.id]?.since,
            localHead: workspace.gitContext?.identity.head, baseRemote: followUpBaseRemote(of: workspace, pullRequest: pullRequest),
            hasTrackedChanges: nil, isInMergeQueue: mergeQueueHolds(pullRequest), readAt: workspace.pullRequestReadAt,
            agent: target.column?.agentUUID, agentRefusal: gate.refusal, agentIsBusy: gate.isBusy,
            trackedSince: center.trackedSince, now: now
        )
    }

    private func followUpAgentState(
        _ column: ColumnState, index: Int, in workspace: WorkspaceState, snapshot: ProcessSnapshot, now: TimeInterval
    ) -> PRFollowUp.AgentState {
        let pty = column.pty
        var waitsOnUser = false
        if case .waitsOnUser? = pty?.agentHold { waitsOnUser = true }
        let missions = MissionStore.shared
        let missionWaits = column.agentUUID.map {
            missions.waitingQuestion(childWorkspaceID: workspace.id, childAgentUUID: $0) != nil
        } == true || missions.pendingPromptDeliveries(now: now).contains { missionRecipient(of: $0) === column }
        return PRFollowUp.AgentState(
            refusal: pty.map { $0.missionPromptRefusal(runningSince: now, snapshot: snapshot) } ?? .noClaude,
            waitsOnUser: waitsOnUser, lastTurnEndedAt: pty?.agentLastTurnEndedAt ?? 0, missionWaits: missionWaits,
            isWatched: NSApp.isActive && workspace === activeWorkspace && workspace.focusedIndex == index
        )
    }

    /// What the triage said of the checks red now; off with the option.
    private func followUpTriage(of workspace: WorkspaceState, pullRequest: PRInfo) -> PRFollowUp.Triage {
        let red = CIFailure.redChecks(pullRequest)
        guard ciTriageCenter.isEnabled, !red.isEmpty else { return .off }
        let signature = CITriage.signature(of: red)
        guard ciTriageCenter.inFlight[workspace.id] != signature, let triage = workspace.ciTriage,
              triage.signature == signature, triage.retryAt == nil
        else { return .pending }
        return .done(triage.verdict)
    }

    /// The checkout's remote for the repository the pull request targets,
    /// for a conflict's merge, read off the main thread: the follow-up runs
    /// again when it comes. A failed read isn't kept; one that found no
    /// such remote is read again after a while.
    private func followUpBaseRemote(of workspace: WorkspaceState, pullRequest: PRInfo) -> String? {
        let center = prFollowUpCenter
        guard pullRequest.mergeable == "CONFLICTING", let root = workspace.gitContext?.identity.repositoryRoot,
              let repository = Self.pullRequestRepository(pullRequest.url)
        else { return nil }
        let key = "\(repository.owner)/\(repository.name)"
        if let read = center.remotes[root],
           read.byRepository[key] != nil || Date().timeIntervalSince1970 - read.readAt < PRFollowUpCenter.remotesLifetime {
            return read.byRepository[key]
        }
        guard center.readingRemotes.insert(root).inserted else { return nil }
        DispatchQueue.global(qos: .utility).async {
            let survey = GitHubBaseRemote.survey(at: root)
            let readAt = Date().timeIntervalSince1970
            DispatchQueue.main.async { [weak self, weak workspace] in
                guard let self else { return }
                self.prFollowUpCenter.readingRemotes.remove(root)
                guard survey.read != .unread, survey.read != .notARepository else { return }
                self.prFollowUpCenter.remotes[root] = (survey.gitHubRemotes, readAt)
                if let workspace { self.followUpPullRequest(of: workspace) }
            }
        }
        return nil
    }

    /// A running merge queue holds a pull request while its entry isn't
    /// merged or stopped; a queue running in another Nirux holds every pull
    /// request of its repository.
    private func mergeQueueHolds(_ pullRequest: PRInfo) -> Bool {
        guard let repository = Self.pullRequestRepository(pullRequest.url) else { return false }
        return mergeQueues.values.contains { queue in
            guard queue.queueRepository == repository else { return false }
            if queue.runsElsewhere { return true }
            guard queue.isRunning, let entries = queue.engine?.entries else { return false }
            return entries.contains { entry in
                switch entry.step {
                case .done, .stopped: false
                default: entry.number == pullRequest.number
                }
            }
        }
    }

    /// `https://<host>/<owner>/<name>/pull/<n>`'s repository.
    nonisolated static func pullRequestRepository(_ url: String) -> GitHubRepository? {
        guard let components = URLComponents(string: url), let host = components.host else { return nil }
        let path = components.path.split(separator: "/").map(String.init)
        guard path.count >= 3, path[2] == "pull" else { return nil }
        return GitHubRepository(host: host, owner: path[0], name: path[1])
    }

    /// At most one round's turn runs across tasks, each may build and test:
    /// a round counts while its pull request is a followed task's.
    private func isFollowUpRoundRunning(besides url: String, now: TimeInterval) -> Bool {
        let center = prFollowUpCenter
        let followed = Set(workspaces.filter(isFollowedTask).compactMap(\.prInfo?.url))
        return center.file.value.pullRequests.contains { key, entry in
            guard key != url, followed.contains(key), let last = entry.rounds.last else { return false }
            return last.endedAt == nil && last.typedAt >= center.trackedSince && now < last.typedAt + PRFollowUp.roundLimit
        }
    }

    /// The user's Address or Why Failed took that feedback, that failure:
    /// no round takes them, the setting on or not yet.
    func noteFollowUpTakenByUser(in workspace: WorkspaceState, feedback: [String] = [], failure: Bool = false) {
        guard let pullRequest = workspace.prInfo, pullRequest.state.uppercased() == "OPEN" else { return }
        let signature = PRFollowUp.failureSignature(pullRequest)
        prFollowUpCenter.updateEntry(
            pullRequest.url, space: workspace.profileID, now: Date().timeIntervalSince1970, open: openPullRequests
        ) { entry in
            entry.handedFeedback += feedback.filter { !entry.handedFeedback.contains($0) }
            if failure, !signature.isEmpty, !entry.userFailures.contains(signature) { entry.userFailures.append(signature) }
        }
    }

    /// Turned on, the space's pull requests follow from now: feedback that
    /// came while it was off is the user's.
    func spaceDefaultsSaved(_ defaults: SpaceDefaults, replacing old: SpaceDefaults, spaceID: String) {
        guard defaults.followsUpPullRequests != old.followsUpPullRequests else { return }
        let now = Date().timeIntervalSince1970
        prFollowUpCenter.file.update { $0.spacesOnSince[spaceID] = defaults.followsUpPullRequests ? now : nil }
        updateSidebar()
    }

    /// What the task's row says: the round whose turn runs, or the stop on
    /// the pull request's head until the user takes it (a prompt of theirs
    /// into one of its agents).
    func followUpRow(of workspace: WorkspaceState) -> SidebarFollowUp? {
        guard let pullRequest = workspace.prInfo, pullRequest.state.uppercased() == "OPEN", isFollowedTask(workspace),
              let entry = prFollowUpCenter.file.value.pullRequests[pullRequest.url]
        else { return nil }
        if let stop = entry.stop {
            guard stop.head == pullRequest.headRefOid, stop.seenAt == nil, Self.lastUserPrompt(in: workspace) <= stop.at else { return nil }
            return .stopped(PRFollowUp.stopText(stop, pullRequest: pullRequest))
        }
        guard let last = entry.rounds.last, last.endedAt == nil, last.settledAt == nil,
              last.typedAt >= prFollowUpCenter.trackedSince
        else { return nil }
        return .round(PRFollowUp.roundText(last.kind, number: entry.rounds.count))
    }

    /// When a prompt last went into one of the workspace's agents (see
    /// `PtySession.agentLastUserPromptAt`).
    private static func lastUserPrompt(in workspace: WorkspaceState) -> TimeInterval {
        workspace.columns.compactMap { $0.pty?.agentLastUserPromptAt }.max() ?? 0
    }

    /// Each change of decision, once: log category `followUp`.
    private func logFollowUp(_ action: PRFollowUp.Action, of workspace: WorkspaceState, pullRequest: PRInfo, note: String?) {
        let decision = switch action {
        case .none: "nothing to follow up"
        case .wait(let why): "waits: \(why)"
        case .type(let round, _): "types round \(round.kind.rawValue)"
        }
        let line = note.map { "\(decision) (\($0))" } ?? decision
        guard prFollowUpCenter.logged[workspace.id] != line else { return }
        prFollowUpCenter.logged[workspace.id] = line
        Self.followUpLogger.log("#\(pullRequest.number, privacy: .public) \(line, privacy: .public)")
    }
}
