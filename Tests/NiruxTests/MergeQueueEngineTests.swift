import XCTest
@testable import Nirux

/// The merge queue's state machine (docs/project-board.md, sections 3 and
/// 7): each transition, driven by a scripted GitHub and an injected clock.
final class MergeQueueEngineTests: XCTestCase {
    private let a = MQ.sha("a")
    private let b = MQ.sha("b")
    private let c = MQ.sha("c")
    private let d = MQ.sha("d")
    private let e = MQ.sha("e")
    private let f = MQ.sha("f")

    /// #52 at `a`, open and mergeable, `test` green on it.
    private func readyWorld() -> MQ.World {
        var world = MQ.World()
        world.pullRequests[52] = MQ.pullRequest(52, head: a)
        world.checks[a] = MQ.checks(MQ.checkRun(id: 1))
        return world
    }

    private func started(_ world: MQ.World, entries: [MergeQueue.ConfirmedEntry]? = nil,
                         settings: BoardConfig.QueueSettings = MQ.settings()) -> MQ.Harness {
        var queue = MQ.Harness(settings: settings, entries: entries ?? [MQ.entry(52, head: a)])
        queue.start()
        return queue
    }

    // MARK: Happy paths

    func testMergesEachPullRequestAfterThePreviousNightly() {
        var world = readyWorld()
        world.pullRequests[53] = MQ.pullRequest(53, head: b)
        world.checks[b] = MQ.checks(MQ.checkRun(id: 2))
        var queue = started(world, entries: [MQ.entry(52, head: a), MQ.entry(53, head: b)])
        XCTAssertEqual(queue.pendingReads, [.auth, .rateLimit, .baseMergeQueue, .baseRuns])

        XCTAssertEqual(queue.run(world), .merge(number: 52, head: a, method: .merge))
        XCTAssertEqual(queue.engine.entries[0].step, .merging(a))
        XCTAssertEqual(queue.engine.entries[1].step, .waiting)
        world.merge(52, as: c)
        world.pushRuns[c] = [MQ.run(10, head: c, status: "in_progress", conclusion: nil)]
        queue.mutated(.sent)
        queue.answer(world)
        XCTAssertEqual(queue.engine.entries[0].mergeCommit, c)
        XCTAssertEqual(queue.engine.entries[0].step, .waitingForPostMerge(c))
        XCTAssertEqual(queue.pendingReads, [.pushRuns(commit: c)])
        queue.answer(world)
        XCTAssertEqual(queue.engine.entries[0].step, .waitingForPostMerge(c))
        XCTAssertEqual(queue.pendingDelay, 30)
        XCTAssertEqual(queue.engine.statusText, "waiting for the nightly of #52, 1 of 2")

        world.pushRuns[c] = [MQ.run(10, head: c)]
        XCTAssertEqual(queue.run(world), .merge(number: 53, head: b, method: .merge))
        XCTAssertEqual(queue.engine.entries[0].step, .done)
        world.merge(53, as: d)
        world.pushRuns[d] = [MQ.run(11, head: d)]
        queue.mutated(.sent)
        XCTAssertNil(queue.run(world))
        XCTAssertEqual(queue.phase, .finished)
        XCTAssertEqual(queue.engine.entries.map(\.step), [.done, .done])
        XCTAssertEqual(queue.mutations.count, 2)
        XCTAssertTrue(queue.noted("Finished: 2 merged"))
        XCTAssertTrue(queue.noted("Merging aaaaaaa into main at 0000000: test ✓ (run 900); mergeable, not behind"))
    }

    func testWithoutAPostMergeWorkflowTheNextMergeFollowsAtOnce() {
        var world = readyWorld()
        world.pullRequests[53] = MQ.pullRequest(53, head: b)
        world.checks[b] = MQ.checks(MQ.checkRun(id: 2))
        var queue = started(world, entries: [MQ.entry(52, head: a), MQ.entry(53, head: b)],
                            settings: MQ.settings(postMergeWorkflow: nil, mergeMethod: .squash))
        XCTAssertEqual(queue.run(world), .merge(number: 52, head: a, method: .squash))
        world.merge(52, as: c)
        queue.mutated(.sent)
        // Right after the merge: no post-merge run to wait for.
        XCTAssertEqual(queue.run(world), .merge(number: 53, head: b, method: .squash))
    }

    func testABehindBranchIsUpdatedAndMergedAtItsNewHeadOnceItsOwnChecksPass() {
        var world = readyWorld()
        world.behind[a] = 2
        var queue = started(world)
        XCTAssertEqual(queue.run(world), .updateBranch(number: 52, expectedHead: a))
        XCTAssertEqual(queue.engine.entries[0].step, .updating(from: a))
        queue.mutated(.sent)
        // GitHub hasn't pushed the update yet.
        queue.answer(world)
        XCTAssertEqual(queue.pendingReads, [.pullRequest(52)])
        XCTAssertEqual(queue.pendingDelay, 10)

        world.pullRequests[52] = MQ.pullRequest(52, head: e)
        world.commits[e] = MergeQueue.CommitInfo(sha: e, committerLogin: "web-flow", parents: [a, world.mainTip])
        queue.answer(world, until: { $0.engine.entries[0].step == .waitingForChecks(e) })
        XCTAssertEqual(queue.engine.entries[0].heads, [a, e])
        XCTAssertEqual(queue.engine.entries[0].updates, 1)
        // `test` is green on the old head only: that doesn't count.
        queue.answer(world)
        XCTAssertEqual(queue.pendingReads, [.pullRequest(52), .checks(e)])
        XCTAssertEqual(queue.pendingDelay, 20)
        world.checks[e] = MQ.checks(MQ.checkRun(id: 2))
        XCTAssertEqual(queue.run(world), .merge(number: 52, head: e, method: .merge))
    }

    // MARK: Preflight

    func testAHeadThatChangedSinceConfirmationStopsWithACompareLink() {
        var world = readyWorld()
        world.pullRequests[52] = MQ.pullRequest(52, head: f)
        var queue = started(world)
        queue.run(world)
        XCTAssertEqual(queue.stopReason?.kind, .changed)
        XCTAssertEqual(queue.stopReason?.url, "https://github.com/acme/widgets/compare/\(a)...\(f)")
        XCTAssertEqual(queue.engine.entries[0].step, queue.stopReason.map { .stopped($0) })
        XCTAssertTrue(queue.mutations.isEmpty)
    }

