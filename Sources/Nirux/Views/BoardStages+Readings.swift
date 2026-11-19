import Foundation

// MARK: - What the Board reads of a task (docs/design/board-stages.md, section 6)

extension BoardStages.TaskReading {
    /// What `info`, the task's sidebar row as built for its space, says, in
    /// the Board's terms: the row's own ladder for what its agents do (a
    /// wait on the user, then a stop, then a question to the agent that
    /// started it, then work), and the row's texts. Beside it, what the
    /// row doesn't hold: the user's own summary (the row's may be the last
    /// turn's line), the worktree its git facts were read in, the review
    /// passes running, and when each working column's turn started.
    @MainActor
    init(
        _ info: WorkspaceInfo, summary: String?, gitRoot: String?, reviewsInFlight: Set<ReviewPass> = [],
        turnStartedAt: (UUID) -> TimeInterval? = { _ in nil }
    ) {
        self.init()
        activity = Self.activity(of: info, turnStartedAt: turnStartedAt)
        reviews = info.reviewBadges
        self.reviewsInFlight = reviewsInFlight
        self.summary = summary
        statusLine = info.statusLine
        nextStep = info.nextStepText
        blocker = info.blockerText
        lastActivityAt = info.lastActivityAt
        self.gitRoot = gitRoot
        reviewRequest = Self.reviewRequest(info.prInfo, hasFeedback: info.prFeedback != nil)
        flakyReason = info.ciFlakyReason
        cleanUp = info.mergedCleanup.map { $0 == .available ? .offered : .running }
        resume = Self.resume(of: info.columns)
        // The pull request detection found merged is one at the HEAD it merged at.
        mergedPullRequest = info.prInfo.flatMap { $0.state == "MERGED" ? $0.number : nil }
        mergedPullRequestRepository = info.prInfo.flatMap { $0.state == "MERGED" ? Self.repository(ofPullRequestAt: $0.url) : nil }
    }

    /// The repository of a pull request's address, its host included:
    /// "https://github.com/owner/name/pull/52".
    static func repository(ofPullRequestAt address: String) -> GitHubRepository? {
        guard let url = URL(string: address), let host = url.host else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 4, parts[2] == "pull" else { return nil }
        return GitHubRepository(host: host, owner: parts[0], name: parts[1])
    }

    /// The agents' steps of the row's ladder (`WorkspaceInfo.agentStep`),
    /// in the Board's terms: red checks are the pull request's, read there.
    @MainActor
    private static func activity(of info: WorkspaceInfo, turnStartedAt: (UUID) -> TimeInterval?) -> BoardStages.Activity {
        switch info.agentStep {
        case .needsYou(let column, let words, _)?: return .needsYou(words, reason: WorkspaceInfo.waitReason(of: column))
        case .broken(_, let sentence)?: return .failed(sentence)
        case .asking(_, let question)?: return .asking(question.parentTitle)
        case .working(let working)?:
            // The row's clock: the column that may be going in circles, else the first working one a minute in.
            let clocks = info.circlingColumn.map { [$0] } ?? working
            let clock = clocks.first { $0.elapsedDisplay != nil } ?? clocks[0]
            return .working(since: clock.id.flatMap(turnStartedAt))
        case .answered?, nil: return .idle
        }
    }

    /// What GitHub still asks of the open pull request: changes, then
    /// comments to answer, then a review.
    private static func reviewRequest(_ pullRequest: PRInfo?, hasFeedback: Bool) -> BoardStages.ReviewRequest? {
        guard let pullRequest, pullRequest.state == "OPEN" else { return nil }
        if pullRequest.reviewDecision == "CHANGES_REQUESTED" { return .changesRequested }
        if hasFeedback { return .feedback }
        return pullRequest.reviewDecision == "REVIEW_REQUIRED" ? .reviewRequired : nil
    }

    /// The sidebar's Resume: an agent stopped on an error first (held back
    /// with why while it can't go out), else a `claude` that exited
    /// mid-turn, as the table offered it, else an agent restored at launch
    /// that hasn't resumed ("Paused · Resume").
    private static func resume(of columns: [ColumnInfo]) -> BoardStages.Resume? {
        for column in columns {
            if case .stoppedOnError(_, _, let failedAt, let resume)? = column.stuck, let id = column.id {
                return BoardStages.Resume(kind: .afterError, column: id, failedAt: failedAt, blocked: resume.status)
            }
        }
        for column in columns {
            if case .exitedMidTurn(.claude)? = column.stuck, let id = column.id {
                return BoardStages.Resume(kind: .afterExit, column: id)
            }
        }
        return columns.lazy.compactMap(\.deferredAgent).first.map { BoardStages.Resume(kind: .afterRelaunch, column: $0.columnID) }
    }
}
