import AppKit
import XCTest
@testable import Nirux

/// The queue's next Start's list, and what the confirmation sheet reads.
/// What the Board says of the queue is in `BoardStagesFactsTests`.
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

    // MARK: - The next Start's list

    @MainActor
    private func controller(_ client: any MergeQueueGitHub = FakeQueueClient(isDryRun: true)) -> MergeQueueController {
        let controller = MergeQueueController(
            projectID: "project", repository: MQ.widgets, client: client,
            local: MergeQueueLocalAccess(folders: { [] }, busyAgents: { _, _ in [] }, reviewTasks: { [] }),
            stateDirectory: root.appendingPathComponent("state"), lockFolder: root.appendingPathComponent("locks")
        )
        controller.beginActivity = { NSObject() }
        controller.endActivity = { _ in }
        return controller
    }

    @MainActor
    func testTheListKeepsNumberOrderUntilTheUserReordersIt() {
        let queue = controller()
        let widgets = MQ.widgets
        var changes = 0
        queue.onChange = { changes += 1 }

        queue.addToSelection(12, repository: widgets)
        queue.addToSelection(7, repository: widgets)
        queue.addToSelection(7, repository: widgets)
        XCTAssertEqual(queue.selection(for: widgets), [7, 12], "oldest first by default")
        queue.removeFromSelection(12)
        XCTAssertEqual(queue.selection(for: widgets), [7])
        XCTAssertEqual(changes, 3)

        queue.addToSelection(3, repository: widgets)
        XCTAssertNil(queue.start(settings: MQ.settings(), entries: [MQ.entry(7, head: MQ.sha("a"))]))
        XCTAssertEqual(queue.selection(for: widgets), [7], "the confirmed list: what the sheet left out leaves it")
        queue.addToSelection(9, repository: widgets)
        XCTAssertEqual(queue.selection(for: widgets), [7], "nothing joins a running queue")
        queue.stop()

        XCTAssertNil(queue.start(settings: MQ.settings(), entries: [
            MQ.entry(9, head: MQ.sha("b")), MQ.entry(7, head: MQ.sha("a"))
        ]))
        queue.stop()
        queue.addToSelection(8, repository: widgets)
        XCTAssertEqual(queue.selection(for: widgets), [9, 7, 8], "after the user's order, additions go at the end")

        queue.removeFromSelection(9)
        queue.addToSelection(5, repository: widgets)
        XCTAssertEqual(queue.selection(for: widgets), [7, 8, 5], "a removal keeps the user's order")
        [7, 8, 5].forEach(queue.removeFromSelection)
        queue.addToSelection(5, repository: widgets)
        queue.addToSelection(2, repository: widgets)
        XCTAssertEqual(queue.selection(for: widgets), [2, 5], "an emptied list starts over by number")
    }

    @MainActor
    func testTheListBelongsToItsRepository() {
        let queue = controller()
        queue.addToSelection(7, repository: MQ.widgets)
        XCTAssertEqual(queue.selection(for: GitHubRepository(owner: "ACME", name: "Widgets")), [7], "GitHub ignores case")
        let gadgets = GitHubRepository(owner: "acme", name: "gadgets")
        XCTAssertEqual(queue.selection(for: gadgets), [], "#7 of widgets isn’t #7 of gadgets")
        XCTAssertEqual(queue.selection(for: nil), [])
        queue.addToSelection(3, repository: gadgets)
        XCTAssertEqual(queue.selection(for: gadgets), [], "a queue never mixes repositories")
        XCTAssertEqual(queue.selection(for: MQ.widgets), [7])
    }

    @MainActor
    private func saveStoppedQueue(for controller: MergeQueueController, order: [Int]) throws {
        let conflict = MergeQueue.StopReason(kind: .conflict, message: "#4 conflicts with main.")
        var engine = MergeQueue.Engine(settings: MQ.settings(), entries: order.map { MQ.entry($0, head: MQ.sha("a")) })
        _ = engine.handle(.start, now: 0)
        var saved = MergeQueue.SavedQueue(engine: engine, dryRun: true, savedAt: Date())
        saved.status = .stopped
        saved.stopReason = conflict
        saved.entries[0].step = .done
        saved.entries[1].step = .stopped(conflict)
        saved.save(to: try XCTUnwrap(controller.files?.state))
    }

    @MainActor
    func testARelaunchProposesWhatTheLastQueueDidNotMergeInItsOrder() throws {
        try saveStoppedQueue(for: controller(), order: [1, 9, 5])

        let relaunched = controller()
        XCTAssertEqual(relaunched.selection(for: MQ.widgets), [9, 5], "for the saved queue’s repository")
        relaunched.addToSelection(8, repository: MQ.widgets)
        XCTAssertEqual(relaunched.selection(for: MQ.widgets), [9, 5, 8], "the user's order survives the relaunch")
        XCTAssertEqual(relaunched.selection(for: GitHubRepository(owner: "acme", name: "gadgets")), [])
    }

    @MainActor
    func testTheListDoesNotChangeWhileAnotherNiruxRunsTheQueue() throws {
        let lockFolder = root.appendingPathComponent("locks")
        let live = MergeQueueController(
            projectID: "project", repository: MQ.widgets, client: FakeQueueClient(),
            local: MergeQueueLocalAccess(folders: { [] }, busyAgents: { _, _ in [] }, reviewTasks: { [] }),
            stateDirectory: root.appendingPathComponent("state"), lockFolder: lockFolder
        )
        var engine = MergeQueue.Engine(settings: MQ.settings(), entries: [MQ.entry(4, head: MQ.sha("a"))])
        _ = engine.handle(.start, now: 0)
        MergeQueue.SavedQueue(engine: engine, dryRun: false, savedAt: Date()).save(to: try XCTUnwrap(live.files?.state))
        // Another Nirux holds the repository's lock: its queue runs.
        let lock = try XCTUnwrap(MergeQueueLock.acquire(repository: MQ.widgets, folder: lockFolder))
        defer { lock.release() }

        live.reloadSaved()
        XCTAssertTrue(live.runsElsewhere)
        live.addToSelection(7, repository: MQ.widgets)
        XCTAssertEqual(live.selection(for: MQ.widgets), [])
    }

    @MainActor
    func testTheLocalChecksKeepTheFoldersTheProjectHadAtStart() throws {
        let folders = FolderList(["/tmp/app", "/tmp/app.feat-4"])
        final class Inspected: @unchecked Sendable {
            private let lock = NSLock()
            private var recorded: [[String]] = []
            func append(_ folders: [String]) { lock.withLock { recorded.append(folders) } }
            var first: [String]? { lock.withLock { recorded.first } }
        }
        let inspected = Inspected()
        let queue = controller(FakeQueueClient(world: {
            var world = MQ.World()
            world.pullRequests[4] = MQ.pullRequest(4, head: MQ.sha("a"))
            world.checks[MQ.sha("a")] = MQ.checks(MQ.checkRun(id: 1, status: "IN_PROGRESS", conclusion: nil))
            return world
        }(), isDryRun: true))
        queue.local.folders = { folders.value }
        queue.local.inspect = { folders, _, _, _, _ in
            inspected.append(folders)
            return .success(MergeQueue.LocalInspection())
        }
        XCTAssertNil(queue.start(settings: MQ.settings(), entries: [MQ.entry(4, head: MQ.sha("a"))]))
        // The space deleted, or its last workspace closed, mid-queue.
        folders.value = ["/tmp/other"]
        let deadline = Date().addingTimeInterval(10)
        while inspected.first == nil, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        queue.stop()
        XCTAssertEqual(inspected.first, ["/tmp/app", "/tmp/app.feat-4", "/tmp/other"])
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
        // Its task, on its branch, recorded a code review on an earlier branch; another task, elsewhere now, records one later.
        var tasks = [
            MergeQueue.ReviewTask(branch: "feat/1", runs: [.codeReview: ReviewRun(head: MQ.sha("e"), at: 1, branch: "feat/earlier")]),
            MergeQueue.ReviewTask(branch: "main", runs: [:])
        ]
        queue.local.reviewTasks = {
            XCTAssertTrue(Thread.isMainThread)
            return tasks
        }
        queue.local.inspect = { _, branch, _, _, _ in
            .success(MergeQueue.LocalInspection(
                worktrees: [MergeQueue.LocalWorktree(path: "/tmp/\(branch)", problem: nil)], allWorktreePaths: []
            ))
        }

        let reading = ReadingBox()
        queue.readConfirmation(settings: MQ.settings(), numbers: [2, 1]) { reading.value = $0 }
        let deadline = Date().addingTimeInterval(10)
        while reading.value == nil, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }

        let read = try XCTUnwrap(reading.value)
        XCTAssertTrue(read.isDryRun)
        XCTAssertEqual(read.candidates.map(\.number), [2, 1], "in the list's order")
        XCTAssertEqual(busyAsked, [["/tmp/feat/1"]])
        let confirmation = MergeQueue.confirmation(read)
        XCTAssertEqual(confirmation.entries.map(\.number), [1])
        XCTAssertEqual(confirmation.excluded.map(\.reason), ["It is a draft."])
        XCTAssertEqual(confirmation.items.first?.notes, ["Behind main by 2 commits."])
        XCTAssertEqual(confirmation.items.first?.warnings, ["No code review yet: Nirux saw none run on its branch."])
        // One recorded on its branch counts, whichever task ran it.
        tasks[1] = MergeQueue.ReviewTask(branch: "main", runs: [.codeReview: ReviewRun(head: MQ.sha("a"), at: 2, branch: "feat/1")])
        let again = ReadingBox()
        queue.readConfirmation(settings: MQ.settings(), numbers: [1]) { again.value = $0 }
        let until = Date().addingTimeInterval(10)
        while again.value == nil, Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertEqual(MergeQueue.confirmation(try XCTUnwrap(again.value)).items.first?.warnings, [])
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
                -> Result<MergeQueue.ReadResult, GitHub.CLI.Failure> {
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

    func testTheSheetRefusesWhenASetupReadAnswersSomethingElse() {
        final class Confused: MergeQueueGitHub, @unchecked Sendable {
            var isDryRun: Bool { true }
            func read(_ read: MergeQueue.Read, settings: BoardConfig.QueueSettings)
                -> Result<MergeQueue.ReadResult, GitHub.CLI.Failure> { .success(.signedIn) }
            func mutate(_ mutation: MergeQueue.Mutation, settings: BoardConfig.QueueSettings) -> MergeQueue.MutationResult {
                .refused(status: nil, message: "")
            }
            func commandLine(_ mutation: MergeQueue.Mutation, settings: BoardConfig.QueueSettings) -> String { "" }
        }
        let fetch = MergeQueueController.fetchConfirmation(
            settings: MQ.settings(), numbers: [1], isDryRun: true, client: Confused(), folders: [],
            inspect: { _, _, _, _, _ in .success(MergeQueue.LocalInspection()) }
        )
        XCTAssertEqual(fetch.reading.setupError, "GitHub’s answers were incomplete. Start again to retry.")
        XCTAssertFalse(MergeQueue.confirmation(fetch.reading).canStart, "no rate limit read is no rate limit checked")
    }

    /// The project's folders as a test changes them.
    @MainActor
    private final class FolderList {
        var value: [String]
        init(_ value: [String]) { self.value = value }
    }

    /// What a completion on the main actor hands back.
    @MainActor
    private final class ReadingBox {
        var value: MergeQueue.ConfirmationReading?
    }

    @MainActor
    func testAClosedSheetStopsItsReadsAndHearsNoAnswer() {
        let cancelled = MergeQueueReadCancellation()
        cancelled.cancel()
        let client = FakeQueueClient(isDryRun: true)
        _ = MergeQueueController.fetchConfirmation(
            settings: MQ.settings(), numbers: [1, 2], isDryRun: true, client: client, folders: [],
            inspect: { _, _, _, _, _ in .success(MergeQueue.LocalInspection()) }, cancellation: cancelled
        )
        XCTAssertEqual(client.reads, [], "nothing is read for a sheet already closed")

        var world = MQ.World()
        world.pullRequests[1] = MQ.pullRequest(1, head: MQ.sha("a"))
        let queue = controller(FakeQueueClient(world: world, isDryRun: true))
        let answered = ReadingBox()
        let reading = queue.readConfirmation(settings: MQ.settings(), numbers: [1]) { answered.value = $0 }
        reading.cancel()
        MergeQueueController.waitForFiles()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertNil(answered.value, "a closed sheet hears no answer")
    }

    // MARK: - The details read

    func testFileEvidenceIncludesTheHeadAndRejectsRenamesMissingPathsAndShortPages() throws {
        let head = MQ.sha("a")
        for (type, count, known) in [("ADDED", 1, true), ("RENAMED", 1, false), ("", 1, false), ("MODIFIED", 2, false)] {
            let json = """
            {"data":{"repository":{"pullRequest":{"title":"Change","headRefOid":"\(head)","baseRefName":"main","changedFiles":\(count),
            "files":{"pageInfo":{"hasNextPage":false},"nodes":[{"path":"new.swift","changeType":"\(type)"}]}}}}}
            """
            let details = try XCTUnwrap(MergeQueue.parsePullRequestDetails(Data(json.utf8)))
            XCTAssertEqual(details.head, head)
            XCTAssertEqual(details.baseBranch, "main")
            XCTAssertEqual(details.allPathsKnown, known)
        }
    }

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
