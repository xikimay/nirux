import XCTest
@testable import Nirux

/// What the Board reads of a task (docs/design/board-stages.md, section 6):
/// its sidebar row's ladder and texts, in the Board's terms. Pure: rows
/// are given.
@MainActor
final class BoardStagesReadingsTests: XCTestCase {
    private func column(
        _ index: Int, status: AgentStatus = .idle, reason: AgentAttentionReason? = nil, stuck: SidebarStuckState? = nil,
        question: SidebarMissionQuestion? = nil, elapsed: TimeInterval? = nil, id: UUID = UUID()
    ) -> ColumnInfo {
        var column = ColumnInfo(
            index: index, processName: "claude", abbreviatedCwd: nil, isFocused: false, isWebView: false, webTitle: nil,
            terminalTitle: nil, agentStatus: status, isEditor: false, editorFileName: nil, agentElapsedSeconds: elapsed,
            attentionReason: reason, id: id
        )
        column.stuck = stuck
        column.missionQuestion = question
        return column
    }

    private func row(
        _ columns: [ColumnInfo], pullRequest: PRInfo? = nil, feedback: Bool = false, nextStep: String? = nil, blocker: String? = nil,
        statusLine: String? = nil, cleanup: MergedCleanupOffer? = nil
    ) -> WorkspaceInfo {
        var info = WorkspaceInfo(
            id: "task", index: 0, title: "Task", profileID: WorkspaceProfile.defaultID, isInactive: false,
            columnCount: columns.count, focusedColumn: 0, gitBranch: "feat/x", notification: nil, isActive: false,
            columns: columns, prInfo: pullRequest, diffStats: nil, purpose: nil, nextStep: nextStep, blocker: blocker,
            phase: .active, lastSummary: nil, lastActivityAt: 1_000
        )
        info.prFeedback = feedback ? SidebarPRFeedback(humans: 1, bots: 0) : nil
        info.ciFlakyReason = "timed out on a slow runner"
        info.reviewBadges = ReviewBadges(runs: [.codeReview: ReviewRun(head: "abc", at: 900)], head: "abc")
        info.statusLine = statusLine
        info.mergedCleanup = cleanup
        return info
    }

    private func pullRequest(_ state: String, review: String? = nil, checks: String = "SUCCESS") -> PRInfo {
        PRInfo(
            number: 52, state: state, isDraft: false, ciStatus: checks, checks: [], reviewDecision: review, mergeable: nil,
            url: "https://github.com/acme/widgets/pull/52", additions: nil, deletions: nil, changedFiles: nil
        )
    }

    private func reading(_ info: WorkspaceInfo, turns: [UUID: TimeInterval] = [:]) -> BoardStages.TaskReading {
        BoardStages.TaskReading(info, summary: nil, gitRoot: nil, turnStartedAt: { turns[$0] })
    }

    /// The row's words after "Needs you · ", as the Board's phrase adds them back.
    private func needsYou(_ info: WorkspaceInfo) -> BoardStages.Activity {
        .needsYou(String(info.rowSummary.status.text.dropFirst("Needs you · ".count)))
    }

    func testWhatItsAgentsDoClimbsTheRowsLadder() {
        let first = UUID(), second = UUID()
        let stopped = column(1, stuck: .stoppedOnError(kind: "overloaded", detail: nil, failedAt: 700, resume: .offered))
        let asking = SidebarMissionQuestion(questionID: "q", parentTitle: "Lead", text: "Which base?", handOff: nil)
        let handedOff = SidebarMissionQuestion(questionID: "q", parentTitle: "Lead", text: "Which base?", handOff: .parentClosed)

        // A wait on the user first, in the row's words; then a stop; then a question to its parent; then work.
        let waiting = row([column(0, status: .working, id: first), stopped, column(2, status: .needsAttention, reason: .question("Keep it?"))])
        XCTAssertEqual(reading(waiting).activity, needsYou(waiting))
        let handed = row([column(0, status: .needsAttention, question: handedOff)])
        XCTAssertEqual(reading(handed).activity, .needsYou("Which base?"), "a question come to the user: the question itself")
        XCTAssertEqual(reading(handed).activity, needsYou(handed))
        var behindDialog = column(0, question: handedOff)
        behindDialog.openDialog = .permission(tool: "Bash", summary: "git push")
        XCTAssertEqual(
            reading(row([behindDialog])).activity, .needsYou("Which base?", reason: .command),
            "the question's words, whatever else the column shows; the dialog's glyph, as on its row"
        )
        let broken = row([column(0, status: .working, id: first), stopped])
        XCTAssertEqual(reading(broken).activity, .failed(broken.rowSummary.status.text))
        XCTAssertEqual(reading(row([column(0, status: .working, id: first), column(1, question: asking)])).activity, .asking("Lead"))
        var answered = asking
        answered.isAnswered = true
        XCTAssertEqual(reading(row([column(0, question: answered)])).activity, .idle, "an answer to type: no agent's wait")
        // Work: since its turn started, in the column the row's clock reads (the first working a minute in, else the first).
        let working = row([column(0), column(1, status: .working, elapsed: 20, id: first), column(2, status: .working, elapsed: 720, id: second)])
        XCTAssertEqual(reading(working, turns: [first: 980, second: 280]).activity, .working(since: 280))
        let fresh = row([column(0), column(1, status: .working, elapsed: 20, id: first), column(2, status: .working, elapsed: 30, id: second)])
        XCTAssertEqual(reading(fresh, turns: [first: 980, second: 970]).activity, .working(since: 980))
        XCTAssertEqual(reading(working).activity, .working(since: nil))
        XCTAssertEqual(reading(row([column(0)])).activity, .idle)
        // Red checks are the pull request's: the Board reads them there, not as the agents'.
        let red = pullRequest("OPEN", checks: "FAILURE")
        XCTAssertEqual(reading(row([column(0, question: asking)], pullRequest: red)).activity, .asking("Lead"))
    }

