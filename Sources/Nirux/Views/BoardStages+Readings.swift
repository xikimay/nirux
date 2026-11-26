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
        settledTurn: (ColumnInfo) -> Bool = { _ in false },
        turnStartedAt: (UUID) -> TimeInterval? = { _ in nil }
    ) {
        self.init()
        activity = Self.activity(of: info, settledTurn: settledTurn, turnStartedAt: turnStartedAt)
        isParked = info.phase == .parked || info.isInactive
        reviews = info.reviewBadges
        self.reviewsInFlight = reviewsInFlight
        self.summary = summary
        statusLine = info.statusLine
        nextStep = info.nextStepText
        blocker = info.blockerText
        lastActivityAt = info.lastActivityAt
        self.gitRoot = gitRoot
        reviewRequest = info.prInfo?.reviewRequest(hasFeedback: info.prFeedback != nil)
        flakyReason = info.ciFlakyReason
        cleanUp = info.mergedCleanup.map { $0 == .available ? .offered : .running }
        shipping = info.shipping
        resume = Self.resume(of: info.columns)
        // The pull request detection found merged is one at the HEAD it merged at.
        mergedPullRequest = info.prInfo.flatMap { $0.state == .merged ? $0.number : nil }
        mergedPullRequestRepository = info.prInfo.flatMap { $0.state == .merged ? GitHubRepository(pullRequestURL: $0.url) : nil }
    }


    /// The agents' steps of the row's ladder (`WorkspaceInfo.agentStep`),
    /// in the Board's terms: red checks are the pull request's, read there.
    @MainActor
    private static func activity(
        of info: WorkspaceInfo, settledTurn: (ColumnInfo) -> Bool, turnStartedAt: (UUID) -> TimeInterval?
    ) -> BoardStages.Activity {
        let columns = info.columns.map { column in
            guard column.missionQuestion?.isAnswered == true, column.questionAskedAt != nil,
                  !settledTurn(column) else { return column }
            var terminal = column
            terminal.missionQuestion = nil
            return terminal
        }
        let step = info.agentStep(in: columns) { column in
            if column.permissionApproval != nil || column.stuck != nil || column.openDialog?.isBlockingDialog == true
                || column.attentionReason?.isBlockingDialog == true { return true }
            if let question = column.missionQuestion {
                if question.handOff != nil && !question.isAnswered { return true }
                if column.attentionReason == nil && column.openDialog == nil { return false }
            }
            guard column.attentionReason == nil || column.attentionReason?.isTurnEnd == true,
                  column.openDialog == nil || column.openDialog?.isTurnEnd == true else { return true }
            return !settledTurn(column)
        }
        switch step {
        case .needsYou(let column, let words, let handedOff)?:
            if handedOff { return .needsYou(words, action: column.missionQuestion?.kind == .decision ? .decide : .reply) }
            if column.attentionLabel == "needs you" { return .needsYou("", action: .inspect) }
            if column.attentionLabel == "plan" { return .needsYou("Proposed plan", action: .plan) }
            return .needsYou(words, action: WorkspaceInfo.waitReason(of: column) == .command ? .permission : .reply)
        case .broken(_, let sentence)?: return .failed(sentence)
        case .asking(_, let question)?: return .asking(question.parentTitle, question: question.text)
        case .working(let working)?:
            // The row's clock: the column that may be going in circles, else the first working one a minute in.
            let clocks = info.circlingColumn.map { [$0] } ?? working
            let clock = clocks.first { $0.elapsedDisplay != nil } ?? clocks[0]
            return .working(since: clock.id.flatMap(turnStartedAt))
        case .answered?, nil: return .idle
        }
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
