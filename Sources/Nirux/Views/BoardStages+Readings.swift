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
    }

    /// The row's ladder, as `WorkspaceInfo.rowSummary` climbs it, without
    /// what isn't an agent's (red checks, the pull request, the texts).
    @MainActor
    private static func activity(of info: WorkspaceInfo, turnStartedAt: (UUID) -> TimeInterval?) -> BoardStages.Activity {
        let columns = info.columns
        if let waiting = columns.first(where: { $0.attention == .waiting }) {
            if let question = waiting.missionQuestion, question.handOff != nil, !question.isAnswered {
                return .needsYou(AgentText.clean(question.text, maxLength: 300) ?? "a question")
            }
            return .needsYou(WorkspaceInfo.needsYouDetail(waiting))
        }
        if let broken = columns.first(where: { $0.attention == .error }), let headline = broken.attentionSummary?.headline {
            return .failed(WorkspaceInfo.sentence(headline))
        }
        if let asking = WorkspaceInfo.questionColumn(in: columns), let pending = asking.missionQuestion, !pending.isAnswered {
            return .asking(pending.parentTitle)
        }
        let working = columns.filter { $0.agentStatus == .working }
        guard !working.isEmpty else { return .idle }
        // The row's clock: the column that may be going in circles, else the first working one that has one.
        let clocks = info.circlingColumn.map { [$0] } ?? working
        return .working(since: clocks.compactMap { $0.id.flatMap(turnStartedAt) }.first)
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
    /// mid-turn, as the table offered it.
    private static func resume(of columns: [ColumnInfo]) -> BoardStages.Resume? {
        for column in columns {
            if case .stoppedOnError(_, _, let failedAt, let resume)? = column.stuck, let id = column.id {
                return BoardStages.Resume(kind: .afterError, column: id, failedAt: failedAt, blocked: resume.status)
            }
        }
        for column in columns {
            if case .exitedMidTurn(let process)? = column.stuck, process == "claude", let id = column.id {
                return BoardStages.Resume(kind: .afterExit, column: id)
            }
        }
        return nil
    }
}
