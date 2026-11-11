import XCTest
@testable import Nirux

/// The Board's lines grouped into units and sections (docs/design/board-stages.md,
/// section 4): families, stacks, the pull requests without a task, the
/// two orders, "Merged today". Pure.
final class BoardStagesUnitsTests: XCTestCase {
    private typealias Facts = BoardStages.Facts

    /// 2026-11-11 15:00 in Paris (UTC+1).
    private let now: TimeInterval = 1_794_405_600
    private let paris = TimeZone(identifier: "Europe/Paris")!
    private let head = String(repeating: "a", count: 40)

    /// A reviewed task; with `number`, its green open pull request.
    private func task(
        _ id: String, _ number: Int? = nil, checks: BoardStages.Checks = .passed,
        stack: ProjectBoard.StackPlace? = nil, merged: Bool = false, hasTask: Bool = true
    ) -> Facts {
        var facts = Facts(id: id, title: id.uppercased())
        facts.hasTask = hasTask
        facts.reviews = ReviewBadges(runs: [.codeReview: ReviewRun(head: head, at: 500)], head: head)
        facts.pullRequest = number.map {
            BoardStages.PullRequest(number: $0, isMerged: merged, base: stack?.parent == nil ? "main" : "stack", checks: checks, stack: stack)
        }
        return facts
    }

    private func place(_ order: Int, of chain: [Int] = [52, 53, 54], merged: ProjectBoard.MergedBase? = nil) -> ProjectBoard.StackPlace {
        ProjectBoard.StackPlace(
            parent: order == 0 ? nil : chain[order - 1], chain: chain, rootBase: merged == nil ? "main" : "feat/x",
            mergedBase: order == 0 ? merged : nil, root: chain[0], order: order
        )
    }

    private func section(
        _ lines: [Facts], parents: [String: String] = [:], merged: [BoardStages.MergedFacts] = [],
        order: BoardStages.Order = .sidebar
    ) -> BoardStages.Section {
        BoardStages.section(
            BoardStages.SectionFacts(id: "nirux", lines: lines, parents: parents, merged: merged), order: order, now: now,
            timeZone: paris
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
            [task("x"), task("y"), task("z"), task("under")], parents: ["x": "y", "y": "x", "z": "z", "under": "x"]
        )
        XCTAssertEqual(shape(loop.units), ["x", "y", "z", "under"], "parents in a loop have no root: flat, as in the sidebar")
    }

    // MARK: - Stacks

    func testAStackIsAUnitInMergeOrderAtTheFirstOfItsLines() {
        let result = section([
            task("x"), task("third", 54, stack: place(2)), task("y"), task("first", 52, stack: place(0)),
            task("second", 53, stack: place(1))
        ])
        XCTAssertEqual(shape(result.units), ["x", "s[first,second,third]", "y"])
        guard case .stack(let title, _)? = result.units.dropFirst().first else { return XCTFail("no stack") }
        XCTAssertEqual(title, "Stack · 3 pull requests on main")
    }

    func testAStackOnAMergedBaseNamesIt() {
        let merged = ProjectBoard.MergedBase(number: 51, onto: "main")
        let result = section([
            task("first", 52, stack: place(0, of: [52, 53], merged: merged)), task("second", 53, stack: place(1, of: [52, 53], merged: merged))
        ])
        guard case .stack(let title, _)? = result.units.first else { return XCTFail("no stack") }
        XCTAssertEqual(title, "Stack · 2 pull requests on feat/x (#51 merged)")
        let lone = section([task("lone", 52, stack: place(0, of: [52], merged: merged))])
        XCTAssertEqual(shape(lone.units), ["lone"], "one pull request is no stack")
    }

    func testTheFamilyWinsOverTheStack() {
        let result = section(
            [task("a", 52, stack: place(0)), task("a1", 53, stack: place(1)), task("b", 54, stack: place(2))], parents: ["a1": "a"]
        )
        XCTAssertEqual(shape(result.units), ["a+a1", "b"], "a line is drawn once: its family has it")
        XCTAssertEqual(result.units.last?.lines.first?.pullRequest, "#54 · 3/3", "its pull request cell still says the stack")
        let two = [task("first", 52, stack: place(0, of: [52, 53])), task("second", 53, stack: place(1, of: [52, 53])), task("other")]
        XCTAssertEqual(shape(section(two, parents: ["other": "first"]).units), ["first+other", "second"], "one of the stack has a sub-task")
        XCTAssertEqual(shape(section([two[2], two[0], two[1]], parents: ["first": "other"]).units), ["other+first", "second"],
                       "one of the stack is a sub-task")
    }

    // MARK: - Pull requests without a task

    func testPullRequestsWithoutATaskCloseTheSection() {
        let result = section([
            task("a"), task("first", 52, stack: place(0)), task("pr53", 53, stack: place(1), hasTask: false),
            task("pr60", 60, hasTask: false), task("pr70", 70, stack: place(0, of: [70, 71]), hasTask: false),
            task("pr71", 71, stack: place(1, of: [70, 71]), hasTask: false)
        ])
        XCTAssertEqual(shape(result.units), ["a", "s[first,pr53]"], "a stack with a task stays whole in the list")
        XCTAssertEqual(shape(result.withoutTask), ["pr60", "s[pr70,pr71]"])
    }

    // MARK: - Orders

    func testByProgressPutsTheClosestToItsBaseFirst() {
        var blocked = task("blocked", 61)
        blocked.blocker = "waits for upstream"
        var unreviewed = task("coding")
        unreviewed.reviews = nil
        let lines = [
            unreviewed, task("checking", 62, checks: .pending(since: nil)), blocked, task("ready", 63),
            task("family"), task("child", 64), task("merged", 40, merged: true), task("ready2", 65)
        ]
        let parents = ["child": "family"]
        XCTAssertEqual(shape(section(lines, parents: parents).units),
                       ["coding", "checking", "blocked", "ready", "family+child", "merged", "ready2"])
        XCTAssertEqual(
            shape(section(lines, parents: parents, order: .progress).units),
            ["ready", "family+child", "ready2", "checking", "coding", "blocked", "merged"],
            "by station; a family by its furthest line; ties in the sidebar's order; blocked below Code; merged last"
        )
    }

    // MARK: - Merged today

    func testAPullRequestMergedTodayLeavesTheListForTheClosingLine() {
        let midnight = now - 15 * 3600
        let merged = [
            BoardStages.MergedFacts(number: 40, title: "Remove Telegram (#40)", mergedAt: now - 3600 + 120),
            BoardStages.MergedFacts(number: 41, title: "The Board is always empty", mergedAt: midnight),
            BoardStages.MergedFacts(number: 39, title: "Yesterday's", mergedAt: midnight - 1)
        ]
        var asking = task("asking", 42, merged: true)
        asking.activity = .needsYou("a question")
        let result = section(
            [task("telegram", 40, merged: true), task("old", 39, merged: true), asking],
            merged: merged + [BoardStages.MergedFacts(number: 42, title: "Asked after its merge", mergedAt: now - 60)]
        )
        XCTAssertEqual(shape(result.units), ["old", "asking"],
                       "merged yesterday with its task still open: a line; merged today with an agent that asks: amber stays in the list")
        XCTAssertEqual(result.merged, [
            BoardStages.Merged(lineID: "telegram", title: "TELEGRAM", number: 40, time: "14:02"),
            BoardStages.Merged(lineID: nil, title: "The Board is always empty", number: 41, time: "00:00")
        ], "the newest first; the task's title while it is open, else the pull request's; one place per pull request")
    }
}
