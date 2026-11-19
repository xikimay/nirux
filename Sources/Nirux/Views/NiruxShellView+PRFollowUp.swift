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
    let trackedSince = Date().timeIntervalSince1970
    /// By workspace: when the read that gave its pull request, and its
    /// feedback, started.
    var readAt: [String: TimeInterval] = [:]
    var feedbackReadAt: [String: TimeInterval] = [:]
    /// By workspace: the failure a round may take
    /// (`PRFollowUp.failureSignature`), and when Nirux first saw it.
    var redSince: [String: (signature: String, since: TimeInterval)] = [:]
    /// By repository root: the remote of each GitHub repository its remotes
    /// name, by lowercased `owner/name`.
    var remotes: [String: [String: String]] = [:]
    var readingRemotes: Set<String> = []
    /// Workspaces whose checkout is being read before a round.
    var checking: Set<String> = []
    /// By space: the setting, read again when its defaults.json changes.
    var settings: [String: FileBackedValue<Bool>] = [:]
    /// By workspace: the last decision logged.
    var logged: [String: String] = [:]
}

extension NiruxShellView {
    static let followUpLogger = Logger(subsystem: "com.xikimay.nirux", category: "followUp")

    /// Space Settings › Defaults, "Follow up on pull requests".
    func followsUpPullRequests(inSpace spaceID: String) -> Bool {
        if let setting = prFollowUpCenter.settings[spaceID] { return setting.value }
        guard let store = SpaceDefaultsStore(spaceID: spaceID) else { return false }
        let setting = FileBackedValue(url: store.fileURL, read: { _ in store.load().defaults.followsUpPullRequests }, write: { _, _ in })
        prFollowUpCenter.settings[spaceID] = setting
        return setting.value
    }

    /// At each turn end: a round may go now, or one may have ended.
    func followUpPullRequests() {
        for workspace in workspaces where workspace.prInfo != nil { followUpPullRequest(of: workspace) }
    }

