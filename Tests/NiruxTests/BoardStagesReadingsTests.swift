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
        info.prFeedback = feedback ? PRFeedback.Counts(humans: 1, bots: 0) : nil
        info.ciFlakyReason = "timed out on a slow runner"
        info.reviewBadges = ReviewBadges(runs: [.codeReview: ReviewRun(head: "abc", at: 900)], head: "abc")
        info.statusLine = statusLine
        info.mergedCleanup = cleanup
        return info
    }

    private func pullRequest(_ state: GitHub.PullRequestState, review: String? = nil, checks: String = "SUCCESS") -> PRInfo {
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

    func testIncompleteCoverageAndIndependentTerminalRequests() {
        let workspace = ProjectBoard.Workspace(id: "task", title: "Task", folder: "/repo", isInactive: false, agent: .init())
        var inputs = ProjectBoardController.StagesInputs(workspaces: [workspace], tasks: ["task"])
        XCTAssertEqual(inputs.inputStatus(repositoryStatusKnown: true), "Status incomplete")
        inputs.readings["task"] = .init(terminalStatusKnown: false)
        XCTAssertEqual(inputs.inputStatus(repositoryStatusKnown: true), "Status incomplete")
        inputs.readings["task"] = .init()
        XCTAssertEqual(inputs.inputStatus(repositoryStatusKnown: false), "Status incomplete")
        inputs.missionStatusAvailable = false
        XCTAssertEqual(inputs.inputStatus(repositoryStatusKnown: true), "Status incomplete")

        let unqualified = row([column(0, status: .needsAttention)])
        XCTAssertEqual(reading(unqualified).activity, .needsYou("", action: .inspect))
        XCTAssertEqual(BoardStages.TaskReading(unqualified, summary: nil, gitRoot: nil, settledTurn: { _ in true }).activity, .idle)
        let question = column(0, status: .needsAttention, reason: .askedInReply("Keep the tests?"))
        XCTAssertEqual(reading(row([question])).activity, .needsYou("Keep the tests?"))
        var newer = question
        newer.missionQuestion = SidebarMissionQuestion(questionID: "old", parentTitle: "Lead", text: "Already answered.", handOff: nil, isAnswered: true)
        newer.questionAskedAt = 40
        newer.openDialog = .askedInReply("Keep the tests?")
        XCTAssertEqual(reading(row([newer])).activity, .needsYou("Keep the tests?"))

        var permission = column(1)
        permission.openDialog = .permission(tool: "Bash", summary: "git push")
        let read = BoardStages.TaskReading(row([question, permission]), summary: nil, gitRoot: nil, settledTurn: { $0.index == 0 })
        XCTAssertEqual(read.activity, .needsYou("Bash: git push", action: .permission))
        inputs.readings["task"] = read
        XCTAssertEqual(inputs.inputStatus(repositoryStatusKnown: false), "1 needs you · Task")
    }

    func testWhoActsOnTheBoardBeforeAndAfterAReply() throws {
        let store = MissionStore(persistsToDisk: false)
        let mission = try XCTUnwrap(store.create(MissionCreationRequest(
            id: UUID().uuidString, parentWorkspaceID: UUID().uuidString, parentAgentUUID: UUID().uuidString,
            childWorkspaceID: UUID().uuidString, childAgentUUID: UUID().uuidString, childAgentKind: "codex", branch: "rollout"
        ), enabled: true))
        var decision = MissionEvent(id: UUID().uuidString, missionID: mission.id, childWorkspaceID: mission.childWorkspaceID,
                                    childAgentUUID: mission.childAgentUUID, kind: .question, message: "Enable rollout?",
                                    timestamp: 20)
        decision.questionKind = .decision
        XCTAssertNotNil(store.accept(decision, enabled: true))
        let view = BoardStagesView(frame: NSRect(x: 0, y: 0, width: 1120, height: 465))
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.appearance = NSAppearance(named: .darkAqua)
        defer { window.close() }
        view.clock = { 0 }
        view.pointerLocation = { nil }

        func task(_ title: String, _ number: Int? = nil, activity: BoardStages.Activity = .idle) -> BoardStages.Facts {
            var facts = BoardStages.Facts(id: title, title: title, activity: activity)
            facts.pullRequest = number.map { .init(number: $0, base: "main", checks: .passed) }
            facts.reviews = ReviewBadges(runs: [.codeReview: ReviewRun(head: "abc", at: 10, branch: "feature")], head: "abc", branch: "feature")
            return facts
        }
        var checks = task("Test speed", 708)
        checks.queue = .init(order: 2, step: .checks("macOS checks"))
        var worker = task("Agent refactor", 666, activity: .working(since: nil))
        worker.pullRequest?.isConflicting = true
        var wait = BoardStagesLineTests.startWait(after: worker.id)
        wait.awaited.pullRequest = .init(number: 666, url: "https://github.com/acme/widgets/pull/666")
        let waits = try ["Agent selection", "NiruxCore"].map { try XCTUnwrap(BoardStages.WaitingTask(id: $0, title: $0, wait: wait)) }
        var ready = task("Lead session", 715)
        var answered = SidebarMissionQuestion(questionID: "settled", parentTitle: "Lead", text: "Use the active session.", handOff: nil)
        answered.isAnswered = true
        ready.activity = reading(row([column(0, status: .needsAttention, question: answered)])).activity
        var glass = task("Glass bar", 594)
        glass.nextStep = "Wait for #654 before retargeting."
        glass.pullRequest?.stack = ProjectBoard.StackPlace(parent: nil, chain: [594], rootBase: "p5",
                                                          mergedBase: .init(number: 654, onto: "main"), root: 594, order: 0)
        glass.queue.list = .open
        var conflicts = task("Forgotten tasks", 685)
        conflicts.nextStep = "Lead approved the earlier revision."
        conflicts.pullRequest?.isConflicting = true
        let lead = task("Release review", activity: .asking("Lead", question: "Review the rollout?"))
        var parked = task("Documentation")
        parked.isParked = true

        func render() throws {
            let pending = store.waitingQuestion(childWorkspaceID: mission.childWorkspaceID, childAgentUUID: mission.childAgentUUID)?.event
            let question = pending.map { SidebarMissionQuestion(questionID: $0.id, parentTitle: "Lead", text: $0.message,
                                                                handOff: .handedOver(why: "Your rollout choice"), kind: $0.questionKind) }
            let info = row([column(0, status: .needsAttention, reason: .askedInReply("Enable rollout?"), question: question)])
            let decisionReading = BoardStages.TaskReading(info, summary: nil, gitRoot: nil, settledTurn: { _ in
                NiruxShellView.settledTurn(decision.timestamp, events: store.missions[0].events)
            })
            let choice = task("Rollout", activity: decisionReading.activity)
            let tasks = [checks, worker, ready, glass, conflicts, lead, parked, choice]
            let lines = BoardStages.section(.init(id: "widgets", lines: tasks, waiting: waits), order: .progress, now: 60)
            let workspaces = tasks.map { ProjectBoard.Workspace(id: $0.id, title: $0.title, folder: "", isInactive: false, agent: .init()) }
            let inputs = ProjectBoardController.StagesInputs(workspaces: workspaces, tasks: tasks.map(\.id), waiting: waits,
                readings: Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, BoardStages.TaskReading(activity: $0.activity)) }))
            view.show(.init(header: .init(name: "Nirux", color: Theme.Color.accent, summary: "1 repository · 10 tasks"),
                            order: .progress, sections: [.init(id: "widgets", title: "nirux-public", lines: lines)],
                            now: 60, inputStatus: inputs.inputStatus(repositoryStatusKnown: true)))
            view.layoutSubtreeIfNeeded()
        }
        func capture(_ name: String) throws {
            guard let directory = ProcessInfo.processInfo.environment["NIRUX_BOARD_CAPTURES"] else { return }
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
        }
        try render()
        XCTAssertEqual(view.columnTitles[1].stringValue, "Now · 1 needs you · Rollout")
        XCTAssertEqual(view.lineViews.first?.phraseLabel.stringValue, "Decide · Enable rollout?")
        let labels = view.lineViews.map { $0.linkLabel.isHidden ? $0.phraseLabel.stringValue : $0.line.phrase.text }
        XCTAssertEqual(Set(labels), Set(["Decide · Enable rollout?", "Auto · macOS checks", "Agent working · Conflict with main",
                                         "Starts after #666 merges", "Merge manually · reviews done, checks green", "Base #654 merged · Retarget to main",
                                         "Resolve conflict with main", "Awaiting Lead reply · Review the rollout?", "Parked"]))
        XCTAssertEqual(view.lineViews.filter { $0.line.state == .needsYou }.count, 1)
        XCTAssertEqual(view.lineViews.filter { $0.phraseLabel.stringValue == "Starts after #666 merges" }.count, 2)
        XCTAssertEqual(view.lineViews.first { $0.line.title == conflicts.title }?.accessibilityHelp(), "Next step · Lead approved the earlier revision.")
        try capture("board-now-decision.png")
        window.setContentSize(NSSize(width: 360, height: 465))
        view.layoutSubtreeIfNeeded()
        let first = try XCTUnwrap(view.lineViews.first)
        XCTAssertFalse(first.phraseLabel.isHidden)
        XCTAssertGreaterThan(first.phraseLabel.frame.width, ColumnHeaderView.textWidth(first.phraseLabel))
        XCTAssertTrue(first.accessibilityLabel()?.contains("Decide · Enable rollout?") == true)
        try capture("board-now-narrow.png")
        XCTAssertNotNil(store.respond(to: decision.id, message: "Enable it", enabled: true, now: 30))
        window.setContentSize(NSSize(width: 1120, height: 465))
        try render()
        XCTAssertEqual(view.columnTitles[1].stringValue, "Now · No input requested")
        XCTAssertFalse(view.lineViews.contains { $0.line.state == .needsYou })
        try capture("board-now-answered.png")
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
            reading(row([behindDialog])).activity, .needsYou("Which base?"),
            "the current Mission question owns both words and glyph"
        )
        let broken = row([column(0, status: .working, id: first), stopped])
        XCTAssertEqual(reading(broken).activity, .failed(broken.rowSummary.status.text))
        XCTAssertEqual(reading(row([column(0, status: .working, id: first), column(1, question: asking)])).activity, .asking("Lead", question: "Which base?"))
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
        let red = pullRequest(.open, checks: "FAILURE")
        XCTAssertEqual(reading(row([column(0, question: asking)], pullRequest: red)).activity, .asking("Lead", question: "Which base?"))
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
        let ask = { (state: GitHub.PullRequestState, review: String?, feedback: Bool) in
            self.reading(self.row([self.column(0)], pullRequest: self.pullRequest(state, review: review), feedback: feedback)).reviewRequest
        }
        XCTAssertEqual(ask(.open, "CHANGES_REQUESTED", true), .changesRequested)
        XCTAssertEqual(ask(.open, "REVIEW_REQUIRED", true), .feedback)
        XCTAssertEqual(ask(.open, "REVIEW_REQUIRED", false), .reviewRequired)
        XCTAssertNil(ask(.open, "APPROVED", false))
        XCTAssertNil(ask(.merged, "CHANGES_REQUESTED", true))
        // Merged, as its own detection found it at its head; and the clean-up its row offers.
        info = row([column(0)], pullRequest: pullRequest(.merged), cleanup: .available)
        XCTAssertEqual(reading(info).mergedPullRequest, 52)
        XCTAssertEqual(reading(info).mergedPullRequestRepository, GitHubRepository(owner: "acme", name: "widgets"), "from its address")
        let enterprise = GitHubRepository(pullRequestURL: "https://ghe.example.com/acme/widgets/pull/52")
        XCTAssertEqual(enterprise?.host, "ghe.example.com", "another host's address is read too")
        XCTAssertNotEqual(enterprise, GitHubRepository(owner: "acme", name: "widgets"), "and is another repository")
        XCTAssertEqual(reading(info).cleanUp, .offered)
        XCTAssertEqual(reading(row([column(0)], cleanup: .inProgress)).cleanUp, .running)
        XCTAssertNil(reading(row([column(0)])).cleanUp)
        XCTAssertNil(reading(row([column(0)], pullRequest: pullRequest(.closed))).mergedPullRequest)
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
