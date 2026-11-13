import XCTest
@testable import Nirux

/// A section's facts from what the app holds (docs/design/board-stages.md,
/// section 6): today's rows, the queue's state and what each task's sidebar
/// row reads. Pure: rows, entries and readings are given.
final class BoardStagesFactsTests: XCTestCase {
    private let head = String(repeating: "a", count: 40)
    private let updated = String(repeating: "b", count: 40)
    private let moved = String(repeating: "c", count: 40)
    private let mergeCommit = String(repeating: "d", count: 40)

    private func pullRequest(
        _ number: Int, _ branch: String = "feat/x", state: String = "OPEN", base: String? = "main", draft: Bool = false,
        mergeable: String = "MERGEABLE", checks: [ProjectBoard.Check] = [], title: String = "", mergedAt: Date? = nil,
        fork: Bool = false, oid: String? = nil
    ) -> ProjectBoard.PullRequest {
        ProjectBoard.PullRequest(
            number: number, state: state, headRefName: branch, headOid: oid ?? head, baseRefName: base, isDraft: draft,
            mergeable: mergeable, checks: checks, url: url(number),
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
        entry.mergeCommit = isMerged ? mergeCommit : nil
        return entry
    }

    private func queue(
        _ run: ProjectBoard.QueueState.Run, _ entries: [MergeQueue.Entry] = [], selection: [Int] = []
    ) -> ProjectBoard.QueueState {
        ProjectBoard.QueueState(run: run, isDryRun: false, entries: entries, workflow: "nightly.yml", selection: selection)
    }

    private func url(_ number: Int) -> String { "https://github.com/acme/widgets/pull/\(number)" }

    /// Why the list can't change while a queue runs here.
    private let whileRunning = BoardStages.QueueList.locked("The queue is running: change the list once it stops.")

    private func stopped(_ kind: MergeQueue.StopReason.Kind, _ message: String = "It stopped.") -> MergeQueue.Step {
        .stopped(MergeQueue.StopReason(kind: kind, message: message))
    }

    /// The section's facts; "task" is the one task unless said, and `reading` what the sidebar read of it.
    private func facts(
        _ rows: [ProjectBoard.Row], tasks: [String] = ["task"], reading: BoardStages.TaskReading? = nil,
        readings: [String: BoardStages.TaskReading] = [:], parents: [String: String] = [:], required: [String] = [],
        queue: ProjectBoard.QueueState? = nil, merged: [ProjectBoard.PullRequest] = [], heads: [String: String] = [:],
        readsPullRequests: Bool = true, baseBranch: String? = "main", cleaningUp: Set<String> = []
    ) -> BoardStages.SectionFacts {
        BoardStages.sectionFacts(
            BoardStages.RepositoryReading(
                id: "widgets", rows: rows, readsPullRequests: readsPullRequests, requiredChecks: required, baseBranch: baseBranch,
                queue: queue, merged: merged, heads: heads, cleaningUp: cleaningUp
            ),
            tasks: tasks, readings: reading.map { ["task": $0] } ?? readings, parents: parents
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
            readings: ["pair": BoardStages.TaskReading(activity: .working(since: 50)), "lead": BoardStages.TaskReading(activity: .failed("Stopped"))],
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
        let first = BoardStages.Folder(path: "/p/widgets.b", title: "feat/b", canCleanUp: true)
        XCTAssertEqual(section.lines.first, BoardStages.Facts(id: "first", title: "First", location: ["feat/b", "/p/widgets.b"], folder: first),
                       "one the sidebar hasn't read yet is at rest")
        XCTAssertEqual(section.lines.dropFirst().map(\.location), [
            ["main checkout", "main", "/p/widgets"], ["feat/a", "/p/widgets.x"], ["feat/a", "/p/widgets.x"],
            ["main checkout", "main", "/p/widgets"], ["cloud", "not checked out"], ["bot", "/p/widgets.bot"]
        ], "its branch and its worktree, for the title's tooltip")
        XCTAssertEqual(section.lines.map(\.activity), [.idle, .idle, .idle, .working(since: 50), .idle, .idle, .idle],
                       "a task says its own reading, not that of one sharing its worktree")
        XCTAssertEqual(section.lines.map(\.hasRepository), Array(repeating: true, count: 7), "a task in the main checkout has its rail")
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
        var expected = BoardStages.Facts(id: "task", title: "Task", location: ["feat/x", "/p/widgets.x"])
        expected.folder = BoardStages.Folder(path: "/p/widgets.x", title: "feat/x", canCleanUp: true)
        expected.activity = .needsYou("a question")
        expected.reviews = reading.reviews
        expected.reviewsInFlight = [.premortem]
        expected.summary = "The import side"
        expected.statusLine = "Asked about the format"
        expected.nextStep = "Write the export side"
        expected.blocker = "Waits for the schema"
        expected.lastActivityAt = 400
        expected.flakyReason = "ImportTests timed out"
        XCTAssertEqual(facts([row(workspaces: ["task"])], reading: reading).lines, [expected])
        reading.gitRoot = "/p/widgets.x"
        XCTAssertEqual(facts([row(workspaces: ["task"])], reading: reading).lines, [expected], "read in the task's own worktree")

        // Its focused column is in another worktree: what the sidebar read of git there isn't about this task.
        reading.gitRoot = "/p/widgets.other"
        reading.mergedPullRequest = 20
        reading.reviewRequest = .feedback
        reading.cleanUp = .running
        expected.reviews = ReviewBadges(runs: runs, head: nil)
        expected.flakyReason = nil
        XCTAssertEqual(facts([row(workspaces: ["task"])], reading: reading).lines, [expected],
                       "its reviews ran, on a HEAD nothing says; no pull request of elsewhere, nor its clean-up")
        let open = facts([row(workspaces: ["task"], pullRequest: pullRequest(12))], reading: reading).lines[0]
        XCTAssertEqual(open.pullRequest, BoardStages.PullRequest(number: 12, base: "main", checks: .absent, url: url(12)),
                       "nor what GitHub asks of another pull request")
        let merged = facts([row(workspaces: ["task"], pullRequest: pullRequest(9, state: "MERGED"))], reading: reading).lines[0]
        XCTAssertEqual(merged.cleanUp, .offered, "its own merged pull request's worktree is the row's to offer")
        // A folder has no worktree: nothing read of git is about it.
        let notes = row(nil, workspaces: ["task"], group: .otherRepository, path: nil, folder: "/Users/me/Nirux Tasks/Notes")
        XCTAssertNil(facts([notes], reading: reading).lines[0].reviews?.head)
        XCTAssertEqual(facts([notes]).lines[0].location, ["/Users/me/Nirux Tasks/Notes"])
        var gone = notes
        gone.folderIsGone = true
        XCTAssertEqual(facts([gone]).lines[0].location, ["/Users/me/Nirux Tasks/Notes", "folder is gone"])
        let detached = ProjectBoard.Row(
            group: .main, worktreePath: "/p/widgets", branch: nil, detachedHead: head,
            workspaces: [ProjectBoard.WorkspaceRef(id: "task", title: "Task", isInactive: false)], pullRequest: nil,
            agent: ProjectBoard.Agent(), folder: nil
        )
        XCTAssertEqual(facts([detached]).lines[0].location, ["main checkout", "detached HEAD (aaaaaaa)", "/p/widgets"])

        XCTAssertTrue(facts([row(workspaces: ["task"], inactive: true)]).lines[0].isArchived)
        // No rail where no pull request is read: a repository not on GitHub, a workspace in another repository or in none.
        XCTAssertEqual(facts([row(workspaces: ["task"])], readsPullRequests: false).lines.map(\.hasRepository), [false])
        let folder = row(nil, workspaces: ["notes"], group: .otherRepository, path: nil, folder: "/Users/me/Nirux Tasks/Notes")
        XCTAssertEqual(facts([row(workspaces: ["task"]), folder], tasks: ["task", "notes"]).lines.map(\.hasRepository), [true, false])
    }

    func testALineSaysWhereItsWorkIsOnDiskAndHowItsAgentGoesOn() {
        let stopped = BoardStages.Resume(kind: .afterError, column: UUID(), failedAt: 700, blocked: "Resuming…")
        var reading = BoardStages.TaskReading(activity: .failed("Stopped on an API error"))
        reading.resume = stopped
        let rows = [
            row(workspaces: ["task"]),
            row("main", workspaces: ["lead"], group: .main, path: "/p/widgets"),
            row(nil, workspaces: ["notes"], group: .otherRepository, path: nil, folder: "/Users/me/Nirux Tasks/Notes"),
            row("cloud", pullRequest: pullRequest(14, "cloud"), path: nil),
            row("bot", pullRequest: pullRequest(15, "bot"), path: "/p/widgets.bot"),
            row("main", pullRequest: pullRequest(16, "main"), group: .main, path: "/p/copy"),
            row("shared", workspaces: ["lead2"], pullRequest: pullRequest(17, "shared"), path: "/p/widgets.shared")
        ]
        let section = facts(rows, tasks: ["task", "lead", "notes"], readings: ["task": reading, "notes": reading], cleaningUp: ["/p/widgets.bot"])
        XCTAssertEqual(section.lines.map(\.id), ["task", "lead", "notes", "widgets#14", "widgets#15", "widgets#16", "widgets#17"])
        XCTAssertEqual(section.lines.map(\.folder), [
            BoardStages.Folder(path: "/p/widgets.x", title: "feat/x", canCleanUp: true),
            BoardStages.Folder(path: "/p/widgets", title: "main"),
            BoardStages.Folder(path: "/Users/me/Nirux Tasks/Notes", title: "Notes"),
            nil,
            BoardStages.Folder(path: "/p/widgets.bot", title: "bot", canCleanUp: true, canOpen: true, isCleaningUp: true),
            BoardStages.Folder(path: "/p/copy", title: "main", canOpen: true),
            BoardStages.Folder(path: "/p/widgets.shared", title: "shared", canCleanUp: true)
        ], "as the table's buttons: Clean Up where a row can be cleaned up, Open where no workspace is open (the Lead's is one); "
            + "a clean-up that runs, by path")
        XCTAssertEqual(section.lines.map(\.resume), [stopped, nil, stopped, nil, nil, nil, nil], "as the sidebar offers it, repository or not")
        var gone = row(nil, workspaces: ["task"], group: .otherRepository, path: nil, folder: "/Users/me/old")
        gone.folderIsGone = true
        XCTAssertEqual(facts([gone]).lines.map(\.folder?.canCleanUp), [true], "a folder gone: Clean Up closes its workspaces")
        // A merged task's clean-up runs, as its path says: its line says so, and so would "Merged today".
        let merged = [row(workspaces: ["task"], pullRequest: pullRequest(9, state: "MERGED"))]
        XCTAssertEqual(facts(merged).lines.map(\.cleanUp), [.offered])
        XCTAssertEqual(facts(merged, cleaningUp: ["/p/widgets.x"]).lines.map(\.cleanUp), [.running])
        XCTAssertEqual(facts(merged, cleaningUp: ["/p/widgets.other"]).lines.map(\.cleanUp), [.offered])
        XCTAssertEqual(facts([row(workspaces: ["task"])], cleaningUp: ["/p/widgets.x"]).lines.map(\.cleanUp), [nil], "nothing merged to say")
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
                row("odd", pullRequest: pullRequest(16, "odd", base: nil), path: nil, stack: place)
            ],
            reading: reading
        )
        XCTAssertEqual(section.lines[0].pullRequest, BoardStages.PullRequest(
            number: 12, isMerged: false, isDraft: true, isConflicting: true, base: "feat/base", isOnBaseBranch: false,
            checks: .absent, reviewRequest: .changesRequested, stack: place, url: url(12)
        ))
        XCTAssertEqual(section.lines[1].pullRequest, BoardStages.PullRequest(number: 14, base: "main", checks: .absent, url: url(14)),
                       "on the base branch; what GitHub asks of it is a task's to know")
        XCTAssertEqual(section.lines[2].pullRequest, BoardStages.PullRequest(number: 16, base: "main", checks: .absent, stack: place, url: url(16)),
                       "a base gh didn't name holds nothing back, as for the queue; its place in a stack, task or not")
        let free = facts([row(workspaces: ["task"], pullRequest: open)], baseBranch: nil).lines[0]
        XCTAssertEqual(free.pullRequest?.isOnBaseBranch, true, "a repository without a base branch: every base is one")
    }

