import XCTest
@testable import Nirux

/// The queue's files and lock (sections 3.4, 3.5 and 4), and its local
/// preflight on real git repositories.
final class MergeQueueStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nirux-merge-queue-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let root { try? FileManager.default.removeItem(at: root) }
        super.tearDown()
    }

    // MARK: Lock

    func testTheLockExcludesASecondHolderUntilReleased() throws {
        let folder = root.appendingPathComponent("locks")
        let first = try XCTUnwrap(MergeQueueLock.acquire(repository: MQ.widgets, folder: folder))
        // Another open of the file, as another process would make.
        XCTAssertNil(MergeQueueLock.acquire(repository: MQ.widgets, folder: folder))
        XCTAssertTrue(MergeQueueLock.isHeld(repository: MQ.widgets, folder: folder))
        // Another repository has its own lock.
        let other = MergeQueueLock.acquire(repository: GitHubRepository(owner: "acme", name: "gadgets"), folder: folder)
        XCTAssertNotNil(other)
        XCTAssertEqual(first.url.lastPathComponent, "acme+widgets.lock")

        first.release()
        XCTAssertFalse(MergeQueueLock.isHeld(repository: MQ.widgets, folder: folder))
        var second = MergeQueueLock.acquire(repository: MQ.widgets, folder: folder)
        XCTAssertNotNil(second)
        // Dropping the holder releases it, as a dying process does.
        second = nil
        XCTAssertNotNil(MergeQueueLock.acquire(repository: MQ.widgets, folder: folder))
    }

    // MARK: Journal

    func testTheJournalIsCappedWithOnePreviousFile() throws {
        var journal = MergeQueue.Journal(url: root.appendingPathComponent("queue.log"))
        journal.maxBytes = 400
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        for index in 0..<12 {
            journal.append([MergeQueue.Journal.line(MergeQueue.Note(number: 52, step: "checks", message: "poll \(index)"), at: date)])
        }
        let current = try String(contentsOf: journal.url, encoding: .utf8)
        let previous = try String(contentsOf: journal.previousURL, encoding: .utf8)
        XCTAssertLessThanOrEqual(current.utf8.count, 400)
        XCTAssertLessThanOrEqual(previous.utf8.count, 400)
        XCTAssertTrue(current.contains("poll 11"))
        XCTAssertFalse(current.contains("poll 0\""))
        let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertEqual(Set(files), ["queue.log", "queue.log.1"])
        let attributes = try FileManager.default.attributesOfItem(atPath: journal.url.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)

        let line = try XCTUnwrap(current.split(separator: "\n").last)
        let decoded = try JSONDecoder().decode(MergeQueue.Journal.Line.self, from: Data(line.utf8))
        XCTAssertEqual(decoded.pr, 52)
        XCTAssertEqual(decoded.step, "checks")
        XCTAssertEqual(decoded.time, "2026-09-21T14:13:20Z")
    }

    func testTheJournalNeverHoldsAToken() {
        let line = MergeQueue.Journal.line(
            number: 52, step: "merging",
            command: "gh pr merge 52 --repo github.com/acme/widgets --merge --match-head-commit \(MQ.sha("a"))",
            result: "HTTP 401: Bad credentials for ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 and github_pat_11ABCDEFG0123456789_abcdefghij",
            at: Date()
        )
        XCTAssertFalse(line.result.contains("ghp_"))
        XCTAssertFalse(line.result.contains("github_pat_"))
        XCTAssertEqual(line.result, "HTTP 401: Bad credentials for [token] and [token]")
        XCTAssertTrue(line.command?.contains("--match-head-commit") == true)
    }

    // MARK: Saved state

    func testAQueueSavedWhileRunningReadsAsInterrupted() throws {
        let c = MQ.sha("c")
        var world = MQ.World()
        world.pullRequests[52] = MQ.pullRequest(52, head: MQ.sha("a"))
        world.checks[MQ.sha("a")] = MQ.checks(MQ.checkRun(id: 1))
        var queue = MQ.Harness(entries: [MQ.entry(52, head: MQ.sha("a")), MQ.entry(53, head: MQ.sha("b"))])
        queue.start()
        queue.run(world)
        world.merge(52, as: c)
        world.pushRuns[c] = [MQ.run(10, head: c, status: "in_progress", conclusion: nil)]
        queue.mutated(.sent)
        queue.answer(world)

        let url = root.appendingPathComponent("queue-state.json")
        MergeQueue.SavedQueue(engine: queue.engine, dryRun: false, savedAt: Date()).save(to: url)
        let saved = try XCTUnwrap(MergeQueue.SavedQueue.load(from: url))
        XCTAssertEqual(saved.status, .running)
        XCTAssertEqual(saved.entries[0].step, .waitingForPostMerge(c))

        let interrupted = saved.interrupted()
        XCTAssertEqual(interrupted.status, .stopped)
        XCTAssertEqual(interrupted.stopReason?.kind, .interrupted)
        XCTAssertEqual(interrupted.stopReason?.message, "Interrupted while waiting for the nightly of #52: Nirux quit.")
        XCTAssertEqual(interrupted.entries[0].step, interrupted.stopReason.map { .stopped($0) })
        XCTAssertEqual(interrupted.entries[0].mergeCommit, c)
        XCTAssertEqual(interrupted.entries[1].step, .waiting)
        // A stopped queue stays as it was.
        XCTAssertEqual(interrupted.interrupted(), interrupted)

        // A newer Nirux's file isn't read.
        var newer = saved
        newer.schemaVersion = 2
        newer.save(to: url)
        XCTAssertNil(MergeQueue.SavedQueue.load(from: url))
    }

    func testAnInterruptedMergeSaysItMayHaveGoneThrough() {
        var world = MQ.World()
        world.pullRequests[52] = MQ.pullRequest(52, head: MQ.sha("a"))
        world.checks[MQ.sha("a")] = MQ.checks(MQ.checkRun(id: 1))
        var queue = MQ.Harness(entries: [MQ.entry(52, head: MQ.sha("a"))])
        queue.start()
        queue.run(world)
        let saved = MergeQueue.SavedQueue(engine: queue.engine, dryRun: false, savedAt: Date()).interrupted()
        XCTAssertTrue(saved.stopReason?.message.contains("The merge may have gone through: check #52 on GitHub.") == true)
    }

    // MARK: Local preflight

    @MainActor
    private func git(_ arguments: [String], at path: URL) throws {
        _ = try UIFlowHarness.git(arguments, at: path.path)
    }

    @MainActor
    func testTheLocalPreflightFindsTrackedChangesAndUnpushedCommits() throws {
        let repository = root.appendingPathComponent("widgets")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"], at: repository)
        try git(["remote", "add", "origin", "git@github.com:Acme/widgets.git"], at: repository)
        try "one\n".write(to: repository.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        try git(["add", "file.txt"], at: repository)
        try git(["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-q", "-m", "init"], at: repository)
        let worktree = root.appendingPathComponent("widgets.feat-52")
        try git(["worktree", "add", "-q", "-b", "feat/52", worktree.path], at: repository)
        let head = try UIFlowHarness.git(["rev-parse", "HEAD"], at: worktree.path).trimmingCharacters(in: .whitespacesAndNewlines)

        let client = FakeQueueClient()
        let tools = WorktreeCleanup.Tools()
        func inspect(_ prHead: String) throws -> MergeQueue.LocalInspection {
            try MergeQueue.inspectLocal(folders: [repository.path], branch: "feat/52", head: prHead, settings: MQ.settings(),
                                        client: client, tools: tools).get()
        }

        // At the PR's head, with an untracked handover: clean.
        try "notes\n".write(to: worktree.appendingPathComponent(".claude-handover.md"), atomically: true, encoding: .utf8)
        var inspection = try inspect(head)
        XCTAssertEqual(inspection.worktrees.map(\.problem), [nil])
        XCTAssertEqual(inspection.worktrees.first?.path, NiruxShellView.comparablePath(worktree.path))
        XCTAssertEqual(Set(inspection.allWorktreePaths),
                       Set([repository.path, worktree.path].map(NiruxShellView.comparablePath)))
        XCTAssertTrue(client.reads.isEmpty)

        // A tracked file changed.
        try "two\n".write(to: worktree.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try inspect(head).worktrees.map(\.problem), [.trackedChanges])
        try git(["checkout", "--", "file.txt"], at: worktree)

        // A local commit: only GitHub can say whether it is pushed.
        try git(["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-q", "--allow-empty", "-m", "local"],
                at: worktree)
        let local = try UIFlowHarness.git(["rev-parse", "HEAD"], at: worktree.path).trimmingCharacters(in: .whitespacesAndNewlines)
        let compare = MergeQueue.Read.compare(base: head, head: local)
        client.update { $0.compares[compare] = MergeQueue.Comparison(status: "ahead", aheadBy: 1, behindBy: 0, baseCommit: head) }
        XCTAssertEqual(try inspect(head).worktrees.map(\.problem), [.unpushed])
        client.update { $0.compares[compare] = .some(nil) }
        XCTAssertEqual(try inspect(head).worktrees.map(\.problem), [.unpushed])
        // The local branch only lacks the queue's own update: fine.
        client.update { $0.compares[compare] = MergeQueue.Comparison(status: "behind", aheadBy: 0, behindBy: 1, baseCommit: head) }
        inspection = try inspect(head)
        XCTAssertEqual(inspection.worktrees.map(\.problem), [nil])
        XCTAssertEqual(client.reads.last, compare)

        // Another branch, or another repository: no worktree to check.
        XCTAssertTrue(try MergeQueue.inspectLocal(folders: [repository.path], branch: "feat/53", head: head,
                                                  settings: MQ.settings(), client: client, tools: tools).get().worktrees.isEmpty)
        XCTAssertTrue(MergeQueue.unpushed(nil))
    }

    func testAWorkspaceInANestedWorktreeBelongsToThatOne() {
        let roots = ["/w/repo"]
        let all = ["/w/repo", "/w/repo/.claude/worktrees/x"]
        XCTAssertTrue(MergeQueue.isInside("/w/repo/Sources", roots: roots, allWorktrees: all))
        XCTAssertFalse(MergeQueue.isInside("/w/repo/.claude/worktrees/x/Sources", roots: roots, allWorktrees: all))
        XCTAssertFalse(MergeQueue.isInside("/w/repo-other", roots: roots, allWorktrees: all))
    }
}
