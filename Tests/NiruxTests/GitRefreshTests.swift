import XCTest
@testable import Nirux

/// Refresh scheduling: the git and pull-request policies and the
/// per-workspace coordinator, driven by an injected clock.
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

    func testArchivedWorkspaceWithoutContextIsRetriedSlowly() {
        func isDue(hasContext: Bool, after elapsed: TimeInterval) -> Bool {
            GitRefreshPolicy.isDue(
                tier: .archived,
                pendingChange: nil,
                workingDirectoryChanged: false,
                lastRefresh: 0,
                hasContext: hasContext,
                now: elapsed
            )
        }
        XCTAssertFalse(isDue(hasContext: false, after: 119))
        XCTAssertTrue(isDue(hasContext: false, after: 120))
        XCTAssertFalse(isDue(hasContext: true, after: 86_400))
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

    func testDiffStatsFollowChangesAtTheTierCadence() {
        func isDue(_ tier: GitRefreshTier, changed: Bool, last: TimeInterval?, now: TimeInterval) -> Bool {
            GitRefreshPolicy.isDiffStatsDue(tier: tier, changedSinceLastRefresh: changed, lastRefresh: last, now: now)
        }
        XCTAssertFalse(isDue(.focused, changed: false, last: nil, now: 0))
        XCTAssertTrue(isDue(.focused, changed: true, last: nil, now: 0))
        XCTAssertFalse(isDue(.focused, changed: true, last: 0, now: 9))
        XCTAssertTrue(isDue(.focused, changed: true, last: 0, now: 10))
        XCTAssertFalse(isDue(.background, changed: true, last: 0, now: 59))
        XCTAssertTrue(isDue(.background, changed: true, last: 0, now: 60))
        XCTAssertFalse(isDue(.archived, changed: true, last: nil, now: 0))
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

    func testRunningChecksKeepTheRollupPending() {
        func ciStatus(_ rollup: [[String: Any]]) -> String? {
            PRDetect.pullRequestInfo(from: [
                "number": 1, "state": "OPEN", "url": "https://example.test/pull/1",
                "statusCheckRollup": rollup
            ]).ciStatus
        }
        let passed: [String: Any] = ["status": "COMPLETED", "conclusion": "SUCCESS"]
        XCTAssertEqual(ciStatus([passed, ["status": "IN_PROGRESS", "conclusion": ""]]), "PENDING")
        XCTAssertEqual(ciStatus([passed, ["status": "COMPLETED", "conclusion": "NEUTRAL"]]), "SUCCESS")
        XCTAssertEqual(ciStatus([["status": "COMPLETED", "conclusion": "FAILURE"], ["status": "QUEUED", "conclusion": ""]]), "FAILURE")
        XCTAssertEqual(ciStatus([passed, ["state": "PENDING"]]), "PENDING")
        XCTAssertEqual(ciStatus([passed, ["state": "SUCCESS"]]), "SUCCESS")
        XCTAssertNil(ciStatus([]))
    }

    // MARK: - GitRefreshCoordinator

    func testCoordinatorReadsEachWorkspaceOnceThenFollowsItsTier() {
        let harness = CoordinatorHarness()
        let focused = makeWorkspace("focused")
        let background = makeWorkspace("background")
        let archived = makeWorkspace("archived")
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

    func testArchivedWorkspaceIsRetriedWhileItHasNoContext() {
        let harness = CoordinatorHarness()
        let archived = WorkspaceState(title: "archived", cwd: NSTemporaryDirectory())
        let tiers: [(workspace: WorkspaceState, tier: GitRefreshTier)] = [(archived, .archived)]
        harness.coordinator.tick(tiers)
        harness.advance(119)
        harness.coordinator.tick(tiers)
        XCTAssertEqual(harness.reads.count, 1)
        harness.advance(1)
        harness.coordinator.tick(tiers)
        XCTAssertEqual(harness.reads.count, 2)

        archived.updateGitContext(GitContext(
            branch: "main",
            identity: GitIdentity(repositoryRoot: NSTemporaryDirectory(), head: "abc")
        ))
        harness.advance(1_000)
        harness.coordinator.tick(tiers)
        XCTAssertEqual(harness.reads.count, 2)
        XCTAssertEqual(harness.watcherAttempts, 0, "archived workspaces are never watched")
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

    func testFailedWatcherIsRetriedWithBackoff() {
        let harness = CoordinatorHarness()
        let focused = makeWorkspace("focused")
        let tiers: [(workspace: WorkspaceState, tier: GitRefreshTier)] = [(focused, .focused)]
        harness.coordinator.tick(tiers)
        XCTAssertEqual(harness.watcherAttempts, 1)
        harness.advance(29)
        harness.coordinator.tick(tiers)
        XCTAssertEqual(harness.watcherAttempts, 1)
        harness.advance(1)
        harness.coordinator.tick(tiers)
        XCTAssertEqual(harness.watcherAttempts, 2)
    }

    func testNewWatcherReadsOnceMoreToCoverItsStartGap() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let harness = CoordinatorHarness()
        harness.makesRealWatchers = true
        let focused = WorkspaceState(title: "focused", cwd: root.path)
        let tiers: [(workspace: WorkspaceState, tier: GitRefreshTier)] = [(focused, .focused)]
        harness.coordinator.tick(tiers)
        XCTAssertEqual(harness.reads, ["focused"])

        // The read's result names the repository: the watcher starts after it.
        focused.updateGitContext(GitContext(
            branch: "main",
            identity: GitIdentity(repositoryRoot: root.path, head: "abc")
        ))
        harness.coordinator.gitContextChanged(focused)
        XCTAssertEqual(harness.watcherAttempts, 1)
        harness.advance(1)
        harness.coordinator.tick(tiers)
        XCTAssertEqual(harness.reads, ["focused", "focused"])
        harness.advance(1)
        harness.coordinator.tick(tiers)
        XCTAssertEqual(harness.reads.count, 2)
        harness.coordinator.tick([])
    }

    func testDiffStatsAreRefreshedOnlyAfterChanges() {
        let harness = CoordinatorHarness()
        let focused = makeWorkspace("focused")
        let tiers: [(workspace: WorkspaceState, tier: GitRefreshTier)] = [(focused, .focused)]
        harness.coordinator.tick(tiers)
        XCTAssertTrue(harness.coordinator.diffStatsDue(tiers).isEmpty)

        harness.coordinator.noteChange(.worktree, for: focused)
        XCTAssertEqual(harness.coordinator.diffStatsDue(tiers).map(\.title), ["focused"])
        harness.coordinator.noteDiffStatsRefresh(focused)
        XCTAssertTrue(harness.coordinator.diffStatsDue(tiers).isEmpty)

        harness.advance(5)
        harness.coordinator.noteChange(.worktree, for: focused)
        XCTAssertTrue(harness.coordinator.diffStatsDue(tiers).isEmpty, "focused diff cadence is 10 s")
        harness.advance(5)
        XCTAssertEqual(harness.coordinator.diffStatsDue(tiers).map(\.title), ["focused"])
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

    func testPushFollowsThePullRequestClosely() {
        let harness = CoordinatorHarness()
        let focused = makeWorkspace("focused")
        let tiers: [(workspace: WorkspaceState, tier: GitRefreshTier)] = [(focused, .focused)]
        harness.coordinator.tick(tiers)
        harness.coordinator.notePullRequestRefresh(focused)
        XCTAssertTrue(harness.coordinator.pullRequestsDue(tiers).isEmpty)

        harness.coordinator.noteChange(.remoteBranch, for: focused)
        XCTAssertEqual(harness.reads, ["focused"], "a push does not change the local context")
        harness.advance(9)
        XCTAssertTrue(harness.coordinator.pullRequestsDue(tiers).isEmpty, "GitHub needs a moment")
        harness.advance(1)
        XCTAssertEqual(harness.coordinator.pullRequestsDue(tiers).map(\.title), ["focused"])

        harness.coordinator.notePullRequestRefresh(focused)
        harness.advance(30)
        XCTAssertEqual(harness.coordinator.pullRequestsDue(tiers).map(\.title), ["focused"])

        harness.advance(300)
        harness.coordinator.notePullRequestRefresh(focused)
        harness.advance(30)
        XCTAssertTrue(harness.coordinator.pullRequestsDue(tiers).isEmpty, "follow-up window is over")
        XCTAssertEqual(PullRequestRefreshPolicy.interval(for: .background, pullRequest: nil, recentlyPushed: true), 120)
    }

    // MARK: - Helpers

    private func makeWorkspace(_ title: String) -> WorkspaceState {
        let workspace = WorkspaceState(title: title, cwd: NSTemporaryDirectory())
        workspace.updateGitContext(GitContext(
            branch: "feature/\(title)",
            identity: GitIdentity(repositoryRoot: "/repo/\(title)", head: "abc")
        ))
        return workspace
    }

    @MainActor
    private final class CoordinatorHarness {
        var now: TimeInterval = 1_000
        var reads: [String] = []
        var attempts = 0
        var acceptsReads = true
        var watcherAttempts = 0
        var makesRealWatchers = false
        private(set) var coordinator: GitRefreshCoordinator!

        init() {
            coordinator = GitRefreshCoordinator(
                clock: { [unowned self] in self.now },
                makeWatcher: { [unowned self] layout, branch, onChange in
                    self.watcherAttempts += 1
                    guard self.makesRealWatchers else { return nil }
                    return GitRepositoryWatcher(layout: layout, branch: branch, onChange: onChange)
                },
                startObservation: { [unowned self] workspace, _ in
                    self.attempts += 1
                    guard self.acceptsReads else { return false }
                    self.reads.append(workspace.title)
                    return true
                },
                resolveLayout: { root, completion in
                    completion(GitRepositoryLayout(worktreeRoot: root, gitDirectory: nil, commonDirectory: nil))
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
}
