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

    func testAPlainWorkspaceIsNamedAfterItsFolder() {
        XCTAssertEqual(NewTask.folderTitle("/Users/me/Projects/nirux", home: "/Users/me"), "nirux")
        XCTAssertEqual(NewTask.folderTitle("/Users/me/", home: "/Users/me"), "~")
        XCTAssertEqual(NewTask.folderTitle("/Users/me", home: "/Users/me/"), "~")
        XCTAssertEqual(NewTask.folderTitle("/", home: "/Users/me"), "/")
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

        The user started this session from Nirux (⌘N) for the task below, on the new branch \
        `fix/the-sidebar`, created from origin/main, fetched just before. This file is for you only: never commit it.

        ## Task

        Fix the sidebar

        It flickers on resize.

        ## How to proceed (template “Bugfix”)

        1. Reproduce.

        """)
    }

    func testHandoverSaysWhereTheBranchStartedAndWhereTheSpaceWorks() {
        let stale = NewTask.handover(
            description: "Look", template: nil, branch: "feat/look", start: .lastFetched("origin/main"), subdirectory: "apps/web"
        )
        XCTAssertTrue(stale.contains(
            "created from origin/main as last fetched: Nirux couldn’t fetch it, so fetch and rebase before you push. "
                + "The space works in `apps/web` of this repository. This file is for you only"
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

    // MARK: - Tasks without a repository

    func testAFolderIsNamedAfterTheFirstLine() {
        XCTAssertEqual(NewTask.suggestedFolderName(description: "\n  Compare   two\tlibraries  \nmore"), "Compare two libraries")
        // Finder shows ":" as "/"; a leading "." hides the folder.
        XCTAssertEqual(NewTask.suggestedFolderName(description: "Notes: Q3/Q4 plan"), "Notes- Q3-Q4 plan")
        XCTAssertEqual(NewTask.suggestedFolderName(description: "..hidden draft"), "hidden draft")
        XCTAssertEqual(NewTask.suggestedFolderName(description: "Café, “quoted” 日本"), "Café, “quoted” 日本")
        // Cut at a whole word, never past the limit.
        let long = NewTask.suggestedFolderName(description: String(repeating: "word ", count: 20))
        XCTAssertEqual(long, Array(repeating: "word", count: 10).joined(separator: " "))
        XCTAssertLessThanOrEqual(long.count, NewTask.maxFolderNameLength)
        XCTAssertEqual(NewTask.suggestedFolderName(description: String(repeating: "x", count: 80)), String(repeating: "x", count: 50))
        for nothing in ["", " \n\t", "..."] {
            XCTAssertEqual(NewTask.suggestedFolderName(description: nothing), "Task", nothing)
        }
        XCTAssertEqual(NewTask.suggestedFolderName(description: "/"), "-")
    }

    func testATypedFolderNameIsCleaned() {
        XCTAssertEqual(NewTask.cleanedFolderName("  .config\u{7}  backup "), "config backup")
        // Emoji keep their joiners; a bidi override goes.
        XCTAssertEqual(NewTask.cleanedFolderName("Team 👩‍💻 notes"), "Team 👩‍💻 notes")
        XCTAssertEqual(NewTask.cleanedFolderName("invoice\u{202E}fdp.app"), "invoicefdp.app")
        XCTAssertEqual(NewTask.cleanedFolderName("Re\u{200B}search\u{FEFF}"), "Research", "two names that look the same are one")
        XCTAssertNil(NewTask.cleanedFolderName(" . . "))
        XCTAssertNil(NewTask.cleanedFolderName(""))
        // APFS takes 255 bytes: "name 999" must still fit.
        let wide = NewTask.cleanedFolderName(String(repeating: "日", count: 100))
        XCTAssertLessThanOrEqual(wide?.utf8.count ?? .max, NewTask.maxFolderNameBytes)
        XCTAssertEqual(wide?.isEmpty, false)
    }

    func testAFolderIsAlwaysANewOne() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("nirux-task-folders-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: base) }
        let parent = base + "/Nirux Tasks"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        // Another folder that's gone: nothing is made.
        guard case .failure(let gone) = NewTask.makeFolder(named: "Research", in: parent, makesParent: false) else {
            return XCTFail("a parent that's gone isn't made again")
        }
        XCTAssertTrue(gone.message.hasSuffix("is gone: nothing was made."), gone.message)
        XCTAssertFalse(FileManager.default.fileExists(atPath: parent))
        // Never a whole path: a volume not mounted stays so.
        guard case .failure = NewTask.makeFolder(named: "Research", in: base + "/missing/Tasks", makesParent: true) else {
            return XCTFail("only the folder itself is made")
        }
        // The default tasks folder is made the first time.
        XCTAssertEqual(NewTask.makeFolder(named: "Research", in: parent, makesParent: true), .success(parent + "/Research"))
        // Taken, by a folder or a file: the next number.
        XCTAssertEqual(NewTask.makeFolder(named: "Research", in: parent, makesParent: false), .success(parent + "/Research 2"))
        try Data().write(to: URL(fileURLWithPath: parent + "/Research 3"))
        XCTAssertEqual(NewTask.makeFolder(named: "Research", in: parent, makesParent: false), .success(parent + "/Research 4"))
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: parent + "/Research 4", isDirectory: &isDirectory) && isDirectory.boolValue)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent + "/Research"), [], "never one already there")
    }

    func testAFolderCantGoUnderAFile() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("nirux-task-file-\(UUID().uuidString)")
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        guard case .failure(let error) = NewTask.makeFolder(named: "Research", in: file.path, makesParent: true) else {
            return XCTFail("a file can't hold a folder")
        }
        XCTAssertTrue(error.message.hasSuffix("is a file, not a folder: nothing was made."), error.message)
    }

    func testAFolderIsOutsideGitOnlyWithNoGitAbove() throws {
        let (root, repo) = try makeRepository()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: repo + "/docs/notes", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: root + "/notes", withIntermediateDirectories: true)
        XCTAssertFalse(NewTask.isOutsideGit(repo + "/docs/notes"), "inside a repository, even one git can't read now")
        XCTAssertTrue(NewTask.isOutsideGit(root + "/notes"))
        XCTAssertFalse(NewTask.isOutsideGit(root + "/gone"), "a folder that isn't there tells nothing")
    }

    func testAFolderHandoverNamesTheFolderAndNoBranch() {
        let text = NewTask.folderHandover(
            description: "Compare two libraries\n\nWhich one parses faster?\n",
            template: TaskTemplates.Template(name: "Investigation", body: "Write a summary."),
            folder: "/Users/me/Nirux Tasks/Compare two libraries"
        )
        XCTAssertEqual(text, """
        # Task: Compare two libraries

        The user started this session from Nirux (⌘N) for the task below, in `/Users/me/Nirux Tasks/Compare two libraries`, \
        a new folder Nirux made for it: no repository, no branch. Change no git repository from here: if the task \
        needs one, say so. This file is for you only.

        ## Task

        Compare two libraries

        Which one parses faster?

        ## How to proceed (template “Investigation”)

        Write a summary.

        """)
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

    func testTargetIsTheMainCheckoutFromAnyOfItsWorktrees() throws {
        let (root, repo) = try makeRepository()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try git(["worktree", "add", "-q", "-b", "feat/a", root + "/repo.feat-a"], at: repo)

        let target = try XCTUnwrap(NewTask.resolveTarget(folder: root + "/repo.feat-a", baseBranch: nil))
        XCTAssertEqual(target.repository, repo)
        // No remote: the checkout's HEAD.
        XCTAssertEqual(target.startPoint, "HEAD")
        XCTAssertNil(target.remoteBranch)
        XCTAssertEqual(target.checkoutBranch, "main")
        XCTAssertNil(target.subdirectory)
        XCTAssertNil(NewTask.resolveTarget(folder: root, baseBranch: nil), "in no repository")
        XCTAssertNil(NewTask.resolveTarget(folder: root + "/missing", baseBranch: nil))
    }

    /// A folder anchor inside a repository: its tasks open in that folder.
    func testTargetKeepsTheSpacesFolderInTheRepository() throws {
        let (root, repo) = try makeRepository()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: repo + "/apps/web", withIntermediateDirectories: true)

        let target = NewTask.resolveTarget(folder: repo + "/apps/web", baseBranch: nil)
        XCTAssertEqual(target?.repository, repo)
        XCTAssertEqual(target?.subdirectory, "apps/web")
    }

    /// Each repository anchor has its own board base; a repository the
    /// board doesn't set up has none; a space anchored to no repository
    /// uses its one config, as before anchors (docs/spaces.md, S12).
    func testTheBoardBaseIsEachRepositorysOwn() throws {
        let (root, repo) = try makeRepository()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try git(["worktree", "add", "-q", "-b", "feat/a", root + "/repo.feat-a"], at: repo)
        let other = root + "/other"
        try FileManager.default.createDirectory(atPath: other, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"], at: other)
        let third = root + "/third"
        try FileManager.default.createDirectory(atPath: third, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"], at: third)
        var repository = try XCTUnwrap(FolderIdentity.identify(repo, timeout: 10)).anchor
        repository.isDefault = true
        let otherAnchor = try XCTUnwrap(FolderIdentity.identify(other, timeout: 10)).anchor
        let thirdAnchor = try XCTUnwrap(FolderIdentity.identify(third, timeout: 10)).anchor
        let state = URL(fileURLWithPath: root + "/state")
        let store = try XCTUnwrap(BoardConfigStore(spaceID: "space", stateDirectory: state))
        let config = { (base: String) in
            BoardConfig(repository: "acme/\(base)", baseBranch: base, requiredChecks: ["test"], postMergeWorkflow: .noWorkflow)
        }
        let base = { (folder: String, anchors: [SpaceAnchor]) in
            NiruxShellView.boardBaseBranch(for: folder, spaceID: "space", anchors: anchors, stateDirectory: state)
        }
        let anchors = [repository, otherAnchor, thirdAnchor]

        // Schema 1: the default repository's, as no remote names it.
        XCTAssertNoThrow(try store.save(config("develop")).get())
        XCTAssertEqual(base(root + "/repo.feat-a", anchors), "develop")
        XCTAssertNil(base(other, anchors))
        XCTAssertEqual(base(other, []), "develop", "no repository anchor: the one config")
        try FileManager.default.createDirectory(atPath: repo + "/apps", withIntermediateDirectories: true)
        XCTAssertEqual(base(root + "/repo.feat-a", [.folder(repo + "/apps")]), "develop", "the folder anchor's repository")
        XCTAssertNil(base(other, [.folder(repo + "/apps")]), "not another repository")

        // Schema 2: each its own; the third has none.
        let commonDir = { (anchor: SpaceAnchor) in try XCTUnwrap(BoardSections.commonDir(of: anchor)) }
        XCTAssertNoThrow(try store.save(entries: [
            BoardConfigStore.Entry(slot: .anchor(commonDir: try commonDir(repository)), config: config("develop")),
            BoardConfigStore.Entry(slot: .anchor(commonDir: try commonDir(otherAnchor)), config: config("trunk"))
        ]).get())
        XCTAssertEqual(base(root + "/repo.feat-a", anchors), "develop")
        XCTAssertEqual(base(other, anchors), "trunk")
        XCTAssertNil(base(third, anchors))
        XCTAssertNil(base(root, anchors), "in no repository")
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
        XCTAssertEqual(try XCTUnwrap(NewTask.resolveTarget(folder: repo, baseBranch: "main")).startPoint, "HEAD")
        try git(["remote", "add", "origin", root + "/origin.git"], at: repo)
        // Remote-tracking refs as a fetch leaves them, without a network.
        try git(["commit", "-q", "--allow-empty", "-m", "two"], at: repo)
        try git(["update-ref", "refs/remotes/origin/develop", "HEAD"], at: repo)
        try git(["update-ref", "refs/remotes/origin/master", "HEAD"], at: repo)
        try git(["update-ref", "refs/remotes/origin/main", "HEAD"], at: repo)

        // origin/HEAD isn't set (a repository made with `git init`): main.
        var target = try XCTUnwrap(NewTask.resolveTarget(folder: repo, baseBranch: nil))
        XCTAssertEqual(target.startPoint, "refs/remotes/origin/main")
        XCTAssertEqual(target.remoteBranch, "main")
        XCTAssertEqual(target.remoteBranchName, "origin/main")
        XCTAssertNil(target.checkoutBranch)

        try git(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/master"], at: repo)
        target = try XCTUnwrap(NewTask.resolveTarget(folder: repo, baseBranch: nil))
        XCTAssertEqual(target.remoteBranch, "master")

        target = try XCTUnwrap(NewTask.resolveTarget(folder: repo, baseBranch: "develop"))
        XCTAssertEqual(target.startPoint, "refs/remotes/origin/develop")
        // Never fetched here: the fetch at Start brings it.
        XCTAssertEqual(try XCTUnwrap(NewTask.resolveTarget(folder: repo, baseBranch: "release/2.0")).remoteBranch, "release/2.0")
        // A base that isn't a branch name (develop~1 is a commit of origin):
        // its default branch.
        for base in ["develop~1", "develop^", "-x"] {
            XCTAssertEqual(try XCTUnwrap(NewTask.resolveTarget(folder: repo, baseBranch: base)).remoteBranch, "master")
        }
    }
}