    func testAPullRequestThatCantJoinStopsAtPreflight() {
        let cases: [(String, MergeQueue.PullRequestSnapshot, MergeQueue.StopReason.Kind)] = [
            ("auto-merge", MQ.pullRequest(52, head: a, autoMerge: true), .notMergeable),
            ("GitHub's merge queue", MQ.pullRequest(52, head: a, inMergeQueue: true), .notMergeable),
            ("draft", MQ.pullRequest(52, head: a, isDraft: true), .notMergeable),
            ("closed", MQ.pullRequest(52, head: a, state: "CLOSED"), .notMergeable),
            ("merged elsewhere", MQ.pullRequest(52, head: a, state: "MERGED"), .notMergeable),
            ("another base", MQ.pullRequest(52, head: a, base: "dev"), .notMergeable),
            ("a fork", MQ.pullRequest(52, head: a, repository: GitHubRepository(owner: "someone", name: "widgets")), .notMergeable),
            ("a deleted fork", MQ.pullRequest(52, head: a, repository: nil), .notMergeable),
            ("a conflict", MQ.pullRequest(52, head: a, mergeable: "CONFLICTING"), .conflict)
        ]
        for (name, pullRequest, kind) in cases {
            var world = readyWorld()
            world.pullRequests[52] = pullRequest
            var queue = started(world)
            queue.run(world)
            XCTAssertEqual(queue.stopReason?.kind, kind, name)
            XCTAssertTrue(queue.mutations.isEmpty, name)
        }
        var world = readyWorld()
        world.pullRequests[52] = MQ.pullRequest(52, head: a, autoMerge: true)
        var queue = started(world)
        queue.run(world)
        XCTAssertTrue(queue.stopReason?.message.contains("gh pr merge 52 --disable-auto") == true)
    }

    func testABusyAgentThatGoesIdleInTimeLetsThePullRequestGoOn() {
        var world = readyWorld()
        world.local.busyAgents = ["claude working in “api”"]
        var queue = started(world)
        queue.answer(world, until: { $0.pendingDelay == 20 })
        XCTAssertEqual(queue.pendingReads, [.pullRequest(52)])
        XCTAssertTrue(queue.noted("Waiting up to 10 minutes for claude working in “api”"))
        queue.answer(world)
        queue.answer(world)
        world.local.busyAgents = []
        XCTAssertEqual(queue.run(world), .merge(number: 52, head: a, method: .merge))
    }

    func testABusyAgentStopsTheQueueAfterTenMinutes() {
        var world = readyWorld()
        world.local.busyAgents = ["codex waiting (permission: Bash) in “api”"]
        var queue = started(world)
        let start = queue.now
        XCTAssertNil(queue.run(world))
        XCTAssertEqual(queue.stopReason?.kind, .agentBusy)
        XCTAssertTrue(queue.stopReason?.message.contains("codex waiting (permission: Bash)") == true)
        XCTAssertGreaterThanOrEqual(queue.now - start, 600)
        XCTAssertLessThan(queue.now - start, 640)
    }

    func testAnOpenDialogInAFocusedColumnCountsAsBusy() {
        // A focused column reads `.idle` while its dialog is open.
        let state = ProjectBoard.agentState(
            stuck: nil, hasAgent: true, agentInFront: true, status: .idle,
            openDialog: .permission(tool: "Bash", summary: "rm -rf build")
        )
        XCTAssertEqual(MergeQueue.busyLabel(state), "waiting (permission · Bash)")
        XCTAssertEqual(MergeQueue.busyLabel(.working(duration: "3m")), "working")
        XCTAssertNil(MergeQueue.busyLabel(.idle))
        XCTAssertNil(MergeQueue.busyLabel(.exitedMidTurn(processName: "claude")))
    }

    func testAnAgentBackAtWorkBeforeTheMergeIsWaitedForAgain() {
        var world = readyWorld()
        // Busy for nearly 10 minutes at preflight: the wait before the merge starts afresh.
        world.local.busyAgents = ["claude working in “api”"]
        var queue = started(world)
        queue.answer(world, until: { $0.now >= 1_000 + 590 })
        world.local.busyAgents = []
        queue.answer(world, until: { $0.engine.entries[0].step == .merging(self.a) })
        world.local.busyAgents = ["claude working in “api”"]
        queue.answer(world)
        XCTAssertEqual(queue.pendingDelay, 20)
        XCTAssertNil(queue.pendingMutation)
        world.local.busyAgents = []
        XCTAssertEqual(queue.run(world), .merge(number: 52, head: a, method: .merge))

        world = readyWorld()
        queue = atMergeChecks(world)
        world.local.worktrees = [MergeQueue.LocalWorktree(path: "/work/widgets.feat-52", problem: .unpushed)]
        queue.answer(world)
        XCTAssertEqual(queue.stopReason?.kind, .local)
        XCTAssertTrue(queue.mutations.isEmpty)
    }

    func testLocalChangesOrUnpushedCommitsStopAtPreflight() {
        for (problem, text) in [
            (MergeQueue.LocalWorktree.Problem.trackedChanges, "changes to tracked files"),
            (.unpushed, "commits that aren’t on GitHub")
        ] {
            var world = readyWorld()
            world.local.worktrees = [MergeQueue.LocalWorktree(path: "/work/widgets.feat-52", problem: problem)]
            var queue = started(world)
            queue.run(world)
            XCTAssertEqual(queue.stopReason?.kind, .local)
            XCTAssertTrue(queue.stopReason?.message.contains(text) == true, text)
            XCTAssertTrue(queue.stopReason?.message.contains("/work/widgets.feat-52") == true)
        }
        var world = readyWorld()
        world.local.worktrees = [MergeQueue.LocalWorktree(path: "/work/widgets.feat-52", problem: nil)]
        var queue = started(world)
        XCTAssertEqual(queue.run(world), .merge(number: 52, head: a, method: .merge))
    }

    // MARK: Updates

