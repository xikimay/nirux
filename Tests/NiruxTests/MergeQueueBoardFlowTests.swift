import AppKit
import XCTest
@testable import Nirux

/// The merge queue from the board, in a real window: a line's Merge station, Start,
/// the confirmation sheet read off the main thread and reordered, the
/// queue run by the real driver over the real `gh` client, whose scripted
/// GitHub answers on another queue (the #48 path), then Stop. Every queue
/// here is a dry run: nothing is ever merged. Clicks are hit-tested by
/// hand, since a window that is never shown (CI) drops events sent with
/// `sendEvent`.
final class MergeQueueBoardFlowTests: XCTestCase {
    private var root: String!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("nirux-merge-queue-board-flow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        root = try XCTUnwrap(base.path.realPath)
    }

    override func tearDown() {
        MergeQueueController.waitForFiles()
        if let root { try? FileManager.default.removeItem(atPath: root) }
        super.tearDown()
    }

    private static let a = MQ.sha("a")
    private static let b = MQ.sha("b")

    /// What the board reads: #12 on the login worktree, #14 with no worktree.
    private static let boardPullRequests = """
    [
      {"number": 12, "state": "OPEN", "headRefName": "feat/login", "headRefOid": "\(a)",
       "headRepository": {"name": "widgets"}, "headRepositoryOwner": {"login": "acme"}, "baseRefName": "main",
       "isDraft": false, "mergeable": "MERGEABLE", "url": "https://github.com/acme/widgets/pull/12",
       "statusCheckRollup": []},
      {"number": 14, "state": "OPEN", "headRefName": "feat/api", "headRefOid": "\(b)",
       "headRepository": {"name": "widgets"}, "headRepositoryOwner": {"login": "acme"}, "baseRefName": "main",
       "isDraft": false, "mergeable": "MERGEABLE", "url": "https://github.com/acme/widgets/pull/14",
       "statusCheckRollup": []}
    ]
    """

    /// #14 based on `feat/old`, whose #10 merged.
    private static let retargetPullRequests = """
    [
      {"number": 12, "state": "OPEN", "headRefName": "feat/login", "headRefOid": "\(a)",
       "headRepository": {"name": "widgets"}, "headRepositoryOwner": {"login": "acme"}, "baseRefName": "main",
       "isDraft": false, "mergeable": "MERGEABLE", "url": "https://github.com/acme/widgets/pull/12",
       "statusCheckRollup": []},
      {"number": 14, "state": "OPEN", "headRefName": "feat/api", "headRefOid": "\(b)",
       "headRepository": {"name": "widgets"}, "headRepositoryOwner": {"login": "acme"}, "baseRefName": "feat/old",
       "baseRefOid": "\(MQ.sha("c"))", "isDraft": false, "mergeable": "MERGEABLE", "url": "https://github.com/acme/widgets/pull/14",
       "statusCheckRollup": []}
    ]
    """
    private static let mergedBase = """
    [{"number": 10, "state": "MERGED", "headRefName": "feat/old", "headRefOid": "\(MQ.sha("c"))",
      "headRepository": {"name": "widgets"}, "headRepositoryOwner": {"login": "acme"}, "baseRefName": "main",
      "url": "https://github.com/acme/widgets/pull/10"}]
    """

    // MARK: - Flows

