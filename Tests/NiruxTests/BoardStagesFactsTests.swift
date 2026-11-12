import XCTest
@testable import Nirux

/// A section's facts from what the app holds (docs/design/board-stages.md,
/// section 6): today's rows, the queue's state and what each task's sidebar
/// row reads. Pure: rows, entries and readings are given.
final class BoardStagesFactsTests: XCTestCase {
    private let head = String(repeating: "a", count: 40)
    private let updated = String(repeating: "b", count: 40)
    private let moved = String(repeating: "c", count: 40)

    private func pullRequest(
        _ number: Int, _ branch: String = "feat/x", state: String = "OPEN", base: String? = "main", draft: Bool = false,
        mergeable: String = "MERGEABLE", checks: [ProjectBoard.Check] = [], title: String = "", mergedAt: Date? = nil,
        fork: Bool = false, oid: String? = nil
    ) -> ProjectBoard.PullRequest {
        ProjectBoard.PullRequest(
            number: number, state: state, headRefName: branch, headOid: oid ?? head, baseRefName: base, isDraft: draft,
            mergeable: mergeable, checks: checks, url: "https://github.com/acme/widgets/pull/\(number)",
            isFromConfiguredRepository: !fork, title: title, mergedAt: mergedAt
        )
    }

    /// A row of today's Board: a worktree with its workspaces (by id), or a pull request alone.
    private func row(
        _ branch: String? = "feat/x", workspaces: [String] = [], pullRequest: ProjectBoard.PullRequest? = nil,
        group: ProjectBoard.RowGroup = .active, path: String? = "/p/widgets.x", inactive: Bool = false,
        stack: ProjectBoard.StackPlace? = nil, folder: String? = nil
    ) -> ProjectBoard.Row {
        ProjectBoard.Row(
            group: group, worktreePath: path, branch: branch, detachedHead: nil,
            workspaces: workspaces.map { ProjectBoard.WorkspaceRef(id: $0, title: $0.capitalized, isInactive: inactive) },
            pullRequest: pullRequest, agent: ProjectBoard.Agent(), folder: folder, stack: stack
        )
    }

    private func check(
        _ name: String, _ result: ProjectBoard.CheckResult, workflow: String? = nil, startedAt: String? = "2026-11-11T12:00:00Z"
    ) -> ProjectBoard.Check {
        ProjectBoard.Check(name: name, workflowName: workflow, result: result, startedAt: startedAt, url: nil)
    }

    /// A queue's entry, confirmed at `head`; one the queue updated has that head too, and one it merged a merge commit.
    private func entry(
        _ number: Int, _ branch: String = "feat/x", step: MergeQueue.Step = .waiting, isUpdated: Bool = false, isMerged: Bool = false
    ) -> MergeQueue.Entry {
        var entry = MergeQueue.Entry(MergeQueue.ConfirmedEntry(number: number, head: head, branch: branch))
        entry.step = step
        if isUpdated { entry.heads.append(updated) }
        entry.mergeCommit = isMerged ? String(repeating: "d", count: 40) : nil
        return entry
    }

    private func queue(
        _ run: ProjectBoard.QueueState.Run, _ entries: [MergeQueue.Entry] = [], selection: [Int] = []
    ) -> ProjectBoard.QueueState {
        ProjectBoard.QueueState(run: run, isDryRun: false, entries: entries, workflow: "nightly.yml", selection: selection)
    }

    private func stopped(_ kind: MergeQueue.StopReason.Kind, _ message: String = "It stopped.") -> MergeQueue.Step {
        .stopped(MergeQueue.StopReason(kind: kind, message: message))
    }

    /// The section's facts; "task" is the one task unless said, and `reading` what the sidebar read of it.
    private func facts(
        _ rows: [ProjectBoard.Row], tasks: [String] = ["task"], reading: BoardStages.TaskReading? = nil,
        parents: [String: String] = [:], required: [String] = [], queue: ProjectBoard.QueueState? = nil,
        merged: [ProjectBoard.PullRequest] = [], heads: [String: String] = [:], readsPullRequests: Bool = true
    ) -> BoardStages.SectionFacts {
        BoardStages.sectionFacts(
            BoardStages.RepositoryReading(
                id: "widgets", rows: rows, readsPullRequests: readsPullRequests, requiredChecks: required, baseBranch: "main",
                queue: queue, merged: merged, heads: heads
            ),
            tasks: tasks, readings: reading.map { ["task": $0] } ?? [:], parents: parents
        )
    }

