import XCTest
@testable import Nirux

/// The confirmation sheet's content (docs/project-board.md, section 4):
/// who joins, in which order, who is left out and why, the warnings, the
/// refusals, and what will happen.
final class MergeQueueConfirmationTests: XCTestCase {
    private let a = MQ.sha("a")
    private let b = MQ.sha("b")
    private let c = MQ.sha("c")

    private func candidate(
        _ number: Int,
        head: String,
        pullRequest: MergeQueue.PullRequestSnapshot? = nil,
        files: [String] = ["Sources/app.swift"],
        hasMoreFiles: Bool = false,
        checks: MergeQueue.CommitChecks? = MQ.checks(MQ.checkRun(id: 1)),
        behind: Int = 0,
        local: MergeQueue.LocalState = MergeQueue.LocalState()
    ) -> MergeQueue.ConfirmationReading.Candidate {
        var candidate = MergeQueue.ConfirmationReading.Candidate(number: number)
        candidate.pullRequest = pullRequest ?? MQ.pullRequest(number, head: head)
        candidate.details = MergeQueue.PullRequestDetails(title: "Change \(number)", files: files, hasMoreFiles: hasMoreFiles)
        candidate.checks = checks
        candidate.comparison = .some(MergeQueue.Comparison(
            status: behind > 0 ? "diverged" : "ahead", aheadBy: 1, behindBy: behind, baseCommit: MQ.sha("0")
        ))
        candidate.local = local
        return candidate
    }

    private func reading(
        _ candidates: [MergeQueue.ConfirmationReading.Candidate],
        settings: BoardConfig.QueueSettings = MQ.settings(),
        isDryRun: Bool = false,
        baseRuns: [MergeQueue.Run] = [],
        remaining: Int = 5000,
        baseMergeQueue: Bool = false
    ) -> MergeQueue.ConfirmationReading {
        var reading = MergeQueue.ConfirmationReading(settings: settings, isDryRun: isDryRun)
        reading.rateLimit = MergeQueue.RateLimit(
            coreRemaining: remaining, coreReset: Date(timeIntervalSince1970: 0),
            graphQLRemaining: 5000, graphQLReset: Date(timeIntervalSince1970: 0)
        )
        reading.baseMergeQueue = baseMergeQueue
        reading.baseRuns = baseRuns
        reading.candidates = candidates
        return reading
    }

    // MARK: - Who joins

    func testEveryReadyPullRequestJoinsInTheProposedOrderWithItsHeadAndChecks() {
        let confirmation = MergeQueue.confirmation(reading([candidate(12, head: a), candidate(7, head: b)]))

        XCTAssertTrue(confirmation.canStart)
        XCTAssertEqual(confirmation.entries, [
            MergeQueue.ConfirmedEntry(number: 12, head: a, branch: "feat/12"),
            MergeQueue.ConfirmedEntry(number: 7, head: b, branch: "feat/7"),
        ], "the order proposed, never sorted by Nirux")
        XCTAssertEqual(confirmation.items.map(\.title), ["Change 12", "Change 7"])
        XCTAssertEqual(confirmation.items.map(\.checks), ["test ✓", "test ✓"])
        XCTAssertEqual(confirmation.items.flatMap(\.notes), [])
        XCTAssertEqual(confirmation.items.flatMap(\.warnings), [])
        XCTAssertEqual(confirmation.excluded, [])
        XCTAssertEqual(confirmation.refusals, [])
        XCTAssertEqual(confirmation.warnings, [])
    }

