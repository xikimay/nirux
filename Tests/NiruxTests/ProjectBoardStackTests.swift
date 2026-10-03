import XCTest
@testable import Nirux

/// Stacked pull requests on the board (docs/pr-stacks.md): where each one
/// sits, the order of their rows, what their PR and Queue columns say, and
/// Retarget once a base merged. Pure: nothing runs git or gh. Through
/// `rows`, as the board builds them.
final class ProjectBoardStackTests: XCTestCase {
    private let widgets = GitHubRepository(owner: "acme", name: "widgets")

    private func pullRequest(
        _ number: Int, _ branch: String, base: String = "main", state: String = "OPEN", draft: Bool = false,
        baseOid: String = String(repeating: "a", count: 40)
    ) -> ProjectBoard.PullRequest {
        // Every head is `aaa…`: a base reads untouched since its merge.
        ProjectBoard.PullRequest(
            number: number, state: state, headRefName: branch,
            headOid: String(repeating: "a", count: 40), baseRefName: base, isDraft: draft, mergeable: "MERGEABLE",
            checks: [], url: "https://github.com/acme/widgets/pull/\(number)", isFromConfiguredRepository: true,
            baseOid: baseOid
        )
    }

    private func rows(
        open: [ProjectBoard.PullRequest], merged: [ProjectBoard.PullRequest] = [], baseBranch: String? = "main"
    ) -> [ProjectBoard.Row] {
        ProjectBoard.rows(ProjectBoard.Sources(
            repository: widgets, baseBranch: baseBranch,
            local: [ProjectBoard.LocalRepository(worktrees: [
                WorktreeCleanup.ListedWorktree(path: "/p/widgets", head: String(repeating: "1", count: 40),
                                               branch: "main", isBare: false, isPrunable: false)
            ], remotes: [widgets])],
            openPullRequests: open, mergedPullRequests: merged
        )).filter { $0.group == .active }
    }

    private func row(_ number: Int, in rows: [ProjectBoard.Row]) throws -> ProjectBoard.Row {
        try XCTUnwrap(rows.first { $0.pullRequest?.number == number })
    }

    // MARK: - Places and order

    func testAStraightStackReadsNOfNAndItsRowsFollowItsRoot() throws {
        let result = rows(open: [
            pullRequest(60, "stack/c", base: "stack/b"),
            pullRequest(55, "lone"),
            pullRequest(52, "stack/a"),
            pullRequest(53, "stack/b", base: "stack/a"),
            pullRequest(58, "later")
        ])
        XCTAssertEqual(result.map { $0.pullRequest?.number }, [52, 53, 60, 55, 58],
                       "a stack sits at its root's place, in stack order; the rest stays oldest first")
        let third = try row(60, in: result)
        XCTAssertEqual(third.stack?.label, "3/3")
        XCTAssertEqual(third.stack?.parent, 53)
        XCTAssertEqual(third.stack?.tooltip, "Stack: #52 → #53 → #60, on main")
        XCTAssertEqual(try row(52, in: result).stack?.label, "1/3")
        XCTAssertNil(try row(55, in: result).stack, "a lone pull request is no stack")
        XCTAssertEqual(ProjectBoard.pullRequestText(try XCTUnwrap(third.pullRequest), baseBranch: "main", stack: third.stack),
                       "#60 open · 3/3")
    }

    func testAForkNamesWhatEachIsBasedOnWithoutNOfN() throws {
        let result = rows(open: [
            pullRequest(52, "stack/a"),
            pullRequest(54, "stack/c", base: "stack/a"),
            pullRequest(53, "stack/b", base: "stack/a")
        ])
        XCTAssertEqual(result.map { $0.pullRequest?.number }, [52, 53, 54])
        XCTAssertEqual(try row(53, in: result).stack?.label, "on #52")
        let deeper = rows(open: [
            pullRequest(52, "stack/a"),
            pullRequest(53, "stack/b", base: "stack/a"),
            pullRequest(60, "stack/c", base: "stack/a"),
            pullRequest(54, "stack/d", base: "stack/b"),
            pullRequest(61, "stack/e", base: "stack/c")
        ])
        XCTAssertEqual(deeper.map { $0.pullRequest?.number }, [52, 53, 54, 60, 61], "each one is followed by those on it")
        XCTAssertEqual(try row(54, in: result).stack?.tooltip, "Stacked on #52")
        XCTAssertNil(try row(52, in: result).stack?.label, "the root of a fork is based on main")
    }

    func testPullRequestsBasedOnEachOtherInALoopAreNoStack() {
        let result = rows(open: [pullRequest(52, "loop/a", base: "loop/b"), pullRequest(53, "loop/b", base: "loop/a")])
        XCTAssertEqual(result.compactMap(\.stack), [])
    }