    // MARK: - Lines

    func testEachTaskIsALineInTheSidebarsOrderThenThePullRequestsWithoutOne() {
        let section = facts(
            [
                row("main", workspaces: ["lead", "import", "export"], group: .main, path: "/p/widgets"),
                row("feat/a", workspaces: ["second", "pair"], pullRequest: pullRequest(12, "feat/a")),
                row("cloud", pullRequest: pullRequest(14, "cloud", title: " \u{202E}From the\ncloud\u{7} "), path: nil),
                row("feat/b", workspaces: ["first"], path: "/p/widgets.b"),
                row("bot", pullRequest: pullRequest(15, "bot"), path: "/p/widgets.bot"),
                row("bot", pullRequest: pullRequest(15, "bot"), path: "/p/copy.bot"),
                row("feat/a", pullRequest: pullRequest(12, "feat/a"), path: "/p/copy.a"),
                row("idle", group: .otherWorktree, path: "/p/widgets.idle"),
                row("done", pullRequest: pullRequest(9, "done", state: "MERGED"), group: .otherWorktree, path: "/p/widgets.done")
            ],
            // The sidebar's order, the Lead left out; one task is in another repository.
            tasks: ["first", "export", "elsewhere", "second", "pair", "import", "first"],
            parents: ["second": "first", "import": "lead", "export": "elsewhere", "elsewhere": "first"],
            queue: queue(.none, selection: [15, 14])
        )
        XCTAssertEqual(section.id, "widgets")
        XCTAssertEqual(section.lines.map(\.id), ["first", "export", "second", "pair", "import", "widgets#14", "widgets#15"],
                       "each task once, wherever its worktree; the Lead, a main checkout or a worktree with neither are no line")
        XCTAssertEqual(section.lines.map(\.title), ["First", "Export", "Second", "Pair", "Import", "From the cloud", "bot"],
                       "a pull request without a task is named by its title, cleaned and on one line, else its branch")
        XCTAssertEqual(section.lines.map(\.hasTask), [true, true, true, true, true, false, false])
        XCTAssertEqual(section.lines.map(\.pullRequest?.number), [nil, nil, 12, 12, nil, 14, 15],
                       "two tasks sharing a worktree share its pull request; one a task's line shows isn't listed again")
        XCTAssertEqual(section.lines.map(\.queue.order), [nil, nil, nil, nil, nil, 2, 1],
                       "a pull request without a task has its place in the queue too")
        XCTAssertEqual(section.parents, ["second": "first"], "a sub-task under its task, when both are lines here")
        XCTAssertEqual(section.lines.first, BoardStages.Facts(id: "first", title: "First"), "one the sidebar hasn't read yet is at rest")
    }

    func testATaskSaysWhatItsSidebarRowReads() {
        let runs = [ReviewPass.codeReview: ReviewRun(head: head, at: 200)]
        var reading = BoardStages.TaskReading(activity: .needsYou("a question"))
        reading.reviews = ReviewBadges(runs: runs, head: head)
        reading.reviewsInFlight = [.premortem]
        reading.summary = "The import side"
        reading.statusLine = "Asked about the format"
        reading.nextStep = "Write the export side"
        reading.blocker = "Waits for the schema"
        reading.lastActivityAt = 400
        reading.flakyReason = "ImportTests timed out"
        reading.reviewRequest = .feedback
        reading.cleanUp = .running
        var expected = BoardStages.Facts(id: "task", title: "Task")
        expected.activity = .needsYou("a question")
        expected.reviews = reading.reviews
        expected.reviewsInFlight = [.premortem]
        expected.summary = "The import side"
        expected.statusLine = "Asked about the format"
        expected.nextStep = "Write the export side"
        expected.blocker = "Waits for the schema"
        expected.lastActivityAt = 400
        expected.flakyReason = "ImportTests timed out"
        expected.cleanUp = .running
        XCTAssertEqual(facts([row(workspaces: ["task"])], reading: reading).lines, [expected])
        reading.gitRoot = "/p/widgets.x"
        XCTAssertEqual(facts([row(workspaces: ["task"])], reading: reading).lines, [expected], "read in the task's own worktree")

        // Its focused column is in another worktree: what the sidebar read of git there isn't about this task.
        reading.gitRoot = "/p/widgets.other"
        reading.mergedPullRequest = 20
        expected.reviews = ReviewBadges(runs: runs, head: nil)
        expected.flakyReason = nil
        expected.cleanUp = nil
        XCTAssertEqual(facts([row(workspaces: ["task"])], reading: reading).lines, [expected],
                       "its reviews ran, on a HEAD nothing says; no pull request of elsewhere, nor its clean-up")
        let open = facts([row(workspaces: ["task"], pullRequest: pullRequest(12))], reading: reading).lines[0]
        XCTAssertNil(open.pullRequest?.reviewRequest, "nor what GitHub asks of another pull request")

        XCTAssertTrue(facts([row(workspaces: ["task"], inactive: true)]).lines[0].isArchived)
        // No rail where no pull request is read: a repository not on GitHub, a workspace in another repository or in none.
        XCTAssertEqual(facts([row(workspaces: ["task"])], readsPullRequests: false).lines.map(\.hasRepository), [false])
        let folder = row(nil, workspaces: ["notes"], group: .otherRepository, path: nil, folder: "/Users/me/Nirux Tasks/Notes")
        XCTAssertEqual(facts([row(workspaces: ["task"]), folder], tasks: ["task", "notes"]).lines.map(\.hasRepository), [true, false])
    }