    func testItsTextsAreTheRowsAndWhatGitHubAsks() {
        var info = row([column(0)], nextStep: "  write\n the import ", blocker: " waits for #105 ", statusLine: "Reviewed the sheet")
        let read = BoardStages.TaskReading(info, summary: "My summary", gitRoot: "/p/widgets.x", reviewsInFlight: [.premortem])
        XCTAssertEqual([read.summary, read.statusLine, read.nextStep, read.blocker, read.gitRoot, read.flakyReason],
                       ["My summary", "Reviewed the sheet", "write the import", "waits for #105", "/p/widgets.x", "timed out on a slow runner"])
        XCTAssertEqual(read.lastActivityAt, 1_000)
        XCTAssertEqual(read.reviews, info.reviewBadges)
        XCTAssertEqual(read.reviewsInFlight, [.premortem])
        XCTAssertNil(read.reviewRequest)
        XCTAssertNil(read.mergedPullRequest)
        // Changes asked, then comments to answer, then a review; only while it is open.
        let ask = { (state: String, review: String?, feedback: Bool) in
            self.reading(self.row([self.column(0)], pullRequest: self.pullRequest(state, review: review), feedback: feedback)).reviewRequest
        }
        XCTAssertEqual(ask("OPEN", "CHANGES_REQUESTED", true), .changesRequested)
        XCTAssertEqual(ask("OPEN", "REVIEW_REQUIRED", true), .feedback)
        XCTAssertEqual(ask("OPEN", "REVIEW_REQUIRED", false), .reviewRequired)
        XCTAssertNil(ask("OPEN", "APPROVED", false))
        XCTAssertNil(ask("MERGED", "CHANGES_REQUESTED", true))
        // Merged, as its own detection found it at its head; and the clean-up its row offers.
        info = row([column(0)], pullRequest: pullRequest("MERGED"), cleanup: .available)
        XCTAssertEqual(reading(info).mergedPullRequest, 52)
        XCTAssertEqual(reading(info).mergedPullRequestRepository, GitHubRepository(owner: "acme", name: "widgets"), "from its address")
        let enterprise = BoardStages.TaskReading.repository(ofPullRequestAt: "https://ghe.example.com/acme/widgets/pull/52")
        XCTAssertEqual(enterprise?.host, "ghe.example.com", "another host's address is read too")
        XCTAssertNotEqual(enterprise, GitHubRepository(owner: "acme", name: "widgets"), "and is another repository")
        XCTAssertEqual(reading(info).cleanUp, .offered)
        XCTAssertEqual(reading(row([column(0)], cleanup: .inProgress)).cleanUp, .running)
        XCTAssertNil(reading(row([column(0)])).cleanUp)
        XCTAssertNil(reading(row([column(0)], pullRequest: pullRequest("CLOSED"))).mergedPullRequest)
    }

    func testResumeIsTheSidebarsAStopFirstThenAClaudeThatExited() {
        let failed = UUID(), exited = UUID()
        let sending = column(1, stuck: .stoppedOnError(kind: nil, detail: nil, failedAt: 700, resume: .sending), id: failed)
        let gone = column(0, stuck: .exitedMidTurn(processName: "claude"), id: exited)
        XCTAssertEqual(reading(row([gone, sending])).resume,
                       BoardStages.Resume(kind: .afterError, column: failed, failedAt: 700, blocked: "Resuming…"),
                       "a stop first, held back with why")
        let offered = column(1, stuck: .stoppedOnError(kind: nil, detail: nil, failedAt: 700, resume: .offered), id: failed)
        XCTAssertNil(reading(row([offered])).resume?.blocked)
        XCTAssertEqual(reading(row([gone])).resume, BoardStages.Resume(kind: .afterExit, column: exited))
        XCTAssertNil(reading(row([column(0, stuck: .exitedMidTurn(processName: "codex"))])).resume, "the table offered it for claude only")
        XCTAssertNil(reading(row([column(0)])).resume)
        // An agent restored at launch that hasn't resumed: "Paused · Resume", after a stop or an exit.
        let restored = UUID()
        var paused = column(2)
        paused.deferredAgent = SidebarDeferredAgent(processName: "claude", summary: "claude --resume", columnID: restored)
        XCTAssertEqual(reading(row([column(0), paused])).resume, BoardStages.Resume(kind: .afterRelaunch, column: restored))
        XCTAssertEqual(reading(row([paused, gone])).resume?.kind, .afterExit)
    }
}
