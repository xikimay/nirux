import os
import AppKit

// MARK: - Merge waits (docs/design/task-dependencies.md)

/// What the shell keeps of merge waits between reads.
struct MergeWaitTracking {
    /// The reading each wait was last looked up after, by wait id: GitHub
    /// is asked once per change of what the reads say.
    var lookedUpAfter: [String: String] = [:]
    var lookingUp: Set<String> = []
}

/// `tell`'s `after`: a message held on the task it is for until another
/// task's pull request merges, then sent as the Lead's tell. Nothing here
/// merges anything.
extension NiruxShellView {
    private static let mergeWaitLog = Logger(subsystem: "com.xikimay.nirux", category: "mergeWait")

    /// The workspaces a wait follows: their pull request is read at the
    /// hot cadence, archived or not.
    var awaitedWorkspaceIDs: Set<String> {
        Set(workspaces.lazy.flatMap(\.mergeWaits).map(\.awaited.workspaceID))
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
        lead: NewTask.MissionParent, answer: @escaping LeadAnswer
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
            id: UUID().uuidString,
            awaited: MergeWait.Awaited(
                workspaceID: awaited.id, title: awaited.title, branch: awaited.gitBranch,
                repository: repositoryAnchor(of: awaited, in: space)?.folder
            ),
            action: .tell(message: message), createdAt: Date().timeIntervalSince1970
        )
        let reading = MergeWait.Reading.read(awaited.prInfo)
        switch wait.step(after: reading) {
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
                + (wait.awaited.pullRequest == nil ? " (it has no pull request open yet)" : "")
                + ". If that pull request closes without merging, or “\(MissionPromptText.quoted(awaited.title))” closes first, "
                + "the message isn't typed and you hear it.", false)
            settleMergeWait(wait.id, of: workspace.id, after: reading, key: Self.readingKey(reading, now: wait.createdAt))
        }
    }

    // MARK: Following the awaited task

    /// A read of `workspace`'s pull request found `info` (nil: none) at
    /// `now`: each wait on it takes it.
    func followMergeWaits(awaiting workspace: WorkspaceState, read info: PRInfo?, now: TimeInterval) {
        let key = Self.readingKey(.read(info), now: now)
        for holder in workspaces where !holder.isClosing {
            for index in holder.mergeWaits.indices where holder.mergeWaits[index].awaited.workspaceID == workspace.id {
                holder.mergeWaits[index].awaited.title = workspace.title
                if let branch = workspace.gitBranch { holder.mergeWaits[index].awaited.branch = branch }
            }
            for wait in holder.mergeWaits where wait.awaited.workspaceID == workspace.id {
                settleMergeWait(wait.id, of: holder.id, after: .read(info), key: key)
            }
        }
    }

    /// `workspace` closes: the messages it holds go untyped, and each wait
    /// on it asks GitHub once.
    func closeMergeWaits(of workspace: WorkspaceState) {
        let held = workspace.mergeWaits
        workspace.mergeWaits = []
        for wait in held {
            guard case .tell(let message) = wait.action else { continue }
            noticeLead(of: workspace, "“\(MissionPromptText.quoted(workspace.title))” closed: your message held until "
                + "\(wait.awaitedLongName) merges wasn't typed. It said: “\(Self.heldQuote(message))”")
        }
        for holder in workspaces where !holder.isClosing {
            for wait in holder.mergeWaits where wait.awaited.workspaceID == workspace.id {
                settleMergeWait(wait.id, of: holder.id, after: .gone, key: Self.readingKey(.gone))
            }
        }
        if !held.isEmpty { saveState() }
    }

    /// After a restore: the waits whose task didn't come back ask GitHub.
    func settleOrphanedMergeWaits() {
        let present = Set(workspaces.map(\.id))
        for holder in workspaces {
            for wait in holder.mergeWaits where !present.contains(wait.awaited.workspaceID) {
                settleMergeWait(wait.id, of: holder.id, after: .gone, key: Self.readingKey(.gone))
            }
        }
    }

    /// The step `reading` takes the wait to, if both are still there.
    /// `key`: what a look-up it leads to was asked after (`readingKey`).
    private func settleMergeWait(_ waitID: String, of holderID: String, after reading: MergeWait.Reading, key: String) {
        guard let holder = workspaces.first(where: { $0.id == holderID && !$0.isClosing }),
              let index = holder.mergeWaits.firstIndex(where: { $0.id == waitID })
        else { return }
        let before = holder.mergeWaits[index]
        var wait = before
        let step = wait.step(after: reading)
        Self.mergeWaitLog.info("wait=\(waitID, privacy: .public) step=\(String(describing: step), privacy: .public)")
        switch step {
        case .keep, .lookUp:
            if wait != before {
                holder.mergeWaits[index] = wait
                saveState()
            }
            if step == .lookUp { lookUpMergeWait(wait, of: holderID, after: key) }
        case .release:
            holder.mergeWaits.remove(at: index)
            mergeWaitTracking.lookedUpAfter[waitID] = nil
            saveState()
            updateSidebar()
            releaseMergeWait(wait, of: holder)
        case .fail(let failure):
            holder.mergeWaits.remove(at: index)
            mergeWaitTracking.lookedUpAfter[waitID] = nil
            saveState()
            updateSidebar()
            guard case .tell(let message) = wait.action else { return }
            noticeLead(of: holder, "\(wait.sentence(failure)): your message for “\(MissionPromptText.quoted(holder.title))” "
                + "wasn't typed. It said: “\(Self.heldQuote(message))”")
        }
    }

    /// Asks GitHub about the wait's pull request (or its branch's), once
    /// per reading.
    private func lookUpMergeWait(_ wait: MergeWait, of holderID: String, after key: String) {
        guard let target = wait.lookUpTarget, mergeWaitTracking.lookedUpAfter[wait.id] != key,
              mergeWaitTracking.lookingUp.insert(wait.id).inserted
        else { return }
        mergeWaitTracking.lookedUpAfter[wait.id] = key
        let lookUp = mergeWaitLookUp
        Self.offMain({ lookUp(target) }) { [weak self] result in
            guard let self else { return }
            self.mergeWaitTracking.lookingUp.remove(wait.id)
            let gone = !self.workspaces.contains { $0.id == wait.awaited.workspaceID && !$0.isClosing }
            switch result {
            case .success(let found):
                self.settleMergeWait(wait.id, of: holderID, after: .lookedUp(found, awaitedGone: gone), key: key)
            case .failure(let failure):
                // The next read asks again.
                self.mergeWaitTracking.lookedUpAfter[wait.id] = nil
                self.settleMergeWait(wait.id, of: holderID, after: .unanswered(failure.reason, awaitedGone: gone), key: key)
            }
        }
    }

    /// The awaited pull request merged: the held message goes as the
    /// Lead's tell would now, and the Lead hears how.
    private func releaseMergeWait(_ wait: MergeWait, of holder: WorkspaceState) {
        guard case .tell(let message) = wait.action else { return }
        guard let lead = leadMissionParent(inSpace: holder.profileID) else {
            return Self.mergeWaitLog.info("wait=\(wait.id, privacy: .public) released with no Lead to send it")
        }
        let merged = "\(wait.awaitedLongName) merged"
        tellTask(message, to: holder, lead: lead) { [weak self] text, isError in
            self?.tellProposer(lead, isError
                ? "\(merged), but your message for “\(MissionPromptText.quoted(holder.title))” couldn't go: \(text) "
                    + "It said: “\(Self.heldQuote(message))”"
                : "\(merged): \(text)")
        }
    }

    /// A line for the Lead of `workspace`'s space, if it has one.
    private func noticeLead(of workspace: WorkspaceState, _ text: String) {
        guard let lead = leadMissionParent(inSpace: workspace.profileID) else { return }
        tellProposer(lead, text)
    }

    /// One look-up per change of what reads say, and at most one per
    /// `MergeWait.lookUpInterval` while they say the same.
    private static func readingKey(_ reading: MergeWait.Reading, now: TimeInterval = 0) -> String {
        switch reading {
        case .read(let info): return "read \(info?.state ?? "none") \(info?.url ?? "") \(Int(now / MergeWait.lookUpInterval))"
        case .gone: return "gone"
        case .lookedUp, .unanswered: return "looked up"
        }
    }

    static func heldQuote(_ message: String) -> String {
        let line = MissionPromptText.quoted(message)
        return line.count > MergeWait.quotedLength ? String(line.prefix(MergeWait.quotedLength - 1)) + "…" : line
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
        var names: [String] = []
        for (wait, _) in held where !names.contains(wait.awaitedName) { names.append(wait.awaitedName) }
        let count = held.count == 1 ? "a message" : "\(held.count) messages"
        line = "After \(names.joined(separator: ", ")) \(names.count == 1 ? "merges" : "merge") · \(count) from the Lead"
        tooltip = held.map { wait, message in
            "Typed as the Lead's message once \(wait.awaitedLongName) merges: “\(NiruxShellView.heldQuote(message))”"
        }.joined(separator: "\n")
    }
}