    func testPullRequestsTheQueueWouldStopOnAreLeftOutWithTheirReason() {
        let fork = GitHubRepository(owner: "someone", name: "widgets")
        let candidates = [
            candidate(1, head: a, pullRequest: MQ.pullRequest(1, head: a, isDraft: true)),
            candidate(2, head: a, pullRequest: MQ.pullRequest(2, head: a, repository: fork)),
            candidate(3, head: a, pullRequest: MQ.pullRequest(3, head: a, mergeable: "CONFLICTING")),
            candidate(4, head: a, local: MergeQueue.LocalState(busyAgents: ["claude working in “api”"])),
            candidate(5, head: a, local: MergeQueue.LocalState(worktrees: [
                MergeQueue.LocalWorktree(path: "/tmp/x/app.feat-5", problem: .trackedChanges)
            ])),
            candidate(6, head: a, local: MergeQueue.LocalState(worktrees: [
                MergeQueue.LocalWorktree(path: "/tmp/x/app.feat-6", problem: .unpushed)
            ])),
            candidate(7, head: a, pullRequest: MQ.pullRequest(7, head: a, state: "MERGED")),
            candidate(8, head: a, pullRequest: MQ.pullRequest(8, head: a, base: "dev")),
            candidate(9, head: a, pullRequest: MQ.pullRequest(9, head: a, autoMerge: true)),
            candidate(10, head: a, pullRequest: MQ.pullRequest(10, head: a, inMergeQueue: true)),
            candidate(11, head: b),
        ]
        let confirmation = MergeQueue.confirmation(reading(candidates))

        XCTAssertEqual(confirmation.entries.map(\.number), [11])
        let reasons = Dictionary(uniqueKeysWithValues: confirmation.excluded.map { ($0.number, $0.reason) })
        XCTAssertEqual(reasons[1], "It is a draft.")
        XCTAssertEqual(reasons[2], "It comes from a fork: the queue only merges branches of acme/widgets.")
        XCTAssertEqual(reasons[3], "It conflicts with main: resolve that first.")
        XCTAssertEqual(reasons[4], "claude working in “api”: wait until it is back at its prompt.")
        XCTAssertEqual(reasons[5], "Tracked files changed in /.../x/app.feat-5: commit or discard them first.")
        XCTAssertEqual(reasons[6], "Commits not on GitHub in /.../x/app.feat-6: push them first.")
        XCTAssertEqual(reasons[7], "It is merged.")
        XCTAssertEqual(reasons[8], "It targets dev, not main.")
        XCTAssertEqual(reasons[9], "It is set to auto-merge: disable that first (gh pr merge 9 --disable-auto).")
        XCTAssertEqual(reasons[10], "It is in GitHub’s merge queue: remove it from there first.")
        XCTAssertEqual(confirmation.excluded.first?.title, "Change 1", "listed with its title")
    }

    func testWhatCouldNotBeReadIsLeftOutRatherThanGuessed() {
        var unread = MergeQueue.ConfirmationReading.Candidate(number: 1)
        unread.error = "Not Found (HTTP 404)"
        var unknownHead = candidate(2, head: a)
        unknownHead.comparison = .some(nil)
        var noLocal = candidate(3, head: a)
        noLocal.local = nil
        var unreadableWorktree = candidate(4, head: a)
        unreadableWorktree.local = MergeQueue.LocalState(worktrees: [
            MergeQueue.LocalWorktree(path: "/tmp/x/app", problem: .unreadable("git status failed"))
        ])
        let confirmation = MergeQueue.confirmation(reading([unread, unknownHead, noLocal, unreadableWorktree]))

        XCTAssertFalse(confirmation.canStart)
        XCTAssertEqual(confirmation.excluded.map(\.reason), [
            "Couldn’t read it on GitHub: Not Found (HTTP 404)",
            "GitHub can’t compare its head aaaaaaa with main.",
            "Its worktrees on this Mac couldn’t be checked.",
            "/.../x/app can’t be checked: git status failed.",
        ])
        XCTAssertEqual(confirmation.refusals, ["No pull request can join the queue."])
    }

    // MARK: - What the sheet says of each