    /// After each read of a task's pull request or its feedback, and each
    /// turn end: types the round the pull request needs (`PRFollowUp`)
    /// once its checkout, read now, says go.
    func followUpPullRequest(of workspace: WorkspaceState) {
        guard let pullRequest = workspace.prInfo, !pullRequest.url.isEmpty else { return }
        let center = prFollowUpCenter
        guard pullRequest.state.uppercased() == "OPEN" else {
            // Merged or closed: nothing more to follow.
            if center.file.value.pullRequests[pullRequest.url] != nil {
                center.file.update { $0.pullRequests[pullRequest.url] = nil }
            }
            return
        }
        guard Self.isTask(workspace), !workspace.isInactive, !workspace.isClosing,
              followsUpPullRequests(inSpace: workspace.profileID),
              let agent = followUpAgent(in: workspace)
        else { return }
        let now = Date().timeIntervalSince1970
        let facts = followUpFacts(for: workspace, pullRequest: pullRequest, agent: agent, now: now)
        let decided = decideFollowUp(of: workspace, pullRequest: pullRequest, agent: agent, facts: facts)
        // With the checkout unknown, nothing types: everything else says go?
        var probe = decided.entry
        var ready = facts
        ready.hasTrackedChanges = false
        guard case .wait = decided.action, case .type = PRFollowUp.next(&probe, ready),
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
    /// nothing was typed meanwhile. A round that didn't go in is dropped.
    private func typeFollowUpRound(of workspace: WorkspaceState, head: String?, hasTrackedChanges: Bool?) {
        // Hooks still in the queue may say the agent started working.
        AgentHookCenter.shared.drain()
        guard let pullRequest = workspace.prInfo, pullRequest.state.uppercased() == "OPEN", !workspace.isClosing,
              followsUpPullRequests(inSpace: workspace.profileID), let agent = followUpAgent(in: workspace)
        else { return }
        let now = Date().timeIntervalSince1970
        guard !isFollowUpRoundRunning(besides: pullRequest.url, now: now) else { return }
        var facts = followUpFacts(for: workspace, pullRequest: pullRequest, agent: agent, now: now)
        facts.localHead = head
        facts.hasTrackedChanges = hasTrackedChanges
        if hasTrackedChanges == false, workspace.gitContext?.identity.isDirty == true {
            Self.followUpLogger.log("#\(pullRequest.number, privacy: .public) untracked files in the checkout: not blocking")
        }
        let decided = decideFollowUp(of: workspace, pullRequest: pullRequest, agent: agent, facts: facts)
        guard case .type(let round, let prompt) = decided.action else { return }
        guard let pty = agent.column.pty, let paste = TypedPromptSanitizer.bracketedPaste(for: prompt) else {
            return cancelFollowUpRound(round, of: pullRequest)
        }
        typeMissionPrompt(paste, into: pty, keepingInFront: pty.foregroundProcess(snapshot: ProcessSnapshot())?.instance) { [weak self] typed in
            Self.followUpLogger.log("#\(pullRequest.number, privacy: .public) round \(round.kind.rawValue, privacy: .public): \(String(describing: typed), privacy: .public)")
            guard let self, typed != .sent else { return }
            self.cancelFollowUpRound(round, of: pullRequest)
        }
        scheduleMetadataRefresh()
    }

    private func cancelFollowUpRound(_ round: PRFollowUp.Round, of pullRequest: PRInfo) {
        prFollowUpCenter.file.update { store in
            store.update(pullRequest.url, now: Date().timeIntervalSince1970) { entry in
                if entry.rounds.last == round { entry.cancelRound() }
            }
        }
        scheduleMetadataRefresh()
    }

    /// Runs the decision on the pull request's entry, its last round ended
    /// first when its turn is over; a stop it raises marks the task.
    private func decideFollowUp(
        of workspace: WorkspaceState, pullRequest: PRInfo, agent: (column: ColumnState, index: Int), facts: PRFollowUp.Facts
    ) -> (action: PRFollowUp.Action, entry: PRFollowUp.Entry) {
        let snapshot = ProcessSnapshot()
        let (action, entry, raised) = prFollowUpCenter.file.update { store in
            var action = PRFollowUp.Action.none
            var raised = false
            store.update(pullRequest.url, now: facts.now, since: store.spacesOnSince[workspace.profileID]) { entry in
                if let last = entry.rounds.last, last.endedAt == nil, let pty = agent.column.pty,
                   pty.finishedTurn(afterTypingAt: last.typedAt),
                   pty.missionPromptRefusal(runningSince: facts.now, snapshot: snapshot) != .failedTurn {
                    entry.endRound(at: pty.agentLastTurnEndedAt)
                }
                let hadStop = entry.stop != nil
                action = PRFollowUp.next(&entry, facts)
                raised = !hadStop && entry.stop != nil
            }
            return (action, store.pullRequests[pullRequest.url] ?? PRFollowUp.Entry(), raised)
        }
        logFollowUp(action, of: workspace, pullRequest: pullRequest)
        if raised {
            if !(NSApp.isActive && workspace === activeWorkspace) { workspace.raiseNotification(.waiting) }
            scheduleMetadataRefresh()
        }
        return (action, entry)
    }

    /// The task's Claude in the pull request's checkout, running with
    /// Nirux's hooks.
    private func followUpAgent(in workspace: WorkspaceState) -> (column: ColumnState, index: Int)? {
        guard let target = pullRequestAgent(in: workspace), let column = workspace.columns[safe: target.columnIndex],
              let pty = column.pty, let foreground = pty.foregroundProcess(snapshot: ProcessSnapshot()),
              pty.agentTookPrompt(since: foreground) != nil
        else { return nil }
        return (column, target.columnIndex)
    }

    private func followUpFacts(
        for workspace: WorkspaceState, pullRequest: PRInfo, agent: (column: ColumnState, index: Int), now: TimeInterval
    ) -> PRFollowUp.Facts {
        let center = prFollowUpCenter
        let signature = PRFollowUp.failureSignature(pullRequest)
        if signature.isEmpty {
            center.redSince[workspace.id] = nil
        } else if center.redSince[workspace.id]?.signature != signature {
            center.redSince[workspace.id] = (signature, now)
        }
        let gate = PRFollowUp.gate(followUpAgentState(agent, in: workspace, now: now), now: now)
        return PRFollowUp.Facts(
            pullRequest: pullRequest, feedback: workspace.prFeedback, feedbackReadAt: center.feedbackReadAt[workspace.id],
            triage: followUpTriage(of: workspace, pullRequest: pullRequest), redSince: center.redSince[workspace.id]?.since,
            localHead: workspace.gitContext?.identity.head, baseRemote: followUpBaseRemote(of: workspace, pullRequest: pullRequest),
            hasTrackedChanges: nil, isInMergeQueue: mergeQueueHolds(pullRequest), readAt: center.readAt[workspace.id],
            agentRefusal: gate.refusal, agentIsBusy: gate.isBusy, trackedSince: center.trackedSince, now: now
        )
    }

    private func followUpAgentState(
        _ agent: (column: ColumnState, index: Int), in workspace: WorkspaceState, now: TimeInterval
    ) -> PRFollowUp.AgentState {
        let pty = agent.column.pty
        var waitsOnUser = false
        if case .waitsOnUser? = pty?.agentHold { waitsOnUser = true }
        let missions = MissionStore.shared
        let missionWaits = agent.column.agentUUID.map {
            missions.waitingQuestion(childWorkspaceID: workspace.id, childAgentUUID: $0) != nil
        } == true || missions.pendingPromptDeliveries(now: now).contains { missionRecipient(of: $0) === agent.column }
        return PRFollowUp.AgentState(
            refusal: pty.map { $0.missionPromptRefusal(runningSince: now, snapshot: ProcessSnapshot()) } ?? .noClaude,
            waitsOnUser: waitsOnUser, lastTurnEndedAt: pty?.agentLastTurnEndedAt ?? 0, missionWaits: missionWaits,
            isWatched: NSApp.isActive && workspace === activeWorkspace && workspace.focusedIndex == agent.index
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
    /// for a conflict's merge. Read off the main thread once per checkout:
    /// the follow-up runs again when it comes.
    private func followUpBaseRemote(of workspace: WorkspaceState, pullRequest: PRInfo) -> String? {
        let center = prFollowUpCenter
        guard pullRequest.mergeable == "CONFLICTING", let root = workspace.gitContext?.identity.repositoryRoot,
              let repository = Self.pullRequestRepository(pullRequest.url)
        else { return nil }
        if let remotes = center.remotes[root] { return remotes["\(repository.owner)/\(repository.name)"] }
        guard center.readingRemotes.insert(root).inserted else { return nil }
        DispatchQueue.global(qos: .utility).async {
            let remotes = GitHubBaseRemote.survey(at: root).gitHubRemotes
            DispatchQueue.main.async { [weak self, weak workspace] in
                guard let self else { return }
                self.prFollowUpCenter.readingRemotes.remove(root)
                self.prFollowUpCenter.remotes[root] = remotes
                if let workspace { self.followUpPullRequest(of: workspace) }
            }
        }
        return nil
    }

    /// A merge queue holds a pull request while any entry of a running
    /// queue for its repository isn't merged or stopped; a queue running
    /// in another Nirux holds them all.
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

    /// At most one round's turn runs across tasks: each may build and test.
    private func isFollowUpRoundRunning(besides url: String, now: TimeInterval) -> Bool {
        let center = prFollowUpCenter
        return center.file.value.pullRequests.contains { key, entry in
            guard key != url, let last = entry.rounds.last else { return false }
            return last.endedAt == nil && last.typedAt >= center.trackedSince && now < last.typedAt + PRFollowUp.roundLimit
        }
    }

    /// The user's Address or Why Failed took that feedback, that failure:
    /// no round takes them.
    func noteFollowUpTakenByUser(in workspace: WorkspaceState, feedback: [String] = [], failure: Bool = false) {
        guard let pullRequest = workspace.prInfo, followsUpPullRequests(inSpace: workspace.profileID) else { return }
        let signature = PRFollowUp.failureSignature(pullRequest)
        prFollowUpCenter.file.update { store in
            store.update(pullRequest.url, now: Date().timeIntervalSince1970) { entry in
                entry.handedFeedback += feedback.filter { !entry.handedFeedback.contains($0) }
                if failure, !signature.isEmpty, !entry.userFailures.contains(signature) { entry.userFailures.append(signature) }
            }
        }
    }

    /// Turned on, the space's tasks follow from now: feedback that came
    /// while it was off is the user's.
    func spaceDefaultsSaved(_ defaults: SpaceDefaults, replacing old: SpaceDefaults, spaceID: String) {
        guard defaults.followsUpPullRequests != old.followsUpPullRequests else { return }
        let now = Date().timeIntervalSince1970
        let isOn = defaults.followsUpPullRequests
        let urls = workspaces.filter { $0.profileID == spaceID }.compactMap(\.prInfo?.url)
        prFollowUpCenter.file.update { store in
            store.spacesOnSince[spaceID] = isOn ? now : nil
            guard isOn else { return }
            for url in urls { store.update(url, now: now) { $0.since = now } }
        }
        updateSidebar()
    }

    /// What the task's row says: the round whose turn runs, or the stop
    /// until a prompt goes into one of its agents.
    func followUpRow(of workspace: WorkspaceState) -> SidebarFollowUp? {
        guard let pullRequest = workspace.prInfo, pullRequest.state.uppercased() == "OPEN",
              followsUpPullRequests(inSpace: workspace.profileID), Self.isTask(workspace),
              let entry = prFollowUpCenter.file.value.pullRequests[pullRequest.url]
        else { return nil }
        if let stop = entry.stop {
            let lastPrompt = workspace.columns.compactMap { $0.pty?.agentLastPromptAt }.max() ?? 0
            return lastPrompt > stop.at ? nil : .stopped(PRFollowUp.stopText(stop, pullRequest: pullRequest))
        }
        guard let last = entry.rounds.last, last.endedAt == nil, last.settledAt == nil,
              last.typedAt >= prFollowUpCenter.trackedSince
        else { return nil }
        return .round(PRFollowUp.roundText(last.kind, number: entry.rounds.count))
    }

    /// Each change of decision, once: log category `followUp`.
    private func logFollowUp(_ action: PRFollowUp.Action, of workspace: WorkspaceState, pullRequest: PRInfo) {
        let line = switch action {
        case .none: "nothing to follow up"
        case .wait(let why): "waits: \(why)"
        case .type(let round, _): "types round \(round.kind.rawValue)"
        }
        guard prFollowUpCenter.logged[workspace.id] != line else { return }
        prFollowUpCenter.logged[workspace.id] = line
        Self.followUpLogger.log("#\(pullRequest.number, privacy: .public) \(line, privacy: .public)")
    }
}