    func testAMergedPullRequestStaysOnTheTaskTheQueueLeftBehind() {
        let path = "/p/widgets.x"
        // At its head: the row has it, and its worktree can be cleaned up.
        let atHead = facts([row(workspaces: ["task"], pullRequest: pullRequest(9, state: "MERGED"))], required: ["test"]).lines[0]
        XCTAssertEqual(atHead.pullRequest, BoardStages.PullRequest(number: 9, isMerged: true, base: "main", checks: .passed, url: url(9)),
                       "merged: its checks no longer hold anything")
        XCTAssertEqual(atHead.cleanUp, .offered)
        var cleaning = BoardStages.TaskReading()
        cleaning.cleanUp = .running
        XCTAssertEqual(facts([row(workspaces: ["task"], pullRequest: pullRequest(9, state: "MERGED"))], reading: cleaning).lines[0].cleanUp,
                       .running, "what the sidebar reads of the clean-up first")
        XCTAssertNil(facts([row(workspaces: ["task"], pullRequest: pullRequest(9))]).lines[0].cleanUp, "nothing to clean up while it is open")
        let inMain = row("main", workspaces: ["task"], pullRequest: pullRequest(9, "main", state: "MERGED"), group: .main, path: "/p/widgets")
        XCTAssertNil(facts([inMain]).lines[0].cleanUp, "a main checkout is never cleaned up")

        // The queue updated its branch, then merged it: the worktree is a commit behind, the row shows nothing.
        let entries = [entry(9, step: .waitingForPostMerge(mergeCommit), isUpdated: true, isMerged: true)]
        let running = queue(.running(isStopping: false), entries, selection: [9])
        let behind = facts([row(workspaces: ["task"])], queue: running, heads: [path: head]).lines[0]
        XCTAssertEqual(behind.pullRequest, BoardStages.PullRequest(number: 9, isMerged: true, base: "main", checks: .passed))
        XCTAssertEqual(behind.queue, BoardStages.Queue(list: whileRunning, order: 1, step: .merge("Waiting for nightly")))
        XCTAssertEqual(behind.cleanUp, .offered)
        XCTAssertEqual(facts([row(workspaces: ["task"])], queue: running, heads: [path: updated]).lines[0].pullRequest?.number, 9,
                       "at any head the queue knew")
        var elsewhere = BoardStages.TaskReading()
        elsewhere.mergedPullRequest = 20
        XCTAssertEqual(facts([row(workspaces: ["task"])], reading: elsewhere, queue: running, heads: [path: head]).lines[0].pullRequest?.number, 9,
                       "what the queue did here, before what the sidebar detected")
        // Its post-merge run failed: the stop stays on the task left behind.
        let failed = queue(.ended, [entry(9, step: stopped(.postMerge), isUpdated: true, isMerged: true)])
        XCTAssertEqual(facts([row(workspaces: ["task"])], queue: failed, heads: [path: head]).lines[0].queue.stop?.isAfterMerge, true)

        // New work on that branch since, a worktree whose HEAD isn't known, an entry the queue didn't merge: not merged.
        XCTAssertNil(facts([row(workspaces: ["task"])], queue: running, heads: [path: moved]).lines[0].pullRequest)
        XCTAssertNil(facts([row(workspaces: ["task"])], queue: running).lines[0].pullRequest)
        let waiting = queue(.running(isStopping: false), [entry(9, step: .waitingForChecks(head))], selection: [9])
        XCTAssertNil(facts([row(workspaces: ["task"])], queue: waiting, heads: [path: head]).lines[0].pullRequest)
        XCTAssertNil(facts([row("other", workspaces: ["task"])], queue: running, heads: [path: head]).lines[0].pullRequest, "another branch")

        // Nirux quit while its merge was sent: the queue never saw it merged, GitHub's list says it did, at a head the queue knew.
        let unanswered = queue(.ended, [entry(9, step: stopped(.interrupted), isUpdated: true)])
        let atAKnownHead = [pullRequest(9, state: "MERGED", oid: updated)]
        let found = facts([row(workspaces: ["task"])], queue: unanswered, merged: atAKnownHead, heads: [path: head]).lines[0]
        XCTAssertEqual(found.pullRequest?.number, 9)
        let atAnotherHead = [pullRequest(9, state: "MERGED", oid: moved)]
        XCTAssertNil(facts([row(workspaces: ["task"])], queue: unanswered, merged: atAnotherHead, heads: [path: head]).lines[0].pullRequest,
                     "merged at a head the queue never knew: nothing says the worktree is behind it")
        XCTAssertNil(facts([row(workspaces: ["task"])], queue: unanswered, merged: [pullRequest(8, state: "MERGED", oid: updated)],
                           heads: [path: head]).lines[0].pullRequest, "another pull request's merge")

        // No queue merged it: the task's own detection says so, and the merged list its base.
        var detected = BoardStages.TaskReading()
        detected.mergedPullRequest = 9
        let list = [pullRequest(10, "other", state: "MERGED", base: "develop"), pullRequest(9, state: "MERGED", base: "release")]
        let read = facts([row(workspaces: ["task"])], reading: detected, merged: list).lines[0]
        XCTAssertEqual(read.pullRequest, BoardStages.PullRequest(number: 9, isMerged: true, base: "release", checks: .passed, url: url(9)),
                       "its address too")
        XCTAssertEqual(facts([row(workspaces: ["task"])], reading: detected).lines[0].pullRequest?.base, "main", "beyond the list: the base branch")
        // In another repository's worktree, the number detected is that repository's: not looked up here.
        detected.gitRoot = "/p/gadgets.x"
        let foreign = row(workspaces: ["task"], group: .otherRepository, path: "/p/gadgets.x")
        let mixed = facts([foreign, row("cloud", pullRequest: pullRequest(9, "cloud"), path: nil)], reading: detected)
        XCTAssertEqual(mixed.lines.map(\.pullRequest?.number), [nil, 9], "this repository's #9 keeps its own line")

        // Merged by the queue before GitHub's list says so: the open list's copy reads merged. Only that one, and only once merged.
        let rows = [
            row(workspaces: ["task"], pullRequest: pullRequest(9)),
            row("next", pullRequest: pullRequest(10, "next"), path: nil), row("last", pullRequest: pullRequest(11, "last"), path: nil)
        ]
        let early = queue(.running(isStopping: false), entries + [entry(10, "next")], selection: [9, 10])
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
        XCTAssertEqual(judge([check("test", .failure, workflow: "Tests")], ["Tests / test"]), .failed(["Tests / test"]),
                       "a red required check is named once, as it is required")
        XCTAssertEqual(judge([check("lint", .failure), check("docs", .pending)], []), .failed(["lint"]), "red, though another still runs")
        let rerun = [check("test", .failure, startedAt: "2026-11-11T12:00:00Z"), check("test", .success, startedAt: "2026-11-11T12:30:00Z")]
        XCTAssertEqual(judge(rerun, ["test"]), .passed, "only the latest run of a check counts")

        let rerunLint = [check("lint", .failure, startedAt: "2026-11-11T11:00:00Z"), check("lint", .success)]
        let line = facts([row(workspaces: ["task"], pullRequest: pullRequest(12, checks: rerunLint))], required: ["test"]).lines[0]
        XCTAssertEqual(line.pullRequest?.checks, .pending(since: nil, missing: ["test"]),
                       "with the section's required checks, and the latest run of each")
        XCTAssertEqual(line.pullRequest?.checkLines, [
            BoardStages.CheckLine(name: "test", result: "no run yet"), BoardStages.CheckLine(name: "lint", result: "✓")
        ])
    }

