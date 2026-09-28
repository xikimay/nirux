import AppKit
import XCTest
@testable import Nirux

/// The queue as the board shows it (its Queue column and its header line),
/// the next Start's list, and what the confirmation sheet reads.
final class MergeQueueBoardTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nirux-merge-queue-board-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        MergeQueueController.waitForFiles()
        if let root { try? FileManager.default.removeItem(at: root) }
        super.tearDown()
    }

    private func row(
        _ number: Int, isDraft: Bool = false, base: String = "main", mergeable: String = "MERGEABLE", state: String = "OPEN",
        agent: ProjectBoard.AgentState = .idle
    ) -> ProjectBoard.Row {
        ProjectBoard.Row(
            group: .active, worktreePath: "/tmp/app.feat-\(number)", branch: "feat/\(number)", detachedHead: nil,
            workspaces: [], pullRequest: ProjectBoard.PullRequest(
                number: number, state: state, headRefName: "feat/\(number)", headOid: MQ.sha("a"), baseRefName: base,
                isDraft: isDraft, mergeable: mergeable, checks: [], url: "https://github.com/acme/widgets/pull/\(number)",
                isFromConfiguredRepository: true
            ),
            agent: ProjectBoard.Agent(state: agent), folder: nil
        )
    }

    private func entry(_ number: Int, _ step: MergeQueue.Step) -> MergeQueue.Entry {
        var entry = MergeQueue.Entry(MQ.entry(number, head: MQ.sha("a")))
        entry.step = step
        return entry
    }

    private func cell(_ row: ProjectBoard.Row, _ queue: ProjectBoard.QueueState) -> ProjectBoardView.QueueCell? {
        ProjectBoardView.queueCell(for: row, queue: queue, baseBranch: "main")
    }

    // MARK: - The Queue column

    func testAReadyPullRequestOffersAddToQueueAndOtherRowsSayWhyNot() {
        let queue = ProjectBoard.QueueState(isDryRun: false)

        let ready = cell(row(1), queue)
        XCTAssertEqual(ready?.button?.title, "Add to Queue")
        XCTAssertEqual(ready?.action, .addToQueue(number: 1))
        XCTAssertEqual(ready?.text, "")
        XCTAssertEqual(cell(row(2, isDraft: true), queue)?.text, "draft")
        XCTAssertEqual(cell(row(3, base: "dev"), queue)?.text, "targets dev")
        XCTAssertEqual(cell(row(4, mergeable: "CONFLICTING"), queue)?.text, "conflict")
        XCTAssertEqual(cell(row(5, agent: .working(duration: "3m")), queue)?.text, "agent working")
        XCTAssertEqual(cell(row(6, agent: .waiting(.permission(tool: "Bash", summary: nil))), queue)?.text, "agent waiting (permission · Bash)")
        XCTAssertNil(cell(row(7, isDraft: true), queue)?.button, "no button where the queue would refuse it")
        XCTAssertNil(cell(row(8, state: "MERGED"), queue), "a merged pull request has nothing to queue")
        var noPullRequest = row(9)
        noPullRequest = ProjectBoard.Row(group: .active, worktreePath: "/tmp/x", branch: "x", detachedHead: nil, workspaces: [],
                                         pullRequest: nil, agent: ProjectBoard.Agent(), folder: nil)
        XCTAssertNil(cell(noPullRequest, queue))
    }

    func testAQueuedPullRequestShowsItsPlaceWithRemoveUntilTheQueueRuns() {
        var queue = ProjectBoard.QueueState(isDryRun: false)
        queue.selection = [7, 3]

        let queued = cell(row(3), queue)
        XCTAssertEqual(queued?.text, "queued · 2")
        XCTAssertEqual(queued?.button?.title, "✕")
        XCTAssertEqual(queued?.button?.tooltip, "Remove #3 from the queue")
        XCTAssertEqual(queued?.action, .removeFromQueue(number: 3))
        XCTAssertEqual(queued?.button?.isEnabled, true)

        queue.isConfirming = true
        XCTAssertEqual(cell(row(1), queue)?.button?.isEnabled, false, "the sheet shows the list as it opened")
        XCTAssertEqual(cell(row(3), queue)?.button?.isEnabled, false)
        queue.isConfirming = false
        queue.run = .elsewhere
        XCTAssertEqual(cell(row(1), queue)?.button?.isEnabled, false, "read-only while another Nirux runs the queue")
        XCTAssertEqual(cell(row(3), queue)?.button?.isEnabled, false)
    }

    func testARunningQueueShowsEachPlaceAndStepWithoutButtons() {
        var queue = ProjectBoard.QueueState(isDryRun: false)
        queue.run = .running(isStopping: false)
        queue.workflow = "nightly.yml"
        queue.selection = [1, 2, 3, 4]
        queue.entries = [
            entry(1, .done),
            entry(2, .waitingForPostMerge(MQ.sha("m"))),
            entry(3, .waiting),
            entry(4, .stopped(MergeQueue.StopReason(kind: .conflict, message: "#4 conflicts with main."))),
        ]

        XCTAssertEqual(cell(row(1), queue), ProjectBoardView.QueueCell(text: "merged ✓", tone: .success))
        XCTAssertEqual(cell(row(2), queue), ProjectBoardView.QueueCell(text: "2 of 4 · waiting for nightly", tone: .active))
        XCTAssertEqual(cell(row(3), queue)?.text, "3 of 4 · waiting")
        XCTAssertEqual(cell(row(4), queue)?.text, "stopped: conflict")
        XCTAssertEqual(cell(row(4), queue)?.tooltip, "#4 conflicts with main.")
        XCTAssertEqual(cell(row(4), queue)?.tone, .failure)
        XCTAssertEqual(cell(row(5), queue)?.button?.isEnabled, false, "nothing joins a running queue")
    }

    func testAfterAQueueStopsItsLastWordShowsNextToTheNextStart() {
        var queue = ProjectBoard.QueueState(isDryRun: false)
        queue.run = .ended
        let conflict = MergeQueue.StopReason(kind: .conflict, message: "#4 conflicts with main.")
        queue.entries = [entry(1, .done), entry(4, .stopped(conflict)), entry(5, .waiting)]
        queue.selection = [4, 5]

        XCTAssertEqual(cell(row(1), queue)?.text, "merged ✓")
        XCTAssertEqual(cell(row(4), queue)?.text, "queued · 1")
        XCTAssertEqual(cell(row(4), queue)?.detail, "last: conflict")
        XCTAssertEqual(cell(row(4), queue)?.detailTone, .failure)
        XCTAssertEqual(cell(row(4), queue)?.tooltip, "Last queue: #4 conflicts with main.")
        XCTAssertEqual(cell(row(4), queue)?.button?.isEnabled, true)
        XCTAssertEqual(cell(row(5), queue)?.text, "queued · 2")
        queue.selection = [5]
        XCTAssertEqual(cell(row(4, mergeable: "CONFLICTING"), queue)?.text, "conflict")
        XCTAssertEqual(cell(row(4, mergeable: "CONFLICTING"), queue)?.detail, "last: conflict")
        XCTAssertEqual(cell(row(4), queue)?.text, "")
        XCTAssertEqual(cell(row(4), queue)?.detail, "last: conflict")
        XCTAssertEqual(cell(row(4), queue)?.button?.title, "Add to Queue")
    }

    // MARK: - The header's queue line

    func testTheHeaderOffersStartOnlyWithAValidConfigAndAList() {
        var queue = ProjectBoard.QueueState(isDryRun: false)
        var header = ProjectBoardView.queueHeader(queue)
        XCTAssertEqual(header.text, "Queue: add pull requests with Add to Queue, then Start")
        XCTAssertEqual(header.start?.isEnabled, false)
        XCTAssertEqual(header.start?.tooltip, "Add pull requests to the queue first.")
        XCTAssertNil(header.stop)

        queue.selection = [3]
        header = ProjectBoardView.queueHeader(queue)
        XCTAssertEqual(header.text, "Queue: 1 pull request queued")
        XCTAssertEqual(header.start, ProjectBoardView.QueueButton(
            title: "Start…", isEnabled: true,
            tooltip: "Read the queued pull requests on GitHub, then confirm what the queue will do"
        ))

        queue.startProblems = ["Choose the post-merge workflow in Board Settings…, or None."]
        XCTAssertEqual(ProjectBoardView.queueHeader(queue).start?.isEnabled, false)
        XCTAssertEqual(ProjectBoardView.queueHeader(queue).start?.tooltip, queue.startProblems[0])
        queue.startProblems = []
        queue.isConfirming = true
        XCTAssertEqual(ProjectBoardView.queueHeader(queue).start?.isEnabled, false)
    }

    func testARunningQueueShowsStopAndADryRunSaysSoEverywhere() {
        var queue = ProjectBoard.QueueState(isDryRun: true)
        queue.selection = [3]
        XCTAssertEqual(ProjectBoardView.queueHeader(queue).start?.title, "Start Dry Run…")
        XCTAssertTrue(ProjectBoardView.queueHeader(queue).isDryRun)

        queue.run = .running(isStopping: false)
        queue.status = "#3 waiting for the checks of #3, 1 of 1"
        var header = ProjectBoardView.queueHeader(queue)
        XCTAssertEqual(header.text, "Queue: #3 waiting for the checks of #3, 1 of 1")
        XCTAssertNil(header.start)
        XCTAssertEqual(header.stop?.title, "Stop")
        XCTAssertEqual(header.stop?.isEnabled, true)

        queue.run = .running(isStopping: true)
        header = ProjectBoardView.queueHeader(queue)
        XCTAssertEqual(header.stop?.title, "Stopping…")
        XCTAssertEqual(header.stop?.isEnabled, false)
    }

    func testAnInterruptedQueueAndOneRunningElsewhereSaySo() {
        var queue = ProjectBoard.QueueState(isDryRun: false)
        queue.run = .ended
        queue.status = "Stopped: Interrupted while waiting for the nightly of #52: Nirux quit."
        queue.statusIsFailure = true
        queue.selection = [52]
        var header = ProjectBoardView.queueHeader(queue)
        XCTAssertEqual(header.text, "Queue: Stopped: Interrupted while waiting for the nightly of #52: Nirux quit. · 1 pull request queued")
        XCTAssertEqual(header.tone, .failure)
        XCTAssertEqual(header.start?.isEnabled, true, "Start opens a new confirmation")

        queue.run = .elsewhere
        queue.status = "waiting for the nightly of #52, 1 of 2"
        header = ProjectBoardView.queueHeader(queue)
        XCTAssertEqual(header.text, "Queue: running in another Nirux, read-only here · waiting for the nightly of #52, 1 of 2")
        XCTAssertEqual(header.start?.isEnabled, false)
        XCTAssertNil(header.stop, "only the Nirux that runs it stops it")
    }

    // MARK: - The next Start's list

    @MainActor
    private func controller(_ client: any MergeQueueGitHub = FakeQueueClient(isDryRun: true)) -> MergeQueueController {
        let controller = MergeQueueController(
            projectID: "project", client: client,
            local: MergeQueueLocalAccess(folders: { [] }, busyAgents: { _, _ in [] }),
            stateDirectory: root.appendingPathComponent("state"), lockFolder: root.appendingPathComponent("locks")
        )
        controller.beginActivity = { NSObject() }
        controller.endActivity = { _ in }
        return controller
    }

    @MainActor
    func testTheListKeepsNumberOrderUntilTheUserReordersIt() {
        let queue = controller()
        var changes = 0
        queue.onChange = { changes += 1 }

        queue.addToSelection(12)
        queue.addToSelection(7)
        queue.addToSelection(7)
        XCTAssertEqual(queue.selection, [7, 12], "oldest first by default")
        queue.removeFromSelection(12)
        XCTAssertEqual(queue.selection, [7])
        XCTAssertEqual(changes, 3)

        queue.addToSelection(3)
        XCTAssertNil(queue.start(settings: MQ.settings(), entries: [MQ.entry(7, head: MQ.sha("a"))]))
        XCTAssertEqual(queue.selection, [7], "the confirmed list: what the sheet left out leaves it")
        queue.addToSelection(9)
        XCTAssertEqual(queue.selection, [7], "nothing joins a running queue")
        queue.stop()

        XCTAssertNil(queue.start(settings: MQ.settings(), entries: [
            MQ.entry(9, head: MQ.sha("b")), MQ.entry(7, head: MQ.sha("a"))
        ]))
        queue.stop()
        queue.addToSelection(8)
        XCTAssertEqual(queue.selection, [9, 7, 8], "after the user's order, additions go at the end")
    }

    @MainActor
    func testARelaunchProposesWhatTheLastQueueDidNotMerge() throws {
        let first = controller()
        let conflict = MergeQueue.StopReason(kind: .conflict, message: "#4 conflicts with main.")
        var engine = MergeQueue.Engine(settings: MQ.settings(), entries: [
            MQ.entry(1, head: MQ.sha("a")), MQ.entry(4, head: MQ.sha("b")), MQ.entry(5, head: MQ.sha("c"))
        ])
        _ = engine.handle(.start, now: 0)
        var saved = MergeQueue.SavedQueue(engine: engine, dryRun: true, savedAt: Date())
        saved.status = .stopped
        saved.stopReason = conflict
        saved.entries[0].step = .done
        saved.entries[1].step = .stopped(conflict)
        saved.save(to: try XCTUnwrap(first.files?.state))

        XCTAssertEqual(controller().selection, [4, 5])
    }

    // MARK: - What the sheet reads

    @MainActor
    func testTheSheetReadsEachPullRequestAndSkipsWhatALeftOutOneNeeds() throws {
        var world = MQ.World()
        world.pullRequests[1] = MQ.pullRequest(1, head: MQ.sha("a"))
        world.pullRequests[2] = MQ.pullRequest(2, head: MQ.sha("b"), isDraft: true)
        world.behind[MQ.sha("a")] = 2
        let client = FakeQueueClient(world: world, isDryRun: true)
        let queue = controller(client)
        var busyAsked: [[String]] = []
        queue.local.busyAgents = { worktrees, _ in
            busyAsked.append(worktrees)
            XCTAssertTrue(Thread.isMainThread)
            return []
        }
        queue.local.inspect = { _, branch, _, _, _ in
            .success(MergeQueue.LocalInspection(
                worktrees: [MergeQueue.LocalWorktree(path: "/tmp/\(branch)", problem: nil)], allWorktreePaths: []
            ))
        }

        var reading: MergeQueue.ConfirmationReading?
        queue.readConfirmation(settings: MQ.settings(), numbers: [2, 1]) { reading = $0 }
        let deadline = Date().addingTimeInterval(10)
        while reading == nil, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }

        let read = try XCTUnwrap(reading)
        XCTAssertTrue(read.isDryRun)
        XCTAssertEqual(read.candidates.map(\.number), [2, 1], "in the list's order")
        XCTAssertEqual(busyAsked, [["/tmp/feat/1"]])
        let confirmation = MergeQueue.confirmation(read)
        XCTAssertEqual(confirmation.entries.map(\.number), [1])
        XCTAssertEqual(confirmation.excluded.map(\.reason), ["It is a draft."])
        XCTAssertEqual(confirmation.items.first?.notes, ["Behind main by 2 commits: the queue merges main into it first."])
        let reads = client.reads
        XCTAssertEqual(Array(reads.prefix(4)), [.auth, .rateLimit, .baseMergeQueue, .baseRuns], "the queue's own reads first")
        XCTAssertFalse(reads.contains(.checks(MQ.sha("b"))), "a draft is left out: its checks aren’t read")
        XCTAssertTrue(reads.contains(.checks(MQ.sha("a"))))
        XCTAssertTrue(reads.contains(.pullRequestDetails(2)), "its title, for the list of those left out")
        XCTAssertEqual(client.mutations, [], "reading changes nothing")
    }

    @MainActor
    func testASignedOutGhStopsTheSheetBeforeAnyPullRequestIsRead() {
        final class SignedOut: MergeQueueGitHub, @unchecked Sendable {
            var isDryRun: Bool { false }
            private let lock = NSLock()
            private var recorded: [MergeQueue.Read] = []
            var reads: [MergeQueue.Read] { lock.withLock { recorded } }
            func read(_ read: MergeQueue.Read, settings: BoardConfig.QueueSettings)
                -> Result<MergeQueue.ReadResult, MergeQueue.ClientError> {
                lock.withLock { recorded.append(read) }
                return .failure(.notSignedIn("You are not logged into any GitHub hosts."))
            }
            func mutate(_ mutation: MergeQueue.Mutation, settings: BoardConfig.QueueSettings) -> MergeQueue.MutationResult {
                XCTFail("no mutation")
                return .refused(status: nil, message: "")
            }
            func commandLine(_ mutation: MergeQueue.Mutation, settings: BoardConfig.QueueSettings) -> String { "" }
        }
        let client = SignedOut()
        let fetch = MergeQueueController.fetchConfirmation(
            settings: MQ.settings(), numbers: [1, 2], isDryRun: false, client: client, folders: [],
            inspect: { _, _, _, _, _ in XCTFail("no local read"); return .success(MergeQueue.LocalInspection()) }
        )
        XCTAssertEqual(client.reads, [.auth])
        XCTAssertEqual(fetch.reading.candidates, [])
        XCTAssertEqual(MergeQueue.confirmation(fetch.reading).refusals, [
            "gh isn’t signed in to github.com (You are not logged into any GitHub hosts.): run gh auth login in a terminal, "
                + "then Start again."
        ])
    }

    // MARK: - The details read

    func testTheDetailsQueryReadsTheTitleAndFilesAndFailsClosed() throws {
        let json = """
        {"data":{"repository":{"pullRequest":{"title":"Fix the nightly","files":{"pageInfo":{"hasNextPage":true},
        "nodes":[{"path":".github/workflows/nightly.yml"},{"path":"README.md"}]}}}}}
        """
        let details = try XCTUnwrap(MergeQueue.parsePullRequestDetails(Data(json.utf8)))
        XCTAssertEqual(details.title, "Fix the nightly")
        XCTAssertEqual(details.files, [".github/workflows/nightly.yml", "README.md"])
        XCTAssertTrue(details.hasMoreFiles)
        XCTAssertTrue(details.changesWorkflows)
        let noPageInfo = #"{"data":{"repository":{"pullRequest":{"title":"x","files":{"nodes":[]}}}}}"#
        XCTAssertNil(MergeQueue.parsePullRequestDetails(Data(noPageInfo.utf8)))
        XCTAssertTrue(GitHubCLIQueueClient.pullRequestDetailsArguments(repository: "acme/widgets", number: 7)
            .contains("number=7"))
    }
}