    func testNotesSayWhatTheQueueWillDoAndWarningsWhatMayStopIt() {
        let pending = MQ.checks(MQ.checkRun(id: 1, status: "IN_PROGRESS", conclusion: nil))
        let red = MQ.checks(MQ.checkRun(id: 1), MQ.checkRun(id: 2, name: "lint", conclusion: "FAILURE"))
        let failed = MQ.checks(MQ.checkRun(id: 1, conclusion: "FAILURE"))
        let skipped = MQ.checks(MQ.checkRun(id: 1, conclusion: "SKIPPED"))
        let candidates = [
            candidate(1, head: a, checks: pending, behind: 3),
            candidate(2, head: a, pullRequest: MQ.pullRequest(2, head: a, mergeable: "UNKNOWN"), checks: red),
            candidate(3, head: a, files: [".github/workflows/tests.yml"], checks: failed),
            candidate(4, head: a, hasMoreFiles: true, checks: skipped),
            candidate(5, head: a, checks: MergeQueue.CommitChecks()),
        ]
        let items = MergeQueue.confirmation(reading(candidates)).items

        XCTAssertEqual(items.map(\.checks), ["test ●", "test ✓", "test ✗", "test (skipped)", "test not started"])
        XCTAssertEqual(items[0].notes, ["Behind main by 3 commits: the queue merges main into it first."])
        XCTAssertEqual(items[1].notes, ["GitHub is still computing whether it merges cleanly: the queue waits up to 2 minutes for it."])
        XCTAssertEqual(items[1].warnings, ["Red, though not required: Tests / lint. The queue never merges with a check red."])
        XCTAssertEqual(items[2].notes, ["A required check failed on this head: the queue reruns it once if it can, and stops if it fails again."])
        XCTAssertEqual(items[2].warnings, ["It changes .github/workflows/: its checks ran its own version of the workflows."])
        XCTAssertEqual(items[3].warnings, [
            "test (skipped): only a new run can turn it green, so the queue will stop on it.",
            "It changes more than 100 files: Nirux didn’t check them all for .github/workflows/.",
        ])
    }

    func testUnreadChecksFilesOrComparisonAreSaidButDoNotLeaveThePullRequestOut() {
        var unread = candidate(1, head: a)
        unread.checks = nil
        unread.checksError = "HTTP 502"
        unread.details = nil
        unread.detailsError = "not read"
        unread.comparison = nil
        unread.compareError = "HTTP 502"
        let item = try? XCTUnwrap(MergeQueue.confirmation(reading([unread])).items.first)

        XCTAssertEqual(item?.checks, "checks unknown: HTTP 502")
        XCTAssertEqual(item?.notes, ["Nirux couldn’t tell whether it is behind main (HTTP 502): the queue checks again."])
        XCTAssertEqual(item?.warnings, ["Nirux couldn’t read the files it changes (not read): check .github/workflows/ yourself."])
        XCTAssertNil(item?.title)
    }

    // MARK: - The queue as a whole

    func testAFailedLastPostMergeRunAndOneStillRunningAreWarnedOf() {
        let runs = [
            MQ.run(3, head: c, status: "in_progress", conclusion: nil),
            MQ.run(2, head: b, conclusion: "failure", title: "Merge pull request #9"),
            MQ.run(1, head: a),
        ]
        let confirmation = MergeQueue.confirmation(reading([candidate(1, head: a)], baseRuns: runs))

        XCTAssertEqual(confirmation.warnings, [
            "The last nightly on main failed (bbbbbbb, “Merge pull request #9”): the base may already be broken.",
            "A nightly is running on main: the first merge waits for it, and the queue stops if it fails.",
        ])
        XCTAssertTrue(confirmation.canStart, "a warning, not a refusal: a pull request may fix the nightly")
        let succeeded = MergeQueue.confirmation(reading([candidate(1, head: a)], baseRuns: [MQ.run(2, head: b), runs[1]]))
        XCTAssertEqual(succeeded.warnings, [], "only the last completed run counts")
    }

