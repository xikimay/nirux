import Foundation

// MARK: - Review badges (docs/design/review-badges.md)

extension WorkspaceState {
    /// Records passes that started at `timestamp` on `head`, on `branch`
    /// (nil on a detached HEAD). A replayed event older than the stored run
    /// doesn't replace it.
    @discardableResult
    func recordReviewPasses(_ passes: [ReviewPass], head: String, branch: String? = nil, at timestamp: TimeInterval) -> Bool {
        var changed = false
        for pass in passes where reviewRuns[pass].map({ timestamp >= $0.at }) ?? true {
            reviewRuns[pass] = ReviewRun(head: head, at: timestamp, branch: branch)
            changed = true
        }
        return changed
    }

    /// What a hook event in `column` says of the passes running, in the
    /// order events come:
    /// - a main-thread event that types a pass (UserPromptSubmit) or runs it
    ///   (a Skill call's PostToolUse) starts it there; a replayed one (a
    ///   minute old) starts nothing, a subagent's event nothing at all;
    /// - the main turn's end there (Stop, a failed turn, Claude idle at its
    ///   prompt) ends its passes; a Stop that lists subagents still at work
    ///   makes them wait for those (a review run in the background outlives
    ///   the turn that started it): each is gone at its SubagentStop or at a
    ///   later Stop there that no longer lists it, whichever comes first, so
    ///   a lost SubagentStop can't keep a pass running;
    /// - the session's end ends every pass there.
    /// True when something changed.
    @discardableResult
    func noteReviewPasses(of event: AgentHookEvent, in column: UUID, now: TimeInterval) -> Bool {
        let before = reviewsRunning
        if let agent = event.agentID {
            guard event.name == .subagentStop else { return false }
            waitLess(in: column) { $0.subtracting([agent]) }
            return reviewsRunning != before
        }
        switch event.name {
        case .sessionEnd:
            reviewsRunning.removeAll { $0.column == column }
        case .stop:
            let listed = Set(event.backgroundAgents ?? [])
            for index in reviewsRunning.indices where reviewsRunning[index].column == column && reviewsRunning[index].waitingOn == nil {
                reviewsRunning[index].waitingOn = listed
            }
            waitLess(in: column) { $0.intersection(listed) }
        case .stopFailure:
            reviewsRunning.removeAll { $0.column == column && $0.waitingOn == nil }
        case .notification where event.notificationType == "idle_prompt":
            reviewsRunning.removeAll { $0.column == column && $0.waitingOn == nil }
        default:
            guard now - event.timestamp < 60 else { break }
            for pass in event.passes {
                reviewsRunning.removeAll { $0.pass == pass && $0.column == column }
                reviewsRunning.append(RunningPass(pass: pass, column: column, emitter: event.emitterProcess))
            }
        }
        return reviewsRunning != before
    }

    /// The column's waiting passes wait for what `rest` leaves of their
    /// subagents; one left waiting for none ends.
    private func waitLess(in column: UUID, _ rest: (Set<String>) -> Set<String>) {
        reviewsRunning = reviewsRunning.compactMap { running in
            guard running.column == column, let waiting = running.waitingOn else { return running }
            var less = running
            less.waitingOn = rest(waiting)
            return less.waitingOn?.isEmpty == true ? nil : less
        }
    }

    /// Ends the passes whose process `isAlive` says exited (or that named
    /// none), or whose column closed. True when one ended.
    @discardableResult
    func followReviewPasses(_ isAlive: (RunningPass) -> Bool) -> Bool {
        let before = reviewsRunning.count
        reviewsRunning.removeAll { !isAlive($0) }
        return reviewsRunning.count != before
    }

    /// Nil hides the card's row: no pull request and no pass ever ran.
    var reviewBadges: ReviewBadges? {
        guard prInfo != nil || !reviewRuns.isEmpty else { return nil }
        return ReviewBadges(runs: reviewRuns, head: gitContext?.identity.head)
    }
}
