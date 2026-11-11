import XCTest
@testable import Nirux

/// The Board's lines grouped into units and sections
/// (docs/design/board-stages.md, section 4): families, stacks, the pull
/// requests without a task, the two orders, "Merged today". Pure.
final class BoardStagesUnitsTests: XCTestCase {
    private typealias Facts = BoardStages.Facts

    /// 2026-11-11 14:00 UTC: 04:30 in a zone no machine runs in (UTC−9:30).
    private let now: TimeInterval = 1_794_405_600
    private let zone = TimeZone(secondsFromGMT: -(9 * 3600 + 30 * 60))!
    private let head = String(repeating: "a", count: 40)

    /// A reviewed task, titled by its id in capitals; with `number`, its
    /// green open pull request.
    private func task(
        _ id: String, _ number: Int? = nil, checks: BoardStages.Checks = .passed, stack: ProjectBoard.StackPlace? = nil,
        merged: Bool = false, hasTask: Bool = true
    ) -> Facts {
        var facts = Facts(id: id, title: id.uppercased())
        facts.hasTask = hasTask
        facts.reviews = hasTask ? ReviewBadges(runs: [.codeReview: ReviewRun(head: head, at: 500)], head: head) : nil
        facts.pullRequest = number.map {
            BoardStages.PullRequest(
                number: $0, isMerged: merged, base: stack == nil ? "main" : "stack", isOnBaseBranch: stack?.parent == nil,
                checks: checks, stack: stack
            )
        }
        return facts
    }

    /// The place of the pull request at `order` in a straight stack.
    private func place(_ order: Int, of chain: [Int] = [52, 53, 54], merged: ProjectBoard.MergedBase? = nil) -> ProjectBoard.StackPlace {
        ProjectBoard.StackPlace(
            parent: order == 0 ? nil : chain[order - 1], chain: chain, rootBase: merged == nil ? "main" : "feat/x",
            mergedBase: order == 0 ? merged : nil, root: chain[0], order: order
        )
    }

    private func section(
        _ lines: [Facts], parents: [String: String] = [:], merged: [BoardStages.MergedFacts] = [],
        order: BoardStages.Order = .sidebar, rules: BoardStages.Rules = BoardStages.Rules()
    ) -> BoardStages.Section {
        BoardStages.section(
            BoardStages.SectionFacts(id: "nirux", lines: lines, parents: parents, merged: merged), order: order, rules: rules,
            now: now, timeZone: zone
        )
    }

    /// "a+a1+a2" for a task and its sub-tasks, "s[x,y]" for a stack.
    private func shape(_ units: [BoardStages.Unit]) -> [String] {
        units.map { unit in
            switch unit {
            case .task(let task, let subtasks): return ([task] + subtasks).map(\.id).joined(separator: "+")
            case .stack(_, let lines): return "s[" + lines.map(\.id).joined(separator: ",") + "]"
            }
        }
    }

    private func stackTitles(_ units: [BoardStages.Unit]) -> [String] {
        units.compactMap { unit in
            if case .stack(let title, _) = unit { return title }
            return nil
        }
    }

    // MARK: - Families

    func testATaskAndTheTasksListedUnderItAreAFamily() {
        let result = section(
            [task("a"), task("a1"), task("a2"), task("b"), task("a3")], parents: ["a1": "a", "a2": "a1", "a3": "a"]
        )
        XCTAssertEqual(shape(result.units), ["a+a1+a2+a3", "b"], "depth first, at the task's place, whatever came between")
    }

    func testASubtaskWithoutItsTaskHereStandsAlone() {
        let elsewhere = section([task("a1"), task("b")], parents: ["a1": "gone"])
        XCTAssertEqual(shape(elsewhere.units), ["a1", "b"], "its task is in another section, or closed")
        let loop = section(
            [task("z"), task("x"), task("y"), task("under")], parents: ["x": "y", "y": "x", "z": "z", "under": "y"]
        )
        XCTAssertEqual(shape(loop.units), ["z", "x+y+under"],
                       "parents in a loop: its first line heads it, as in the sidebar; no line is lost, none drawn twice")
    }

    // MARK: - Stacks

    func testAStackIsAUnitInMergeOrderAtTheFirstOfItsLines() {
        let result = section([
            task("x"), task("third", 54, stack: place(2)), task("y"), task("first", 52, stack: place(0)),
            task("second", 53, stack: place(1))
        ])
        XCTAssertEqual(result.units.map(\.lines).map { $0.map(\.id) }, [["x"], ["first", "second", "third"], ["y"]])
        XCTAssertEqual(shape(result.units), ["x", "s[first,second,third]", "y"])
        XCTAssertEqual(stackTitles(result.units), ["Stack · 3 pull requests on main"])
    }

