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
    /// order events come: a pass's event (the prompt that typed it, or the
    /// Skill call that ran it) starts it there; the turn's end there (Stop,
    /// a failed turn, Claude back at its prompt after an interrupt) or its
    /// session's ends the passes running there. A replayed event (a minute
    /// old) says nothing. True when something changed.
    @discardableResult
    func noteReviewPasses(of event: AgentHookEvent, in column: UUID, now: TimeInterval) -> Bool {
        guard now - event.timestamp < 60 else { return false }
        switch event.name {
        case .stop, .stopFailure, .sessionEnd:
            return endReviewPasses(in: column)
        case .notification where event.notificationType == "idle_prompt":
            return endReviewPasses(in: column)
        default:
            let passes = event.reviewPasses?.compactMap(ReviewPass.init(rawValue:)) ?? []
            for pass in passes { reviewsRunning[pass] = RunningPass(column: column) }
            return !passes.isEmpty
        }
    }

    private func endReviewPasses(in column: UUID) -> Bool {
        let before = reviewsRunning.count
        reviewsRunning = reviewsRunning.filter { $0.value.column != column }
        return reviewsRunning.count != before
    }

    /// What the process table says of the running passes' columns: a pass
    /// whose `claude` was seen in front ends once another process is (it
    /// exited, crashed or was quit: no hook says so), and any ends once its
    /// column closed. True when one ended.
    @discardableResult
    func followReviewPasses(_ front: (UUID) -> RunningPass.Front) -> Bool {
        var ended = false
        for (pass, running) in reviewsRunning {
            switch front(running.column) {
            case .claude: reviewsRunning[pass]?.isClaudeSeen = true
            case .other where running.isClaudeSeen, .gone:
                reviewsRunning[pass] = nil
                ended = true
            case .other, .unknown: break
            }
        }
        return ended
    }

    /// Nil hides the card's row: no pull request and no pass ever ran.
    var reviewBadges: ReviewBadges? {
        guard prInfo != nil || !reviewRuns.isEmpty else { return nil }
        return ReviewBadges(runs: reviewRuns, head: gitContext?.identity.head)
    }
}