    func testEachCheckIsNamedWithItsResultThoseThatHoldItFirst() {
        let named = { (checks: [ProjectBoard.Check], required: [String]) in
            BoardStages.checkLines(checks, required: required).map { line in
                ([line.workflow, line.name].compactMap { $0 }.joined(separator: " / ")) + ": " + line.result
            }
        }
        let checks = [
            check("build", .success), check("lint", .pending), check("test", .failure, workflow: "Tests"),
            check("docs", .skipped, workflow: "CI"), check("scan", .neutral), check("slow", .pending, workflow: "CI"),
            check("e2e", .failure), check("pages", .skipped), check("build", .failure, startedAt: "2026-11-11T11:00:00Z")
        ]
        // A required check is named by its job, or by its workflow and its job.
        let required = ["nightly", "build", "Tests / test", "docs", "scan", "CI / slow"]
        XCTAssertEqual(named(checks, required), [
            "Tests / test: ✗", "CI / docs: skipped", "scan: neutral", "e2e: ✗", "nightly: no run yet", "CI / slow: ●",
            "build: ✓", "lint: ●", "pages: skipped"
        ], "the latest run of each: what holds it (a required one that ended skipped or neutral, as a red one), what hasn't "
            + "reported, what it waits for, then the rest: one that isn't required may still run or be skipped")
        XCTAssertEqual(BoardStages.checks(checks, required: required), .failed(["Tests / test", "docs", "scan", "e2e"]),
                       "those the phrase names are listed first")
        XCTAssertEqual(named([check("docs", .skipped), check("lint", .pending), check("build", .success)], []),
                       ["lint: ●", "docs: skipped", "build: ✓"], "without a required check, every one that runs is waited for")
    }

