import Foundation

// MARK: - Review badges (docs/review-badges.md)

extension WorkspaceState {
    /// Records the review passes `event` starts on the current HEAD. Not
    /// before the first git read: a pass replayed at launch is lost then.
    @discardableResult
    func recordReviewPasses(_ event: AgentHookEvent) -> Bool {
        guard let passes = event.reviewPasses, let head = gitContext?.identity.head else { return false }
        var changed = false
        for pass in passes where reviewRuns[pass].map({ event.timestamp >= $0.at }) ?? true {
            reviewRuns[pass] = ReviewRun(head: head, at: event.timestamp)
            changed = true
        }
        return changed
    }

    /// Nil hides the card's row: no pull request and no pass ever ran.
    var reviewBadges: ReviewBadges? {
        guard prInfo != nil || !reviewRuns.isEmpty else { return nil }
        return ReviewBadges(runs: reviewRuns, head: gitContext?.identity.head)
    }
}