    func testAStackOnAMergedBaseNamesIt() {
        let merged = ProjectBoard.MergedBase(number: 51, onto: "main")
        let result = section([
            task("second", 53, stack: place(1, of: [52, 53], merged: merged)), task("first", 52, stack: place(0, of: [52, 53], merged: merged))
        ])
        XCTAssertEqual(shape(result.units), ["s[first,second]"])
        XCTAssertEqual(stackTitles(result.units), ["Stack · 2 pull requests on feat/x (#51 merged)"])
        let lone = place(0, of: [52], merged: merged)
        XCTAssertEqual(shape(section([task("clone1", 52, stack: lone), task("clone2", 52, stack: lone)]).units), ["clone1", "clone2"],
                       "one pull request on a merged base is no stack")
        let clones = [task("clone1", 52, stack: place(0, of: [52, 53])), task("clone2", 52, stack: place(0, of: [52, 53]))]
        XCTAssertEqual(shape(section(clones).units), ["clone1", "clone2"], "nor is one held by two checkouts")
        let twice = section(clones + [task("second", 53, stack: place(1, of: [52, 53]))])
        XCTAssertEqual(stackTitles(twice.units), ["Stack · 2 pull requests on main"], "a stack counts pull requests, not lines")
    }

    func testAForkIsNoStackOfItsOwn() {
        // #53 and #54 both on #52's branch: no single merge order.
        let fork = { (order: Int, parent: Int?) in
            ProjectBoard.StackPlace(parent: parent, chain: [], rootBase: "main", mergedBase: nil, root: 52, order: order)
        }
        let result = section([task("root", 52, stack: fork(0, nil)), task("left", 53, stack: fork(1, 52)), task("right", 54, stack: fork(2, 52))])
        XCTAssertEqual(shape(result.units), ["root", "left", "right"])
        XCTAssertEqual(result.units.last?.lines.last?.pullRequest, "#54 · on #52", "its cell says what it is on")
    }

    func testTheFamilyWinsOverTheStack() {
        let two = [task("first", 52, stack: place(0, of: [52, 53])), task("second", 53, stack: place(1, of: [52, 53])), task("other")]
        XCTAssertEqual(shape(section(two, parents: ["other": "first"]).units), ["first+other", "second"], "one of the stack has a sub-task")
        let result = section([two[2], two[0], two[1]], parents: ["first": "other"])
        XCTAssertEqual(shape(result.units), ["other+first", "second"], "one of the stack is a sub-task: a line is drawn once")
        XCTAssertEqual(result.units.last?.lines.last?.pullRequest, "#53 · 2/2", "its pull request cell still says the stack")
    }

    // MARK: - Pull requests without a task

    func testPullRequestsWithoutATaskCloseTheSection() {
        let lines = [
            task("a"), task("first", 52, stack: place(0, of: [52, 53])), task("pr53", 53, stack: place(1, of: [52, 53]), hasTask: false),
            task("pr80", 80, checks: .pending(since: nil), hasTask: false),
            task("pr70", 70, checks: .pending(since: nil), stack: place(0, of: [70, 71]), hasTask: false),
            task("pr71", 71, stack: place(1, of: [70, 71]), hasTask: false), task("pr60", 60, hasTask: false)
        ]
        XCTAssertEqual(shape(section(lines).units), ["a", "s[first,pr53]"], "a stack with a task stays whole in the list")
        XCTAssertEqual(shape(section(lines).withoutTask), ["pr80", "s[pr70,pr71]", "pr60"])
        let byProgress = section(lines, order: .progress)
        XCTAssertEqual(shape(byProgress.units), ["s[first,pr53]", "a"], "a stack counts as its furthest line")
        XCTAssertEqual(shape(byProgress.withoutTask), ["s[pr70,pr71]", "pr60", "pr80"], "the same order in both lists")
    }

    // MARK: - Orders

    func testByProgressPutsTheClosestToItsBaseFirst() {
        var blocked = task("blocked", 61)
        blocked.blocker = "waits for upstream"
        var unreviewed = task("coding")
        unreviewed.reviews = nil
        var archived = task("archived", 66)
        archived.isArchived = true
        var mergedWorking = task("merged", 40, merged: true)
        mergedWorking.activity = .working(since: nil)
        var updating = task("updating", 67, checks: .pending(since: nil))
        updating.queue = BoardStages.Queue(order: 1, step: .checks("Updating branch"))
        var queued = task("queued", 68)
        queued.queue.order = 2
        // Listed from the furthest from its base to the closest: every rank moves.
        let lines = [
            archived, mergedWorking, blocked, unreviewed, task("checking", 62, checks: .pending(since: nil)), task("ready", 63),
            task("family"), task("child", 64), queued, updating
        ]
        let parents = ["child": "family"]
        XCTAssertEqual(shape(section(lines, parents: parents).units),
                       ["archived", "merged", "blocked", "coding", "checking", "ready", "family+child", "queued", "updating"])
        XCTAssertEqual(
            shape(section(lines, parents: parents, order: .progress).units),
            ["updating", "queued", "ready", "family+child", "checking", "coding", "blocked", "merged", "archived"],
            "the queue's own first, then its list in order; by station; a family by its furthest line; ties in the sidebar's "
                + "order; blocked below Code; then merged, whatever its agent does, and archived"
        )
    }