    // MARK: - Pull request

    func testAPullRequestIsReadAsTheBoardShowsIt() {
        let place = ProjectBoard.StackPlace(parent: 11, chain: [11, 12], rootBase: "main", mergedBase: nil, root: 11, order: 1)
        var reading = BoardStages.TaskReading()
        reading.reviewRequest = .changesRequested
        let open = pullRequest(12, base: "feat/base", draft: true, mergeable: "CONFLICTING")
        let section = facts(
            [
                row(workspaces: ["task"], pullRequest: open, stack: place), row("cloud", pullRequest: pullRequest(14, "cloud"), path: nil),
                row("odd", pullRequest: pullRequest(16, "odd", base: nil), path: nil)
            ],
            reading: reading
        )
        XCTAssertEqual(section.lines[0].pullRequest, BoardStages.PullRequest(
            number: 12, isMerged: false, isDraft: true, isConflicting: true, base: "feat/base", isOnBaseBranch: false,
            checks: .absent, reviewRequest: .changesRequested, stack: place
        ))
        XCTAssertEqual(section.lines[1].pullRequest, BoardStages.PullRequest(number: 14, base: "main", checks: .absent),
                       "on the base branch; what GitHub asks of it is a task's to know")
        XCTAssertEqual(section.lines[2].pullRequest, BoardStages.PullRequest(number: 16, base: "", checks: .absent),
                       "a base gh didn't name holds nothing back, as for the queue")
    }

    func testAMergedPullRequestStaysOnTheTaskTheQueueLeftBehind() {
        let path = "/p/widgets.x"
        // At its head: the row has it, and its worktree can be cleaned up.
        let atHead = facts([row(workspaces: ["task"], pullRequest: pullRequest(9, state: "MERGED"))], required: ["test"]).lines[0]
        XCTAssertEqual(atHead.pullRequest, BoardStages.PullRequest(number: 9, isMerged: true, base: "main", checks: .passed),
                       "merged: its checks no longer hold anything")
        XCTAssertEqual(atHead.cleanUp, .offered)
        var cleaning = BoardStages.TaskReading()
        cleaning.cleanUp = .running
        XCTAssertEqual(facts([row(workspaces: ["task"], pullRequest: pullRequest(9, state: "MERGED"))], reading: cleaning).lines[0].cleanUp,
                       .running, "what the sidebar reads of the clean-up first")
        XCTAssertNil(facts([row(workspaces: ["task"], pullRequest: pullRequest(9))]).lines[0].cleanUp, "nothing to clean up while it is open")

        // The queue updated its branch, then merged it: the worktree is a commit behind, the row shows nothing.
        let entries = [entry(9, step: .waitingForPostMerge(updated), isUpdated: true, isMerged: true)]
        let running = queue(.running(isStopping: false), entries)
        let behind = facts([row(workspaces: ["task"])], queue: running, heads: [path: head]).lines[0]
        XCTAssertEqual(behind.pullRequest, BoardStages.PullRequest(number: 9, isMerged: true, base: "main", checks: .passed))
        XCTAssertEqual(behind.queue.step, .merge("Waiting for nightly"))
        XCTAssertEqual(behind.cleanUp, .offered)
        // New work on that branch since, a worktree whose HEAD isn't known, an entry the queue didn't merge: not merged.
        XCTAssertNil(facts([row(workspaces: ["task"])], queue: running, heads: [path: moved]).lines[0].pullRequest)
        XCTAssertNil(facts([row(workspaces: ["task"])], queue: running).lines[0].pullRequest)
        let waiting = queue(.running(isStopping: false), [entry(9, step: .waitingForChecks(head))])
        XCTAssertNil(facts([row(workspaces: ["task"])], queue: waiting, heads: [path: head]).lines[0].pullRequest)
        XCTAssertNil(facts([row("other", workspaces: ["task"])], queue: running, heads: [path: head]).lines[0].pullRequest, "another branch")

        // No queue merged it: the task's own detection says so, and the merged list its base.
        var detected = BoardStages.TaskReading()
        detected.mergedPullRequest = 9
        let list = [pullRequest(10, "other", state: "MERGED", base: "develop"), pullRequest(9, state: "MERGED", base: "release")]
        let read = facts([row(workspaces: ["task"])], reading: detected, merged: list).lines[0]
        XCTAssertEqual(read.pullRequest, BoardStages.PullRequest(number: 9, isMerged: true, base: "release", checks: .passed))
        XCTAssertEqual(facts([row(workspaces: ["task"])], reading: detected).lines[0].pullRequest?.base, "main", "beyond the list: the base branch")

        // Merged by the queue before GitHub's list says so: the open list's copy reads merged. Only that one, and only once merged.
        let rows = [
            row(workspaces: ["task"], pullRequest: pullRequest(9)),
            row("next", pullRequest: pullRequest(10, "next"), path: nil), row("last", pullRequest: pullRequest(11, "last"), path: nil)
        ]
        let early = queue(.running(isStopping: false), entries + [entry(10, "next", step: .waitingForChecks(head))])
        XCTAssertEqual(facts(rows, queue: early).lines.map(\.pullRequest?.isMerged), [true, false, false])
        XCTAssertEqual(facts(rows, queue: early).lines.map(\.pullRequest?.checks), [.passed, .absent, .absent])
    }