    func testStartIsRefusedOnAMergeQueueBaseALowRateLimitOrGitHubUnread() {
        let mergeQueue = MergeQueue.confirmation(reading([candidate(1, head: a)], baseMergeQueue: true))
        XCTAssertFalse(mergeQueue.canStart)
        XCTAssertEqual(mergeQueue.refusals.first?.hasPrefix("main requires GitHub’s merge queue"), true)

        let limited = MergeQueue.confirmation(reading([candidate(1, head: a)], remaining: 499))
        XCTAssertFalse(limited.canStart)
        XCTAssertEqual(limited.refusals.count, 1)
        XCTAssertTrue(limited.refusals[0].hasPrefix("Only 499 GitHub requests are left"), limited.refusals[0])
        XCTAssertTrue(MergeQueue.confirmation(reading([candidate(1, head: a)], remaining: 500)).canStart)

        var signedOut = reading([candidate(1, head: a)])
        signedOut.setupError = MergeQueueController.setupMessage(.notSignedIn("not logged in"))
        let refused = MergeQueue.confirmation(signedOut)
        XCTAssertFalse(refused.canStart)
        XCTAssertEqual(refused.refusals, [
            "gh isn’t signed in to github.com (not logged in): run gh auth login in a terminal, then Start again."
        ])
        XCTAssertEqual(refused.items, [])
        XCTAssertEqual(refused.excluded, [], "nothing is judged on answers never read")
    }

    // MARK: - Order and plan

    func testOnlyTheUserReordersAndTheEndsStayPut() {
        var confirmation = MergeQueue.confirmation(reading([candidate(1, head: a), candidate(2, head: b), candidate(3, head: c)]))

        confirmation.move(2, by: -1)
        XCTAssertEqual(confirmation.entries.map(\.number), [1, 3, 2])
        confirmation.move(0, by: -1)
        confirmation.move(2, by: 1)
        XCTAssertEqual(confirmation.entries.map(\.number), [1, 3, 2], "nothing moves past an end")
        confirmation.move(0, by: 1)
        XCTAssertEqual(confirmation.entries.map(\.number), [3, 1, 2])
        XCTAssertEqual(confirmation.entries.map(\.head), [c, a, b], "each keeps its confirmed head")
    }

    func testThePlanSaysHowManyNightliesTheQueuePublishes() {
        let confirmation = MergeQueue.confirmation(reading([candidate(1, head: a), candidate(2, head: b)]))
        XCTAssertEqual(confirmation.plan, [
            "In this order, for each pull request:",
            "• If its branch is behind main, merge main into it on GitHub (never a rebase or a force push), at most 2 times.",
            "• Wait for the required checks on its head: test (up to 30 minutes). A failed one is rerun once; a second "
                + "failure stops the queue.",
            "• Merge it with a merge commit, pinned to the head shown here, or to the queue’s own updates of it "
                + "(gh pr merge --merge --match-head-commit).",
            "• Wait for nightly.yml on main (up to 30 minutes), then go on to the next one.",
            "This queue publishes 2 nightlies: nightly.yml runs after each of its 2 merges.",
            "It stops at the first problem. Stop is in the board and in the status bar; a call already sent to GitHub "
                + "finishes.",
        ])

        let dryRun = MergeQueue.confirmation(reading([candidate(1, head: a)], isDryRun: true))
        XCTAssertTrue(dryRun.plan.contains("A real queue would publish 1 nightly, one after each merge. This dry run publishes none."))

        let noWorkflow = MergeQueue.confirmation(reading(
            [candidate(1, head: a)], settings: MQ.settings(postMergeWorkflow: nil, mergeMethod: .squash)
        ))
        XCTAssertTrue(noWorkflow.plan.contains("• Go on to the next one right away: no post-merge workflow."))
        XCTAssertTrue(noWorkflow.plan.contains("This queue makes 1 merge into main, one right after the other."))
        XCTAssertTrue(noWorkflow.plan[3].hasPrefix("• Squash and merge it"))
    }
}