    func testTheRulesReachTheLines() {
        var unreviewed = task("unreviewed", 61)
        unreviewed.reviews = nil
        let lines = [task("checking", 62, checks: .pending(since: nil)), unreviewed]
        XCTAssertEqual(shape(section(lines, order: .progress).units), ["checking", "unreviewed"], "at Reviews, behind Checks")
        let noReview = BoardStages.Rules(requiredReviews: [])
        XCTAssertEqual(shape(section(lines, order: .progress, rules: noReview).units), ["unreviewed", "checking"],
                       "no review asked for: at Merge")
    }

    // MARK: - Merged today

    private func mergedToday(_ number: Int, _ title: String = "", minutesAgo: Double = 58) -> BoardStages.MergedFacts {
        BoardStages.MergedFacts(number: number, title: title, mergedAt: now - minutesAgo * 60)
    }

    func testAPullRequestMergedTodayLeavesTheListForTheClosingLine() {
        let midnight = now - 4.5 * 3600
        var telegram = task("telegram", 40, merged: true)
        telegram.cleanUp = .offered
        let result = section([telegram, task("old", 39, merged: true), task("open", 43)], merged: [
            mergedToday(40, "Remove Telegram (#40)"),
            BoardStages.MergedFacts(number: 41, title: "The Board is always empty", mergedAt: midnight),
            BoardStages.MergedFacts(number: 39, title: "Yesterday's", mergedAt: midnight - 1)
        ])
        XCTAssertEqual(shape(result.units), ["old", "open"], "merged yesterday with its task still open: a line")
        XCTAssertEqual(result.merged, [
            BoardStages.Merged(lineID: "telegram", title: "TELEGRAM", number: 40, mergedAt: now - 58 * 60, cleanUp: .offered),
            BoardStages.Merged(lineID: nil, title: "The Board is always empty", number: 41, mergedAt: midnight)
        ], "the newest first; its task's title, line and clean-up while that task is open, else the pull request's title")
        let untitled = section([], merged: [mergedToday(44, " \u{202E}\n")])
        XCTAssertEqual(untitled.merged.map(\.title), ["#44"], "GitHub's text is whatever its author typed")
    }

    func testAMergedLineDoesNotComeAndGoWithItsAgent() {
        var asking = task("asking", 40, merged: true)
        asking.activity = .needsYou("a question")
        var working = task("working", 41, merged: true)
        working.activity = .working(since: nil)
        let result = section([asking, working], merged: [mergedToday(40), mergedToday(41, minutesAgo: 5)])
        XCTAssertEqual(shape(result.units), [], "whatever their agents do next, turn after turn")
        XCTAssertEqual(result.merged.map(\.lineID), ["working", "asking"])
        XCTAssertEqual(result.merged.map(\.needsYou), [false, true], "amber is never hidden: the closing line carries it")
    }

    func testTheQueueKeepsItsLineUntilItIsThroughWithIt() {
        var waiting = task("waiting", 40, merged: true)
        waiting.queue = BoardStages.Queue(order: 1, step: .merge("Waiting for nightly"))
        var failed = task("failed", 41, merged: true)
        failed.queue.stop = BoardStages.QueueStop(label: "nightly failed", message: "", isProblem: true, isAfterMerge: true)
        let result = section([waiting, failed], merged: [mergedToday(40), mergedToday(41)])
        XCTAssertEqual(shape(result.units), ["waiting", "failed"])
        XCTAssertEqual(result.merged, [], "one place per pull request: not on the closing line while its line is listed")
    }

    func testAMergedTaskStaysWhileASubtaskOfItIsListed() {
        let lines = [task("a", 40, merged: true), task("a1", 41, merged: true), task("a2"), task("b", 42, merged: true), task("b1", 43, merged: true)]
        let parents = ["a1": "a", "a2": "a1", "b1": "b"]
        let merged = [mergedToday(40), mergedToday(41), mergedToday(42), mergedToday(43)]
        let result = section(lines, parents: parents, merged: merged)
        XCTAssertEqual(shape(result.units), ["a+a1+a2"], "a family stays whole around the sub-task still open; one all merged leaves")
        XCTAssertEqual(result.merged.map(\.number), [42, 43])
    }

    func testNoLineIsLostWhenTwoShareAMergedPullRequest() {
        // Not what the app gives, but no input may lose a line.
        var asking = task("t1", 40, merged: true)
        asking.queue = BoardStages.Queue(step: .merge("Waiting for nightly"))
        let remote = task("pr40", 40, merged: true, hasTask: false)
        let result = section([asking, remote], merged: [mergedToday(40, "From the cloud")])
        XCTAssertEqual(shape(result.units), ["t1"])
        XCTAssertEqual(result.merged, [BoardStages.Merged(lineID: nil, title: "From the cloud", number: 40, mergedAt: now - 58 * 60)],
                       "the one that left is on the closing line; without a task, nothing to open")
    }
}