    private func updating(_ world: inout MQ.World) -> MQ.Harness {
        world.behind[a] = 1
        var queue = started(world)
        XCTAssertEqual(queue.run(world), .updateBranch(number: 52, expectedHead: a))
        return queue
    }

    func testUpdateBranch422WithNoNewCommitsGoesOn() {
        var world = readyWorld()
        var queue = updating(&world)
        queue.mutated(.refused(status: 422, message: "There are no new commits on the base branch."))
        XCTAssertEqual(queue.pendingReads, [.pullRequest(52)])
        queue.answer(world)
        XCTAssertEqual(queue.engine.entries[0].step, .waitingForChecks(a))
    }

    func testUpdateBranch422WhoseHeadMovedStops() {
        var world = readyWorld()
        var queue = updating(&world)
        world.pullRequests[52] = MQ.pullRequest(52, head: f)
        queue.mutated(.refused(status: 422, message: "expected head sha didn’t match current head ref."))
        queue.run(world)
        XCTAssertEqual(queue.stopReason?.kind, .changed)
    }

    func testUpdateBranch422OnAConflictStopsAsAConflict() {
        var world = readyWorld()
        var queue = updating(&world)
        world.pullRequests[52] = MQ.pullRequest(52, head: a, mergeable: "UNKNOWN")
        queue.mutated(.refused(status: 422, message: "merge conflict between base and head"))
        queue.answer(world)
        // GitHub is still computing: read again, with back-off.
        XCTAssertEqual(queue.pendingReads, [.pullRequest(52)])
        XCTAssertEqual(queue.pendingDelay, 5)
        world.pullRequests[52] = MQ.pullRequest(52, head: a, mergeable: "CONFLICTING")
        queue.run(world)
        XCTAssertEqual(queue.stopReason?.kind, .conflict)
        XCTAssertEqual(queue.mutations.count, 1)
    }

    func testUpdateBranch422ForAnotherReasonStopsWithGitHubsMessage() {
        var world = readyWorld()
        var queue = updating(&world)
        queue.mutated(.refused(status: 422, message: "Branch is protected"))
        queue.run(world)
        XCTAssertEqual(queue.stopReason?.kind, .update)
        XCTAssertTrue(queue.stopReason?.message.contains("Branch is protected") == true)
    }

    func testANewHeadThatIsntGitHubsUpdateStops() {
        let parentOnMain = MQ.sha("9")
        let cases: [(String, MergeQueue.CommitInfo, MergeQueue.Comparison?)] = [
            ("another committer", MergeQueue.CommitInfo(sha: e, committerLogin: "someone", parents: [a, parentOnMain]), nil),
            ("unexpected first parent", MergeQueue.CommitInfo(sha: e, committerLogin: "web-flow", parents: [b, parentOnMain]), nil),
            ("one parent", MergeQueue.CommitInfo(sha: e, committerLogin: "web-flow", parents: [a]), nil),
            ("second parent off main", MergeQueue.CommitInfo(sha: e, committerLogin: "web-flow", parents: [a, parentOnMain]),
             MergeQueue.Comparison(status: "diverged", aheadBy: 3, behindBy: 1, baseCommit: parentOnMain))
        ]
        for (name, commit, comparison) in cases {
            var world = readyWorld()
            var queue = updating(&world)
            queue.mutated(.sent)
            world.pullRequests[52] = MQ.pullRequest(52, head: e)
            world.commits[e] = commit
            if let comparison { world.compares[.compare(base: parentOnMain, head: "main")] = comparison }
            queue.run(world)
            XCTAssertEqual(queue.stopReason?.kind, .changed, name)
            XCTAssertTrue(queue.stopReason?.message.contains("Someone pushed to #52") == true, name)
        }
    }

    func testAnUpdateThatNeverLandsStopsAfterFiveMinutes() {
        var world = readyWorld()
        var queue = updating(&world)
        let sent = queue.now
        queue.mutated(.sent)
        queue.run(world)
        XCTAssertEqual(queue.stopReason?.kind, .update)
        XCTAssertGreaterThanOrEqual(queue.now - sent, 300)
    }

    func testAFailedUpdateIsNeverSentAgain() {
        var world = readyWorld()
        var queue = updating(&world)
        queue.mutated(.uncertain("gh couldn’t start, or took longer than 120 s"))
        queue.run(world)
        XCTAssertEqual(queue.stopReason?.kind, .update)
        XCTAssertEqual(queue.mutations.count, 1)

        // The same failure, but GitHub made the update after all.
        world = readyWorld()
        queue = updating(&world)
        world.pullRequests[52] = MQ.pullRequest(52, head: e)
        world.commits[e] = MergeQueue.CommitInfo(sha: e, committerLogin: "web-flow", parents: [a, world.mainTip])
        world.checks[e] = MQ.checks(MQ.checkRun(id: 2))
        queue.mutated(.uncertain("timeout"))
        XCTAssertEqual(queue.run(world), .merge(number: 52, head: e, method: .merge))
        XCTAssertEqual(queue.mutations.count, 2)
    }

    func testABranchStillBehindAfterTwoUpdatesStops() {
        var world = readyWorld()
        var queue = updating(&world)
        world.pullRequests[52] = MQ.pullRequest(52, head: e)
        world.commits[e] = MergeQueue.CommitInfo(sha: e, committerLogin: "web-flow", parents: [a, world.mainTip])
        world.behind[e] = 1
        queue.mutated(.sent)
        XCTAssertEqual(queue.run(world), .updateBranch(number: 52, expectedHead: e))
        world.pullRequests[52] = MQ.pullRequest(52, head: f)
        world.commits[f] = MergeQueue.CommitInfo(sha: f, committerLogin: "web-flow", parents: [e, world.mainTip])
        world.behind[f] = 1
        queue.mutated(.sent)
        XCTAssertNil(queue.run(world))
        XCTAssertEqual(queue.stopReason?.kind, .update)
        XCTAssertTrue(queue.stopReason?.message.contains("after 2 updates") == true)
        XCTAssertEqual(queue.engine.entries[0].heads, [a, e, f])
    }

    // MARK: Checks

