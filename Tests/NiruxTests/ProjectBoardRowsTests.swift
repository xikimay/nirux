import XCTest
@testable import Nirux

/// Which rows the Project Board shows, and in what order
/// (docs/project-board.md, section 2). Pure: listings, workspaces and pull
/// requests are given, nothing runs git or gh.
final class ProjectBoardRowsTests: XCTestCase {
    private let widgets = GitHubRepository(owner: "acme", name: "widgets")
    private let gadgets = GitHubRepository(owner: "acme", name: "gadgets")

    private func worktree(
        _ path: String, branch: String? = nil, head: String? = "1111111111111111111111111111111111111111",
        bare: Bool = false, prunable: Bool = false
    ) -> WorktreeCleanup.ListedWorktree {
        WorktreeCleanup.ListedWorktree(
            path: path, head: bare ? nil : head, branch: branch, isBare: bare, isPrunable: prunable
        )
    }

    private func workspace(
        _ id: String, _ folder: String, title: String? = nil, inactive: Bool = false,
        agent: ProjectBoard.AgentState = .none
    ) -> ProjectBoard.Workspace {
        ProjectBoard.Workspace(
            id: id, title: title ?? id, folder: folder, isInactive: inactive,
            agent: ProjectBoard.Agent(state: agent, workspaceID: agent == .none ? nil : id, columnID: nil, failedAt: nil)
        )
    }

    private func pullRequest(
        _ number: Int, _ branch: String, state: String = "OPEN", fork: Bool = false, draft: Bool = false
    ) -> ProjectBoard.PullRequest {
        ProjectBoard.PullRequest(
            number: number, state: state, headRefName: branch,
            headOid: String(repeating: "a", count: 40), baseRefName: "main", isDraft: draft, mergeable: "MERGEABLE",
            checks: [], url: "https://github.com/acme/widgets/pull/\(number)", isFromConfiguredRepository: !fork
        )
    }

    private func rows(
        local: [ProjectBoard.LocalRepository],
        workspaces: [ProjectBoard.Workspace] = [],
        open: [ProjectBoard.PullRequest] = [],
        merged: [ProjectBoard.PullRequest] = [],
        repository: GitHubRepository? = nil
    ) -> [ProjectBoard.Row] {
        ProjectBoard.rows(ProjectBoard.Sources(
            repository: repository ?? widgets, local: local, workspaces: workspaces,
            openPullRequests: open, mergedPullRequests: merged
        ))
    }

    private func summary(_ rows: [ProjectBoard.Row]) -> [String] {
        rows.map { row in
            var text = "\(row.group) \(row.name)"
            if let number = row.pullRequest?.number { text += " #\(number)" }
            if !row.workspaces.isEmpty { text += " [\(row.workspaces.map(\.id).joined(separator: ","))]" }
            return text
        }
    }

    // MARK: - Order

    func testTheMainCheckoutComesFirstThenPullRequestsThenWorkspacesThenTheRest() {
        let repository = ProjectBoard.LocalRepository(worktrees: [
            worktree("/p/widgets", branch: "feat/on-main"),
            worktree("/p/widgets.zeta", branch: "zeta"),
            worktree("/p/widgets.feat-b", branch: "feat/b"),
            worktree("/p/widgets.feat-a", branch: "feat/a"),
            worktree("/p/widgets.alpha", branch: "alpha"),
            worktree("/p/widgets.scratch", branch: "scratch")
        ], remotes: [widgets])
        let result = rows(
            local: [repository],
            workspaces: [
                workspace("main", "/p/widgets"),
                workspace("zeta-ws", "/p/widgets.zeta", title: "zeta work"),
                workspace("alpha-ws", "/p/widgets.alpha", title: "alpha work"),
                workspace("b-ws", "/p/widgets.feat-b/Sources")
            ],
            open: [pullRequest(12, "feat/b"), pullRequest(9, "feat/a"), pullRequest(15, "cloud/only")]
        )
        XCTAssertEqual(summary(result), [
            "main main [main]",
            "active feat/a #9",
            "active b-ws #12 [b-ws]",
            "active cloud/only #15",
            "active alpha work [alpha-ws]",
            "active zeta work [zeta-ws]",
            "otherWorktree scratch"
        ])
        XCTAssertEqual(result[0].branch, "feat/on-main", "whatever branch the main checkout is on")
        XCTAssertNil(result[3].worktreePath, "a pull request with no local worktree still has its row")
        XCTAssertFalse(result[3].canCleanUp)
        XCTAssertTrue(result[6].canCleanUp)
        XCTAssertFalse(result[0].canCleanUp, "the main checkout is never cleaned up")
    }

