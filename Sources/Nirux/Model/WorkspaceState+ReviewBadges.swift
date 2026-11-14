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
    /// - a pass's event (the prompt that typed it, the Skill call that runs
    ///   it, a subagent's included) starts it there; a replayed one (a
    ///   minute old) starts nothing;
    /// - the main turn's end there (Stop, its failed turn, Claude idle at
    ///   its prompt) ends the main thread's passes, once the subagents seen
    ///   at work there since have stopped (a review run in the background
    ///   outlives the turn that started it);
    /// - a subagent's stop ends the passes it ran itself;
    /// - the session's end ends every pass there.
    /// True when something changed.
    @discardableResult
    func noteReviewPasses(of event: AgentHookEvent, in column: UUID, now: TimeInterval) -> Bool {
        let before = reviewsRunning
        let isMain = event.agentID == nil
        let endsTurn = isMain && (event.name == .stop || event.name == .stopFailure
            || event.name == .notification && event.notificationType == "idle_prompt")
        if event.name == .sessionEnd, isMain {
            reviewsRunning.removeAll { $0.column == column }
        } else if endsTurn {
            for index in reviewsRunning.indices where reviewsRunning[index].column == column && reviewsRunning[index].agentID == nil {
                if event.name == .stopFailure, let failed = event.promptID, let own = reviewsRunning[index].promptID, failed != own { continue }
                reviewsRunning[index].isMainTurnOver = true
            }
        } else if event.name == .subagentStop, let agent = event.agentID {
            reviewsRunning.removeAll { $0.column == column && $0.agentID == agent }
            for index in reviewsRunning.indices where reviewsRunning[index].column == column {
                reviewsRunning[index].subagents.remove(agent)
            }
        } else if let agent = event.agentID {
            for index in reviewsRunning.indices where reviewsRunning[index].column == column {
                reviewsRunning[index].subagents.insert(agent)
            }
        }
        reviewsRunning.removeAll { $0.isMainTurnOver && $0.subagents.isEmpty }
        if now - event.timestamp < 60 {
            for pass in event.passes {
                reviewsRunning.removeAll { $0.pass == pass && $0.column == column }
                reviewsRunning.append(RunningPass(
                    pass: pass, column: column, agentID: event.agentID, promptID: event.promptID, emitter: event.emitterProcess
                ))
            }
        }
        return reviewsRunning != before
    }

    /// What the process table says of each running pass (`RunningPass.Front`):
    /// it ends once its process exited, nothing runs in its column, or the
    /// column closed; without a process named, once another process is in
    /// front after `claude` was seen there. True when one ended.
    @discardableResult
    func followReviewPasses(_ front: (RunningPass) -> RunningPass.Front) -> Bool {
        let before = reviewsRunning.count
        reviewsRunning = reviewsRunning.compactMap { running in
            var running = running
            switch front(running) {
            case .claude: running.isClaudeSeen = true
            case .other where running.isClaudeSeen, .gone: return nil
            case .other, .unknown: break
            }
            return running
        }
        return reviewsRunning.count != before
    }

    /// Nil hides the card's row: no pull request and no pass ever ran.
    var reviewBadges: ReviewBadges? {
        guard prInfo != nil || !reviewRuns.isEmpty else { return nil }
        return ReviewBadges(runs: reviewRuns, head: gitContext?.identity.head)
    }
}
