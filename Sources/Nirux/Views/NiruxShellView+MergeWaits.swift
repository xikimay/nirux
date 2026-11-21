import os
import AppKit

// MARK: - Merge waits (docs/design/task-dependencies.md)

/// What the shell keeps of merge waits between reads, in memory.
struct MergeWaitTracking {
    /// The reading each wait was last looked up after, by wait id: GitHub
    /// is asked once per change of what the reads say.
    var lookedUpAfter: [String: String] = [:]
    var lookingUp: Set<String> = []
    /// Look-ups GitHub left unanswered in a row, by wait id.
    var unanswered: [String: Int] = [:]
    /// The `lookUpInterval` window each merged message was last tried in.
    var triedIn: [String: Int] = [:]
    /// Merged messages whose Lead heard they couldn't go yet.
    var heldBack: Set<String> = []
}

/// `tell`'s `after`: a message held on the task it is for until another
/// task's pull request merges, then sent as the Lead's tell. Nothing here
/// merges anything.
extension NiruxShellView {
    private static let mergeWaitLog = Logger(subsystem: "com.xikimay.nirux", category: "mergeWait")

    /// The workspaces a wait follows: their pull request is read at the
    /// hot cadence, archived or not, away from Nirux too.
    var awaitedWorkspaceIDs: Set<String> {
        Set(workspaces.lazy.flatMap(\.mergeWaits).filter { $0.mergedAt == nil }.map(\.awaited.workspaceID))
    }

    /// Whether reads of `workspace`'s pull request go on.
    func followsPullRequest(_ workspace: WorkspaceState) -> Bool {
        !workspace.isInactive || awaitedWorkspaceIDs.contains(workspace.id)
    }

    // MARK: Holding a tell

    /// `tell` with `after`: `message` waits on `workspace` until the task
    /// named `name` has its pull request merged; at once if it already has.
    func holdTell(
        _ message: String, to workspace: WorkspaceState, after name: String, in space: WorkspaceProfile,
        lead: NewTask.MissionParent, now: TimeInterval, answer: @escaping LeadAnswer
    ) {
        guard let awaited = spaceTask(name, in: space) else { return answer(noSpaceTask(name, in: space), true) }
        let title = MissionPromptText.quoted(workspace.title)
        guard awaited !== workspace else {
            return answer("“\(title)” can't wait for its own pull request: name the task whose pull request must merge first.", true)
        }
        if leadMission(of: workspace, lead: lead.workspaceID) == nil, let refusal = leadRefusal(for: workspace, title: title) {
            return answer(refusal, true)
        }
        guard !awaited.isFolderTask, Self.isTask(awaited) else {
            return answer("“\(MissionPromptText.quoted(awaited.title))” has no pull request to wait for: "
                + "only a task in a worktree of one of the space's repositories has one.", true)
        }
        var wait = MergeWait(
            id: UUID().uuidString, awaited: MergeWait.Awaited(workspaceID: awaited.id, title: awaited.title),
            action: .tell(message: message), createdAt: now
        )
        switch wait.step(after: .read(awaited.prInfo)) {
        case .release:
            tellTask(message, to: workspace, lead: lead) { text, isError in
                answer("\(wait.awaitedLongName) is merged already: " + text, isError)
            }
        case .fail(let failure):
            answer("\(wait.sentence(failure)): nothing is held. Tell it again once there is a pull request to wait for.", true)
        case .keep, .lookUp:
            workspace.mergeWaits.append(wait)
            saveState()
            updateSidebar()
            answer("Held: Nirux types it into “\(title)”’s prompt as your tell once \(wait.awaitedLongName) merges"
                + (wait.awaited.pullRequest == nil ? " (it has no pull request open yet: the first one it opens counts)" : "")
                + ". If that pull request closes without merging, or “\(MissionPromptText.quoted(awaited.title))” closes first, "
                + "the message isn't typed and you hear it.", false)
        }
    }

    // MARK: Following the awaited task