    // MARK: - Matching workspaces

    func testAWorkspaceBelongsToTheInnermostWorktree() {
        let repository = ProjectBoard.LocalRepository(worktrees: [
            worktree("/p/widgets", branch: "main"),
            worktree("/p/widgets/.claude/worktrees/fix", branch: "fix"),
            worktree("/p/widgets-other", branch: "other")
        ], remotes: [widgets])
        let result = rows(local: [repository], workspaces: [
            workspace("nested", "/p/widgets/.claude/worktrees/fix/Tests"),
            workspace("main-sub", "/p/widgets/Sources"),
            workspace("sibling", "/p/widgets-other"),
            workspace("second", "/p/widgets/.claude/worktrees/fix")
        ])
        XCTAssertEqual(summary(result), [
            "main main-sub [main-sub]",
            "active nested [nested,second]",
            "active sibling [sibling]"
        ], "a folder whose name starts like a worktree's is not inside it")
    }

    /// Its worktree removed under it, a workspace doesn't join the
    /// checkout around it: it keeps a row of its own, to be closed.
    func testAWorkspaceWhoseFolderIsGoneGetsItsOwnRow() {
        let repository = ProjectBoard.LocalRepository(worktrees: [
            worktree("/p/widgets", branch: "main"),
            worktree("/p/widgets/.claude/worktrees/fix", branch: "fix", prunable: true)
        ], remotes: [widgets])
        var gone = workspace("gone", "/p/widgets/.claude/worktrees/fix", agent: .exitedMidTurn(processName: "claude"))
        gone.folderIsGone = true
        let result = rows(local: [repository], workspaces: [gone, workspace("main", "/p/widgets")])
        XCTAssertEqual(summary(result), ["main main [main]", "otherRepository gone [gone]"])
        XCTAssertEqual(result[0].agent.state, .none, "the main checkout doesn't take its agent")
        XCTAssertTrue(result[1].folderIsGone)
        XCTAssertTrue(result[1].canCleanUp)
        XCTAssertEqual(ProjectBoardView.subtitle(for: result[1]), "/.../worktrees/fix · folder is gone")
        XCTAssertEqual(ProjectBoardView.actions(for: result[1]).last?.action,
                       .cleanUp(path: "/p/widgets/.claude/worktrees/fix"), "the clean-up closes its workspace")
    }

    func testSeveralWorkspacesShareTheirWorktreeRowWithItsMostUrgentAgent() {
        let repository = ProjectBoard.LocalRepository(worktrees: [
            worktree("/p/widgets", branch: "main"),
            worktree("/p/widgets.fix", branch: "fix")
        ], remotes: [widgets])
        let result = rows(local: [repository], workspaces: [
            workspace("one", "/p/widgets.fix", agent: .working(duration: "3m")),
            workspace("two", "/p/widgets.fix", inactive: true, agent: .waiting(.permission(tool: "Bash", summary: nil))),
            workspace("three", "/p/widgets.fix", agent: .idle)
        ])
        XCTAssertEqual(result[1].workspaces.map(\.id), ["one", "two", "three"])
        XCTAssertEqual(result[1].agent.state, .waiting(.permission(tool: "Bash", summary: nil)))
        XCTAssertEqual(result[1].agent.workspaceID, "two", "Focus goes to the agent that waits")
        XCTAssertEqual(ProjectBoardView.subtitle(for: result[1]), "fix · /p/widgets.fix", "one of them is active")
    }

    // MARK: - Listing entries

    func testBareAndPrunableEntriesGetNoRow() {
        let repository = ProjectBoard.LocalRepository(worktrees: [
            worktree("/p/widgets.git", bare: true),
            worktree("/p/widgets.main", branch: "main"),
            worktree("/p/widgets.gone", branch: "gone", prunable: true)
        ], remotes: [widgets])
        let result = rows(local: [repository], workspaces: [workspace("ws", "/p/widgets.git/hooks")],
                          open: [pullRequest(4, "gone")])
        XCTAssertEqual(summary(result), [
            "active gone #4",
            "otherWorktree main",
            "otherRepository ws [ws]"
        ], "no main row for a bare repository; the pull request of a pruned worktree has no local worktree")
        XCTAssertNil(result[0].worktreePath)
        XCTAssertEqual(result[2].folder, "/p/widgets.git/hooks")
    }