    // MARK: - Queue

    func testARunningQueueSaysEachPullRequestsPlaceAndStep() {
        let steps: [(MergeQueue.Step, BoardStages.QueueStep?)] = [
            (.preflight, .checks("Checking")), (.updating(from: head), .checks("Updating branch")),
            (.waitingForChecks(head), .checks("Waiting for checks")), (.rerunning(head), .checks("Rerunning checks")),
            (.merging(head), .merge("Merging"))
        ]
        // The queue merged #7 and is through with it: it left the next Start's list, not the queue's count.
        let through = entry(7, "other", step: .done, isMerged: true)
        for (step, expected) in steps {
            let state = queue(.running(isStopping: false), [through, entry(12, step: step)], selection: [12])
            XCTAssertEqual(BoardStages.queue(of: 12, head: head, in: state), BoardStages.Queue(list: whileRunning, order: 2, step: expected),
                           "\(step): its place as the queue counts it, not the next Start's")
        }
        // Merged, and the queue waits for its post-merge run: its number stays while the queue has it.
        let merged = queue(.running(isStopping: false), [
            through, entry(12, step: .waitingForPostMerge(mergeCommit), isMerged: true), entry(13, "next")
        ], selection: [12, 13])
        XCTAssertEqual(BoardStages.queue(of: 12, head: nil, in: merged),
                       BoardStages.Queue(list: whileRunning, order: 2, step: .merge("Waiting for nightly")))
        XCTAssertEqual(BoardStages.queue(of: 7, head: nil, in: merged), BoardStages.Queue(list: whileRunning), "the queue is through with it")
        XCTAssertEqual(BoardStages.queue(of: 13, head: head, in: merged), BoardStages.Queue(list: whileRunning, order: 3))
        XCTAssertEqual(BoardStages.queue(of: 99, head: head, in: merged), BoardStages.Queue(list: whileRunning), "not in the queue that runs")
        XCTAssertEqual(BoardStages.queue(of: 12, head: head, in: nil), BoardStages.Queue(), "a section without a queue has no list")
        // Run by another Nirux: its saved entries, read the same; no list for a next Start here.
        let elsewhere = queue(.elsewhere, [through, entry(12, step: .merging(head))])
        XCTAssertEqual(BoardStages.queue(of: 12, head: head, in: elsewhere), BoardStages.Queue(
            list: .locked("Another Nirux runs this repository’s queue: wait until it ends."), order: 2, step: .merge("Merging")
        ))

        let line = facts([row(workspaces: ["task"], pullRequest: pullRequest(12))],
                         queue: queue(.running(isStopping: false), [entry(12, step: .merging(head))], selection: [12])).lines[0]
        XCTAssertEqual(line.queue, BoardStages.Queue(list: whileRunning, order: 1, step: .merge("Merging")))
    }