    @MainActor
    func testAQueueStartsFromTheBoardThroughTheSheetInTheUsersOrder() throws {
        let world = MergeQueueFlowTests.GitHubWorld(pullRequests: [12: Self.a, 14: Self.b])
        try withBoard(world: world) { shell, board in
            // A click on a line's Merge station, Add to Queue in another's menu: the list goes by number.
            try BoardStagesClicks.pressMerge(try line("feat/api", in: board))
            waitUntil("#14 is queued") { (BoardStagesClicks.shownLine("feat/api", in: board)?.line.offer?.change) == .remove }
            try BoardStagesClicks.choose("Add to Queue", in: try line("login", in: board).contextMenu())
            waitUntil("#12 is queued") { (BoardStagesClicks.shownLine("login", in: board)?.line.offer?.change) == .remove }
            let queue = shell.mergeQueue(projectID: board.projectID, repository: MQ.widgets)
            XCTAssertEqual(queue.selection, [12, 14])
            XCTAssertEqual(try line("login", in: board).line.tooltips.stations[.merge], "Remove from Queue")
            let header = try self.header(of: board)
            BoardStagesClicks.layOut(header)
            XCTAssertFalse(header.dryRunBadge.isHidden, "a dev build's queue is a dry run, and says so")
            XCTAssertTrue(header.dryRunBadge.toolTip?.hasSuffix("\nThis build: NIRUX_STATE_DIR is set.") == true,
                          "and why: \(header.dryRunBadge.toolTip ?? "")")
            XCTAssertEqual(header.startButton.title, "Start Dry Run… · 2")
            XCTAssertEqual(header.queueLabel.stringValue, "2 pull requests queued")

            try BoardStagesClicks.click(header.startButton)
            let sheet = try XCTUnwrap(shell.mergeQueueConfirmation)
            XCTAssertFalse(header.startButton.isEnabled, "one sheet at a time")
            waitUntil("the sheet read GitHub") { sheet.confirmation != nil }
            let confirmation = try XCTUnwrap(sheet.confirmation)
            XCTAssertEqual(confirmation.refusals, [])
            XCTAssertEqual(confirmation.entries.map(\.number), [12, 14])
            XCTAssertEqual(confirmation.entries.map(\.head), [Self.a, Self.b], "the heads GitHub has now")
            XCTAssertEqual(Array(sheet.lines.prefix(2)), [
                MergeQueueConfirmationPanel.dryRunExplanation, "This build: NIRUX_STATE_DIR is set."
            ])
            XCTAssertTrue(sheet.lines.contains("1. #12  Change 12"), "\(sheet.lines)")
            XCTAssertTrue(sheet.lines.contains("A real queue would publish 2 nightlies, one after each merge. This dry run publishes none."))
            XCTAssertEqual(sheet.startButton?.title, "Start Dry Run")
            XCTAssertTrue(world.answeredOffMain, "the sheet read GitHub off the main thread")

            // The user's order: #14 first.
            try click(try XCTUnwrap(sheet.moveButtons.first?.down))
            XCTAssertEqual(sheet.confirmation?.entries.map(\.number), [14, 12])
            XCTAssertTrue(sheet.lines.contains("1. #14  Change 14"))
            try click(try XCTUnwrap(sheet.startButton))
            XCTAssertNil(shell.mergeQueueConfirmation, "started: the sheet is gone")

            XCTAssertEqual(queue.engine?.entries.map(\.number), [14, 12])
            waitUntil("the dry run stops at its first mutation") { !queue.isRunning }
            guard case .stopped(let reason)? = queue.engine?.phase else { return XCTFail("not stopped") }
            XCTAssertEqual(reason.kind, .dryRun)
            XCTAssertTrue(reason.message.contains("gh pr merge 14"), reason.message)
            XCTAssertEqual(world.mergedNumbers, [], "a dry run merges nothing")
            XCTAssertEqual(world.forbiddenCalls, [])
            XCTAssertFalse(world.allCalls.contains { $0.first == "pr" && $0.dropFirst().first == "merge" })

            waitUntil("the board shows where it stopped") { header.queueLabel.stringValue.hasPrefix("Stopped: Dry run") }
            XCTAssertEqual(queue.selection, [14, 12], "both still in the next Start's list, in the user's order")
            XCTAssertEqual(header.startButton.title, "Start Dry Run… · 2")
            let notice = try XCTUnwrap(shell.statusBar.queueNotice)
            XCTAssertTrue(notice.text.hasPrefix("Queue (dry run) stopped: Dry run"), notice.text)
        }
    }