    func testOnceItsBaseMergedTheRootOffersToRetargetOntoThatBase() throws {
        let result = rows(
            open: [pullRequest(53, "stack/b", base: "stack/a"), pullRequest(54, "stack/c", base: "stack/b")],
            merged: [pullRequest(52, "stack/a", state: "MERGED")]
        )
        let root = try row(53, in: result)
        XCTAssertEqual(root.stack?.mergedBase, ProjectBoard.MergedBase(number: 52, onto: "main"))
        XCTAssertEqual(root.stack?.label, "1/2", "the stack counts its open pull requests")
        XCTAssertEqual(root.stack?.tooltip, "Stack: #53 → #54, on stack/a (#52 merged)")
        XCTAssertNil(try row(54, in: result).stack?.mergedBase, "only the root can be retargeted")

        let lone = rows(open: [pullRequest(53, "stack/b", base: "stack/a")], merged: [pullRequest(52, "stack/a", state: "MERGED")])
        let loneRow = try row(53, in: lone)
        XCTAssertEqual(loneRow.stack?.mergedBase?.number, 52)
        XCTAssertNil(loneRow.stack?.label)
        XCTAssertEqual(ProjectBoard.pullRequestText(try XCTUnwrap(loneRow.pullRequest), baseBranch: "main", stack: loneRow.stack),
                       "#53 open → stack/a")
    }

    func testAPullRequestOnTheBaseBranchIsNeverRetargeted() {
        // A pull request once merged from `main` into a release branch.
        let result = rows(open: [pullRequest(53, "feat/x")], merged: [pullRequest(40, "main", base: "release", state: "MERGED")])
        XCTAssertEqual(result.compactMap(\.stack), [])
        // Nor stacked on an open one from `main`.
        let released = rows(open: [pullRequest(40, "main", base: "release"), pullRequest(53, "feat/x"), pullRequest(54, "feat/y")])
        XCTAssertEqual(released.compactMap(\.stack), [])
        XCTAssertEqual(released.map { $0.pullRequest?.number }, [53, 54], "oldest first, not under #40")
    }

    func testABaseWithNewCommitsSinceItsMergeIsNoStack() {
        // `develop` merged into `main` once, and moved on since.
        let result = rows(open: [pullRequest(53, "feat/x", base: "develop", baseOid: String(repeating: "b", count: 40))],
                          merged: [pullRequest(40, "develop", state: "MERGED")])
        XCTAssertEqual(result.compactMap(\.stack), [])
    }

    func testWithoutABaseBranchNothingIsRetargeted() {
        let result = rows(open: [pullRequest(53, "feat/x")], merged: [pullRequest(40, "main", base: "release", state: "MERGED")],
                          baseBranch: nil)
        XCTAssertEqual(result.compactMap(\.stack), [])
    }

    // MARK: - The Queue column

    private func cell(_ row: ProjectBoard.Row, dryRun: Bool = false) -> ProjectBoardView.QueueCell? {
        ProjectBoardView.queueCell(for: row, queue: ProjectBoard.QueueState(isDryRun: dryRun), baseBranch: "main")
    }

    func testAPullRequestOnAnOpenOneWaitsForIt() throws {
        let result = rows(open: [pullRequest(52, "stack/a"), pullRequest(53, "stack/b", base: "stack/a")])
        XCTAssertEqual(cell(try row(53, in: result))?.text, "after #52")
        XCTAssertNil(cell(try row(53, in: result))?.button)
        XCTAssertEqual(cell(try row(52, in: result))?.button?.title, "Add to Queue")
    }

    func testAMergedBaseOffersRetargetExceptInADryRun() throws {
        let result = rows(open: [pullRequest(53, "stack/b", base: "stack/a", draft: true)],
                          merged: [pullRequest(52, "stack/a", state: "MERGED")])
        let live = try XCTUnwrap(cell(try row(53, in: result)))
        XCTAssertEqual(live.button?.title, "Retarget to main")
        XCTAssertEqual(live.button?.isEnabled, true)
        XCTAssertEqual(live.action, .retarget(number: 53, base: "main"))
        XCTAssertEqual(live.detail, "draft", "a draft can be retargeted, and still says why it can't join")

        let dryRun = try XCTUnwrap(cell(try row(53, in: result), dryRun: true))
        XCTAssertEqual(dryRun.button?.isEnabled, false)
        XCTAssertTrue(dryRun.button?.tooltip?.hasPrefix("Dry run: ") == true)

        let ready = rows(open: [pullRequest(53, "stack/b", base: "stack/a")], merged: [pullRequest(52, "stack/a", state: "MERGED")])
        XCTAssertEqual(cell(try row(53, in: ready))?.detail, "base #52 merged")
    }
}
