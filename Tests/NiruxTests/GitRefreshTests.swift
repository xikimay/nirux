import CoreServices
import XCTest
@testable import Nirux

@MainActor
final class GitRefreshTests: XCTestCase {
    // MARK: - GitRefreshPolicy

    func testNeverObservedWorkspaceIsDueInEveryTier() {
        for tier in [GitRefreshTier.focused, .background, .archived] {
            XCTAssertTrue(GitRefreshPolicy.isDue(
                tier: tier,
                pendingChange: nil,
                workingDirectoryChanged: false,
                lastRefresh: nil,
                now: 0
            ), "\(tier)")
        }
    }

    func testArchivedWorkspaceIsNeverPolledAgain() {
        XCTAssertFalse(GitRefreshPolicy.isDue(
            tier: .archived,
            pendingChange: .metadata,
            workingDirectoryChanged: true,
            lastRefresh: 0,
            now: 86_400
        ))
    }

    func testFocusedThrottlesFollowTheKindOfChange() {
        func isDue(_ change: GitRepositoryChange?, after elapsed: TimeInterval) -> Bool {
            GitRefreshPolicy.isDue(
                tier: .focused,
                pendingChange: change,
                workingDirectoryChanged: false,
                lastRefresh: 100,
                now: 100 + elapsed
            )
        }
        XCTAssertFalse(isDue(.metadata, after: 0.5))
        XCTAssertTrue(isDue(.metadata, after: 1))
        XCTAssertFalse(isDue(.worktree, after: 3))
        XCTAssertTrue(isDue(.worktree, after: 4))
        XCTAssertFalse(isDue(nil, after: 29))
        XCTAssertTrue(isDue(nil, after: 30))
    }

    func testBackgroundWorkspacesAreFollowedMoreSlowly() throws {
        let focused = try XCTUnwrap(GitRefreshPolicy.intervals(for: .focused))
        let background = try XCTUnwrap(GitRefreshPolicy.intervals(for: .background))
        XCTAssertGreaterThan(background.metadata, focused.metadata)
        XCTAssertGreaterThan(background.worktree, focused.worktree)
        XCTAssertGreaterThan(background.fallback, focused.fallback)
        XCTAssertNil(GitRefreshPolicy.intervals(for: .archived))
    }

    func testWorkingDirectoryChangeIsDueImmediately() {
        XCTAssertTrue(GitRefreshPolicy.isDue(
            tier: .background,
            pendingChange: nil,
            workingDirectoryChanged: true,
            lastRefresh: 100,
            now: 100
        ))
    }

    // MARK: - PullRequestRefreshPolicy

    func testPullRequestCadenceTracksPendingChecksAndTier() {
        let pending = makePullRequest(state: "OPEN", ciStatus: "PENDING")
        let settled = makePullRequest(state: "OPEN", ciStatus: "SUCCESS")
        let merged = makePullRequest(state: "MERGED", ciStatus: "PENDING")
        XCTAssertEqual(PullRequestRefreshPolicy.interval(for: .focused, pullRequest: pending), 30)
        XCTAssertEqual(PullRequestRefreshPolicy.interval(for: .focused, pullRequest: settled), 120)
        XCTAssertEqual(PullRequestRefreshPolicy.interval(for: .focused, pullRequest: nil), 120)
        XCTAssertEqual(PullRequestRefreshPolicy.interval(for: .focused, pullRequest: merged), 120)
        XCTAssertEqual(PullRequestRefreshPolicy.interval(for: .background, pullRequest: pending), 120)
        XCTAssertEqual(PullRequestRefreshPolicy.interval(for: .background, pullRequest: settled), 600)
        XCTAssertNil(PullRequestRefreshPolicy.interval(for: .archived, pullRequest: pending))

        XCTAssertTrue(PullRequestRefreshPolicy.isDue(tier: .background, pullRequest: nil, lastRefresh: nil, now: 0))
        XCTAssertFalse(PullRequestRefreshPolicy.isDue(tier: .archived, pullRequest: nil, lastRefresh: nil, now: 0))
        XCTAssertFalse(PullRequestRefreshPolicy.isDue(tier: .focused, pullRequest: settled, lastRefresh: 0, now: 119))
        XCTAssertTrue(PullRequestRefreshPolicy.isDue(tier: .focused, pullRequest: settled, lastRefresh: 0, now: 120))
    }

    // MARK: - GitRepositoryLayout

    func testLayoutResolvesPlainCheckoutAndLinkedWorktree() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let main = root.appendingPathComponent("main", isDirectory: true)
        let linked = root.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
        try initializeRepository(at: main)
        try git(["worktree", "add", "-q", "-b", "feature/x", linked.path], at: main)

