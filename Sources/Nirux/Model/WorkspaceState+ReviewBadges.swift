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
    ///   prompt) ends its passes; a Stop that lists a subagent still at work
    ///   keeps them until a Stop there lists none (a review run in the
    ///   background outlives the turn that started it, and only a Stop ends
    ///   that wait);
    /// - the session's end ends every pass there.
    /// True when something changed.
    @discardableResult
    func noteReviewPasses(of event: AgentHookEvent, in column: UUID, now: TimeInterval) -> Bool {
        guard event.agentID == nil else { return false }
        let before = reviewsRunning
        switch event.name {
        case .sessionEnd:
            reviewsRunning.removeAll { $0.column == column }
        case .stop:
            let waits = !(event.backgroundAgents ?? []).isEmpty
            reviewsRunning = reviewsRunning.compactMap { running in
                guard running.column == column else { return running }
                guard waits else { return nil }
                var waiting = running
                waiting.waitsOnBackground = true
                return waiting
            }
        case .stopFailure:
            reviewsRunning.removeAll { $0.column == column && !$0.waitsOnBackground }
        case .notification where event.notificationType == "idle_prompt":
            reviewsRunning.removeAll { $0.column == column && !$0.waitsOnBackground }
        default:
            guard now - event.timestamp < 60 else { break }
            for pass in event.passes {
                reviewsRunning.removeAll { $0.pass == pass && $0.column == column }
                reviewsRunning.append(RunningPass(pass: pass, column: column, emitter: event.emitterProcess))
            }
        }
        return reviewsRunning != before
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