    func testAnEndedQueueLeavesItsStopAndTheNextStartsOrder() {
        // "Changed" is a head that moved: by the Board's next read, GitHub's head is none the queue knew.
        let changed = queue(
            .ended, [entry(12, step: stopped(.changed, "#12 changed since you confirmed it.")), entry(13, "next")], selection: [13, 12]
        )
        let read = BoardStages.queue(of: 12, head: moved, in: changed)
        XCTAssertEqual(read.stop, BoardStages.QueueStop(label: "changed", message: "#12 changed since you confirmed it.", isProblem: true))
        XCTAssertEqual(read.order, 2, "its place in the next Start's list")
        XCTAssertEqual(BoardStages.queue(of: 13, head: head, in: changed), BoardStages.Queue(list: .open, order: 1))
        XCTAssertEqual(BoardStages.queue(of: 14, head: head, in: changed), BoardStages.Queue(list: .open), "in neither list")
        XCTAssertEqual(BoardStages.queue(of: 13, head: head, in: queue(.none, selection: [12, 13])), BoardStages.Queue(list: .open, order: 2),
                       "no queue ran: the next Start's list alone")

        // A stop a push answers is over once the head moved; the others stay until the next Start.
        let aboutItsHead: [MergeQueue.StopReason.Kind] = [.checks, .conflict, .merge, .update, .local, .agentBusy]
        let others: [MergeQueue.StopReason.Kind] = [.changed, .interrupted, .setup, .github, .notMergeable, .postMerge, .user, .dryRun]
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

        // After its merge, any stop still says something, and it has no place in the next Start: the others count from 1.
        let nightly = queue(.ended, [
            entry(12, step: stopped(.postMerge, "nightly failed on the merge of #12."), isMerged: true), entry(13, "next"), entry(14, "last")
        ], selection: [12, 13, 14])
        XCTAssertEqual(BoardStages.queue(of: 12, head: nil, in: nightly), BoardStages.Queue(list: .open, stop: BoardStages.QueueStop(
            label: "nightly failed", message: "nightly failed on the merge of #12.", isProblem: true, isAfterMerge: true
        )))
        XCTAssertEqual([13, 14, 15].map { BoardStages.queue(of: $0, head: head, in: nightly).order }, [1, 2, nil])
        let interrupted = queue(.ended, [entry(12, step: stopped(.interrupted), isMerged: true)])
        XCTAssertEqual(BoardStages.queue(of: 12, head: moved, in: interrupted).stop?.isAfterMerge, true)
        let afterAMergeThatFailed = queue(.ended, [entry(12, step: stopped(.merge), isMerged: true)])
        XCTAssertNotNil(BoardStages.queue(of: 12, head: moved, in: afterAMergeThatFailed).stop, "merged, though not as asked: it still needs a look")
        // The base's own run failed before this one merged: a stop from before its merge.
        let base = queue(.ended, [entry(12, step: stopped(.postMerge, "The nightly of abc1234 on main failed."))])
        XCTAssertEqual(BoardStages.queue(of: 12, head: head, in: base).stop?.isAfterMerge, false)
    }