    @MainActor
    func testStopFromTheBoardEndsAWaitingQueue() throws {
        // Checks still running: the queue waits between looks.
        let world = MergeQueueFlowTests.GitHubWorld(pullRequests: [12: Self.a, 14: Self.b], testConclusion: nil)
        try withBoard(world: world) { shell, board in
            try BoardStagesClicks.pressMerge(try line("login", in: board))
            waitUntil("#12 is queued") { (BoardStagesClicks.shownLine("login", in: board)?.line.offer?.change) == .remove }
            let header = try self.header(of: board)
            try BoardStagesClicks.click(header.startButton)
            let sheet = try XCTUnwrap(shell.mergeQueueConfirmation)
            waitUntil("the sheet read GitHub") { sheet.startButton?.isEnabled == true }
            try click(try XCTUnwrap(sheet.startButton))

            let queue = shell.mergeQueue(projectID: board.projectID, repository: MQ.widgets)
            waitUntil("the queue waits for the checks") {
                if case .waitingForChecks? = queue.engine?.currentEntry?.step { return true }
                return false
            }
            waitUntil("the line says so") { (BoardStagesClicks.shownLine("login", in: board)?.line.phrase.text) == "Auto · Waiting for checks" }
            BoardStagesClicks.layOut(header)
            XCTAssertTrue(header.startButton.isHidden)
            XCTAssertFalse(header.stopButton.isHidden, "Stop is in reach while it runs")
            XCTAssertEqual(board.view.stages.runningQueueViews.map(\.queue.title), ["acme/widgets"], "and at the Board's foot")
            try BoardStagesClicks.click(header.stopButton)
            XCTAssertFalse(queue.isRunning)
            XCTAssertEqual(header.queueLabel.stringValue, "Stopped: Stopped by the user. · 1 pull request queued")
            BoardStagesClicks.layOut(header)
            XCTAssertTrue(header.stopButton.isHidden)
            XCTAssertEqual(header.startButton.isEnabled, true, "a new Start opens a new sheet")
            XCTAssertEqual(board.view.stages.runningQueueViews.count, 0)
        }
    }

    /// #14 is based on #10's branch, merged: Retarget bases it on `main`
    /// off the main thread, then the board reads the pull requests again.
    /// No queue starts, so the live client is never called.
    @MainActor
    func testRetargetFromTheBoardChangesTheBaseThenReadsAgain() throws {
        let client = ProjectBoardFlowTests.FakeGitHub(
            openPullRequests: Self.retargetPullRequests, mergedPullRequests: Self.mergedBase,
            runs: ProjectBoardGitHubTests.postMergeRuns
        )
        let world = MergeQueueFlowTests.GitHubWorld(pullRequests: [12: Self.a, 14: Self.b])
        try withBoard(world: world, boardClient: client, isDryRun: false) { shell, board in
            waitUntil("#10 reads merged") {
                (BoardStagesClicks.shownLine("feat/api", in: board)?.line.phrase.link) == .retarget(number: 14, onto: "main")
            }
            XCTAssertEqual(try line("feat/api", in: board).line.phrase.text, "Base #10 merged · Retarget to main")
            // GitHub refuses: the repository's pill says why, until Refresh.
            client.retargetFailure = .failed("HTTP 422: Validation Failed")
            try BoardStagesClicks.pressLink(try line("feat/api", in: board))
            let header = try self.header(of: board)
            waitUntil("the refusal shows") { header.pill.status?.toolTip?.contains("Retarget #14: gh: HTTP 422") == true }
            XCTAssertEqual(header.pill.status?.tone, .error)
            XCTAssertTrue(board.view.refreshButton.toolTip?.contains("Retarget #14: gh: HTTP 422") == true, "and under Refresh")
            client.retargetFailure = nil
            try BoardStagesClicks.click(board.view.refreshButton)
            waitUntil("Refresh clears it") { header.pill.status?.tone != .error && BoardStagesClicks.wasUpdated(board) }

            let reads = client.calls.filter { $0.what == "pr open acme/widgets" }.count
            try BoardStagesClicks.choose("Retarget to main", in: try line("feat/api", in: board).contextMenu())
            waitUntil("the pull requests are read again") {
                client.calls.filter { $0.what == "pr open acme/widgets" }.count > reads
            }
            XCTAssertEqual(client.calls.filter { $0.what.hasPrefix("retarget") }.map(\.what),
                           ["retarget acme/widgets #14 main", "retarget acme/widgets #14 main"])
            // A pull request none of the section's lines has: not retargeted.
            let section = try XCTUnwrap(board.view.stages.content?.sections.first?.id)
            shell.performBoardLink(.retarget(number: 99, onto: "main"), line: nil, section: section, board: board)
            RunLoop.main.run(until: Date().addingTimeInterval(1))
            XCTAssertFalse(client.calls.contains { $0.what.contains("#99") })

            // The confirmation sheet locks the list: the link held under the pointer, or the offer of a line held so,
            // changes nothing, and says why.
            try BoardStagesClicks.pressMerge(try line("login", in: board))
            waitUntil("#12 is queued") { (BoardStagesClicks.shownLine("login", in: board)?.line.offer?.change) == .remove }
            try BoardStagesClicks.click(header.startButton)
            XCTAssertNotNil(shell.mergeQueueConfirmation)
            waitUntil("the link goes") { (BoardStagesClicks.shownLine("feat/api", in: board)?.line.phrase.link) == nil }
            let locked = "The confirmation sheet is open: change the list once it closes."
            shell.performBoardLink(.retarget(number: 14, onto: "main"), line: nil, section: section, board: board)
            XCTAssertEqual(shell.toast?.message, locked)
            shell.toast?.removeFromSuperview()
            shell.toast = nil
            shell.performBoardOffer(BoardStages.QueueOffer(change: .remove, number: 12), section: section, board: board)
            XCTAssertEqual(shell.toast?.message, locked)
            XCTAssertEqual(shell.mergeQueue(projectID: board.projectID, repository: MQ.widgets).selection, [12])
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            XCTAssertEqual(client.calls.filter { $0.what.hasPrefix("retarget") }.count, 2, "no third retarget")
            XCTAssertFalse(client.calls.contains(where: \.onMainThread), "gh never runs on the main thread")
        }
    }

