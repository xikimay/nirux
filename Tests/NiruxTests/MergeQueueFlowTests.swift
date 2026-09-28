import AppKit
import Security
import XCTest
@testable import Nirux

/// The real driver and controller, with the real `gh` client over a
/// scripted GitHub that answers on background threads: the path of the
/// #48 crash (a main-actor closure called back off the main thread, which
/// CI's Swift 6.1 traps). Waits run on a virtual clock: no fixed sleeps.
final class MergeQueueFlowTests: XCTestCase {
    private var root: URL!
    private var stateDirectory: URL!
    private var lockFolder: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nirux-merge-queue-flow-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        stateDirectory = root.appendingPathComponent("state")
        lockFolder = root.appendingPathComponent("locks")
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        MergeQueueController.waitForFiles()
        if let root { try? FileManager.default.removeItem(at: root) }
        super.tearDown()
    }

    // MARK: A scripted GitHub

    /// GitHub as `gh` shows it: pull requests, checks, runs. A merge makes
    /// a merge commit on main, whose push run succeeds.
    final class GitHubWorld: @unchecked Sendable {
        struct PullRequest {
            var head: String
            var state = "OPEN"
            var mergeCommit: String?
            var parents: [String] = []
        }

        private let lock = NSLock()
        private var pullRequests: [Int: PullRequest]
        private var mainTip = MQ.sha("0")
        private var mergeCount = 0
        /// The `test` check's conclusion per commit; nil: still running.
        private var testConclusion: String?
        private(set) var calls: [[String]] = []
        private(set) var merged: [Int] = []
        private(set) var forbidden: [String] = []
        private(set) var threads: Set<String> = []

        init(pullRequests: [Int: String], testConclusion: String? = "SUCCESS") {
            self.pullRequests = pullRequests.mapValues { PullRequest(head: $0) }
            self.testConclusion = testConclusion
        }

        var callCount: Int { lock.withLock { calls.count } }
        var mergedNumbers: [Int] { lock.withLock { merged } }
        var forbiddenCalls: [String] { lock.withLock { forbidden } }
        var allCalls: [[String]] { lock.withLock { calls } }
        var answeredOffMain: Bool { lock.withLock { !threads.contains("main") && !threads.isEmpty } }

        var run: @Sendable ([String], TimeInterval) -> Result<GitHubCLIQueueClient.Output, MergeQueue.ClientError> {
            { [self] arguments, _ in
                // Answered on another queue, as a slow gh would.
                let answered = DispatchSemaphore(value: 0)
                var result: Result<GitHubCLIQueueClient.Output, MergeQueue.ClientError> = .failure(.noAnswer("unanswered"))
                let calledOnMain = Thread.isMainThread
                DispatchQueue(label: "scripted-gh").async {
                    result = self.respond(arguments, onMain: calledOnMain)
                    answered.signal()
                }
                answered.wait()
                return result
            }
        }

        private func respond(_ arguments: [String], onMain: Bool) -> Result<GitHubCLIQueueClient.Output, MergeQueue.ClientError> {
            lock.lock()
            defer { lock.unlock() }
            calls.append(arguments)
            threads.insert(onMain ? "main" : "background")
            if let problem = ForbiddenCalls.problem(arguments) { forbidden.append(problem) }
            let joined = arguments.joined(separator: " ")
            func ok(_ json: String) -> Result<GitHubCLIQueueClient.Output, MergeQueue.ClientError> {
                .success(.init(status: 0, standardOutput: Data(json.utf8), standardError: Data()))
            }
            func value(after flag: String, prefix: String) -> String? {
                arguments.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
            }
            switch arguments.first {
            case "auth":
                return ok("")
            case "pr" where arguments.count > 2 && arguments[1] == "merge":
                guard let number = Int(arguments[2]), var pullRequest = pullRequests[number],
                      let index = arguments.firstIndex(of: "--match-head-commit"), arguments[index + 1] == pullRequest.head
                else {
                    return .success(.init(status: 1, standardOutput: Data(),
                                          standardError: Data("GraphQL: Head branch was modified.\n".utf8)))
                }
                mergeCount += 1
                let commit = String(repeating: String(mergeCount), count: 40)
                pullRequest.state = "MERGED"
                pullRequest.mergeCommit = commit
                pullRequest.parents = [mainTip, pullRequest.head]
                pullRequests[number] = pullRequest
                mainTip = commit
                merged.append(number)
                return ok("")
            case "run":
                // The push run of a merge commit succeeded; nothing else runs.
                guard let commitIndex = arguments.firstIndex(of: "--commit") else { return ok("[]") }
                let commit = arguments[commitIndex + 1]
                return ok("""
                [{"conclusion":"success","databaseId":\(700 + mergeCount),"displayTitle":"Merge","event":"push",\
                "headSha":"\(commit)","status":"completed","url":"https://github.com/acme/widgets/actions/runs/1"}]
                """)
            case "api":
                if joined.contains("rate_limit") { return ok(MergeQueueGitHubTests.rateLimit) }
                if joined.contains("/rules/branches/") { return ok("[]") }
                if joined.contains("mergeQueue(branch") { return ok(#"{"data":{"repository":{"mergeQueue":null}}}"#) }
                if joined.contains("pullRequest(number"), let number = value(after: "-F", prefix: "number=").flatMap(Int.init),
                   let pullRequest = pullRequests[number] {
                    return ok(Self.pullRequestJSON(number, pullRequest))
                }
                if joined.contains("checkSuites"), value(after: "-f", prefix: "oid=") != nil {
                    return ok(Self.checksJSON(conclusion: testConclusion))
                }
                if joined.contains("/compare/") {
                    return ok(#"{"status":"ahead","ahead_by":1,"behind_by":0,"base_commit":"\#(mainTip)"}"#)
                }
                return .success(.init(status: 1, standardOutput: Data(), standardError: Data("gh: Not Found (HTTP 404)\n".utf8)))
            default:
                return .failure(.noAnswer("unscripted \(joined)"))
            }
        }

        static func pullRequestJSON(_ number: Int, _ pullRequest: PullRequest) -> String {
            let mergeCommit = pullRequest.mergeCommit.map { commit in
                #"{"oid":"\#(commit)","parents":{"nodes":[\#(pullRequest.parents.map { #"{"oid":"\#($0)"}"# }.joined(separator: ","))]}}"#
            } ?? "null"
            return """
            {"data":{"repository":{"pullRequest":{"number":\(number),"state":"\(pullRequest.state)","isDraft":false,\
            "url":"https://github.com/acme/widgets/pull/\(number)","headRefName":"feat/\(number)",\
            "headRefOid":"\(pullRequest.head)","baseRefName":"main","headRepository":{"name":"widgets","owner":{"login":"acme"}},\
            "mergeable":"MERGEABLE","isInMergeQueue":false,"autoMergeRequest":null,"mergeCommit":\(mergeCommit)}}}}
            """
        }

        static func checksJSON(conclusion: String?) -> String {
            let status = conclusion == nil ? "IN_PROGRESS" : "COMPLETED"
            let conclusionJSON = conclusion.map { #""\#($0)""# } ?? "null"
            return """
            {"data":{"repository":{"object":{"checkSuites":{"pageInfo":{"hasNextPage":false},"nodes":[\
            {"app":{"slug":"github-actions"},"workflowRun":{"databaseId":900,"workflow":{"name":"Tests"}},\
            "checkRuns":{"pageInfo":{"hasNextPage":false},"nodes":[\
            {"databaseId":5000,"name":"test","status":"\(status)","conclusion":\(conclusionJSON)}]}}]},"status":null}}}}
            """
        }
    }

    /// Seconds of `systemUptime` that pass only when the queue waits.
    final class VirtualClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: TimeInterval = 1_000

        var now: TimeInterval { lock.withLock { value } }

        func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }

        var queueClock: MergeQueueClock {
            MergeQueueClock(
                now: { [self] in now },
                date: { [self] in Date(timeIntervalSince1970: 1_790_000_000 + now) },
                after: { [self] delay, work in
                    advance(delay)
                    VirtualClock.onMain(work)
                }
            )
        }

        nonisolated static func onMain(_ work: @escaping @MainActor @Sendable () -> Void) {
            DispatchQueue.main.async { @MainActor in work() }
        }
    }

    @MainActor
    private func controller(
        _ client: any MergeQueueGitHub, clock: VirtualClock, projectID: String = "project"
    ) -> MergeQueueController {
        let controller = MergeQueueController(
            projectID: projectID,
            client: client,
            local: MergeQueueLocalAccess(folders: { [] }, busyAgents: { _, _ in [] }),
            stateDirectory: stateDirectory,
            lockFolder: lockFolder
        )
        controller.clock = clock.queueClock
        return controller
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 30) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    // MARK: Tests

    @MainActor
    func testTheDriverMergesAQueueEndToEndWithoutTrapping() throws {
        let a = MQ.sha("a")
        let b = MQ.sha("b")
        let world = GitHubWorld(pullRequests: [52: a, 53: b])
        let clock = VirtualClock()
        let queue = controller(GitHubCLIQueueClient(run: world.run), clock: clock)
        var began = 0
        var ended = 0
        queue.beginActivity = {
            began += 1
            return NSObject()
        }
        queue.endActivity = { _ in ended += 1 }
        var changes = 0
        queue.onChange = { changes += 1 }

        XCTAssertNil(queue.start(settings: MQ.settings(), entries: [MQ.entry(52, head: a), MQ.entry(53, head: b)]))
        XCTAssertTrue(queue.isRunning)
        XCTAssertFalse(queue.isDryRun)
        XCTAssertTrue(MergeQueueLock.isHeld(repository: MQ.widgets, folder: lockFolder))
        XCTAssertEqual(queue.start(settings: MQ.settings(), entries: [MQ.entry(54, head: a)]), .alreadyRunning)

        waitUntil { !queue.isRunning }
        XCTAssertEqual(queue.engine?.phase, .finished)
        XCTAssertEqual(world.mergedNumbers, [52, 53])
        XCTAssertTrue(world.forbiddenCalls.isEmpty, "\(world.forbiddenCalls)")
        XCTAssertTrue(world.answeredOffMain)
        XCTAssertEqual(world.allCalls.filter { $0.starts(with: ["pr", "merge"]) },
                       [["pr", "merge", "52", "--repo", "github.com/acme/widgets", "--merge", "--match-head-commit", a],
                        ["pr", "merge", "53", "--repo", "github.com/acme/widgets", "--merge", "--match-head-commit", b]])
        XCTAssertFalse(MergeQueueLock.isHeld(repository: MQ.widgets, folder: lockFolder))
        XCTAssertEqual(began, 1)
        XCTAssertEqual(ended, 1)
        XCTAssertGreaterThan(changes, 5)
        // The nightly's first look waited 10 s of the queue's clock, not of the test's.
        XCTAssertGreaterThanOrEqual(clock.now - 1_000, 20)

        MergeQueueController.waitForFiles()
        let files = try XCTUnwrap(queue.files)
        let journal = try String(contentsOf: files.journal, encoding: .utf8)
        XCTAssertTrue(journal.contains(#""command":"gh pr merge 52 --repo github.com/acme/widgets --merge --match-head-commit \#(a)""#))
        XCTAssertTrue(journal.contains(#""result":"done""#))
        // The step's note, then the call it sent.
        let merging = try XCTUnwrap(journal.range(of: "Merging aaaaaaa"))
        let sent = try XCTUnwrap(journal.range(of: "sent, waiting for the answer"))
        XCTAssertLessThan(merging.lowerBound, sent.lowerBound)
        XCTAssertTrue(journal.contains("Finished: 2 merged"))
        XCTAssertEqual(MergeQueue.SavedQueue.load(from: files.state)?.status, .finished)
    }

    @MainActor
    func testStopEndsAWaitingQueueAndReleasesItsLock() throws {
        let a = MQ.sha("a")
        let world = GitHubWorld(pullRequests: [52: a], testConclusion: nil)
        let queue = controller(GitHubCLIQueueClient(run: world.run), clock: VirtualClock())
        var ended = 0
        queue.beginActivity = { NSObject() }
        queue.endActivity = { _ in ended += 1 }
        // Stopped as soon as it waits for the checks: on the virtual clock
        // it would otherwise reach their timeout within milliseconds.
        var stoppedWhileRunning = false
        queue.onChange = { [weak queue] in
            guard let queue, queue.isRunning, queue.engine?.entries.first?.step == .waitingForChecks(a),
                  case .read(_, let delay)? = queue.engine?.request?.action, delay > 0 else { return }
            stoppedWhileRunning = true
            queue.stop()
        }
        XCTAssertNil(queue.start(settings: MQ.settings(), entries: [MQ.entry(52, head: a)]))
        waitUntil { !queue.isRunning }
        XCTAssertTrue(stoppedWhileRunning)
        XCTAssertEqual(queue.engine?.phase, .stopped(MergeQueue.StopReason(kind: .user, message: "Stopped by the user.")))
        XCTAssertFalse(MergeQueueLock.isHeld(repository: MQ.widgets, folder: lockFolder))
        XCTAssertEqual(ended, 1)
        // Nothing more is read once stopped.
        let calls = world.callCount
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(world.callCount, calls)
        XCTAssertTrue(world.mergedNumbers.isEmpty)
    }

    /// A listener that stops the queue as it hears of a merge comes after
    /// the call went out: Stop never lands between a decision and its call.
    @MainActor
    func testAStopFromAListenerComesAfterTheMergeWasSent() {
        let a = MQ.sha("a")
        var world = MQ.World()
        world.pullRequests[52] = MQ.pullRequest(52, head: a)
        world.checks[a] = MQ.checks(MQ.checkRun(id: 1))
        let driver = MergeQueueDriver(
            engine: MergeQueue.Engine(settings: MQ.settings(), entries: [MQ.entry(52, head: a)]),
            client: FakeQueueClient(world: world),
            local: MergeQueueLocalAccess(folders: { [] }, busyAgents: { _, _ in [] }),
            clock: VirtualClock().queueClock
        )
        var phaseWhenSent: MergeQueue.Phase?
        driver.onMutation = { [weak driver] _, _, result in
            if result == nil { phaseWhenSent = driver?.engine.phase }
        }
        driver.onUpdate = { [weak driver] engine, _ in
            guard engine.phase == .running, case .mutate(.merge)? = engine.request?.action else { return }
            driver?.stop()
        }
        driver.start()
        waitUntil { !driver.engine.phase.isActive }
        XCTAssertEqual(phaseWhenSent, .running)
        guard case .stopped(let reason) = driver.engine.phase else { return XCTFail("\(driver.engine.phase)") }
        XCTAssertEqual(reason.kind, .user)
        XCTAssertTrue(reason.message.contains("Check #52 on GitHub: it may be merged."), reason.message)
    }

    @MainActor
    func testADryRunReadsGitHubButNeverChangesItNorTakesTheLock() throws {
        let a = MQ.sha("a")
        let world = GitHubWorld(pullRequests: [52: a])
        let dryRun = MergeQueue.client(environment: [:], signature: .notRelease(errSecCSReqFailed),
                                       live: GitHubCLIQueueClient(run: world.run))
        let queue = controller(dryRun, clock: VirtualClock())
        queue.beginActivity = { NSObject() }
        queue.endActivity = { _ in }
        XCTAssertTrue(queue.isDryRun)
        XCTAssertNil(queue.start(settings: MQ.settings(), entries: [MQ.entry(52, head: a)]))
        XCTAssertFalse(MergeQueueLock.isHeld(repository: MQ.widgets, folder: lockFolder))
        waitUntil { !queue.isRunning }
        guard case .stopped(let reason)? = queue.engine?.phase else { return XCTFail("\(String(describing: queue.engine?.phase))") }
        XCTAssertEqual(reason.kind, .dryRun)
        XCTAssertTrue(reason.message.contains("gh pr merge 52 --repo github.com/acme/widgets --merge --match-head-commit \(a)"))
        XCTAssertTrue(world.mergedNumbers.isEmpty)
        XCTAssertFalse(world.allCalls.contains { $0.starts(with: ["pr", "merge"]) })

        MergeQueueController.waitForFiles()
        let files = try XCTUnwrap(queue.files)
        XCTAssertEqual(files.journal.lastPathComponent, "queue.dry-run.log")
        XCTAssertEqual(files.state.lastPathComponent, "queue-state.dry-run.json")
        XCTAssertTrue(try String(contentsOf: files.journal, encoding: .utf8).contains("not sent (dry run)"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.journal.deletingLastPathComponent()
            .appendingPathComponent("queue.log").path))
    }

    @MainActor
    func testARestartShowsTheQueueInterruptedAndNeverResumesIt() throws {
        let a = MQ.sha("a")
        var world = MQ.World()
        world.pullRequests[52] = MQ.pullRequest(52, head: a)
        world.checks[a] = MergeQueue.CommitChecks()
        var engine = MQ.Harness(entries: [MQ.entry(52, head: a)])
        engine.start()
        engine.answer(world, until: { $0.pendingDelay == 20 })
        let files = try XCTUnwrap(MergeQueue.Files(projectID: "project", stateDirectory: stateDirectory, dryRun: false))
        MergeQueue.SavedQueue(engine: engine.engine, dryRun: false, savedAt: Date()).save(to: files.state)

        let client = FakeQueueClient(world: world)
        let restored = controller(client, clock: VirtualClock())
        XCTAssertFalse(restored.isRunning)
        XCTAssertFalse(restored.runsElsewhere)
        XCTAssertEqual(restored.saved?.status, .stopped)
        XCTAssertEqual(restored.saved?.stopReason?.message, "Interrupted while waiting for the checks of #52: Nirux quit.")
        MergeQueueController.waitForFiles()
        XCTAssertEqual(MergeQueue.SavedQueue.load(from: files.state)?.status, .stopped)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertTrue(client.reads.isEmpty)

        // Saved as running while another Nirux holds the lock: it still runs there.
        MergeQueue.SavedQueue(engine: engine.engine, dryRun: false, savedAt: Date()).save(to: files.state)
        let elsewhere = try XCTUnwrap(MergeQueueLock.acquire(repository: MQ.widgets, folder: lockFolder))
        let second = controller(client, clock: VirtualClock())
        XCTAssertTrue(second.runsElsewhere)
        XCTAssertEqual(second.saved?.status, .running)
        XCTAssertEqual(second.start(settings: MQ.settings(), entries: [MQ.entry(52, head: a)]), .lockedElsewhere)
        elsewhere.release()
        // Once that Nirux let go, the board reads it as interrupted.
        second.reloadSaved()
        XCTAssertFalse(second.runsElsewhere)
        XCTAssertEqual(second.saved?.stopReason?.kind, .interrupted)
    }

    @MainActor
    func testStartRefusesAnInvalidList() {
        let queue = controller(FakeQueueClient(), clock: VirtualClock())
        XCTAssertEqual(queue.start(settings: MQ.settings(), entries: []), .nothingToQueue)
        guard case .invalidEntry = queue.start(settings: MQ.settings(),
                                               entries: [MQ.entry(52, head: MQ.sha("a")), MQ.entry(52, head: MQ.sha("b"))])
        else { return XCTFail("a duplicate") }
        guard case .invalidEntry = queue.start(settings: MQ.settings(), entries: [MQ.entry(52, head: "main")])
        else { return XCTFail("a head that isn't a SHA") }
        guard case .invalidEntry = queue.start(settings: MQ.settings(), entries: [MQ.entry(52, head: MQ.sha("a"), branch: "-x")])
        else { return XCTFail("a branch git would read as an option") }
        guard case .invalidSettings = queue.start(settings: MQ.settings(requiredChecks: []), entries: [MQ.entry(52, head: MQ.sha("a"))])
        else { return XCTFail("no required check would make every head green") }
        XCTAssertFalse(queue.isRunning)
    }

    @MainActor
    func testTheShellOwnsOneQueuePerProjectAndOnePerRepository() throws {
        let previousStateDirectory = ProcessInfo.processInfo.environment["NIRUX_STATE_DIR"]
        setenv("NIRUX_STATE_DIR", stateDirectory.path, 1)
        defer {
            if let previousStateDirectory {
                setenv("NIRUX_STATE_DIR", previousStateDirectory, 1)
            } else {
                unsetenv("NIRUX_STATE_DIR")
            }
        }
        _ = NSApplication.shared
        let shell = NiruxShellView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        shell.stopHeartbeat()
        let client = FakeQueueClient(isDryRun: true)
        shell.mergeQueueClient = client
        shell.mergeQueueLockFolder = lockFolder

        let first = shell.mergeQueue(projectID: "first")
        XCTAssertTrue(shell.mergeQueue(projectID: "first") === first)
        let second = shell.mergeQueue(projectID: "second")
        XCTAssertFalse(first === second)
        XCTAssertTrue(first.isDryRun)
        first.beginActivity = { NSObject() }
        first.endActivity = { _ in }

        XCTAssertNil(first.start(settings: MQ.settings(), entries: [MQ.entry(52, head: MQ.sha("a"))]))
        XCTAssertEqual(second.start(settings: MQ.settings(), entries: [MQ.entry(53, head: MQ.sha("b"))]), .repositoryBusy)
        first.stop()
        XCTAssertFalse(first.isRunning)
        XCTAssertEqual(first.files?.state.deletingLastPathComponent().lastPathComponent, "first")
        // Nothing reached GitHub for real: the fake answered, and no queue changed anything.
        XCTAssertTrue(client.mutations.isEmpty)
    }
}