    func testAFlakyCheckIsRerunOnceAndTheNewRunReplacesTheFailure() {
        var world = readyWorld()
        world.checks[a] = MQ.checks(MQ.checkRun(id: 5000, conclusion: "FAILURE"))
        var queue = started(world)
        XCTAssertEqual(queue.run(world), .rerun(runID: 900))
        XCTAssertEqual(queue.engine.entries[0].step, .rerunning(a))
        queue.mutated(.sent)
        // Right after the rerun the old failure still shows.
        queue.answer(world)
        queue.answer(world)
        XCTAssertNil(queue.stopReason)
        XCTAssertEqual(queue.pendingReads, [.pullRequest(52), .checks(a)])
        world.checks[a] = MQ.checks(MQ.checkRun(id: 5000, conclusion: "FAILURE"),
                                    MQ.checkRun(id: 5001, status: "IN_PROGRESS", conclusion: nil))
        queue.answer(world)
        XCTAssertNil(queue.stopReason)
        world.checks[a] = MQ.checks(MQ.checkRun(id: 5001))
        XCTAssertEqual(queue.run(world), .merge(number: 52, head: a, method: .merge))
        XCTAssertEqual(queue.mutations, [.rerun(runID: 900), .merge(number: 52, head: a, method: .merge)])
    }

    func testARequiredJobSkippedBecauseItsNeedFailedWaitsForTheRerun() {
        var world = readyWorld()
        // `test` needs `build`: build failed, so test was skipped.
        world.checks[a] = MQ.checks(MQ.checkRun(id: 5000, name: "build", conclusion: "FAILURE"),
                                    MQ.checkRun(id: 5001, name: "test", conclusion: "SKIPPED"))
        var queue = started(world, settings: MQ.settings(requiredChecks: ["build", "test"]))
        XCTAssertEqual(queue.run(world), .rerun(runID: 900))
        queue.mutated(.sent)
        queue.answer(world)
        XCTAssertNil(queue.stopReason)
        world.checks[a] = MQ.checks(MQ.checkRun(id: 5002, name: "build"), MQ.checkRun(id: 5003, name: "test"))
        XCTAssertEqual(queue.run(world), .merge(number: 52, head: a, method: .merge))
    }

    func testTheRerunWaitsUntilItsWorkflowRunIsDone() {
        var world = readyWorld()
        // `test` failed, but another job of the same run still runs.
        world.checks[a] = MQ.checks(MQ.checkRun(id: 5000, conclusion: "FAILURE"),
                                    MQ.checkRun(id: 5002, name: "lint", status: "IN_PROGRESS", conclusion: nil))
        var queue = started(world)
        queue.answer(world, until: { $0.pendingDelay == 20 })
        XCTAssertTrue(queue.mutations.isEmpty)
        XCTAssertEqual(queue.engine.entries[0].step, .waitingForChecks(a))
        world.checks[a] = MQ.checks(MQ.checkRun(id: 5000, conclusion: "FAILURE"), MQ.checkRun(id: 5002, name: "lint"))
        XCTAssertEqual(queue.run(world), .rerun(runID: 900))
    }

    func testASecondFailureAfterTheRerunStops() {
        var world = readyWorld()
        world.checks[a] = MQ.checks(MQ.checkRun(id: 5000, conclusion: "FAILURE"))
        var queue = started(world)
        XCTAssertEqual(queue.run(world), .rerun(runID: 900))
        queue.mutated(.sent)
        world.checks[a] = MQ.checks(MQ.checkRun(id: 5001, conclusion: "TIMED_OUT"))
        XCTAssertNil(queue.run(world))
        XCTAssertEqual(queue.stopReason?.kind, .checks)
        XCTAssertTrue(queue.stopReason?.message.contains("failed again") == true)
        XCTAssertEqual(queue.mutations, [.rerun(runID: 900)])
    }

    func testFailuresNiruxCantRerunStopAtOnce() {
        let cases: [(String, MergeQueue.CommitChecks)] = [
            ("another app's check", MQ.checks(MQ.checkRun(id: 1, workflow: nil, runID: nil, conclusion: "FAILURE"))),
            ("two runs", MQ.checks(MQ.checkRun(id: 1, workflow: "Tests", runID: 900, conclusion: "FAILURE"),
                                   MQ.checkRun(id: 2, workflow: "Other", runID: 901, conclusion: "FAILURE"))),
            ("a commit status", MergeQueue.CommitChecks(runs: [], statuses: [.init(context: "test", state: "ERROR")]))
        ]
        for (name, checks) in cases {
            var world = readyWorld()
            world.checks[a] = checks
            var queue = started(world)
            XCTAssertNil(queue.run(world), name)
            XCTAssertEqual(queue.stopReason?.kind, .checks, name)
            XCTAssertTrue(queue.mutations.isEmpty, name)
        }
    }

    func testARequiredCheckThatIsNeitherGreenNorRedStops() {
        var world = readyWorld()
        world.checks[a] = MQ.checks(MQ.checkRun(id: 1, conclusion: "SKIPPED"))
        var queue = started(world)
        queue.run(world)
        XCTAssertEqual(queue.stopReason?.kind, .checks)
        XCTAssertTrue(queue.stopReason?.message.contains("test (skipped)") == true)
    }

    func testAMissingRequiredCheckStopsAfterTheTimeout() {
        var world = readyWorld()
        world.checks[a] = MQ.checks(MQ.checkRun(id: 1, name: "tset"))
        var queue = started(world)
        let start = queue.now
        queue.run(world)
        XCTAssertEqual(queue.stopReason?.kind, .checks)
        XCTAssertTrue(queue.stopReason?.message.contains("test (not started)") == true)
        XCTAssertGreaterThanOrEqual(queue.now - start, 30 * 60)
        XCTAssertLessThan(queue.now - start, 30 * 60 + 60)
    }

    func testAQueuedRequiredCheckTimesOutWithoutBlamingItsName() {
        var world = readyWorld()
        world.checks[a] = MQ.checks(MQ.checkRun(id: 1, status: "QUEUED", conclusion: nil))
        var queue = started(world)
        queue.run(world)
        let message = queue.stopReason?.message ?? ""
        XCTAssertTrue(message.contains("test (queued)"), message)
        XCTAssertTrue(message.contains("raise the checks timeout"), message)
        XCTAssertFalse(message.contains("misspelled"), message)
    }