    /// A read of `workspace`'s pull request found `info` (nil: none) at
    /// `now`: each wait on it takes it.
    func followMergeWaits(awaiting workspace: WorkspaceState, read info: PRInfo?, now: TimeInterval) {
        let key = Self.readingKey(.read(info), now: now)
        for holder in workspaces where !holder.isClosing {
            var renamed = false
            for index in holder.mergeWaits.indices where holder.mergeWaits[index].awaited.workspaceID == workspace.id
                && holder.mergeWaits[index].awaited.title != workspace.title {
                holder.mergeWaits[index].awaited.title = workspace.title
                renamed = true
            }
            if renamed { saveState() }
            for wait in holder.mergeWaits where wait.awaited.workspaceID == workspace.id {
                settleMergeWait(wait.id, of: holder.id, after: .read(info), key: key, now: now)
            }
        }
    }

    /// `workspace` closes: the messages it holds go untyped, and each wait
    /// on it asks GitHub about its pull request.
    func closeMergeWaits(of workspace: WorkspaceState, now: TimeInterval) {
        let held = workspace.mergeWaits
        workspace.mergeWaits = []
        for wait in held {
            guard case .tell(let message) = wait.action else { continue }
            noticeLead(of: workspace, "“\(MissionPromptText.quoted(workspace.title))” closed: your message "
                + (wait.mergedAt == nil ? "held until \(wait.awaitedLongName) merges" : "for after \(wait.awaitedLongName)")
                + " wasn't typed. It said: “\(Self.heldQuote(message, MergeWait.noticeQuoteLength))”")
        }
        for holder in workspaces where !holder.isClosing {
            for wait in holder.mergeWaits where wait.awaited.workspaceID == workspace.id {
                // GitHub gets its tries from now.
                mergeWaitTracking.unanswered[wait.id] = nil
                settleMergeWait(wait.id, of: holder.id, after: .gone, key: Self.readingKey(.gone, now: now), now: now)
            }
        }
        if !held.isEmpty { saveState() }
    }

    /// `close_task` read GitHub's word on `task`'s branch before closing
    /// it: the waits on it take that answer, when it is about the pull
    /// request they recorded, or, with none recorded, one that merged the
    /// branch's tip (a reused branch name has older ones).
    func closeMergeWaits(of task: WorkspaceState, inspected inspection: WorktreeCleanup.Inspection, now: TimeInterval) {
        guard case .inspected(let report) = inspection, let pullRequest = report.pullRequest else { return }
        let found = MergeWait.LookedUp(number: pullRequest.number, state: pullRequest.state, url: pullRequest.url)
        for holder in workspaces where !holder.isClosing {
            for wait in holder.mergeWaits where wait.awaited.workspaceID == task.id {
                let isTheirs = wait.awaited.pullRequest.map { $0.url == pullRequest.url } ?? report.mergedHoldsTip
                guard isTheirs else { continue }
                settleMergeWait(wait.id, of: holder.id, after: .lookedUp(found, awaitedGone: true), key: "closed", now: now)
            }
        }
    }

    /// After a restore: those whose task didn't come back ask GitHub, and
    /// merged messages wait one window for their agents to resume.
    func restoreMergeWaits(now: TimeInterval) {
        let window = Int(now / MergeWait.lookUpInterval)
        for wait in workspaces.lazy.flatMap(\.mergeWaits) where wait.mergedAt != nil { mergeWaitTracking.triedIn[wait.id] = window }
        sweepMergeWaits(now: now)
    }

    /// Each heartbeat, and away from Nirux too: a wait
    /// whose task is gone asks GitHub again, and a merged message that
    /// couldn't go is tried again, once per `lookUpInterval`, for a day.
    func sweepMergeWaits(now: TimeInterval) {
        let present = Set(workspaces.lazy.filter { !$0.isClosing }.map(\.id))
        let window = Int(now / MergeWait.lookUpInterval)
        for holder in workspaces where !holder.isClosing {
            for wait in holder.mergeWaits {
                if wait.isPastDelivery(at: now) {
                    dropUndelivered(wait, of: holder)
                } else if wait.mergedAt != nil {
                    if mergeWaitTracking.triedIn[wait.id] != window { deliverMergeWait(wait.id, of: holder, now: now) }
                } else if !present.contains(wait.awaited.workspaceID) {
                    settleMergeWait(wait.id, of: holder.id, after: .gone, key: Self.readingKey(.gone, now: now), now: now)
                }
            }
        }
    }

