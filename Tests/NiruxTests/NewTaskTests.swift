import XCTest
@testable import Nirux

final class NewTaskTests: XCTestCase {
    // MARK: - Names

    func testBranchIsAFeatureSlugOfTheFirstLine() {
        XCTAssertEqual(
            NewTask.suggestedBranch(description: "Add a dark mode toggle\nwith a shortcut", templateName: nil),
            "feat/add-a-dark-mode-toggle"
        )
        XCTAssertEqual(
            NewTask.suggestedBranch(description: "\n\n  Améliorer l’écran d’accueil (v2)!  ", templateName: "Feature (full review cycle)"),
            "feat/ameliorer-l-ecran-d-accueil-v2"
        )
    }

    func testBranchIsAFixForABugTemplateOrAFixWordFirst() {
        XCTAssertEqual(NewTask.suggestedBranch(description: "Sidebar flickers", templateName: "Bugfix"), "fix/sidebar-flickers")
        XCTAssertEqual(NewTask.suggestedBranch(description: "Fix: crash on launch", templateName: nil), "fix/crash-on-launch")
        XCTAssertEqual(NewTask.suggestedBranch(description: "Corriger le menu", templateName: nil), "fix/le-menu")
        XCTAssertEqual(NewTask.suggestedBranch(description: "fix", templateName: nil), "fix/fix")
        // A word saying what is broken stays.
        XCTAssertEqual(NewTask.suggestedBranch(description: "Crash on launch", templateName: nil), "fix/crash-on-launch")
        XCTAssertEqual(NewTask.suggestedBranch(description: "Bug in the parser", templateName: nil), "fix/bug-in-the-parser")
        // Only the first word counts.
        XCTAssertEqual(NewTask.suggestedBranch(description: "Document the fix", templateName: nil), "feat/document-the-fix")
    }

    func testBranchStopsAtAWholeWord() {
        let branch = NewTask.suggestedBranch(
            description: "Make the merge queue retry flaky required checks once before it stops", templateName: nil
        )
        XCTAssertEqual(branch, "feat/make-the-merge-queue-retry-flaky")
        XCTAssertLessThanOrEqual(branch.count - "feat/".count, NewTask.maxSlugLength)
        let longWord = String(repeating: "x", count: 60)
        XCTAssertEqual(NewTask.suggestedBranch(description: longWord, templateName: nil), "feat/" + String(repeating: "x", count: 40))
    }

    func testBranchIsEmptyWithoutALetterOrDigit() {
        XCTAssertEqual(NewTask.suggestedBranch(description: "", templateName: "Bugfix"), "")
        XCTAssertEqual(NewTask.suggestedBranch(description: " — !? ", templateName: nil), "")
    }