    /// A dev build can't retarget: the words stay, as no link, the menu's
    /// item is disabled and says why.
    @MainActor
    func testADryRunBuildDoesNotRetarget() throws {
        let client = ProjectBoardFlowTests.FakeGitHub(
            openPullRequests: Self.retargetPullRequests, mergedPullRequests: Self.mergedBase,
            runs: ProjectBoardGitHubTests.postMergeRuns
        )
        let world = MergeQueueFlowTests.GitHubWorld(pullRequests: [12: Self.a, 14: Self.b])
        try withBoard(world: world, boardClient: client) { shell, board in
            waitUntil("#10 reads merged") {
                (BoardStagesClicks.shownLine("feat/api", in: board)?.line.phrase.text) == "Base #10 merged · Retarget to main"
            }
            let api = try line("feat/api", in: board)
            BoardStagesClicks.layOut(api)
            XCTAssertNil(api.line.phrase.link)
            XCTAssertTrue(api.linkLabel.isHidden)
            let item = try XCTUnwrap(api.contextMenu()?.items.first { $0.title == "Retarget to main" })
            XCTAssertFalse(item.isEnabled)
            XCTAssertNotNil(item.toolTip)
            // Even if it were clicked, the shell refuses.
            let section = try XCTUnwrap(board.view.stages.content?.sections.first?.id)
            shell.performBoardLink(.retarget(number: 14, onto: "main"), line: api.line.id, section: section, board: board)
            shell.performProjectBoardAction(.retarget(number: 14, base: "main"), board: board)
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            XCTAssertFalse(client.calls.contains { $0.what.hasPrefix("retarget") })
        }
    }

    // MARK: - Helpers

