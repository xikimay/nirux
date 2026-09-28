import AppKit
import XCTest
@testable import Nirux

/// What a running queue does beyond the board: the status bar, keep-awake,
/// and a quit that asks first and waits for a call already sent.
@MainActor
final class MergeQueueShellTests: XCTestCase {
    private var root: URL!
    private var previousStateDirectory: String?

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nirux-merge-queue-shell-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("state"), withIntermediateDirectories: true)
        previousStateDirectory = ProcessInfo.processInfo.environment["NIRUX_STATE_DIR"]
        setenv("NIRUX_STATE_DIR", root.appendingPathComponent("state").path, 1)
    }

    override func tearDown() async throws {
        MergeQueueController.waitForFiles()
        if let previousStateDirectory {
            setenv("NIRUX_STATE_DIR", previousStateDirectory, 1)
        } else {
            unsetenv("NIRUX_STATE_DIR")
        }
        if let root { try? FileManager.default.removeItem(at: root) }
        try await super.tearDown()
    }

    private func makeShell(_ client: any MergeQueueGitHub) -> NiruxShellView {
        _ = NSApplication.shared
        let shell = NiruxShellView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        shell.stopHeartbeat()
        shell.mergeQueueClient = client
        shell.mergeQueueLockFolder = root.appendingPathComponent("locks")
        return shell
    }

    /// A pull request ready to merge: the engine reaches its merge without a wait.
    private func readyWorld() -> MQ.World {
        var world = MQ.World()
        world.pullRequests[52] = MQ.pullRequest(52, head: MQ.sha("a"))
        world.checks[MQ.sha("a")] = MQ.checks(MQ.checkRun(id: 1))
        return world
    }

    /// A pull request whose checks still run: the queue waits 20 s between looks.
    private func waitingWorld() -> MQ.World {
        var world = readyWorld()
        world.checks[MQ.sha("a")] = MQ.checks(MQ.checkRun(id: 1, status: "IN_PROGRESS", conclusion: nil))
        return world
    }

    private func start(_ shell: NiruxShellView, projectID: String = "project") -> MergeQueueController {
        let queue = shell.mergeQueue(projectID: projectID)
        queue.beginActivity = { NSObject() }
        queue.endActivity = { _ in }
        XCTAssertNil(queue.start(settings: MQ.settings(), entries: [MQ.entry(52, head: MQ.sha("a"))]))
        return queue
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 10, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(condition(), "timed out: \(what)")
    }

    // MARK: - Status bar

    func testTheStatusBarFollowsTheQueueAndItsStopStopsIt() throws {
        let shell = makeShell(FakeQueueClient(world: readyWorld(), isDryRun: true))
        XCTAssertNil(shell.statusBar.queueNotice)

        let queue = start(shell)
        let running = try XCTUnwrap(shell.statusBar.queueNotice)
        XCTAssertTrue(running.text.hasPrefix("Queue (dry run): "), running.text)
        XCTAssertTrue(running.isRunning)
        XCTAssertTrue(running.isDryRun)
        XCTAssertFalse(try XCTUnwrap(shell.statusBar.queueStopButton).isHidden)
        XCTAssertTrue(try XCTUnwrap(shell.statusBar.queueDismissButton).isHidden)
        XCTAssertTrue(shell.statusBar.hasContent, "the bar shows while a queue runs")

        try XCTUnwrap(shell.statusBar.queueStopButton).performClick(nil)
        XCTAssertFalse(queue.isRunning)
        let stopped = try XCTUnwrap(shell.statusBar.queueNotice, "an ended queue stays until dismissed")
        XCTAssertEqual(stopped.text, "Queue (dry run) stopped: Stopped by the user.")
        XCTAssertFalse(stopped.isFailure)
        XCTAssertTrue(try XCTUnwrap(shell.statusBar.queueStopButton).isHidden)

        try XCTUnwrap(shell.statusBar.queueDismissButton).performClick(nil)
        XCTAssertNil(shell.statusBar.queueNotice)
        XCTAssertFalse(shell.statusBar.hasContent)
    }

    func testTheQueueComesFirstAndACrashNoticeFollowsIt() throws {
        let bar = StatusBarView(frame: NSRect(x: 0, y: 0, width: 1200, height: StatusBarView.height))
        bar.showUpdate(version: "nightly-2026.09.29")
        bar.showQueue(StatusBarView.QueueNotice(text: "Queue: #52 waiting for the nightly, 3 of 7", isRunning: true,
                                                isDryRun: false))
        bar.layoutSubtreeIfNeeded()
        let queue = try XCTUnwrap(bar.queueButton)
        let stop = try XCTUnwrap(bar.queueStopButton)
        let update = try XCTUnwrap(bar.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue.hasPrefix("● Update") })
        XCTAssertEqual(queue.title, "● Queue: #52 waiting for the nightly, 3 of 7")
        XCTAssertLessThan(queue.frame.maxX, stop.frame.minX)
        XCTAssertLessThan(stop.frame.maxX, update.frame.minX, "the update notice follows the queue")
        XCTAssertGreaterThan(update.frame.width, 100)

        var clicks: [String] = []
        bar.onQueueClick = { clicks.append("board") }
        bar.onQueueStop = { clicks.append("stop") }
        queue.performClick(nil)
        stop.performClick(nil)
        XCTAssertEqual(clicks, ["board", "stop"])
    }

    // MARK: - Keep-awake

    func testARunningQueueKeepsTheMacAwakeUnderTheSameSetting() {
        let harness = KeepAwakeHarness()
        harness.controller.update(mergeQueueRunning: true)
        XCTAssertTrue(harness.controller.isActive)
        XCTAssertEqual(harness.assertions.held.count, 1)
        harness.controller.update(workingAgentCount: 1)
        harness.controller.update(workingAgentCount: 0)
        XCTAssertTrue(harness.controller.isActive, "the queue still runs")
        harness.clock.advance(by: KeepAwakeController.gracePeriod + 1)
        XCTAssertTrue(harness.controller.isActive)

        harness.controller.update(mergeQueueRunning: false)
        XCTAssertTrue(harness.controller.isActive, "released after the grace period, as for agents")
        harness.clock.advance(by: KeepAwakeController.gracePeriod + 1)
        XCTAssertFalse(harness.controller.isActive)
        XCTAssertEqual(harness.assertions.held, [])

        let disabled = KeepAwakeHarness(enabled: false)
        disabled.controller.update(mergeQueueRunning: true)
        XCTAssertFalse(disabled.controller.isActive, "off means off, queue or not")
        disabled.controller.setEnabled(true)
        XCTAssertTrue(disabled.controller.isActive)
    }

    func testTheShellTellsKeepAwakeWhileAQueueRuns() {
        let shell = makeShell(FakeQueueClient(world: readyWorld(), isDryRun: true))
        let harness = KeepAwakeHarness()
        shell.keepAwake = harness.controller
        let queue = start(shell)
        XCTAssertTrue(harness.controller.isMergeQueueRunning)
        queue.stop()
        XCTAssertFalse(harness.controller.isMergeQueueRunning)
        XCTAssertEqual(
            KeepAwakeIndicator.toolTip(workingAgentCount: 0, isMergeQueueRunning: true),
            "Keeping your Mac awake while a merge queue runs."
        )
        XCTAssertEqual(
            KeepAwakeIndicator.toolTip(workingAgentCount: 2, isMergeQueueRunning: true),
            "Keeping your Mac awake while a merge queue runs and 2 agents work."
        )
    }

    // MARK: - Quitting

    /// The quit question, answered by the test.
    private final class QuitQuestion {
        var asked: [String] = []
        var answer: (@MainActor (Bool) -> Void)?
    }

    private func recordQuitQuestions(_ shell: NiruxShellView) -> QuitQuestion {
        let question = QuitQuestion()
        shell.sideEffects.confirmQuitWithMergeQueue = { message, details, _, answer in
            question.asked.append(message + "\n" + details)
            question.answer = answer
        }
        return question
    }

    func testQuittingWithoutAQueueDoesNotAsk() {
        let shell = makeShell(FakeQueueClient(isDryRun: true))
        let question = recordQuitQuestions(shell)
        XCTAssertEqual(shell.mergeQueueTerminateReply { _ in XCTFail("no later answer") }, .terminateNow)
        XCTAssertTrue(question.asked.isEmpty)
    }

    func testQuittingAsksFirstAndKeepRunningCancels() throws {
        let shell = makeShell(FakeQueueClient(world: waitingWorld(), isDryRun: true))
        let question = recordQuitQuestions(shell)
        let queue = start(shell)
        var replies: [Bool] = []

        XCTAssertEqual(shell.mergeQueueTerminateReply { replies.append($0) }, .terminateLater)
        XCTAssertTrue(question.asked.isEmpty, "asked after AppKit hears .terminateLater")
        waitUntil("the question") { !question.asked.isEmpty }
        XCTAssertTrue(question.asked[0].hasPrefix("A dry-run merge queue is running\nacme/widgets: "), question.asked[0])
        XCTAssertEqual(shell.mergeQueueTerminateReply { _ in XCTFail("a second quit waits for the first") }, .terminateCancel)

        try XCTUnwrap(question.answer)(false)
        XCTAssertEqual(replies, [false])
        XCTAssertTrue(queue.isRunning, "Keep Running keeps it running")
        queue.stop()
    }

    func testQuittingStopsTheQueueAndWaitsForAMergeAlreadySent() throws {
        let client = HeldMutationClient(world: readyWorld())
        let shell = makeShell(client)
        let question = recordQuitQuestions(shell)
        let queue = start(shell)
        waitUntil("the merge is sent") { client.isHoldingMutation }
        var replies: [Bool] = []

        XCTAssertEqual(shell.mergeQueueTerminateReply { replies.append($0) }, .terminateLater)
        waitUntil("the question") { question.answer != nil }
        XCTAssertTrue(question.asked[0].hasPrefix("A merge queue is running\n"), question.asked[0])
        try XCTUnwrap(question.answer)(true)
        XCTAssertEqual(queue.engine?.phase, .stopping, "a merge can't be taken back: its answer is awaited")
        XCTAssertEqual(replies, [], "Nirux doesn't quit before the merge answers")

        client.release()
        waitUntil("the queue stops once the merge answered") { !queue.isRunning }
        XCTAssertEqual(replies, [true])
        guard case .stopped(let reason)? = queue.engine?.phase else { return XCTFail("not stopped") }
        XCTAssertTrue(reason.message.contains("Check #52 on GitHub: it may be merged."), reason.message)
    }

    func testTheWindowsCloseButtonAsksOnceThenTheQuitStopsTheQueue() throws {
        let shell = makeShell(FakeQueueClient(world: waitingWorld(), isDryRun: true))
        let question = recordQuitQuestions(shell)
        let queue = start(shell)
        var quits = 0

        XCTAssertFalse(shell.confirmCloseWithMergeQueues { quits += 1 })
        XCTAssertEqual(question.asked.count, 1)
        XCTAssertTrue(question.asked[0].hasPrefix("A dry-run merge queue is running: closing the window quits Nirux"))
        try XCTUnwrap(question.answer)(true)
        XCTAssertEqual(quits, 1)
        XCTAssertTrue(queue.isRunning, "the quit that follows stops it")

        XCTAssertEqual(shell.mergeQueueTerminateReply { _ in XCTFail("stopped at once") }, .terminateNow)
        XCTAssertEqual(question.asked.count, 1, "asked once")
        XCTAssertFalse(queue.isRunning)
        XCTAssertTrue(shell.confirmCloseWithMergeQueues { XCTFail("nothing runs: nothing to ask") })
    }
}

/// Answers reads like `FakeQueueClient`, and holds each mutation, off the
/// main thread, until the test releases it: a merge sent and not answered.
final class HeldMutationClient: MergeQueueGitHub, @unchecked Sendable {
    private let reads: FakeQueueClient
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var holding = false

    init(world: MQ.World) {
        reads = FakeQueueClient(world: world)
    }

    var isDryRun: Bool { false }
    var isHoldingMutation: Bool { lock.withLock { holding } }

    func release() { gate.signal() }

    func read(_ read: MergeQueue.Read, settings: BoardConfig.QueueSettings) -> Result<MergeQueue.ReadResult, MergeQueue.ClientError> {
        reads.read(read, settings: settings)
    }

    func mutate(_ mutation: MergeQueue.Mutation, settings: BoardConfig.QueueSettings) -> MergeQueue.MutationResult {
        lock.withLock { holding = true }
        gate.wait()
        lock.withLock { holding = false }
        return .sent
    }

    func commandLine(_ mutation: MergeQueue.Mutation, settings: BoardConfig.QueueSettings) -> String { "gh \(mutation)" }
}