    func testARateLimitPauseDoesntCountTowardTimeouts() {
        var world = readyWorld()
        world.checks[a] = MergeQueue.CommitChecks()
        var queue = started(world)
        queue.answer(world, until: { $0.pendingDelay == 20 })
        // An hour's pause in the middle of a 30-minute wait for checks.
        queue.fail(.rateLimited(resumeAt: queue.now + 3_600))
        queue.answer(world)
        XCTAssertNil(queue.stopReason)
        XCTAssertEqual(queue.pendingDelay, 20)

        // Nor toward the 5 minutes of failed reads around it.
        queue.fail(.transient("timeout"))
        queue.fail(.rateLimited(resumeAt: queue.now + 900))
        queue.fail(.transient("timeout"))
        XCTAssertNil(queue.stopReason)
    }

    func testACommitStatusAloneNeverMakesARequiredCheckGreen() {
        let status = MergeQueue.CommitChecks(runs: [], statuses: [.init(context: "test", state: "SUCCESS")])
        XCTAssertEqual(MergeQueue.judge(status, required: ["test"]).pending, ["test (not started)"])
        let both = MergeQueue.CommitChecks(runs: [MQ.checkRun(id: 1)], statuses: [.init(context: "test", state: "SUCCESS")])
        XCTAssertTrue(MergeQueue.judge(both, required: ["test"]).allRequiredGreen)
    }

    func testTwoWorkflowsWithOneNameCountSeparately() {
        let checks = MQ.checks(MQ.checkRun(id: 2, name: "build", workflow: "CI", workflowID: 1),
                               MQ.checkRun(id: 1, name: "build", workflow: "CI", workflowID: 2, runID: 901, conclusion: "FAILURE"))
        XCTAssertEqual(MergeQueue.judge(checks, required: ["build"]).failed.map(\.id), [1])
    }

    func testARerunJobThatIsntRequiredStillBlocksUntilItsNewRunShows() {
        let checks = MQ.checks(MQ.checkRun(id: 1),
                               MQ.checkRun(id: 2, name: "lint", conclusion: "FAILURE"),
                               MQ.checkRun(id: 3, name: "deploy", conclusion: "SKIPPED"))
        let replaced = MergeQueue.runsReplaced(byRerunOf: 900, in: checks, required: ["test"])
        // The failed job, not a job skipped for its own reasons.
        XCTAssertEqual(replaced, [2])
        XCTAssertEqual(MergeQueue.judge(checks, required: ["test"], replaced: replaced).pending, ["Tests / lint (rerun not started)"])
    }

    func testARedCheckThatIsntRequiredBlocksTheMerge() {
        var world = readyWorld()
        world.checks[a] = MQ.checks(MQ.checkRun(id: 1),
                                    MQ.checkRun(id: 2, name: "Analyze (swift)", workflow: "CodeQL", runID: 901,
                                                conclusion: "FAILURE"))
        var queue = started(world)
        queue.run(world)
        XCTAssertEqual(queue.stopReason?.kind, .checks)
        XCTAssertTrue(queue.stopReason?.message.contains("CodeQL / Analyze (swift)") == true)
    }

    func testAPendingCheckThatIsntRequiredDoesntBlock() {
        var world = readyWorld()
        world.checks[a] = MQ.checks(MQ.checkRun(id: 1),
                                    MQ.checkRun(id: 2, name: "Analyze (swift)", workflow: "CodeQL", runID: 901,
                                                status: "IN_PROGRESS", conclusion: nil),
                                    MQ.checkRun(id: 3, name: "CodeQL", workflow: nil, runID: nil, conclusion: "NEUTRAL"))
        var queue = started(world)
        XCTAssertEqual(queue.run(world), .merge(number: 52, head: a, method: .merge))
    }

    // MARK: Merge

    /// Answers until the step 4 reads are pending.
    private func atMergeChecks(_ world: MQ.World) -> MQ.Harness {
        var queue = started(world)
        queue.answer(world, until: { $0.engine.entries[0].step == .merging(self.a) })
        return queue
    }

    func testMergeableUnknownIsReadAgainUntilGitHubKnows() {
        var world = readyWorld()
        world.pullRequests[52] = MQ.pullRequest(52, head: a, mergeable: "UNKNOWN")
        var queue = atMergeChecks(world)
        queue.answer(world)
        XCTAssertEqual(queue.pendingDelay, 5)
        queue.answer(world)
        XCTAssertEqual(queue.pendingDelay, 10)
        world.pullRequests[52] = MQ.pullRequest(52, head: a)
        XCTAssertEqual(queue.run(world), .merge(number: 52, head: a, method: .merge))

        world.pullRequests[52] = MQ.pullRequest(52, head: a, mergeable: "UNKNOWN")
        queue = atMergeChecks(world)
        queue.answer(world)
        world.pullRequests[52] = MQ.pullRequest(52, head: a, mergeable: "CONFLICTING")
        queue.run(world)
        XCTAssertEqual(queue.stopReason?.kind, .conflict)

        world.pullRequests[52] = MQ.pullRequest(52, head: a, mergeable: "UNKNOWN")
        queue = atMergeChecks(world)
        let start = queue.now
        queue.run(world)
        XCTAssertEqual(queue.stopReason?.kind, .merge)
        XCTAssertGreaterThanOrEqual(queue.now - start, 120)
    }

    func testAHeadOrBaseChangeAtMergeStops() {
        var world = readyWorld()
        var queue = atMergeChecks(world)
        world.pullRequests[52] = MQ.pullRequest(52, head: f)
        queue.answer(world)
        XCTAssertEqual(queue.stopReason?.kind, .changed)

        world = readyWorld()
        queue = atMergeChecks(world)
        world.pullRequests[52] = MQ.pullRequest(52, head: a, base: "release")
        queue.answer(world)
        XCTAssertEqual(queue.stopReason?.kind, .notMergeable)
        XCTAssertTrue(queue.stopReason?.message.contains("targets release") == true)
        XCTAssertTrue(queue.mutations.isEmpty)
    }

