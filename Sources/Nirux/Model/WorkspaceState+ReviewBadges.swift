import Foundation

// MARK: - Review badges (docs/review-badges.md)

extension WorkspaceState {
    /// Records passes that started at `timestamp` on `head`. A replayed
    /// event older than the stored run doesn't replace it.
    @discardableResult
    func recordReviewPasses(_ passes: [ReviewPass], head: String, at timestamp: TimeInterval) -> Bool {
        var changed = false
        for pass in passes where reviewRuns[pass].map({ timestamp >= $0.at }) ?? true {
            reviewRuns[pass] = ReviewRun(head: head, at: timestamp)
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