    /// A shell in a window with the board of a project whose repository is
    /// acme/widgets, a workspace in its main checkout and one in the login
    /// worktree, the board read.
    @MainActor
    private func withBoard(
        world: MergeQueueFlowTests.GitHubWorld,
        boardClient: ProjectBoardFlowTests.FakeGitHub? = nil,
        isDryRun: Bool = true,
        _ body: (NiruxShellView, ProjectBoardController) throws -> Void
    ) throws {
        let stateDirectory = root + "/state"
        try FileManager.default.createDirectory(atPath: stateDirectory, withIntermediateDirectories: true)
        let previous = ProcessInfo.processInfo.environment["NIRUX_STATE_DIR"]
        setenv("NIRUX_STATE_DIR", stateDirectory, 1)
        defer {
            if let previous { setenv("NIRUX_STATE_DIR", previous, 1) } else { unsetenv("NIRUX_STATE_DIR") }
        }
        _ = NSApplication.shared
        let shell = NiruxShellView(frame: NSRect(x: 0, y: 0, width: 1600, height: 900))
        shell.stopHeartbeat()
        shell.projectBoardClient = boardClient ?? ProjectBoardFlowTests.FakeGitHub(
            openPullRequests: Self.boardPullRequests, runs: ProjectBoardGitHubTests.postMergeRuns
        )
        let queueClient = GitHubCLIQueueClient(run: world.run)
        shell.mergeQueueClient = isDryRun ? DryRunQueueClient(wrapped: queueClient, reason: "NIRUX_STATE_DIR is set") : queueClient
        shell.mergeQueueLockFolder = URL(fileURLWithPath: root + "/locks")
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1600, height: 900),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = shell
        defer {
            for queue in shell.mergeQueues.values { queue.stop() }
            shell.mergeQueueConfirmation?.dismiss()
            window.close()
        }
        let space = shell.workspaceStore.createProfile(named: "Board")
        let repo = root + "/widgets"
        try BoardConfigSuggestionsTests.makeRepository(at: repo, remote: "https://github.com/acme/widgets.git")
        let login = root + "/widgets.feat-login"
        try BoardConfigSuggestionsTests.git(["worktree", "add", "-q", "-b", "feat/login", login], at: repo)
        let store = try XCTUnwrap(BoardConfigStore(spaceID: space.id))
        let config = BoardConfig(
            repository: "acme/widgets", baseBranch: "main", requiredChecks: ["test"], postMergeWorkflow: .workflow("nightly.yml")
        )
        if case .failure(let error) = store.save(config) { XCTFail(error.message) }
        shell.addWorkspace(title: "widgets", cwd: repo, profileID: space.id)
        shell.addWorkspace(title: "login", cwd: login, profileID: space.id)
        shell.switchToWorkspace(try XCTUnwrap(shell.workspaces.firstIndex { $0.title == "widgets" }))
        shell.openProjectBoard()
        let board = try XCTUnwrap(shell.projectBoardLocation(projectID: space.id)?.board)
        waitUntil("the lines") {
            board.view.stages.content?.sections.first?.lines.withoutTask.flatMap(\.lines).contains { $0.pullRequest == "#14" } == true
        }
        // #14 has no worktree: under "Pull requests without a task", folded.
        let section = try XCTUnwrap(board.view.stages.content?.sections.first?.id)
        try BoardStagesClicks.click(try XCTUnwrap(board.view.stages.foldButton(section: section)))
        try body(shell, board)
    }

    @MainActor
    private func line(_ title: String, in board: ProjectBoardController) throws -> BoardStagesLineView {
        try BoardStagesClicks.line(title, in: board)
    }

    /// The repository's header.
    @MainActor
    private func header(of board: ProjectBoardController) throws -> BoardStagesSectionHeaderView {
        let section = try XCTUnwrap(board.view.stages.content?.sections.first?.id)
        return try XCTUnwrap(board.view.stages.sectionHeader(section: section))
    }

    /// The button must be what its window hit-tests under the pointer, as
    /// AppKit finds it for a real click; then `performClick`, since a
    /// button's own tracking never ends in a window that isn't shown.
    @MainActor
    private func click(_ button: NSButton) throws {
        let window = try XCTUnwrap(button.window)
        let contentView = try XCTUnwrap(window.contentView)
        let frameView = try XCTUnwrap(contentView.superview)
        let location = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        let hitView = try XCTUnwrap(frameView.hitTest(location))
        XCTAssertTrue(hitView === button, "\(hitView) is under the pointer, not \(button.title)")
        XCTAssertTrue(button.isEnabled, "\(button.title) is disabled")
        (hitView as? NSButton)?.performClick(nil)
    }
}
