import AppKit
import XCTest
@testable import Nirux

/// What a running queue does beyond the board: the status bar, keep-awake,
/// and a quit that asks first and waits for a call already sent.
final class MergeQueueShellTests: XCTestCase {
    private var root: URL!
    private var previousStateDirectory: String?

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nirux-merge-queue-shell-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("state"), withIntermediateDirectories: true)
        previousStateDirectory = ProcessInfo.processInfo.environment["NIRUX_STATE_DIR"]
        setenv("NIRUX_STATE_DIR", root.appendingPathComponent("state").path, 1)
    }

    override func tearDown() {
        MergeQueueController.waitForFiles()
        if let previousStateDirectory {
            setenv("NIRUX_STATE_DIR", previousStateDirectory, 1)
        } else {
            unsetenv("NIRUX_STATE_DIR")
        }
        if let root { try? FileManager.default.removeItem(at: root) }
        super.tearDown()
    }

    @MainActor
    private func makeShell(_ client: any MergeQueueGitHub) -> NiruxShellView {
        _ = NSApplication.shared
        let shell = NiruxShellView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        shell.stopHeartbeat()
        shell.mergeQueueClient = client
        shell.mergeQueueLockFolder = root.appendingPathComponent("locks")
        return shell
    }

    /// A pull request ready to merge: the engine reaches its merge without a wait.
    @MainActor
    private func readyWorld() -> MQ.World {
        var world = MQ.World()
        world.pullRequests[52] = MQ.pullRequest(52, head: MQ.sha("a"))
        world.checks[MQ.sha("a")] = MQ.checks(MQ.checkRun(id: 1))
        return world
    }

    /// A pull request whose checks still run: the queue waits 20 s between looks.
    @MainActor
    private func waitingWorld() -> MQ.World {
        var world = readyWorld()
        world.checks[MQ.sha("a")] = MQ.checks(MQ.checkRun(id: 1, status: "IN_PROGRESS", conclusion: nil))
        return world
    }

    @MainActor
    private func start(_ shell: NiruxShellView, projectID: String = "project") -> MergeQueueController {
        let queue = shell.mergeQueue(projectID: projectID)
        queue.beginActivity = { NSObject() }
        queue.endActivity = { _ in }
        XCTAssertNil(queue.start(settings: MQ.settings(), entries: [MQ.entry(52, head: MQ.sha("a"))]))
        return queue
    }

    @MainActor
    private func waitUntil(_ what: String, timeout: TimeInterval = 10, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(condition(), "timed out: \(what)")
    }

    // MARK: - Status bar

    @MainActor
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

    @MainActor
    func testTheStatusBarShowsTheQueueThatEndedLast() throws {
        let shell = makeShell(FakeQueueClient(world: waitingWorld(), isDryRun: true))
        // "aaa" comes first in order, and ends first.
        let older = start(shell, projectID: "aaa")
        older.stop()
        let newer = shell.mergeQueue(projectID: "bbb")
        newer.beginActivity = { NSObject() }
        newer.endActivity = { _ in }
        let gadgets = BoardConfig.QueueSettings(
            repository: "acme/gadgets", gitHubRepository: GitHubRepository(owner: "acme", name: "gadgets"),
            baseBranch: "main", requiredChecks: ["test"], postMergeWorkflow: "nightly.yml", mergeMethod: .merge,
            checksTimeoutMinutes: 30, postMergeTimeoutMinutes: 30
        )
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        XCTAssertNil(newer.start(settings: gadgets, entries: [MQ.entry(53, head: MQ.sha("b"))]))
        newer.stop()

        let notice = try XCTUnwrap(shell.statusBar.queueNotice)
        XCTAssertTrue(notice.tooltip?.contains("acme/gadgets") == true, "the newer stop isn’t hidden behind the older one")
    }

    @MainActor
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

    @MainActor
    func testOnANarrowBarTheQueueShrinksSoACrashNoticeKeepsItsButtons() throws {
        _ = NSApplication.shared
        let report = try XCTUnwrap(CrashReportParser.report(from: CrashReportFixtures.report()))
        let crash = CrashNotice(report: report, reportURL: URL(fileURLWithPath: "/tmp/Nirux-2026-09-29.ips"),
                                date: Date(timeIntervalSince1970: 1_790_500_488), reportCount: 1)
        let bar = StatusBarView(frame: NSRect(x: 0, y: 0, width: 600, height: StatusBarView.height))
        bar.showCrash(crash)
        bar.showQueue(StatusBarView.QueueNotice(text: "Queue: #52 waiting for the checks of #52, 3 of 7", isRunning: true,
                                                isDryRun: false))
        for width in stride(from: CGFloat(600), through: 900, by: 50) {
            bar.setFrameSize(NSSize(width: width, height: StatusBarView.height))
            bar.layoutSubtreeIfNeeded()
            let visible = bar.subviews.compactMap { $0 as? NSButton }.filter { !$0.isHidden }
            let crashDismiss = try XCTUnwrap(visible.last { $0.title == "✕" })
            XCTAssertLessThanOrEqual(crashDismiss.frame.maxX, bar.bounds.width - 120 - 16, "✕ clear of the version at \(width)")
            for button in visible {
                XCTAssertTrue(bar.hitTest(NSPoint(x: button.frame.midX, y: button.frame.midY)) === button,
                              "\(button.title) takes its clicks at \(width)")
            }
            let label = try XCTUnwrap(bar.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue.hasPrefix("● Nirux crashed") })
            XCTAssertGreaterThanOrEqual(label.frame.width, 79, "the crash stays readable at \(width)")
        }
    }

    @MainActor
    func testWithSeveralQueuesTheStatusBarStopsThemAll() throws {
        let shell = makeShell(FakeQueueClient(world: waitingWorld(), isDryRun: true))
        let first = start(shell, projectID: "first")
        let second = shell.mergeQueue(projectID: "second")
        second.beginActivity = { NSObject() }
        second.endActivity = { _ in }
        var gadgets = MQ.settings()
        gadgets = BoardConfig.QueueSettings(
            repository: "acme/gadgets", gitHubRepository: GitHubRepository(owner: "acme", name: "gadgets"),
            baseBranch: gadgets.baseBranch, requiredChecks: gadgets.requiredChecks, postMergeWorkflow: gadgets.postMergeWorkflow,
            mergeMethod: gadgets.mergeMethod, checksTimeoutMinutes: 30, postMergeTimeoutMinutes: 30
        )
        XCTAssertNil(second.start(settings: gadgets, entries: [MQ.entry(52, head: MQ.sha("a"))]))

        let notice = try XCTUnwrap(shell.statusBar.queueNotice)
        XCTAssertTrue(notice.text.hasSuffix("(+1 other queue)"), notice.text)
        XCTAssertEqual(shell.statusBar.queueStopButton?.title, "Stop All")
        XCTAssertEqual(shell.statusBar.queueStopButton?.isEnabled, true)
        try XCTUnwrap(shell.statusBar.queueStopButton).performClick(nil)
        XCTAssertFalse(first.isRunning)
        XCTAssertFalse(second.isRunning, "Stop reaches the queue the bar doesn’t name")
    }

    // MARK: - Spaces

    @MainActor
    func testASpaceWhoseQueueRunsIsNotDeleted() {
        let shell = makeShell(FakeQueueClient(world: waitingWorld(), isDryRun: true))
        var alerts: [String] = []
        shell.sideEffects.runModal = { alert in
            alerts.append(alert.messageText)
            return .alertSecondButtonReturn
        }
        let space = shell.workspaceStore.createProfile(named: "Widgets")
        let queue = start(shell, projectID: space.id)

        shell.confirmDeleteSpace(profileID: space.id)
        XCTAssertEqual(alerts, ["This project’s merge queue is running"])
        shell.deleteSpace(profileID: space.id)
        XCTAssertTrue(shell.profiles.contains { $0.id == space.id }, "its folders would leave the queue's local checks")
        queue.stop()
    }

    // MARK: - Keep-awake

    @MainActor
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

    @MainActor
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
    @MainActor
    private final class QuitQuestion {
        var asked: [String] = []
        var answer: (@MainActor (Bool) -> Void)?
    }

    @MainActor
    private func recordQuitQuestions(_ shell: NiruxShellView) -> QuitQuestion {
        let question = QuitQuestion()
        shell.sideEffects.confirmQuitWithMergeQueue = { message, details, _, _, answer in
            question.asked.append(message + "\n" + details)
            question.answer = answer
        }
        return question
    }

    @MainActor
    func testQuittingWithoutAQueueDoesNotAsk() {
        let shell = makeShell(FakeQueueClient(isDryRun: true))
        let question = recordQuitQuestions(shell)
        XCTAssertEqual(shell.mergeQueueTerminateReply { _ in XCTFail("no later answer") }, .terminateNow)
        XCTAssertTrue(question.asked.isEmpty)
    }

    @MainActor
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

    @MainActor
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

    @MainActor
    func testNoQueueStartsOnceAQuitIsAsked() throws {
        let shell = makeShell(FakeQueueClient(world: waitingWorld(), isDryRun: true))
        _ = recordQuitQuestions(shell)
        let running = start(shell, projectID: "first")
        XCTAssertEqual(shell.mergeQueueTerminateReply { _ in }, .terminateLater)

        // Another project, fully configured: without the guard, its queue would start.
        let space = shell.workspaceStore.createProfile(named: "Gadgets")
        let gadgets = BoardConfig(repository: "acme/gadgets", baseBranch: "main", requiredChecks: ["test"],
                                  postMergeWorkflow: .workflow("nightly.yml"))
        _ = try XCTUnwrap(BoardConfigStore(spaceID: space.id)).save(gadgets)
        let settings = try XCTUnwrap(BoardConfigStore(spaceID: space.id)?.load().queueSettings)
        var reading = MergeQueue.ConfirmationReading(settings: settings, isDryRun: true)
        reading.rateLimit = MergeQueue.RateLimit(coreRemaining: 5000, coreReset: Date(), graphQLRemaining: 5000, graphQLReset: Date())
        reading.baseMergeQueue = false
        reading.baseRuns = []
        var candidate = MergeQueue.ConfirmationReading.Candidate(number: 7)
        candidate.pullRequest = MQ.pullRequest(7, head: MQ.sha("b"), repository: settings.gitHubRepository)
        candidate.checks = MQ.checks(MQ.checkRun(id: 1))
        candidate.comparison = .some(MergeQueue.Comparison(status: "ahead", aheadBy: 1, behindBy: 0, baseCommit: MQ.sha("0")))
        candidate.local = MergeQueue.LocalState()
        reading.candidates = [candidate]
        let confirmation = MergeQueue.confirmation(reading)
        XCTAssertTrue(confirmation.canStart)
        let panel = MergeQueueConfirmationPanel(projectID: space.id, isDryRun: true, numbers: [7])
        panel.show(attachedTo: nil, repository: "acme/gadgets", baseBranch: "main")
        defer { panel.dismiss() }

        shell.confirmMergeQueueStart(confirmation, panel: panel)
        XCTAssertEqual(panel.statusLabel?.stringValue, "Nirux is quitting.")
        XCTAssertNil(shell.mergeQueues[space.id]?.engine, "nothing started")
        running.stop()
    }

    /// The close button's quit comes from a main-queue block if anything
    /// defers it there: AppKit then waits inside that block, where the main
    /// queue runs nothing else. The question must still come.
    @MainActor
    func testTheQuestionComesWhenTheQuitWaitsInsideAMainQueueBlock() {
        let shell = makeShell(FakeQueueClient(world: waitingWorld(), isDryRun: true))
        let question = recordQuitQuestions(shell)
        let queue = start(shell)
        let asked = Flag()
        let done = expectation(description: "the block ends")
        DispatchQueue.main.async { @MainActor in
            XCTAssertEqual(shell.mergeQueueTerminateReply { _ in }, .terminateLater)
            // AppKit's wait for the answer: a modal-panel run loop, inside this block.
            let deadline = Date().addingTimeInterval(5)
            while question.asked.isEmpty, Date() < deadline {
                RunLoop.main.run(mode: .modalPanel, before: Date().addingTimeInterval(0.02))
            }
            asked.value = !question.asked.isEmpty
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        XCTAssertTrue(asked.value)
        question.answer?(false)
        queue.stop()
    }

    @MainActor
    private final class Flag {
        var value = false
    }

    @MainActor
    func testTheWindowsCloseButtonQuitsThroughTheOneQuestion() throws {
        let shell = makeShell(FakeQueueClient(world: waitingWorld(), isDryRun: true))
        let question = recordQuitQuestions(shell)
        var quits = 0
        shell.sideEffects.requestQuit = { quits += 1 }
        XCTAssertTrue(shell.mainWindowShouldClose(), "nothing runs: the window closes, and Nirux quits")
        let queue = start(shell)

        XCTAssertFalse(shell.mainWindowShouldClose(), "the window stays while a queue runs")
        XCTAssertEqual(quits, 1, "and Nirux quits, which asks")
        XCTAssertTrue(question.asked.isEmpty, "the quit asks, not the close button")
        var replies: [Bool] = []
        XCTAssertEqual(shell.mergeQueueTerminateReply { replies.append($0) }, .terminateLater)
        waitUntil("the question") { question.answer != nil }
        try XCTUnwrap(question.answer)(true)
        XCTAssertFalse(queue.isRunning)
        XCTAssertEqual(replies, [true])
        XCTAssertEqual(question.asked.count, 1, "asked once")
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