    func testTheListIsTheUsersUnlessAQueueRunsOrItsSheetIsOpen() {
        var confirming = queue(.none, selection: [12])
        confirming.isConfirming = true
        var elsewhereToo = queue(.elsewhere)
        elsewhereToo.isConfirming = true
        let elsewhere = BoardStages.QueueList.locked("Another Nirux runs this repository’s queue: wait until it ends.")
        var runningToo = queue(.running(isStopping: false), [entry(12, step: .merging(head))])
        runningToo.isConfirming = true
        var endedToo = queue(.ended, [entry(12, step: stopped(.checks))], selection: [12])
        endedToo.isConfirming = true
        let sheet = BoardStages.QueueList.locked("The confirmation sheet is open: change the list once it closes.")
        let lists: [(ProjectBoard.QueueState, BoardStages.QueueList, String)] = [
            (queue(.none), .open, "no queue ran"),
            (queue(.ended, [entry(12, step: stopped(.checks))]), .open, "the last queue ended"),
            (queue(.running(isStopping: false)), whileRunning, "a queue runs"),
            (queue(.running(isStopping: true)), whileRunning, "until it has stopped"),
            (queue(.elsewhere), elsewhere, "another Nirux runs it"),
            (elsewhereToo, elsewhere, "what ends last is said"),
            (runningToo, whileRunning, "the queue outlasts its sheet"),
            (confirming, sheet, "the sheet shows the list as it was when it opened"),
            (endedToo, sheet, "for what the last queue stopped on too")
        ]
        for (state, list, why) in lists {
            XCTAssertEqual(BoardStages.queue(of: 12, head: head, in: state).list, list, why)
            XCTAssertEqual(BoardStages.queue(of: 99, head: head, in: state).list, list, "\(why): for one in no list too")
        }

        // A build that can't change GitHub: said where a click would.
        var dryRun = queue(.none)
        XCTAssertNil(BoardStages.queue(of: 12, head: head, in: dryRun).dryRun)
        dryRun.isDryRun = true
        XCTAssertEqual(BoardStages.queue(of: 12, head: head, in: dryRun).dryRun, "Dry run: this build doesn’t change GitHub.")
        dryRun.dryRunReason = "not the notarized release"
        let why = "Dry run: this build doesn’t change GitHub. This build: not the notarized release."
        XCTAssertEqual(BoardStages.queue(of: 99, head: head, in: dryRun).dryRun, why, "on one line: the phrase's tooltip says it")
        dryRun.run = .running(isStopping: false)
        dryRun.entries = [entry(12, step: .merging(head))]
        dryRun.isConfirming = true
        XCTAssertEqual(BoardStages.queue(of: 12, head: head, in: dryRun).dryRun, why, "whatever the queue does with it")

        // Why the queue's own rule keeps a pull request out of the list, as far as the Board knows without a call.
        let place = ProjectBoard.StackPlace(parent: 11, chain: [11, 12], rootBase: "main", mergedBase: nil, root: 11, order: 1)
        var busy = row(workspaces: ["task"], pullRequest: pullRequest(12))
        busy.agent = ProjectBoard.Agent(state: .working(duration: nil))
        let refusals: [(ProjectBoard.Row, String?)] = [
            (row(workspaces: ["task"], pullRequest: pullRequest(12)), nil),
            (row(workspaces: ["task"], pullRequest: pullRequest(12, draft: true)), "draft"),
            (row(workspaces: ["task"], pullRequest: pullRequest(12, base: "feat/base"), stack: place), "after #11"),
            (row(workspaces: ["task"], pullRequest: pullRequest(12, base: "release")), "targets release"),
            (row(workspaces: ["task"], pullRequest: pullRequest(12, mergeable: "CONFLICTING")), "conflict"),
            (busy, "agent working")
        ]
        for (row, refusal) in refusals {
            XCTAssertEqual(facts([row], queue: queue(.none)).lines[0].queue.refusal, refusal)
        }
        let onRelease = facts([row(workspaces: ["task"], pullRequest: pullRequest(12, base: "release"))], queue: queue(.none), baseBranch: "release")
        XCTAssertNil(onRelease.lines[0].queue.refusal, "by the section's base branch")
        let cloud = facts([row("cloud", pullRequest: pullRequest(14, "cloud", draft: true), path: nil)], queue: queue(.none, selection: [14]))
        XCTAssertEqual(cloud.lines[0].queue, BoardStages.Queue(list: .open, order: 1, refusal: "draft"), "a pull request without a task too")
        let merged = facts([row(workspaces: ["task"], pullRequest: pullRequest(9, state: "MERGED"))], queue: queue(.none))
        XCTAssertNil(merged.lines[0].queue.refusal, "nothing is asked of a merged one")
    }