    func testADetachedHeadKeepsItsRowWithoutAPullRequest() {
        let head = "abcdef0123456789abcdef0123456789abcdef01"
        let repository = ProjectBoard.LocalRepository(worktrees: [
            worktree("/p/widgets", branch: "main"),
            worktree("/p/widgets.merging", branch: nil, head: head)
        ], remotes: [widgets])
        let result = rows(local: [repository], open: [pullRequest(7, "merging")])
        XCTAssertEqual(summary(result), [
            "main main",
            "active merging #7",
            "otherWorktree detached HEAD (abcdef0)"
        ])
        XCTAssertNil(result[2].pullRequest)
        XCTAssertEqual(result[2].detachedHead, head)
        XCTAssertNil(result[1].worktreePath, "the PR shows on its own until the worktree is back on its branch")
    }

    // MARK: - Pull requests

    func testAForkPullRequestMatchesNoBranchAndGetsNoRow() {
        let repository = ProjectBoard.LocalRepository(worktrees: [
            worktree("/p/widgets", branch: "main"),
            worktree("/p/widgets.fix", branch: "fix")
        ], remotes: [widgets])
        let result = rows(local: [repository], open: [pullRequest(30, "fix", fork: true), pullRequest(31, "patch-1", fork: true)])
        XCTAssertEqual(summary(result), ["main main", "otherWorktree fix"])
    }

    func testTheNewestOpenPullRequestOfABranchWinsOverAMergedOne() {
        let repository = ProjectBoard.LocalRepository(worktrees: [
            worktree("/p/widgets", branch: "main"),
            worktree("/p/widgets.fix", branch: "fix"),
            worktree("/p/widgets.done", branch: "done")
        ], remotes: [widgets])
        let result = rows(
            local: [repository],
            open: [pullRequest(40, "fix"), pullRequest(44, "fix")],
            merged: [pullRequest(20, "fix", state: "MERGED"), pullRequest(21, "done", state: "MERGED")]
        )
        XCTAssertEqual(summary(result), ["main main", "active fix #44", "otherWorktree done #21"])
        XCTAssertEqual(result[2].pullRequest?.state, "MERGED", "merged, ready to clean up")
    }

    // MARK: - Other repositories

    func testWorkspacesInAnotherRepositoryOrOutsideAnyComeLastWithoutPullRequests() {
        let project = ProjectBoard.LocalRepository(worktrees: [worktree("/p/widgets", branch: "main")], remotes: [widgets])
        let other = ProjectBoard.LocalRepository(worktrees: [
            worktree("/p/gadgets", branch: "main"),
            worktree("/p/gadgets.fix", branch: "fix"),
            worktree("/p/gadgets.idle", branch: "idle")
        ], remotes: [gadgets])
        let result = rows(
            local: [project, other],
            workspaces: [
                workspace("home", "/Users/me"),
                workspace("gadget-fix", "/p/gadgets.fix"),
                workspace("widgets", "/p/widgets"),
                workspace("home-2", "/Users/me")
            ],
            open: [pullRequest(3, "fix")]
        )
        XCTAssertEqual(summary(result), [
            "main widgets [widgets]",
            "active fix #3",
            "otherRepository home [home,home-2]",
            "otherRepository gadget-fix [gadget-fix]"
        ], "sidebar order; gadgets' fix branch isn't the project's, so PR #3 stands alone")
        XCTAssertNil(result[3].pullRequest)
        XCTAssertFalse(result[3].canCleanUp)
    }

    func testWithoutAConfiguredRepositoryNoLocalRepositoryIsTheProjects() {
        let repository = ProjectBoard.LocalRepository(worktrees: [worktree("/p/widgets", branch: "main")], remotes: [widgets])
        let result = ProjectBoard.rows(ProjectBoard.Sources(
            repository: nil, local: [repository], workspaces: [workspace("ws", "/p/widgets")],
            openPullRequests: [pullRequest(1, "main")]
        ))
        XCTAssertEqual(summary(result), ["otherRepository ws [ws]"])
    }

    func testRemotesSpelledDifferentlyStillNameTheRepository() {
        XCTAssertEqual(ProjectBoard.parseRemotes("""
        origin\tgit@github.com:Acme/Widgets.git (fetch)
        origin\tgit@github.com:Acme/Widgets.git (push)
        fork\thttps://github.com/me/widgets (fetch)
        local\t/srv/git/widgets.git (fetch)
        """), [widgets, GitHubRepository(owner: "me", name: "widgets")])
    }
}
