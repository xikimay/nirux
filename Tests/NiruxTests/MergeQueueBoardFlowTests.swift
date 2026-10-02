import AppKit
import XCTest
@testable import Nirux

/// The merge queue from the board, in a real window: Add to Queue, Start,
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

    // MARK: - Flows

    @MainActor
    func testAQueueStartsFromTheBoardThroughTheSheetInTheUsersOrder() throws {
        let world = MergeQueueFlowTests.GitHubWorld(pullRequests: [12: Self.a, 14: Self.b])
        try withBoard(world: world) { shell, board in
            // Add to Queue on both rows: the list goes by number.
            try click(try XCTUnwrap(try row("feat/api", in: board).queueButton))
            try waitUntil("#14 is queued") { (try? self.row("feat/api", in: board).queue.stringValue) == "queued · 1" }
            try click(try XCTUnwrap(try row("login", in: board).queueButton))
            try waitUntil("#12 is queued") { (try? self.row("login", in: board).queue.stringValue) == "queued · 1" }
            XCTAssertEqual(try row("feat/api", in: board).queue.stringValue, "queued · 2")
            XCTAssertFalse(board.view.dryRunBadge.isHidden, "a dev build's queue is a dry run, and says so")
            XCTAssertTrue(board.view.dryRunBadge.toolTip?.hasSuffix("\nThis build: NIRUX_STATE_DIR is set.") == true,
                          "and why: \(board.view.dryRunBadge.toolTip ?? "")")
            XCTAssertEqual(board.view.startQueueButton.title, "Start Dry Run…")

            try click(board.view.startQueueButton)
            let sheet = try XCTUnwrap(shell.mergeQueueConfirmation)
            XCTAssertFalse(board.view.startQueueButton.isEnabled, "one sheet at a time")
            try waitUntil("the sheet read GitHub") { sheet.confirmation != nil }
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

            let queue = shell.mergeQueue(projectID: board.projectID)
            XCTAssertEqual(queue.engine?.entries.map(\.number), [14, 12])
            try waitUntil("the dry run stops at its first mutation") { !queue.isRunning }
            guard case .stopped(let reason)? = queue.engine?.phase else { return XCTFail("not stopped") }
            XCTAssertEqual(reason.kind, .dryRun)
            XCTAssertTrue(reason.message.contains("gh pr merge 14"), reason.message)
            XCTAssertEqual(world.mergedNumbers, [], "a dry run merges nothing")
            XCTAssertEqual(world.forbiddenCalls, [])
            XCTAssertFalse(world.allCalls.contains { $0.first == "pr" && $0.dropFirst().first == "merge" })

            try waitUntil("the board shows where it stopped") {
                board.view.queueLabel.stringValue.hasPrefix("Queue: Stopped: Dry run")
            }
            XCTAssertEqual(try row("feat/api", in: board).queue.stringValue, "queued · 1")
            XCTAssertEqual(try row("feat/api", in: board).queueDetail.stringValue, "last: dry run")
            XCTAssertEqual(try row("login", in: board).queue.stringValue, "queued · 2")
            let notice = try XCTUnwrap(shell.statusBar.queueNotice)
            XCTAssertTrue(notice.text.hasPrefix("Queue (dry run) stopped: Dry run"), notice.text)
        }
    }

    @MainActor
    func testStopFromTheBoardEndsAWaitingQueue() throws {
        // Checks still running: the queue waits between looks.
        let world = MergeQueueFlowTests.GitHubWorld(pullRequests: [12: Self.a, 14: Self.b], testConclusion: nil)
        try withBoard(world: world) { shell, board in
            try click(try XCTUnwrap(try row("login", in: board).queueButton))
            try waitUntil("#12 is queued") { (try? self.row("login", in: board).queue.stringValue) == "queued · 1" }
            try click(board.view.startQueueButton)
            let sheet = try XCTUnwrap(shell.mergeQueueConfirmation)
            try waitUntil("the sheet read GitHub") { sheet.startButton?.isEnabled == true }
            try click(try XCTUnwrap(sheet.startButton))

            let queue = shell.mergeQueue(projectID: board.projectID)
            try waitUntil("the queue waits for the checks") {
                if case .waitingForChecks? = queue.engine?.currentEntry?.step { return true }
                return false
            }
            XCTAssertEqual(try row("login", in: board).queue.stringValue, "1 of 1 · waiting for checks")
            XCTAssertTrue(board.view.startQueueButton.isHidden)
            XCTAssertFalse(board.view.stopQueueButton.isHidden, "Stop is in reach while it runs")
            try click(board.view.stopQueueButton)
            XCTAssertFalse(queue.isRunning)
            XCTAssertEqual(board.view.queueLabel.stringValue, "Queue: Stopped: Stopped by the user. · 1 pull request queued")
            XCTAssertTrue(board.view.stopQueueButton.isHidden)
            XCTAssertEqual(board.view.startQueueButton.isEnabled, true, "a new Start opens a new sheet")
        }
    }

    // MARK: - Helpers

    /// A shell in a window with the board of a project whose repository is
    /// acme/widgets, a workspace in its main checkout and one in the login
    /// worktree, the board read.
    @MainActor
    private func withBoard(
        world: MergeQueueFlowTests.GitHubWorld,
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
        shell.projectBoardClient = ProjectBoardFlowTests.FakeGitHub(
            openPullRequests: Self.boardPullRequests, runs: ProjectBoardGitHubTests.postMergeRuns
        )
        shell.mergeQueueClient = DryRunQueueClient(wrapped: GitHubCLIQueueClient(run: world.run), reason: "NIRUX_STATE_DIR is set")
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
        shell.viewport.subviews.filter { $0 is NSImageView }.forEach { $0.removeFromSuperview() }
        shell.openProjectBoard()
        let board = try XCTUnwrap(shell.projectBoardLocation(projectID: space.id)?.board)
        try waitUntil("the rows") { board.view.rowViews.contains { $0.row.pullRequest?.number == 14 } }
        try body(shell, board)
    }

    @MainActor
    private func row(_ name: String, in board: ProjectBoardController) throws -> ProjectBoardView.RowViews {
        try XCTUnwrap(board.view.rowViews.first { $0.row.name == name }, "no row “\(name)”")
    }

    @MainActor
    private func waitUntil(_ what: String, timeout: TimeInterval = 30, _ condition: () throws -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while (try? condition()) != true, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(try condition(), "timed out: \(what)")
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