    func testABaseThatMovedBeforeTheMergeUpdatesTheBranchAgain() {
        var world = readyWorld()
        var queue = atMergeChecks(world)
        world.behind[a] = 1
        queue.answer(world)
        XCTAssertEqual(queue.pendingMutation, .updateBranch(number: 52, expectedHead: a))
    }

    func testAnUnfinishedPostMergeRunOnTheBaseIsWaitedForFirst() {
        var world = readyWorld()
        world.baseRuns = [MQ.run(77, head: world.mainTip, status: "in_progress", conclusion: nil, event: "workflow_dispatch")]
        var queue = atMergeChecks(world)
        queue.answer(world)
        XCTAssertEqual(queue.pendingDelay, 30)
        XCTAssertTrue(queue.noted("Waiting for the nightly running on main before merging"))
        // Only the base's runs are polled meanwhile, and a retry keeps saying so.
        XCTAssertEqual(queue.pendingReads, [.baseRuns])
        queue.fail(.transient("timeout"))
        XCTAssertEqual(queue.engine.statusText, "#52 waiting for the nightly on main before merging, 1 of 1")
        world.baseRuns = [MQ.run(77, head: world.mainTip, event: "workflow_dispatch")]
        queue.answer(world)
        // Every check of step 4 again, not the merge yet.
        XCTAssertNil(queue.pendingMutation)
        XCTAssertEqual(queue.pendingReads?.contains(.baseRuns), true)
        XCTAssertEqual(queue.engine.statusText, "merging #52, 1 of 1")
        XCTAssertEqual(queue.run(world), .merge(number: 52, head: a, method: .merge))

        world.baseRuns = [MQ.run(77, head: world.mainTip, status: "queued", conclusion: nil)]
        queue = atMergeChecks(world)
        queue.answer(world)
        world.baseRuns = [MQ.run(77, head: world.mainTip, conclusion: "failure")]
        queue.run(world)
        XCTAssertEqual(queue.stopReason?.kind, .postMerge)
        XCTAssertTrue(queue.stopReason?.message.contains("the base may be broken") == true)
        XCTAssertTrue(queue.mutations.isEmpty)
    }

    func testABaseRunThatFailedSinceStartStopsTheNextMerge() {
        var world = readyWorld()
        // A nightly that failed before Start is the sheet's warning, not a stop.
        world.baseRuns = [MQ.run(70, head: world.mainTip, conclusion: "failure")]
        var queue = atMergeChecks(world)
        // A manual run started and failed between two looks.
        world.baseRuns.insert(MQ.run(71, head: world.mainTip, conclusion: "startup_failure", event: "workflow_dispatch"), at: 0)
        queue.run(world)
        XCTAssertEqual(queue.stopReason?.kind, .postMerge)
        XCTAssertEqual(queue.stopReason?.url, "https://github.com/acme/widgets/actions/runs/71")
        XCTAssertTrue(queue.mutations.isEmpty)

        world.baseRuns = [MQ.run(70, head: world.mainTip, conclusion: "failure")]
        queue = started(world)
        XCTAssertEqual(queue.run(world), .merge(number: 52, head: a, method: .merge))

        // Still running at Start, failed while #52's checks ran.
        world.baseRuns = [MQ.run(72, head: world.mainTip, status: "in_progress", conclusion: nil)]
        world.checks[a] = MergeQueue.CommitChecks()
        queue = started(world)
        queue.answer(world, until: { $0.pendingDelay == 20 })
        world.baseRuns = [MQ.run(72, head: world.mainTip, conclusion: "failure")]
        world.checks[a] = MQ.checks(MQ.checkRun(id: 1))
        queue.run(world)
        XCTAssertEqual(queue.stopReason?.url, "https://github.com/acme/widgets/actions/runs/72")

        // Failed before Start, rerun since, and failed again.
        world.baseRuns = [MQ.run(70, head: world.mainTip, conclusion: "failure")]
        world.checks[a] = MergeQueue.CommitChecks()
        queue = started(world)
        queue.answer(world, until: { $0.pendingDelay == 20 })
        var rerun = MQ.run(70, head: world.mainTip, conclusion: "failure")
        rerun.attempt = 2
        world.baseRuns = [rerun]
        world.checks[a] = MQ.checks(MQ.checkRun(id: 1))
        queue.run(world)
        XCTAssertEqual(queue.stopReason?.url, "https://github.com/acme/widgets/actions/runs/70")
    }

    func testAMergeThatTimedOutButHappenedGoesOn() {
        var world = readyWorld()
        var queue = started(world)
        XCTAssertEqual(queue.run(world), .merge(number: 52, head: a, method: .merge))
        world.merge(52, as: c)
        queue.mutated(.uncertain("gh couldn’t start, or took longer than 120 s"))
        queue.answer(world)
        XCTAssertEqual(queue.engine.entries[0].step, .waitingForPostMerge(c))
        XCTAssertEqual(queue.mutations.count, 1)
    }

    func testAMergeThatNeverShowsStopsAfterAMinute() {
        let world = readyWorld()
        var queue = started(world)
        queue.run(world)
        let sent = queue.now
        queue.mutated(.uncertain("timeout"))
        queue.run(world)
        XCTAssertEqual(queue.stopReason?.kind, .merge)
        XCTAssertGreaterThanOrEqual(queue.now - sent, 60)
        XCTAssertEqual(queue.mutations.count, 1)

        queue = started(world)
        queue.run(world)
        queue.mutated(.refused(status: nil, message: "Head branch was modified. Review and try the merge again."))
        queue.run(world)
        XCTAssertTrue(queue.stopReason?.message.contains("Head branch was modified") == true)

        // Reads that fail while GitHub doesn't show the merge yet: the stop says it was sent.
        queue = started(world)
        queue.run(world)
        queue.mutated(.uncertain("timeout"))
        queue.fail(.refused("Bad credentials (HTTP 401)"))
        XCTAssertEqual(queue.stopReason?.kind, .github)
        XCTAssertTrue(queue.stopReason?.message.hasSuffix("The merge of #52 at aaaaaaa was sent and GitHub didn’t show "
            + "its effect yet: check #52 on GitHub.") == true)
    }