    func testSuggestedBranchesAreValidBranchNames() throws {
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: repo) }
        for description in ["..lock", "a..b", "-rf /", "@{u}", "日本語のタスク", "x.lock", "~^:?*[\\"] {
            let branch = NewTask.suggestedBranch(description: description, templateName: nil)
            XCTAssertTrue(branch.isEmpty || GitWorktree.isValidBranchName(branch, repoRoot: repo), "\(description) → \(branch)")
        }
    }

    func testTitleIsTheFirstLineCollapsedAndCut() {
        XCTAssertEqual(NewTask.workspaceTitle(description: "\n  Fix   the\tsidebar  \nmore"), "Fix the sidebar")
        XCTAssertNil(NewTask.workspaceTitle(description: " \n\t"))
        let long = NewTask.workspaceTitle(description: String(repeating: "word ", count: 20))
        XCTAssertEqual(long?.count, NewTask.maxTitleLength)
        XCTAssertEqual(long?.hasSuffix("…"), true)
    }

    // MARK: - Handover

    func testHandoverHoldsTheDescriptionThenTheTemplate() {
        let text = NewTask.handover(
            description: "Fix the sidebar\n\nIt flickers on resize.\n",
            template: TaskTemplates.Template(name: "Bugfix", body: "1. Reproduce."),
            branch: "fix/the-sidebar", start: .fetched("origin/main"), subdirectory: nil
        )
        XCTAssertEqual(text, """
        # Task: Fix the sidebar

        The user started this session from Nirux (New Task…) for the task below, on the new branch \
        `fix/the-sidebar`, created from origin/main, fetched just before. This file is for you only: never commit it.

        ## Task

        Fix the sidebar

        It flickers on resize.

        ## How to proceed (template “Bugfix”)

        1. Reproduce.

        """)
    }

    func testHandoverSaysWhereTheBranchStartedAndWhereTheProjectIs() {
        let stale = NewTask.handover(
            description: "Look", template: nil, branch: "feat/look", start: .lastFetched("origin/main"), subdirectory: "apps/web"
        )
        XCTAssertTrue(stale.contains(
            "created from origin/main as last fetched: Nirux couldn’t fetch it, so fetch and rebase before you push. "
                + "The project lives in `apps/web` of this repository. This file is for you only"
        ), stale)
        for template in [nil, TaskTemplates.Template(name: "Empty", body: "")] {
            let text = NewTask.handover(
                description: "Look", template: template, branch: "feat/look",
                start: .checkoutHead(repository: "/repo", branch: "main"), subdirectory: nil
            )
            XCTAssertTrue(text.contains("created from the HEAD of /repo (main): origin has no default branch"), text)
            XCTAssertFalse(text.contains("How to proceed"), text)
            XCTAssertTrue(text.hasSuffix("## Task\n\nLook\n"), text)
        }
    }

    // MARK: - Repository

    /// Pinned against a developer's global config (hooks, signing).
    private func git(_ arguments: [String], at directory: String) throws {
        let pinned = ["-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false", "-c", "user.name=t", "-c", "user.email=t@t"]
        let result = GitWorktree.gitRunFull(pinned + arguments, cwd: directory)
        guard result.status == 0 else {
            throw NSError(domain: "git", code: Int(result.status), userInfo: [NSLocalizedDescriptionKey: result.stderr])
        }
    }

    private func makeRepository() throws -> (root: String, repo: String) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("nirux-new-task-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let root = try XCTUnwrap(base.path.realPath)
        let repo = root + "/repo"
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"], at: repo)
        try git(["commit", "-q", "--allow-empty", "-m", "one"], at: repo)
        return (root, repo)
    }

    private func folders(_ paths: String..., isWorkspaceFolder: Bool = true) -> [NewTask.Folder] {
        paths.map { NewTask.Folder(path: $0, isWorkspaceFolder: isWorkspaceFolder) }
    }

    func testTargetIsTheMainCheckoutFromAnyOfItsWorktrees() throws {
        let (root, repo) = try makeRepository()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try git(["worktree", "add", "-q", "-b", "feat/a", root + "/repo.feat-a"], at: repo)

        let target = try XCTUnwrap(NewTask.resolveTarget(folders: folders(root, root + "/repo.feat-a"), baseBranch: nil))
        XCTAssertEqual(target.repository, repo)
        // No remote: the checkout's HEAD.
        XCTAssertEqual(target.startPoint, "HEAD")
        XCTAssertNil(target.remoteBranch)
        XCTAssertEqual(target.checkoutBranch, "main")
        XCTAssertNil(target.subdirectory)
        XCTAssertNil(NewTask.resolveTarget(folders: folders(root, root + "/missing"), baseBranch: nil))
    }

    func testTargetKeepsTheProjectsFolderInTheRepositoryButNotATerminals() throws {
        let (root, repo) = try makeRepository()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: repo + "/apps/web", withIntermediateDirectories: true)

        XCTAssertEqual(NewTask.resolveTarget(folders: folders(repo + "/apps/web"), baseBranch: nil)?.subdirectory, "apps/web")
        let terminal = NewTask.resolveTarget(folders: folders(repo + "/apps/web", isWorkspaceFolder: false), baseBranch: nil)
        XCTAssertEqual(terminal?.repository, repo)
        XCTAssertNil(terminal?.subdirectory)
    }

    func testTheWorkspaceOpensInTheProjectsFolderOnlyInsideTheWorktree() throws {
        let (root, worktree) = try makeRepository()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: worktree + "/apps/web", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: root + "/outside", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: worktree + "/apps/linked", withDestinationPath: root + "/outside")
        try "x".write(toFile: worktree + "/apps/file", atomically: true, encoding: .utf8)

        XCTAssertEqual(NewTask.workingDirectory(in: worktree, subdirectory: "apps/web"), worktree + "/apps/web")
        for subdirectory in [nil, "apps/linked", "apps/file", "apps/missing", "../outside"] {
            XCTAssertEqual(NewTask.workingDirectory(in: worktree, subdirectory: subdirectory), worktree, subdirectory ?? "nil")
        }
    }

    func testTargetStartsFromTheBoardBaseThenOriginsDefaultBranch() throws {
        let (root, repo) = try makeRepository()
        defer { try? FileManager.default.removeItem(atPath: root) }
        // Without an origin, the board's base branch has nowhere to come from.
        XCTAssertEqual(try XCTUnwrap(NewTask.resolveTarget(folders: folders(repo), baseBranch: "main")).startPoint, "HEAD")
        try git(["remote", "add", "origin", root + "/origin.git"], at: repo)
        // Remote-tracking refs as a fetch leaves them, without a network.
        try git(["commit", "-q", "--allow-empty", "-m", "two"], at: repo)
        try git(["update-ref", "refs/remotes/origin/develop", "HEAD"], at: repo)
        try git(["update-ref", "refs/remotes/origin/master", "HEAD"], at: repo)
        try git(["update-ref", "refs/remotes/origin/main", "HEAD"], at: repo)

        // origin/HEAD isn't set (a repository made with `git init`): main.
        var target = try XCTUnwrap(NewTask.resolveTarget(folders: folders(repo), baseBranch: nil))
        XCTAssertEqual(target.startPoint, "refs/remotes/origin/main")
        XCTAssertEqual(target.remoteBranch, "main")
        XCTAssertEqual(target.remoteBranchName, "origin/main")
        XCTAssertNil(target.checkoutBranch)

        try git(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/master"], at: repo)
        target = try XCTUnwrap(NewTask.resolveTarget(folders: folders(repo), baseBranch: nil))
        XCTAssertEqual(target.remoteBranch, "master")

        target = try XCTUnwrap(NewTask.resolveTarget(folders: folders(repo), baseBranch: "develop"))
        XCTAssertEqual(target.startPoint, "refs/remotes/origin/develop")
        // Never fetched here: the fetch at Start brings it.
        XCTAssertEqual(try XCTUnwrap(NewTask.resolveTarget(folders: folders(repo), baseBranch: "release/2.0")).remoteBranch, "release/2.0")
        // A base that isn't a branch name (develop~1 is a commit of origin):
        // its default branch.
        for base in ["develop~1", "develop^", "-x"] {
            XCTAssertEqual(try XCTUnwrap(NewTask.resolveTarget(folders: folders(repo), baseBranch: base)).remoteBranch, "master")
        }
    }
}