    // MARK: - Checks

    func testChecksAreCountedByTheMergeQueuesRules() {
        let judge = { (checks: [ProjectBoard.Check], required: [String]) in BoardStages.checks(checks, required: required) }
        XCTAssertEqual(judge([], []), .absent, "no check, none required: nothing to wait for")
        XCTAssertEqual(judge([], ["test"]), .pending(since: nil, missing: ["test"]), "a required one that hasn't reported")
        XCTAssertEqual(judge([check("test", .success)], ["test"]), .passed)
        XCTAssertEqual(judge([check("test", .success, workflow: "Tests")], ["Tests / test"]), .passed, "by its workflow's name too")
        XCTAssertEqual(judge([check("test", .success), check("lint", .pending)], ["test"]), .passed,
                       "one that isn't required may still run")
        XCTAssertEqual(judge([check("test", .success), check("lint", .pending)], []),
                       .pending(since: 1_794_398_400, missing: []), "without a required check, every one counts")
        XCTAssertEqual(judge([check("lint", .success), check("docs", .skipped)], []), .passed)

        let running = [
            check("test", .pending, startedAt: "2026-11-11T12:05:00Z"), check("build", .pending, startedAt: "2026-11-11T12:01:00Z"),
            check("deploy", .pending, startedAt: "0001-01-01T00:00:00Z"), check("lint", .pending, startedAt: "2026-11-11T11:00:00Z")
        ]
        XCTAssertEqual(judge(running, ["test", "build", "deploy", "e2e"]), .pending(since: 1_794_398_460, missing: ["e2e"]),
                       "since the oldest required one that runs started; one not started has no start")

        XCTAssertEqual(judge([check("test", .failure), check("lint", .failure, workflow: "CI"), check("build", .pending)], ["test", "build"]),
                       .failed(["test", "CI / lint"]), "the red ones by name, required or not")
        XCTAssertEqual(judge([check("test", .skipped), check("build", .neutral), check("lint", .neutral)], ["test", "build"]),
                       .failed(["test", "build"]), "a required one that ended without passing: no wait turns it green")
        let twoWorkflows = [check("test", .success, workflow: "A", startedAt: "2026-11-11T11:00:00Z"), check("test", .pending, workflow: "B")]
        XCTAssertEqual(judge(twoWorkflows, ["test"]), .pending(since: 1_794_398_400, missing: []),
                       "every check of a required name must be green; since the one that runs started")
        XCTAssertEqual(judge([check("test", .success, workflow: "A"), check("test", .skipped, workflow: "B")], ["test"]),
                       .failed(["test"]), "a success doesn't hide a skipped one of that name")
        XCTAssertEqual(judge([check("test", .failure, workflow: "A"), check("test", .pending, workflow: "B")], ["test"]),
                       .failed(["test"]), "red, whatever else of that name still runs")
        let rerun = [check("test", .failure, startedAt: "2026-11-11T12:00:00Z"), check("test", .success, startedAt: "2026-11-11T12:30:00Z")]
        XCTAssertEqual(judge(rerun, ["test"]), .passed, "only the latest run of a check counts")

        let line = facts([row(workspaces: ["task"], pullRequest: pullRequest(12, checks: [check("lint", .success)]))], required: ["test"]).lines[0]
        XCTAssertEqual(line.pullRequest?.checks, .pending(since: nil, missing: ["test"]), "with the section's required checks")
    }