    func testAutoMergeOrGitHubsQueueInsteadOfAMergeStops() {
        var world = readyWorld()
        var queue = started(world)
        queue.run(world)
        world.pullRequests[52] = MQ.pullRequest(52, head: a, autoMerge: true)
        queue.mutated(.sent)
        queue.answer(world)
        XCTAssertEqual(queue.stopReason?.kind, .merge)
        XCTAssertTrue(queue.stopReason?.message.contains("--disable-auto") == true)

        world = readyWorld()
        queue = started(world)
        queue.run(world)
        world.pullRequests[52] = MQ.pullRequest(52, head: a, inMergeQueue: true)
        queue.mutated(.sent)
        queue.answer(world)
        XCTAssertTrue(queue.stopReason?.message.contains("merge queue") == true)
    }

    func testAMergeCommitOnAnUntestedBaseStops() {
        var world = readyWorld()
        var queue = started(world)
        queue.run(world)
        world.pullRequests[52] = MQ.pullRequest(52, head: a, state: "MERGED", mergeCommit: c, parents: [MQ.sha("9"), a])
        queue.mutated(.sent)
        queue.answer(world)
        XCTAssertEqual(queue.stopReason?.kind, .merge)
        XCTAssertTrue(queue.stopReason?.message.contains("untested base") == true)
        XCTAssertEqual(queue.engine.entries[0].mergeCommit, c)
    }

    func testAPullRequestMergedAtAnotherHeadStops() {
        var world = readyWorld()
        var queue = started(world)
        queue.run(world)
        world.pullRequests[52] = MQ.pullRequest(52, head: f, state: "MERGED", mergeCommit: c, parents: [world.mainTip, f])
        queue.mutated(.sent)
        queue.answer(world)
        XCTAssertTrue(queue.stopReason?.message.contains("outside the queue") == true)
        XCTAssertEqual(queue.engine.entries[0].mergeCommit, c)
    }

    // MARK: Post-merge workflow

    /// Merged as `c`; the push run of `c` is `run`.
    private func afterMerge(_ run: MergeQueue.Run?, world: inout MQ.World) -> MQ.Harness {
        var queue = started(world)
        XCTAssertEqual(queue.run(world), .merge(number: 52, head: a, method: .merge))
        world.merge(52, as: c)
        world.pushRuns[c] = run.map { [$0] } ?? []
        queue.mutated(.sent)
        return queue
    }

    func testAFailedPostMergeRunStops() {
        var world = readyWorld()
        var queue = afterMerge(MQ.run(10, head: c, conclusion: "failure"), world: &world)
        queue.run(world)
        XCTAssertEqual(queue.stopReason?.kind, .postMerge)
        XCTAssertEqual(queue.stopReason?.message, "The nightly of #52 failed (failure).")
        XCTAssertEqual(queue.stopReason?.url, "https://github.com/acme/widgets/actions/runs/10")
        XCTAssertEqual(queue.engine.entries[0].mergeCommit, c)
    }

    func testAPostMergeRunThatFailedAfterTheBaseMovedSaysSo() {
        var world = readyWorld()
        var queue = afterMerge(MQ.run(10, head: c, conclusion: "failure"), world: &world)
        world.compares[.compare(base: c, head: "main")] = MergeQueue.Comparison(status: "ahead", aheadBy: 1, behindBy: 0,
                                                                                  baseCommit: c)
        world.baseRuns = [MQ.run(11, head: MQ.sha("9"), status: "in_progress", conclusion: nil,
                                 title: "Merge pull request #60 from acme/feat-x"), MQ.run(10, head: c, conclusion: "failure")]
        queue.run(world)
        let message = queue.stopReason?.message ?? ""
        XCTAssertTrue(message.contains("main moved to 9999999 (“Merge pull request #60 from acme/feat-x”)"), message)
        XCTAssertTrue(message.contains("may not be at fault"), message)
    }

    func testACancelledPostMergeRunSaysWhatCancelledIt() {
        // A push moved main.
        var world = readyWorld()
        var queue = afterMerge(MQ.run(10, head: c, conclusion: "cancelled"), world: &world)
        world.compares[.compare(base: c, head: "main")] = MergeQueue.Comparison(status: "ahead", aheadBy: 1, behindBy: 0,
                                                                                  baseCommit: c)
        world.baseRuns = [MQ.run(11, head: MQ.sha("9"), status: "in_progress", conclusion: nil)]
        queue.run(world)
        XCTAssertTrue(queue.stopReason?.message.contains("cancelled by a push") == true)

        // A manual run on the same commit.
        world = readyWorld()
        queue = afterMerge(MQ.run(10, head: c, conclusion: "cancelled"), world: &world)
        world.baseRuns = [MQ.run(12, head: c, status: "in_progress", conclusion: nil, event: "workflow_dispatch")]
        queue.run(world)
        XCTAssertTrue(queue.stopReason?.message.contains("cancelled by a manual run") == true)

        // By hand.
        world = readyWorld()
        queue = afterMerge(MQ.run(10, head: c, conclusion: "cancelled"), world: &world)
        queue.run(world)
        XCTAssertEqual(queue.stopReason?.message, "The nightly of #52 was cancelled.")
    }

    func testAPostMergeRunThatNeverStartsOrNeverEndsStops() {
        var world = readyWorld()
        var queue = afterMerge(nil, world: &world)
        let merged = queue.now
        queue.run(world)
        XCTAssertTrue(queue.stopReason?.message.contains("No nightly run started") == true)
        XCTAssertGreaterThanOrEqual(queue.now - merged, 300)
        XCTAssertLessThan(queue.now - merged, 360)

        world = readyWorld()
        queue = afterMerge(MQ.run(10, head: c, status: "in_progress", conclusion: nil), world: &world)
        let start = queue.now
        queue.run(world)
        XCTAssertTrue(queue.stopReason?.message.contains("still runs after 30 minutes") == true)
        XCTAssertGreaterThanOrEqual(queue.now - start, 30 * 60)
    }

    // MARK: Start