    /// Away from Nirux the heartbeat stops: the pull requests a wait follows
    /// are still read when due. Their git state is read too, which the read
    /// after this one needs: no tick keeps it current meanwhile.
    func refreshAwaitedPullRequests() {
        let awaited = awaitedWorkspaceIDs
        guard !awaited.isEmpty else { return }
        let tiers = gitRefreshTiers.filter { awaited.contains($0.workspace.id) }
        let due = gitRefresh.pullRequestsDue(tiers, awaited: awaited)
        for (workspace, tier) in tiers where due.contains(where: { $0 === workspace }) {
            gitRefresh.refreshNow(workspace, tier: tier)
        }
        refreshPRInfo(for: due)
    }

    /// The step `reading` takes the wait to, if both are still there.
    /// `key`: what a look-up it leads to was asked after (`readingKey`).
    private func settleMergeWait(_ waitID: String, of holderID: String, after reading: MergeWait.Reading, key: String, now: TimeInterval) {
        guard let holder = workspaces.first(where: { $0.id == holderID && !$0.isClosing }),
              let index = holder.mergeWaits.firstIndex(where: { $0.id == waitID })
        else { return }
        let before = holder.mergeWaits[index]
        var wait = before
        let step = wait.step(after: reading)
        if step != .keep || wait != before {
            Self.mergeWaitLog.info("wait=\(waitID, privacy: .public) step=\(String(describing: step), privacy: .public)")
        }
        switch step {
        case .keep, .lookUp:
            if wait != before {
                holder.mergeWaits[index] = wait
                saveState()
            }
            if step == .lookUp { lookUpMergeWait(wait, of: holderID, after: key) }
        case .release:
            wait.mergedAt = now
            holder.mergeWaits[index] = wait
            forgetMergeWait(waitID)
            saveState()
            deliverMergeWait(waitID, of: holder, now: now)
        case .fail(let failure):
            holder.mergeWaits.remove(at: index)
            forgetMergeWait(waitID)
            saveState()
            updateSidebar()
            guard case .tell(let message) = wait.action else { return }
            noticeLead(of: holder, "\(wait.sentence(failure)): your message for “\(MissionPromptText.quoted(holder.title))” "
                + "wasn't typed. It said: “\(Self.heldQuote(message, MergeWait.noticeQuoteLength))”")
        }
    }

    /// Asks GitHub about the wait's pull request, once per reading.
    private func lookUpMergeWait(_ wait: MergeWait, of holderID: String, after key: String) {
        guard let url = wait.awaited.pullRequest?.url, mergeWaitTracking.lookedUpAfter[wait.id] != key,
              mergeWaitTracking.lookingUp.insert(wait.id).inserted
        else { return }
        mergeWaitTracking.lookedUpAfter[wait.id] = key
        let lookUp = mergeWaitLookUp
        Self.offMain({ lookUp(url) }) { [weak self] result in
            guard let self else { return }
            self.mergeWaitTracking.lookingUp.remove(wait.id)
            let gone = !self.workspaces.contains { $0.id == wait.awaited.workspaceID && !$0.isClosing }
            let now = Date().timeIntervalSince1970
            switch result {
            case .success(let found):
                self.mergeWaitTracking.unanswered[wait.id] = nil
                self.settleMergeWait(wait.id, of: holderID, after: .lookedUp(found, awaitedGone: gone), key: key, now: now)
            case .failure(let failure):
                let attempt = self.mergeWaitTracking.unanswered[wait.id, default: 0] + 1
                self.mergeWaitTracking.unanswered[wait.id] = attempt
                self.settleMergeWait(
                    wait.id, of: holderID, after: .unanswered(failure.reason, awaitedGone: gone, attempt: attempt), key: key, now: now
                )
            }
        }
    }