    // MARK: - Queue

    func testARunningQueueSaysEachPullRequestsPlaceAndStep() {
        let steps: [(MergeQueue.Step, BoardStages.QueueStep?)] = [
            (.waiting, nil), (.preflight, .checks("Checking")), (.updating(from: head), .checks("Updating branch")),
            (.waitingForChecks(head), .checks("Waiting for checks")), (.rerunning(head), .checks("Rerunning checks")),
            (.merging(head), .merge("Merging"))
        ]
        // The queue merged #7 and is through with it: it left the next Start's list, not the queue's count.
        let through = entry(7, "other", step: .done, isMerged: true)
        for (step, expected) in steps {
            let state = queue(.running(isStopping: false), [through, entry(12, step: step)], selection: [12])
            XCTAssertEqual(BoardStages.queue(of: 12, head: head, in: state), BoardStages.Queue(order: 2, step: expected),
                           "\(step): its place as the queue counts it, not the next Start's")
        }
        // Merged, and the queue waits for its post-merge run: its number stays while the queue has it.
        let merged = queue(.running(isStopping: false), [
            through, entry(12, step: .waitingForPostMerge(head), isMerged: true), entry(13, "next")
        ], selection: [12, 13])
        XCTAssertEqual(BoardStages.queue(of: 12, head: nil, in: merged), BoardStages.Queue(order: 2, step: .merge("Waiting for nightly")))
        XCTAssertEqual(BoardStages.queue(of: 7, head: nil, in: merged), BoardStages.Queue(), "the queue is through with it")
        XCTAssertEqual(BoardStages.queue(of: 13, head: head, in: merged), BoardStages.Queue(order: 3))
        XCTAssertEqual(BoardStages.queue(of: 99, head: head, in: merged), BoardStages.Queue(), "not in the queue that runs")
        XCTAssertEqual(BoardStages.queue(of: 12, head: head, in: nil), BoardStages.Queue(), "a section without a queue")
        // Run by another Nirux: its saved entries, read the same; no list for a next Start here.
        let elsewhere = queue(.elsewhere, [through, entry(12, step: .merging(head))])
        XCTAssertEqual(BoardStages.queue(of: 12, head: head, in: elsewhere), BoardStages.Queue(order: 2, step: .merge("Merging")))

        let line = facts([row(workspaces: ["task"], pullRequest: pullRequest(12))],
                         queue: queue(.running(isStopping: false), [entry(12, step: .merging(head))], selection: [12])).lines[0]
        XCTAssertEqual(line.queue, BoardStages.Queue(order: 1, step: .merge("Merging")))
    }