    func testStartRefusesABaseWithGitHubsMergeQueueOrALowRateLimit() {
        var world = readyWorld()
        world.baseMergeQueue = true
        var queue = started(world)
        queue.run(world)
        XCTAssertEqual(queue.stopReason?.kind, .setup)
        XCTAssertTrue(queue.stopReason?.message.contains("requires GitHub’s merge queue") == true)

        world = readyWorld()
        world.rateLimit = MergeQueue.RateLimit(coreRemaining: 4000, coreReset: Date(), graphQLRemaining: 499, graphQLReset: Date())
        queue = started(world)
        queue.run(world)
        XCTAssertEqual(queue.stopReason?.kind, .setup)
        XCTAssertTrue(queue.stopReason?.message.contains("Only 499 GitHub requests") == true)
        XCTAssertNil(queue.engine.currentEntry)
    }

    func testGhMissingOrSignedOutStops() {
        var queue = started(readyWorld())
        queue.fail(.ghMissing)
        XCTAssertEqual(queue.stopReason?.kind, .setup)
        queue = started(readyWorld())
        queue.fail(.notSignedIn("You are not logged into any GitHub hosts."))
        XCTAssertTrue(queue.stopReason?.message.contains("gh auth login") == true)
    }

    // MARK: Stop, pauses, retries

    func testStopInEveryState() {
        typealias Point = (String, (inout MQ.World, inout MQ.Harness) -> Void)
        let readPoints: [Point] = [
            ("starting", { _, _ in }),
            ("preflight", { world, queue in queue.answer(world) }),
            ("waiting for an agent", { world, queue in
                world.local.busyAgents = ["claude working in “api”"]
                queue.answer(world, until: { $0.pendingDelay == 20 })
            }),
            ("waiting for checks", { world, queue in
                world.checks[self.a] = MergeQueue.CommitChecks()
                queue.answer(world, until: { $0.pendingDelay == 20 })
            }),
            ("paused by a rate limit", { _, queue in queue.fail(.rateLimited(resumeAt: queue.now + 600)) }),
            ("waiting for the nightly", { world, queue in
                queue.run(world)
                world.merge(52, as: self.c)
                queue.mutated(.sent)
                queue.answer(world)
            })
        ]
        for (name, reach) in readPoints {
            var world = readyWorld()
            var queue = started(world)
            reach(&world, &queue)
            let stale = queue.engine.request
            XCTAssertNotNil(stale, name)
            queue.send(.stop)
            XCTAssertEqual(queue.stopReason?.kind, .user, name)
            XCTAssertNil(queue.engine.request, name)
            // The read's late answer changes nothing.
            if let stale { queue.send(.read(requestID: stale.id, .success([:]))) }
            XCTAssertEqual(queue.stopReason?.kind, .user, name)
            XCTAssertNil(queue.engine.request, name)
        }

        let mutationPoints: [(String, (inout MQ.World) -> Void, MergeQueue.MutationResult)] = [
            ("updating", { world in world.behind[self.a] = 1 }, .sent),
            ("rerunning", { world in world.checks[self.a] = MQ.checks(MQ.checkRun(id: 9, conclusion: "FAILURE")) }, .sent),
            ("merging", { _ in }, .uncertain("timeout"))
        ]
        for (name, prepare, result) in mutationPoints {
            var world = readyWorld()
            prepare(&world)
            var queue = started(world)
            XCTAssertNotNil(queue.run(world), name)
            queue.send(.stop)
            XCTAssertEqual(queue.phase, .stopping, name)
            XCTAssertTrue(queue.engine.statusText.contains("(stopping)"), name)
            queue.mutated(result)
            XCTAssertEqual(queue.stopReason?.kind, .user, name)
            XCTAssertTrue(queue.stopReason?.message.contains("already sent, answered") == true, name)
            XCTAssertEqual(queue.stopReason?.message.contains("Check #52 on GitHub: it may be merged.") == true,
                           name == "merging", name)
            XCTAssertNil(queue.engine.request, name)
        }

        // Finished and stopped queues ignore Stop.
        var queue = started(readyWorld())
        queue.fail(.ghMissing)
        let reason = queue.stopReason
        queue.send(.stop)
        XCTAssertEqual(queue.stopReason, reason)
    }

    func testARateLimitPausesReadsUntilItsReset() {
        let world = readyWorld()
        var queue = started(world)
        queue.fail(.rateLimited(resumeAt: queue.now + 120))
        XCTAssertEqual(queue.phase, .paused(until: queue.now + 120))
        XCTAssertEqual(queue.pendingReads, [.auth, .rateLimit, .baseMergeQueue, .baseRuns])
        XCTAssertEqual(queue.pendingDelay, 120)
        XCTAssertTrue(queue.engine.statusText.contains("paused"))
        queue.answer(world)
        XCTAssertEqual(queue.phase, .running)

        queue = started(world)
        queue.fail(.secondaryRateLimit)
        XCTAssertEqual(queue.pendingDelay, 60)
        queue.fail(.secondaryRateLimit)
        XCTAssertEqual(queue.pendingDelay, 120)
        // An ordinary retry after the pause isn't a pause any more.
        queue.fail(.transient("HTTP 502: Bad Gateway"))
        XCTAssertEqual(queue.phase, .running)
        queue.answer(world)
        XCTAssertEqual(queue.phase, .running)
    }

    func testAMutationRefusedByARateLimitStops() {
        var world = readyWorld()
        var queue = updating(&world)
        queue.mutated(.rateLimited("API rate limit exceeded"))
        XCTAssertEqual(queue.stopReason?.kind, .update)
        XCTAssertNil(queue.engine.request)
    }

    func testTransientReadFailuresRetryWithBackOffForFiveMinutes() {
        var queue = started(readyWorld())
        let start = queue.now
        var delays: [TimeInterval] = []
        while queue.stopReason == nil {
            queue.fail(.transient("HTTP 502: Bad Gateway"))
            if let delay = queue.pendingDelay { delays.append(delay) }
        }
        XCTAssertEqual(Array(delays.prefix(5)), [5, 10, 20, 40, 60])
        XCTAssertEqual(queue.stopReason?.kind, .github)
        XCTAssertGreaterThanOrEqual(queue.now - start, 300)

        queue = started(readyWorld())
        queue.fail(.refused("Could not resolve to a PullRequest with the number of 52."))
        XCTAssertEqual(queue.stopReason?.kind, .github)
    }
}