    /// The merged wait's message goes as the Lead's tell would now. One
    /// that can't (no Lead, no agent to take it) stays, tried again by
    /// `sweepMergeWaits`; the Lead hears it once.
    private func deliverMergeWait(_ waitID: String, of holder: WorkspaceState, now: TimeInterval) {
        guard let wait = holder.mergeWaits.first(where: { $0.id == waitID }), case .tell(let message) = wait.action else { return }
        mergeWaitTracking.triedIn[waitID] = Int(now / MergeWait.lookUpInterval)
        guard let lead = leadMissionParent(inSpace: holder.profileID) else {
            return Self.mergeWaitLog.info("wait=\(waitID, privacy: .public) merged, with no Lead to send it")
        }
        let merged = "\(wait.awaitedLongName) merged"
        tellTask(message, to: holder, lead: lead) { [weak self] text, isError in
            guard let self else { return }
            let title = MissionPromptText.quoted(holder.title)
            guard !isError else {
                guard self.mergeWaitTracking.heldBack.insert(waitID).inserted else { return }
                return self.tellProposer(lead, "\(merged), but your message for “\(title)” can't go yet: \(text) "
                    + "Nirux tries again every \(Int(MergeWait.lookUpInterval / 60)) minutes for a day.")
            }
            holder.mergeWaits.removeAll { $0.id == waitID }
            self.forgetMergeWait(waitID)
            self.saveState()
            self.updateSidebar()
            self.tellProposer(lead, "\(merged): \(text)")
        }
    }

    /// A day after its merge, a message that never could go.
    private func dropUndelivered(_ wait: MergeWait, of holder: WorkspaceState) {
        holder.mergeWaits.removeAll { $0.id == wait.id }
        forgetMergeWait(wait.id)
        saveState()
        updateSidebar()
        guard case .tell(let message) = wait.action else { return }
        noticeLead(of: holder, "\(wait.awaitedLongName) merged a day ago, and your message for “\(MissionPromptText.quoted(holder.title))” "
            + "couldn't go since: Nirux dropped it. It said: “\(Self.heldQuote(message, MergeWait.noticeQuoteLength))”")
    }

    private func forgetMergeWait(_ waitID: String) {
        mergeWaitTracking.lookedUpAfter[waitID] = nil
        mergeWaitTracking.unanswered[waitID] = nil
        mergeWaitTracking.triedIn[waitID] = nil
        mergeWaitTracking.heldBack.remove(waitID)
    }

    /// A line for the Lead of `workspace`'s space, if it has one.
    private func noticeLead(of workspace: WorkspaceState, _ text: String) {
        guard let lead = leadMissionParent(inSpace: workspace.profileID) else { return }
        tellProposer(lead, text)
    }

    /// One look-up per change of what reads say, and one per
    /// `MergeWait.lookUpInterval` window while they say the same.
    private static func readingKey(_ reading: MergeWait.Reading, now: TimeInterval) -> String {
        let window = Int(now / MergeWait.lookUpInterval)
        switch reading {
        case .read(let info): return "read \(info?.state.rawValue ?? "none") \(info?.url ?? "") \(window)"
        case .gone: return "gone \(window)"
        case .lookedUp, .unanswered: return "looked up"
        }
    }

    static func heldQuote(_ message: String, _ length: Int = MergeWait.quotedLength) -> String {
        let line = MissionPromptText.quoted(message)
        return line.count > length ? String(line.prefix(length - 1)) + "…" : line
    }
}

/// The row's line for the messages a task holds until other tasks' pull
/// requests merge: "After #651 merges · a message from the Lead".
struct SidebarHeldMessages: Hashable {
    let line: String
    let tooltip: String

    init?(_ waits: [MergeWait]) {
        let held = waits.compactMap { wait -> (MergeWait, String)? in
            guard case .tell(let message) = wait.action else { return nil }
            return (wait, message)
        }
        guard !held.isEmpty else { return nil }
        let waiting = held.filter { $0.0.mergedAt == nil }
        let shown = waiting.isEmpty ? held : waiting
        var names: [String] = []
        for (wait, _) in shown where !names.contains(wait.awaitedName) { names.append(wait.awaitedName) }
        let count = shown.count == 1 ? "a message" : "\(shown.count) messages"
        line = waiting.isEmpty
            ? "\(names.joined(separator: ", ")) merged · \(count) from the Lead \(shown.count == 1 ? "waits" : "wait") to go"
            : "After \(names.joined(separator: ", ")) \(names.count == 1 ? "merges" : "merge") · \(count) from the Lead"
        tooltip = held.map { wait, message in
            (wait.mergedAt == nil
                ? "Typed as the Lead's message once \(wait.awaitedLongName) merges"
                : "\(wait.awaitedLongName) merged; tried again every \(Int(MergeWait.lookUpInterval / 60)) minutes for a day")
                + ": “\(NiruxShellView.heldQuote(message))”"
        }.joined(separator: "\n")
    }
}