    func testAMergedPullRequestHasNoPlaceInTheNextStart() {
        // Merged by hand while in the list, which keeps it until Start: the others count without it.
        let listed = queue(.none, selection: [12, 13, 14])
        let rows = [
            row(workspaces: ["task"], pullRequest: pullRequest(12, state: "MERGED")),
            row("next", workspaces: ["next"], pullRequest: pullRequest(13, "next"), path: "/p/widgets.next"),
            row("last", pullRequest: pullRequest(14, "last"), path: nil)
        ]
        let byHand = facts(rows, tasks: ["task", "next"], queue: listed)
        XCTAssertEqual(byHand.lines.map(\.queue.order), [nil, 1, 2], "the row's merged pull request")
        // Its worktree moved on, or is gone: the merged list still says so.
        let gone = facts(Array(rows.dropFirst()), tasks: ["next"], queue: listed, merged: [pullRequest(12, state: "MERGED")])
        XCTAssertEqual(gone.lines.map(\.queue.order), [1, 2])
        XCTAssertEqual(BoardStages.queue(of: 13, head: head, in: listed, merged: [12]).order, 1)
        XCTAssertEqual(BoardStages.queue(of: 13, head: head, in: listed).order, 2, "as far as the Board knows")
        // Only the task's own detection knows it, the merged list not read again yet: no place either, for any line.
        var detected = BoardStages.TaskReading()
        detected.mergedPullRequest = 12
        let found = facts([row(workspaces: ["task"])] + rows.dropFirst(), tasks: ["task", "next"], reading: detected, queue: listed)
        XCTAssertEqual(found.lines.map(\.pullRequest?.number), [12, 13, 14])
        XCTAssertEqual(found.lines.map(\.queue.order), [nil, 1, 2])
        // A detection is one task's word: it gives a pull request no place, and doesn't make an open one merged.
        detected.mergedPullRequest = 13
        let disputed = facts([row(workspaces: ["task"])] + rows.dropFirst(), tasks: ["task", "next"], reading: detected, queue: listed)
        XCTAssertEqual(disputed.lines.map(\.pullRequest?.isMerged), [true, false, false])
        XCTAssertEqual(disputed.lines.map(\.queue.order), [nil, nil, 2])
        // Read in another worktree, in another repository, or beside a pull request the row shows, it says nothing here.
        detected.mergedPullRequest = 12
        detected.gitRoot = "/p/widgets.other"
        let elsewhere = facts([row(workspaces: ["task"])] + rows.dropFirst(), tasks: ["task", "next"], reading: detected, queue: listed)
        XCTAssertEqual(elsewhere.lines.map(\.queue.order), [nil, 2, 3])
        detected.gitRoot = nil
        let foreign = row(workspaces: ["task"], group: .otherRepository, path: "/p/gadgets.x")
        XCTAssertEqual(facts([foreign] + rows.dropFirst(), tasks: ["task", "next"], reading: detected, queue: listed).lines.map(\.queue.order),
                       [nil, 2, 3], "another repository's #12")
        let shown = [row(workspaces: ["task"], pullRequest: pullRequest(15, "new")), row("old", pullRequest: pullRequest(12, "old"), path: nil)]
        XCTAssertEqual(facts(shown, reading: detected, queue: listed).lines.map(\.queue.order), [nil, 1],
                       "an earlier merge of a branch whose row shows its open pull request")
        // The merged list was read since the open one, which still has it: merged at once.
        let stale = facts(
            [row(workspaces: ["task"], pullRequest: pullRequest(12))] + rows.dropFirst(), tasks: ["task", "next"], queue: listed,
            merged: [pullRequest(12, state: "MERGED")]
        )
        XCTAssertEqual(stale.lines.map(\.pullRequest?.isMerged), [true, false, false])
        XCTAssertEqual(stale.lines.map(\.queue.order), [nil, 1, 2])
        XCTAssertEqual(stale.lines[0].pullRequest?.checks, .passed, "as any merged one")
        // While a queue runs, its own count stands, and one that isn't in it has no place: the numbers are one list's.
        let running = queue(.running(isStopping: false), [entry(12, step: .waiting), entry(13, "next")], selection: [12, 13])
        XCTAssertEqual(BoardStages.queue(of: 13, head: head, in: running, merged: [12]).order, 2)
        let other = queue(.elsewhere, [entry(12, step: .merging(head)), entry(13, "next")], selection: [20, 13])
        XCTAssertEqual([12, 13, 20].map { BoardStages.queue(of: $0, head: head, in: other).order }, [1, 2, nil],
                       "this Nirux's own list waits for the other's queue to end")
    }