    func testAnEndedQueueLeavesItsStopAndTheNextStartsOrder() {
        // "Changed" is a head that moved: by the Board's next read, GitHub's head is none the queue knew.
        let changed = queue(
            .ended, [entry(12, step: stopped(.changed, "#12 changed since you confirmed it.")), entry(13, "next")], selection: [13, 12]
        )
        let read = BoardStages.queue(of: 12, head: moved, in: changed)
        XCTAssertEqual(read.stop, BoardStages.QueueStop(label: "changed", message: "#12 changed since you confirmed it.", isProblem: true))
        XCTAssertEqual(read.order, 2, "its place in the next Start's list")
        XCTAssertEqual(BoardStages.queue(of: 13, head: head, in: changed), BoardStages.Queue(order: 1))
        XCTAssertEqual(BoardStages.queue(of: 14, head: head, in: changed), BoardStages.Queue(), "in neither list")
        XCTAssertEqual(BoardStages.queue(of: 13, head: head, in: queue(.none, selection: [12, 13])), BoardStages.Queue(order: 2),
                       "no queue ran: the next Start's list alone")

        // A stop about the commit the queue was at is over once the head moved; the others stay until the next Start.
        let aboutItsHead: [MergeQueue.StopReason.Kind] = [.checks, .conflict, .notMergeable, .merge, .update]
        let others: [MergeQueue.StopReason.Kind] = [.changed, .interrupted, .setup, .github, .agentBusy, .local, .postMerge, .user, .dryRun]
        for kind in aboutItsHead + others {
            let ended = queue(.ended, [entry(12, step: stopped(kind), isUpdated: true)])
            XCTAssertNotNil(BoardStages.queue(of: 12, head: updated, in: ended).stop, "\(kind), at a head the queue knew")
            XCTAssertNotNil(BoardStages.queue(of: 12, head: nil, in: ended).stop, "\(kind): a head the Board doesn't know says nothing")
            XCTAssertEqual(BoardStages.queue(of: 12, head: moved, in: ended).stop == nil, aboutItsHead.contains(kind), "\(kind), once the head moved")
        }
        for kind in [MergeQueue.StopReason.Kind.user, .dryRun] {
            XCTAssertEqual(BoardStages.queue(of: 12, head: head, in: queue(.ended, [entry(12, step: stopped(kind))])).stop?.isProblem, false,
                           "\(kind): Stop pressed, or a dry run reaching its first change, is no problem")
        }
        // The head is the pull request's on GitHub: a task's, and one's without a task.
        let failed = queue(.ended, [entry(12, step: stopped(.checks)), entry(14, "cloud", step: stopped(.checks))])
        let pushed = [
            row(workspaces: ["task"], pullRequest: pullRequest(12, oid: moved)),
            row("cloud", pullRequest: pullRequest(14, "cloud", oid: moved), path: nil)
        ]
        XCTAssertEqual(facts(pushed, queue: failed).lines.map(\.queue.stop), [nil, nil], "a fix was pushed since")
        let still = [row(workspaces: ["task"], pullRequest: pullRequest(12)), row("cloud", pullRequest: pullRequest(14, "cloud"), path: nil)]
        XCTAssertEqual(facts(still, queue: failed).lines.map { $0.queue.stop?.label }, ["checks", "checks"])

        // After its merge, any stop still says something, and it has no place in the next Start.
        let nightly = queue(.ended, [entry(12, step: stopped(.postMerge, "nightly failed on the merge of #12."), isMerged: true)], selection: [12])
        XCTAssertEqual(BoardStages.queue(of: 12, head: nil, in: nightly), BoardStages.Queue(stop: BoardStages.QueueStop(
            label: "nightly failed", message: "nightly failed on the merge of #12.", isProblem: true, isAfterMerge: true
        )))
        let interrupted = queue(.ended, [entry(12, step: stopped(.interrupted), isMerged: true)])
        XCTAssertEqual(BoardStages.queue(of: 12, head: moved, in: interrupted).stop?.isAfterMerge, true)
        let afterAMergeThatFailed = queue(.ended, [entry(12, step: stopped(.merge), isMerged: true)])
        XCTAssertNotNil(BoardStages.queue(of: 12, head: moved, in: afterAMergeThatFailed).stop, "merged at another head: it still needs a look")
        // The base's own run failed before this one merged: a stop from before its merge.
        let base = queue(.ended, [entry(12, step: stopped(.postMerge, "The nightly of abc1234 on main failed."))])
        XCTAssertEqual(BoardStages.queue(of: 12, head: head, in: base).stop?.isAfterMerge, false)
    }

    // MARK: - Merged today

    func testTheMergedListGivesTheDaysMergesTheirTitleAndTime() {
        let noon = Date(timeIntervalSince1970: 1_794_398_400)
        let section = facts([], merged: [
            pullRequest(52, state: "MERGED", title: "Sign in with a passkey", mergedAt: noon),
            pullRequest(51, state: "MERGED", title: "No date read"),
            pullRequest(50, state: "CLOSED", title: "Closed", mergedAt: noon),
            pullRequest(49, state: "MERGED", title: "A fork's", mergedAt: noon, fork: true)
        ])
        XCTAssertEqual(section.merged, [
            BoardStages.MergedFacts(number: 52, title: "Sign in with a passkey", mergedAt: 1_794_398_400),
            BoardStages.MergedFacts(number: 49, title: "A fork's", mergedAt: 1_794_398_400)
        ], "a fork's merge landed on the base branch as any; one whose merge date gh didn't give isn't in the day's merges")
    }
}