        let mainPath = GitRepositoryLayout.canonicalPath(main.path)
        let mainLayout = GitRepositoryLayout.resolve(worktreeRoot: main.path)
        XCTAssertEqual(mainLayout.worktreeRoot, mainPath)
        XCTAssertEqual(mainLayout.gitDirectory, mainPath + "/.git")
        XCTAssertEqual(mainLayout.commonDirectory, mainPath + "/.git")
        XCTAssertEqual(mainLayout.watchedPaths, [mainPath])

        let linkedLayout = GitRepositoryLayout.resolve(worktreeRoot: linked.path)
        XCTAssertEqual(linkedLayout.worktreeRoot, GitRepositoryLayout.canonicalPath(linked.path))
        XCTAssertEqual(linkedLayout.gitDirectory, mainPath + "/.git/worktrees/linked")
        XCTAssertEqual(linkedLayout.commonDirectory, mainPath + "/.git")
        // The private git dir lives inside the common one: one watch covers both.
        XCTAssertEqual(linkedLayout.watchedPaths, [linkedLayout.worktreeRoot, mainPath + "/.git"])

        let plain = GitRepositoryLayout.resolve(worktreeRoot: root.path)
        XCTAssertNil(plain.gitDirectory)
        XCTAssertNil(plain.commonDirectory)
    }

    func testCanonicalPathKeepsPrivatePrefixReportedByFSEvents() {
        XCTAssertEqual(GitRepositoryLayout.canonicalPath("/tmp"), "/private/tmp")
    }

    func testPlainCheckoutClassification() {
        let layout = GitRepositoryLayout(
            worktreeRoot: "/repo",
            gitDirectory: "/repo/.git",
            commonDirectory: "/repo/.git"
        )
        func classify(_ path: String, branch: String? = "main") -> GitRepositoryChange? {
            layout.classify(path, branch: branch)
        }
        XCTAssertEqual(classify("/repo/Sources/app.swift"), .worktree)
        XCTAssertEqual(classify("/repo/.git/HEAD"), .metadata)
        XCTAssertEqual(classify("/repo/.git/index"), .metadata)
        XCTAssertEqual(classify("/repo/.git/refs/heads/main"), .metadata)
        XCTAssertEqual(classify("/repo/.git/packed-refs"), .metadata)
        XCTAssertEqual(classify("/repo/.git/config"), .metadata)
        XCTAssertNil(classify("/repo/.git/refs/heads/other"))
        XCTAssertNil(classify("/repo/.git/refs/remotes/origin/main"))
        XCTAssertNil(classify("/repo/.git/refs/tags/v1"))
        XCTAssertNil(classify("/repo/.git/objects/ab/cdef"))
        XCTAssertNil(classify("/repo/.git/logs/HEAD"))
        XCTAssertNil(classify("/repo/.git/index.lock"))
        XCTAssertNil(classify("/repo/.git/FETCH_HEAD"))
        XCTAssertNil(classify("/repo/.git/worktrees/other/HEAD"))
        XCTAssertEqual(classify("/repo/.git/refs/heads/feature/x", branch: "feature/x"), .metadata)
        XCTAssertEqual(classify("/repo/.git/refs/heads/anything", branch: nil), .metadata)
        XCTAssertEqual(classify("/repository-sibling/file"), .worktree)
    }

    func testLinkedWorktreeIgnoresTheMainCheckoutsHeadAndIndex() {
        let layout = GitRepositoryLayout(
            worktreeRoot: "/wt",
            gitDirectory: "/repo/.git/worktrees/wt",
            commonDirectory: "/repo/.git"
        )
        func classify(_ path: String) -> GitRepositoryChange? {
            layout.classify(path, branch: "feature/x")
        }
        XCTAssertEqual(classify("/wt/README.md"), .worktree)
        XCTAssertEqual(classify("/repo/.git/worktrees/wt/HEAD"), .metadata)
        XCTAssertEqual(classify("/repo/.git/worktrees/wt/index"), .metadata)
        XCTAssertEqual(classify("/repo/.git/refs/heads/feature/x"), .metadata)
        XCTAssertEqual(classify("/repo/.git/config"), .metadata)
        XCTAssertNil(classify("/repo/.git/HEAD"))
        XCTAssertNil(classify("/repo/.git/index"))
        XCTAssertNil(classify("/repo/.git/worktrees/other/index"))
        XCTAssertNil(classify("/repo/.git/refs/heads/main"))
    }

    func testDroppedOrRescannedEventsCountAsMetadata() {
        let layout = GitRepositoryLayout(worktreeRoot: "/repo", gitDirectory: nil, commonDirectory: nil)
        let rescan = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)
        XCTAssertEqual(
            GitRepositoryWatcher.change(for: "/repo/.git/objects/x", flags: rescan, layout: layout, branch: nil),
            .metadata
        )
    }

    // MARK: - GitRepositoryWatcher

    func testWatcherReportsWorktreeAndMetadataChanges() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try initializeRepository(at: root)
        let layout = GitRepositoryLayout.resolve(worktreeRoot: root.path)
        var changes: [GitRepositoryChange] = []
        let watcher = try XCTUnwrap(GitRepositoryWatcher(layout: layout, branch: nil, latency: 0.05) {
            changes.append($0)
        })
        defer { watcher.stop() }
        // Let the stream settle so setup writes are not reported.
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        changes.removeAll()

        try "edited\n".write(to: root.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        XCTAssertTrue(waitUntil { changes.contains(.worktree) }, "no worktree event: \(changes)")

        try git(["add", "tracked.txt"], at: root)
        XCTAssertTrue(waitUntil { changes.contains(.metadata) }, "no metadata event: \(changes)")
    }

    // MARK: - Read-only git observation

    func testObservationDoesNotRewriteTheIndex() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try initializeRepository(at: root)
        let index = root.appendingPathComponent(".git/index").path
        // Stale stat data: plain `git status` would refresh and rewrite the index.
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(60)],
            ofItemAtPath: root.appendingPathComponent("tracked.txt").path
        )
        let before = try inode(of: index)

        guard case .observed(let context) = GitDetect.observe(at: root.path) else {
            return XCTFail("expected an observed repository")
        }
        XCTAssertFalse(context.identity.isDirty)
        XCTAssertEqual(try inode(of: index), before, "GitDetect rewrote .git/index")

        try git(["status", "--porcelain"], at: root)
        XCTAssertNotEqual(try inode(of: index), before, "precondition: plain git status refreshes the index")
    }

    // MARK: - GitRefreshCoordinator

    func testCoordinatorReadsEachWorkspaceOnceThenFollowsItsTier() {
        let harness = CoordinatorHarness()
        let focused = WorkspaceState(title: "focused", cwd: NSTemporaryDirectory())
        let background = WorkspaceState(title: "background", cwd: NSTemporaryDirectory())
        let archived = WorkspaceState(title: "archived", cwd: NSTemporaryDirectory())
        let tiers: [(workspace: WorkspaceState, tier: GitRefreshTier)] = [
            (focused, .focused), (background, .background), (archived, .archived)
        ]

        harness.coordinator.tick(tiers)
        XCTAssertEqual(harness.reads, ["focused", "background", "archived"])

        harness.advance(29)
        harness.coordinator.tick(tiers)
        XCTAssertEqual(harness.reads.count, 3, "nothing is due before the fallback")

        harness.advance(1)
        harness.coordinator.tick(tiers)
        XCTAssertEqual(harness.reads.suffix(1), ["focused"])

        harness.advance(90)
        harness.coordinator.tick(tiers)
        XCTAssertEqual(harness.reads.suffix(2), ["focused", "background"])
        XCTAssertEqual(harness.reads.filter { $0 == "archived" }.count, 1)
    }

    func testFocusedChangeIsReadImmediatelyBackgroundChangeWaitsForTick() {
        let harness = CoordinatorHarness()
        let focused = WorkspaceState(title: "focused", cwd: NSTemporaryDirectory())
        let background = WorkspaceState(title: "background", cwd: NSTemporaryDirectory())
        let tiers: [(workspace: WorkspaceState, tier: GitRefreshTier)] = [
            (focused, .focused), (background, .background)
        ]
        harness.coordinator.tick(tiers)
        harness.reads.removeAll()

        harness.advance(1)
        harness.coordinator.noteChange(.metadata, for: focused)
        harness.coordinator.noteChange(.metadata, for: background)
        XCTAssertEqual(harness.reads, ["focused"])

        harness.advance(3)
        harness.coordinator.tick(tiers)
        XCTAssertEqual(harness.reads, ["focused"], "background metadata throttle is 5 s")
        harness.advance(1)
        harness.coordinator.tick(tiers)
        XCTAssertEqual(harness.reads, ["focused", "background"])
    }

    func testSuspendedCoordinatorOnlyRecordsChanges() {
        let harness = CoordinatorHarness()
        let focused = WorkspaceState(title: "focused", cwd: NSTemporaryDirectory())
        harness.coordinator.tick([(focused, .focused)])
        harness.reads.removeAll()

        harness.coordinator.isSuspended = true
        harness.advance(10)
        harness.coordinator.noteChange(.metadata, for: focused)
        XCTAssertTrue(harness.reads.isEmpty)

        harness.coordinator.isSuspended = false
        harness.coordinator.tick([(focused, .focused)])
        XCTAssertEqual(harness.reads, ["focused"])
    }

    func testInFlightReadKeepsTheChangePending() {
        let harness = CoordinatorHarness()
        let focused = WorkspaceState(title: "focused", cwd: NSTemporaryDirectory())
        harness.coordinator.tick([(focused, .focused)])
        harness.reads.removeAll()

        harness.acceptsReads = false
        harness.advance(2)
        harness.coordinator.noteChange(.metadata, for: focused)
        XCTAssertEqual(harness.attempts, 2)

        harness.acceptsReads = true
        harness.coordinator.tick([(focused, .focused)])
        XCTAssertEqual(harness.reads, ["focused"])
    }

    func testRefreshNowBypassesThrottlesAndRevivesArchivedWorkspaces() {
        let harness = CoordinatorHarness()
        let archived = WorkspaceState(title: "archived", cwd: NSTemporaryDirectory())
        harness.coordinator.tick([(archived, .archived)])
        harness.coordinator.refreshNow(archived, tier: .focused)
        XCTAssertEqual(harness.reads, ["archived", "archived"])
    }

    func testDroppedWorkspaceStopsBeingFollowed() {
        let harness = CoordinatorHarness()
        let dropped = WorkspaceState(title: "dropped", cwd: NSTemporaryDirectory())
        harness.coordinator.tick([(dropped, .focused)])
        harness.coordinator.tick([])
        harness.advance(60)
        harness.coordinator.noteChange(.metadata, for: dropped)
        XCTAssertEqual(harness.reads, ["dropped"])
    }

    func testPullRequestsDueFollowTierAndLastRefresh() {
        let harness = CoordinatorHarness()
        let focused = WorkspaceState(title: "focused", cwd: NSTemporaryDirectory())
        let background = WorkspaceState(title: "background", cwd: NSTemporaryDirectory())
        let archived = WorkspaceState(title: "archived", cwd: NSTemporaryDirectory())
        archived.isInactive = true
        for workspace in [focused, background, archived] {
            workspace.updateGitContext(GitContext(
                branch: "feature/\(workspace.title)",
                identity: GitIdentity(repositoryRoot: "/repo/\(workspace.title)", head: "abc")
            ))
        }
        let tiers: [(workspace: WorkspaceState, tier: GitRefreshTier)] = [
            (focused, .focused), (background, .background), (archived, .archived)
        ]
        XCTAssertEqual(harness.coordinator.pullRequestsDue(tiers).map(\.title), ["focused", "background"])

        harness.coordinator.notePullRequestRefresh(focused)
        harness.coordinator.notePullRequestRefresh(background)
        harness.advance(120)
        XCTAssertEqual(harness.coordinator.pullRequestsDue(tiers).map(\.title), ["focused"])
        harness.advance(480)
        XCTAssertEqual(harness.coordinator.pullRequestsDue(tiers).map(\.title), ["focused", "background"])
    }

    // MARK: - Helpers

    @MainActor
    private final class CoordinatorHarness {
        var now: TimeInterval = 1_000
        var reads: [String] = []
        var attempts = 0
        var acceptsReads = true
        private(set) var coordinator: GitRefreshCoordinator!

        init() {
            coordinator = GitRefreshCoordinator(
                clock: { [unowned self] in self.now },
                makeWatcher: { _, _, _ in nil },
                startObservation: { [unowned self] workspace, _ in
                    self.attempts += 1
                    guard self.acceptsReads else { return false }
                    self.reads.append(workspace.title)
                    return true
                }
            )
        }

        func advance(_ seconds: TimeInterval) {
            now += seconds
        }
    }

    private func makePullRequest(state: String, ciStatus: String?) -> PRInfo {
        PRInfo(
            number: 1,
            state: state,
            isDraft: false,
            ciStatus: ciStatus,
            failedCheckUrl: nil,
            reviewDecision: nil,
            mergeable: nil,
            url: "https://example.test/pull/1",
            additions: nil,
            deletions: nil,
            changedFiles: nil
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func initializeRepository(at directory: URL) throws {
        try git(["init", "-q"], at: directory)
        try "context\n".write(
            to: directory.appendingPathComponent("tracked.txt"),
            atomically: true,
            encoding: .utf8
        )
        try git(["add", "tracked.txt"], at: directory)
        try git([
            "-c", "user.name=Nirux Tests",
            "-c", "user.email=nirux@example.test",
            "commit", "-qm", "initial"
        ], at: directory)
    }

    private func git(_ arguments: [String], at directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "GitRefreshTests.Git", code: Int(process.terminationStatus))
        }
    }

    private func inode(of path: String) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        return try XCTUnwrap((attributes[.systemFileNumber] as? NSNumber)?.uint64Value)
    }

    private func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }
}