    // MARK: - A repository's queue, as its header says it

    func testARepositorysHeaderSaysItsQueueByTheTablesRules() {
        let start = { (state: ProjectBoard.QueueState, proposed: Int) in BoardStagesView.sectionQueue(state, proposed: proposed) }
        var rest = queue(.none, selection: [12, 13])
        // At rest: as many as the Board shows a place for, merged ones counting for none.
        XCTAssertEqual(start(rest, 2), BoardStagesView.SectionQueue(
            status: "2 pull requests queued",
            start: BoardStagesView.QueueButton(
                title: "Start… · 2", tooltip: "Read the queued pull requests on GitHub, then confirm what the queue will do"
            )
        ))
        XCTAssertEqual(start(rest, 1).status, "1 pull request queued")
        let none = start(rest, 0)
        XCTAssertNil(none.status, "nothing queued: nothing to say")
        XCTAssertEqual(none.start, BoardStagesView.QueueButton(title: "Start…", isEnabled: false, tooltip: "Add pull requests to the queue first."),
                       "only merged ones left in the list: nothing to start")
        // What the table says holds Start back, as it says it.
        rest.startProblems = ["board.json names no base branch."]
        XCTAssertEqual(start(rest, 2).start,
                       BoardStagesView.QueueButton(title: "Start… · 2", isEnabled: false, tooltip: "board.json names no base branch."))
        XCTAssertEqual(start(rest, 0).start?.tooltip, "board.json names no base branch.", "what holds it back is said first")
        rest.startProblems = []
        rest.isConfirming = true
        XCTAssertEqual(start(rest, 2).start?.isEnabled, false)
        // A dry run: the badge, with why.
        var dry = queue(.none, selection: [12])
        dry.isDryRun = true
        dry.dryRunReason = "not the notarized release"
        XCTAssertEqual(start(dry, 1).start?.title, "Start Dry Run… · 1")
        XCTAssertEqual(start(dry, 1).dryRun, ProjectBoardView.dryRunTooltip(reason: "not the notarized release"))
        XCTAssertNil(start(rest, 1).dryRun)
        // Ended: what it did, then what is queued; red when a problem stopped it.
        var ended = queue(.ended, [entry(12, step: stopped(.checks))], selection: [13])
        ended.status = "Stopped: test failed on #12"
        ended.statusIsFailure = true
        XCTAssertEqual(start(ended, 1).status, "Stopped: test failed on #12 · 1 pull request queued")
        XCTAssertEqual(start(ended, 1).tone, .failed)
        ended.status = nil
        ended.statusIsFailure = false
        XCTAssertEqual(start(ended, 0).status, "Ended")
        XCTAssertEqual(start(ended, 0).tone, .normal)
        // Running here: its step, green, Stop and no Start; stopping, Stop says so.
        var running = queue(.running(isStopping: false), [entry(12, step: .merging(head))])
        running.status = "#12 merging, 1 of 1"
        let busy = start(running, 0)
        XCTAssertEqual([busy.status, busy.start?.title], ["#12 merging, 1 of 1", nil])
        XCTAssertEqual(busy.tone, .working)
        XCTAssertEqual(busy.stop?.title, "Stop")
        XCTAssertEqual(busy.stop?.isEnabled, true)
        running.run = .running(isStopping: true)
        XCTAssertEqual(start(running, 0).stop, BoardStagesView.QueueButton(
            title: "Stopping…", isEnabled: false, tooltip: "Stop before the next command; a call already sent to GitHub finishes"
        ))
        // Run by another Nirux: said, Start disabled with why, no Stop.
        var other = queue(.elsewhere, [entry(12, step: .merging(head))])
        other.status = "#12 merging"
        let far = start(other, 0)
        XCTAssertEqual(far.status, "Running in another Nirux · #12 merging")
        XCTAssertNil(far.stop)
        XCTAssertEqual(far.start?.isEnabled, false)

        // The Board's foot: a queue that runs, here with Stop, elsewhere without; none at rest.
        XCTAssertEqual(BoardStagesView.runningQueue(id: "widgets", title: "widgets", state: running)?.stop?.title, "Stopping…")
        running.run = .running(isStopping: false)
        XCTAssertEqual(BoardStagesView.runningQueue(id: "widgets", title: "widgets", state: running),
                       BoardStagesView.RunningQueue(id: "widgets", title: "widgets", status: "#12 merging, 1 of 1", stop: busy.stop))
        XCTAssertEqual(BoardStagesView.runningQueue(id: "old", title: "old", state: other),
                       BoardStagesView.RunningQueue(id: "old", title: "old", status: "Running in another Nirux · #12 merging"))
        XCTAssertNil(BoardStagesView.runningQueue(id: "widgets", title: "widgets", state: ended))
        XCTAssertNil(BoardStagesView.runningQueue(id: "widgets", title: "widgets", state: rest))
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
