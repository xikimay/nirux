import XCTest
@testable import Nirux

/// `GitWorktree.create` inputs can come from a `nirux://new-worktree` URL.
final class GitWorktreeValidationTests: XCTestCase {
    private var root: String!
    private var repo: String!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("nirux-worktree-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        root = try XCTUnwrap(base.path.realPath)
        repo = root + "/repo"
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        try git(["init", "-q"], at: repo)
        try "x\n".write(toFile: repo + "/tracked.txt", atomically: true, encoding: .utf8)
        try git(["add", "tracked.txt"], at: repo)
        try git(["-c", "user.name=Nirux Tests", "-c", "user.email=nirux@example.test",
                 "-c", "commit.gpgsign=false", "commit", "-qm", "initial"], at: repo)
    }

    override func tearDown() {
        if let root { try? FileManager.default.removeItem(atPath: root) }
    }

    private func git(_ arguments: [String], at directory: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "GitWorktreeValidationTests.git", code: Int(process.terminationStatus))
        }
    }

    private func gitOutput(_ arguments: [String], at directory: String) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "GitWorktreeValidationTests.gitOutput", code: Int(process.terminationStatus))
        }
        return (String(bytes: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func commit(_ message: String, at directory: String) throws {
        try git(["-c", "user.name=Nirux Tests", "-c", "user.email=nirux@example.test",
                 "-c", "commit.gpgsign=false", "commit", "-q", "--allow-empty", "-m", message], at: directory)
    }

    func testCreatesAndReusesWorktree() throws {
        let created = GitWorktree.create(branch: "feat/x", repoRoot: repo)
        XCTAssertNil(created.error)
        XCTAssertEqual(created.path, root + "/repo.feat-x")
        XCTAssertTrue(GitWorktree.isLinkedWorktree(at: root + "/repo.feat-x"))

        let reused = GitWorktree.create(branch: "feat/x", repoRoot: repo)
        XCTAssertNil(reused.error)
        XCTAssertEqual(reused.path, root + "/repo.feat-x")
    }

    func testRefusesToReuseDirectoryThatIsNotAWorktree() throws {
        let squatter = root + "/repo.feat-x"
        try FileManager.default.createDirectory(atPath: squatter, withIntermediateDirectories: true)

        let result = GitWorktree.create(branch: "feat/x", repoRoot: repo)
        XCTAssertNil(result.path)
        XCTAssertNotNil(result.error)
    }

    func testRefusesToReuseAWorktreeOnAnotherBranch() throws {
        // "a/b" and "a-b" share the folder name repo.a-b.
        XCTAssertNil(GitWorktree.create(branch: "a/b", repoRoot: repo).error)
        let clash = GitWorktree.create(branch: "a-b", repoRoot: repo)
        XCTAssertNil(clash.path)
        XCTAssertNotNil(clash.error)
    }

    func testRefusesWorktreeOfAnotherRepository() throws {
        let other = root + "/other"
        try FileManager.default.createDirectory(atPath: other, withIntermediateDirectories: true)
        try git(["init", "-q"], at: other)
        try git(["-c", "user.name=Nirux Tests", "-c", "user.email=nirux@example.test",
                 "-c", "commit.gpgsign=false", "commit", "-q", "--allow-empty", "-m", "initial"], at: other)
        try git(["worktree", "add", "-q", root + "/repo.feat-x"], at: other)

        let result = GitWorktree.create(branch: "feat/x", repoRoot: repo)
        XCTAssertNil(result.path)
        XCTAssertNotNil(result.error)
    }

    func testRejectsRepoThatIsNotAGitTopLevel() throws {
        let plain = root + "/plain"
        try FileManager.default.createDirectory(atPath: plain, withIntermediateDirectories: true)
        let notARepo = GitWorktree.create(branch: "feat/x", repoRoot: plain)
        XCTAssertNil(notARepo.path)
        XCTAssertTrue(notARepo.error?.contains("not a git repository") == true, "keeps git's own message")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/plain.feat-x"))

        let subdirectory = repo + "/sub"
        try FileManager.default.createDirectory(atPath: subdirectory, withIntermediateDirectories: true)
        XCTAssertNil(GitWorktree.create(branch: "feat/x", repoRoot: subdirectory).path)
        XCTAssertNil(GitWorktree.create(branch: "feat/x", repoRoot: root + "/missing").path)
        XCTAssertNil(GitWorktree.create(branch: "feat/x", repoRoot: "relative/repo").path)
    }

    func testAcceptsRepoPathSpelledThroughSymlink() throws {
        let alias = root + "/alias"
        try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: repo)
        XCTAssertNil(GitWorktree.repositoryTopLevelProblem(alias))
    }

    func testWorktreeCreatedFromALinkedWorktreeGoesNextToTheMainCheckout() throws {
        // Older skills pass the linked worktree's own top level.
        let created = try XCTUnwrap(GitWorktree.create(branch: "feat/x", repoRoot: repo).path)
        XCTAssertNil(GitWorktree.repositoryTopLevelProblem(created))
        XCTAssertEqual(GitWorktree.mainWorktreeRoot(of: created), repo)
        XCTAssertEqual(GitWorktree.mainWorktreeRoot(of: repo), repo)

        let sibling = GitWorktree.create(branch: "feat/y", repoRoot: created)
        XCTAssertNil(sibling.error)
        XCTAssertEqual(sibling.path, root + "/repo.feat-y")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/repo.feat-x.feat-y"))

        // The same folder is reused whichever checkout asks again.
        XCTAssertEqual(GitWorktree.create(branch: "feat/y", repoRoot: repo).path, root + "/repo.feat-y")
        XCTAssertEqual(GitWorktree.create(branch: "feat/y", repoRoot: created).path, root + "/repo.feat-y")
    }

    func testWorktreeCreatedFromAWorktreeElsewhereGoesNextToTheMainCheckout() throws {
        let elsewhere = root + "/elsewhere/wt"
        try git(["worktree", "add", "-q", "-b", "wt", elsewhere], at: repo)

        let result = GitWorktree.create(branch: "feat/y", repoRoot: elsewhere)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.path, root + "/repo.feat-y")
    }

    func testBareRepositoryInADotGitFolderKeepsWorktreesNextToTheCurrentOne() throws {
        // `project/.git` is bare: `project` is not a work tree, so there is
        // no main checkout and the worktree goes next to the current one.
        let project = root + "/project"
        try FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true)
        try git(["clone", "-q", "--bare", repo, project + "/.git"], at: root)
        try git(["worktree", "add", "-q", "-b", "base", project + "/main"], at: project + "/.git")

        XCTAssertEqual(GitWorktree.mainWorktreeRoot(of: project + "/main"), project + "/main")
        let result = GitWorktree.create(branch: "feat/y", repoRoot: project + "/main")
        XCTAssertNil(result.error)
        XCTAssertEqual(result.path, project + "/main.feat-y")
    }

    func testSeparateGitDirKeepsWorktreesNextToTheCurrentOne() throws {
        let separate = root + "/separate"
        try git(["init", "-q", "--separate-git-dir=" + root + "/separate.gitdir", separate], at: root)
        try git(["-c", "user.name=Nirux Tests", "-c", "user.email=nirux@example.test",
                 "-c", "commit.gpgsign=false", "commit", "-q", "--allow-empty", "-m", "initial"], at: separate)

        let created = try XCTUnwrap(GitWorktree.create(branch: "feat/x", repoRoot: separate).path)
        XCTAssertEqual(created, root + "/separate.feat-x")
        // The git dir doesn't say where the main checkout is.
        XCTAssertEqual(GitWorktree.mainWorktreeRoot(of: created), created)
        XCTAssertEqual(GitWorktree.create(branch: "feat/y", repoRoot: created).path, root + "/separate.feat-x.feat-y")
    }

    func testNewBranchStartsFromTheRequestingCheckout() throws {
        let linked = try XCTUnwrap(GitWorktree.create(branch: "feat/x", repoRoot: repo).path)
        try commit("work on feat/x", at: linked)

        let created = try XCTUnwrap(GitWorktree.create(branch: "feat/y", repoRoot: linked).path)
        XCTAssertEqual(created, root + "/repo.feat-y")
        XCTAssertEqual(try gitOutput(["rev-parse", "HEAD"], at: created), try gitOutput(["rev-parse", "HEAD"], at: linked))
    }

    func testReusesTheWorktreeABranchIsAlreadyCheckedOutIn() throws {
        // Named by an older version after the worktree it was created from.
        let linked = try XCTUnwrap(GitWorktree.create(branch: "feat/x", repoRoot: repo).path)
        let nested = root + "/repo.feat-x.feat-y"
        try git(["worktree", "add", "-q", "-b", "feat/y", nested], at: linked)

        XCTAssertEqual(GitWorktree.create(branch: "feat/y", repoRoot: linked).path, nested)
        XCTAssertEqual(GitWorktree.create(branch: "feat/y", repoRoot: repo).path, nested)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/repo.feat-y"))
    }

    func testRefusesBranchesOfTheMainCheckoutAndOfTheRequestingCheckout() throws {
        // A second agent there would share its files and replace its handover.
        let linked = try XCTUnwrap(GitWorktree.create(branch: "feat/x", repoRoot: repo).path)
        let own = GitWorktree.create(branch: "feat/x", repoRoot: linked)
        XCTAssertNil(own.path)
        XCTAssertEqual(own.error, "feat/x is already checked out in \(linked)")

        let mainBranch = try gitOutput(["branch", "--show-current"], at: repo)
        for requester in [repo!, linked] {
            let main = GitWorktree.create(branch: mainBranch, repoRoot: requester)
            XCTAssertNil(main.path, requester)
            XCTAssertEqual(main.error, "\(mainBranch) is already checked out in the main checkout", requester)
        }
    }

    func testReportsGitsOwnErrorFirst() throws {
        // The panel shows one line: git's "Preparing worktree" must not hide the error.
        let created = try XCTUnwrap(GitWorktree.create(branch: "feat/y", repoRoot: repo).path)
        try FileManager.default.removeItem(atPath: created)

        let result = GitWorktree.create(branch: "feat/y", repoRoot: repo)
        XCTAssertNil(result.path)
        XCTAssertTrue(result.error?.hasPrefix("fatal: ") == true, result.error ?? "")
    }

    /// A `.git` file and a `commondir` tie a folder to `repo`'s git dir,
    /// but `repo` never registered it as a worktree.
    private func makeDecoy() throws -> String {
        let decoy = root + "/decoy"
        let decoyGitDir = root + "/decoy-gitdir"
        try FileManager.default.createDirectory(atPath: decoy, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: decoyGitDir, withIntermediateDirectories: true)
        try "gitdir: ../decoy-gitdir\n".write(toFile: decoy + "/.git", atomically: true, encoding: .utf8)
        try "../repo/.git\n".write(toFile: decoyGitDir + "/commondir", atomically: true, encoding: .utf8)
        try (decoy + "/.git\n").write(toFile: decoyGitDir + "/gitdir", atomically: true, encoding: .utf8)
        try (gitOutput(["rev-parse", "HEAD"], at: repo) + "\n")
            .write(toFile: decoyGitDir + "/HEAD", atomically: true, encoding: .utf8)
        XCTAssertNil(GitWorktree.repositoryTopLevelProblem(decoy))
        return decoy
    }

    func testIgnoresACommonDirThatDoesNotListTheCheckout() throws {
        let decoy = try makeDecoy()
        XCTAssertEqual(GitWorktree.mainWorktreeRoot(of: decoy), decoy)
    }

    func testDoesNotHandAnUnregisteredCheckoutAnExistingWorktree() throws {
        let existing = try XCTUnwrap(GitWorktree.create(branch: "feat/x", repoRoot: repo).path)
        let decoy = try makeDecoy()

        let result = GitWorktree.create(branch: "feat/x", repoRoot: decoy)
        XCTAssertNil(result.path)
        XCTAssertNotNil(result.error)
        XCTAssertEqual(GitWorktree.create(branch: "feat/x", repoRoot: repo).path, existing)
    }

    func testDoesNotHandAFolderPointingAtTheGitDirAnExistingWorktree() throws {
        // To git, a `.git` file naming `repo/.git` makes a main checkout.
        _ = try XCTUnwrap(GitWorktree.create(branch: "feat/x", repoRoot: repo).path)
        let pointer = root + "/pointer"
        try FileManager.default.createDirectory(atPath: pointer, withIntermediateDirectories: true)
        try "gitdir: \(repo!)/.git\n".write(toFile: pointer + "/.git", atomically: true, encoding: .utf8)
        XCTAssertNil(GitWorktree.repositoryTopLevelProblem(pointer))

        XCTAssertNil(GitWorktree.create(branch: "feat/x", repoRoot: pointer).path)
    }

    func testDoesNotReuseAFolderThatReplacedARemovedWorktree() throws {
        // The worktree is deleted without `git worktree prune`, and another
        // folder takes its place: git still lists it on the branch.
        let linked = try XCTUnwrap(GitWorktree.create(branch: "feat/x", repoRoot: repo).path)
        let nested = root + "/repo.feat-x.feat-y"
        try git(["worktree", "add", "-q", "-b", "feat/y", nested], at: linked)
        try FileManager.default.removeItem(atPath: nested)
        try FileManager.default.createDirectory(atPath: nested, withIntermediateDirectories: true)

        let result = GitWorktree.create(branch: "feat/y", repoRoot: repo)
        XCTAssertNil(result.path)
        XCTAssertEqual(result.error, "\(nested) is listed for feat/y but can’t be reused from \(repo!)")

        // Not even by a checkout of the same repository.
        try "gitdir: \(repo!)/.git\n".write(toFile: nested + "/.git", atomically: true, encoding: .utf8)
        XCTAssertNil(GitWorktree.create(branch: "feat/y", repoRoot: repo).path)
    }

    func testANewTaskBranchMustBeNew() throws {
        try git(["branch", "feat/local"], at: repo)
        try git(["update-ref", "refs/remotes/origin/feat/remote", "HEAD"], at: repo)
        _ = try XCTUnwrap(GitWorktree.create(branch: "feat/x", repoRoot: repo).path)
        // Packed, as after `git gc`: git itself wouldn't see Feat/Local.
        try git(["pack-refs", "--all"], at: repo)

        for (branch, existing) in [
            ("Feat/Local", "feat/local"), ("feat/REMOTE", "origin/feat/remote"), ("feat/x", "feat/x")
        ] {
            let result = GitWorktree.create(branch: branch, repoRoot: repo, newBranchFrom: "HEAD")
            XCTAssertNil(result.path, branch)
            XCTAssertEqual(result.error, "\(existing) already exists: choose another branch name")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/repo.Feat-Local"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/repo.feat-REMOTE"))

        // A new branch whose folder is taken.
        try FileManager.default.createDirectory(atPath: root + "/repo.feat-y", withIntermediateDirectories: true)
        let taken = GitWorktree.create(branch: "feat/y", repoRoot: repo, newBranchFrom: "HEAD")
        XCTAssertNil(taken.path)
        XCTAssertEqual(taken.error, "\(root!)/repo.feat-y already exists and is not a worktree of \(repo!)")
        XCTAssertThrowsError(try gitOutput(["rev-parse", "--verify", "refs/heads/feat/y"], at: repo))
    }

    func testANewTaskBranchMayNotHideARemoteButMayShareANestedRemoteBranchsEnd() throws {
        try git(["remote", "add", "upstream", root + "/nowhere"], at: repo)
        try git(["update-ref", "refs/remotes/upstream/alice/feat/z", "HEAD"], at: repo)

        let shadowing = GitWorktree.create(branch: "Upstream/main", repoRoot: repo, newBranchFrom: "HEAD")
        XCTAssertNil(shadowing.path)
        XCTAssertEqual(shadowing.error, "Upstream/main starts with the name of the remote upstream: choose another branch name")
        XCTAssertNotNil(GitWorktree.create(branch: "feat/z", repoRoot: repo, newBranchFrom: "HEAD").path)
    }

    func testANewTaskBranchIsntOneAWorktreeHasNotCommittedToYet() throws {
        let orphan = root + "/orphan"
        // `worktree add --orphan` needs git 2.42.
        try git(["worktree", "add", "-q", "--detach", orphan], at: repo)
        try git(["checkout", "-q", "--orphan", "feat/orphan"], at: orphan)
        let result = GitWorktree.create(branch: "feat/orphan", repoRoot: repo, newBranchFrom: "HEAD")
        XCTAssertNil(result.path)
        XCTAssertEqual(result.error, "feat/orphan is already checked out in \(orphan): choose another branch name")
    }

    func testANewTaskBranchStartsFromTheStartPointWithoutTrackingIt() throws {
        try git(["update-ref", "refs/remotes/origin/main", "HEAD"], at: repo)
        try commit("only in the main checkout", at: repo)

        let created = try XCTUnwrap(
            GitWorktree.create(branch: "feat/task", repoRoot: repo, newBranchFrom: "refs/remotes/origin/main").path
        )
        XCTAssertEqual(created, root + "/repo.feat-task")
        XCTAssertEqual(try gitOutput(["rev-parse", "HEAD"], at: created), try gitOutput(["rev-parse", "refs/remotes/origin/main"], at: repo))
        XCTAssertNotEqual(try gitOutput(["rev-parse", "HEAD"], at: created), try gitOutput(["rev-parse", "HEAD"], at: repo))
        XCTAssertEqual(GitWorktree.currentBranch(at: created), "feat/task")
        XCTAssertThrowsError(try gitOutput(["rev-parse", "--abbrev-ref", "feat/task@{upstream}"], at: created))
        XCTAssertEqual(
            GitWorktree.create(branch: "feat/other", repoRoot: repo, newBranchFrom: "refs/remotes/origin/gone").error,
            "refs/remotes/origin/gone isn’t a commit of \(repo!)"
        )
    }

    func testAFailingHookAfterTheCheckoutStillHandsOverTheWorktree() throws {
        let hooks = root + "/hooks"
        try FileManager.default.createDirectory(atPath: hooks, withIntermediateDirectories: true)
        try "#!/bin/sh\necho 'hook failed' >&2\nexit 2\n".write(toFile: hooks + "/post-checkout", atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hooks + "/post-checkout")
        try git(["config", "core.hooksPath", hooks], at: repo)

        let result = GitWorktree.create(branch: "feat/hooked", repoRoot: repo, newBranchFrom: "HEAD")
        XCTAssertEqual(result.path, root + "/repo.feat-hooked")
        XCTAssertEqual(result.error, "hook failed")
        XCTAssertEqual(GitWorktree.currentBranch(at: root + "/repo.feat-hooked"), "feat/hooked")
    }

    func testAFailedCheckoutLeavesNoBranchBehind() throws {
        // A required filter that fails, as git-lfs does when it's missing.
        try ".gitattributes filter=broken\n".write(toFile: repo + "/.gitattributes", atomically: true, encoding: .utf8)
        try git(["add", ".gitattributes"], at: repo)
        try commit("filtered", at: repo)
        try git(["config", "filter.broken.smudge", "false"], at: repo)
        try git(["config", "filter.broken.required", "true"], at: repo)

        let result = GitWorktree.create(branch: "feat/filtered", repoRoot: repo, newBranchFrom: "HEAD")
        XCTAssertNil(result.path)
        XCTAssertNotNil(result.error)
        XCTAssertThrowsError(try gitOutput(["rev-parse", "--verify", "refs/heads/feat/filtered"], at: repo))
        // So the same name can be tried again.
        try git(["config", "filter.broken.required", "false"], at: repo)
        XCTAssertNotNil(GitWorktree.create(branch: "feat/filtered", repoRoot: repo, newBranchFrom: "HEAD").path)
    }

    func testFetchUpdatesTheRemoteBranchOrSaysWhyNot() throws {
        let origin = root + "/origin.git"
        try git(["init", "-q", "--bare", origin], at: root)
        let branch = try gitOutput(["symbolic-ref", "--short", "HEAD"], at: repo)
        try git(["remote", "add", "origin", origin], at: repo)
        // No pre-push hook of the developer's runs.
        let push = ["-c", "core.hooksPath=/dev/null", "push", "-q", "origin", "HEAD:refs/heads/\(branch)"]
        try git(push, at: repo)
        // Someone pushes to origin after this checkout's last fetch.
        try commit("pushed by someone else", at: repo)
        try git(push, at: repo)
        try git(["reset", "-q", "--hard", "HEAD~1"], at: repo)
        try git(["update-ref", "refs/remotes/origin/\(branch)", "HEAD"], at: repo)

        XCTAssertNil(GitWorktree.fetch(branch: branch, repoRoot: repo))
        XCTAssertEqual(
            try gitOutput(["rev-parse", "refs/remotes/origin/\(branch)"], at: repo),
            try gitOutput(["rev-parse", "refs/heads/\(branch)"], at: origin)
        )
        XCTAssertNotEqual(try gitOutput(["rev-parse", "refs/remotes/origin/\(branch)"], at: repo), try gitOutput(["rev-parse", "HEAD"], at: repo))

        try git(["remote", "set-url", "origin", root + "/gone.git"], at: repo)
        let error = try XCTUnwrap(GitWorktree.fetch(branch: branch, repoRoot: repo))
        XCTAssertTrue(error.hasPrefix("fatal:"), error)
    }

    func testHandoversAreExcludedOnceForEveryWorktree() throws {
        let exclude = root + "/repo/.git/info/exclude"
        try "# mine\n.claude-handover.md".write(toFile: exclude, atomically: true, encoding: .utf8)
        let linked = try XCTUnwrap(GitWorktree.create(branch: "feat/x", repoRoot: repo).path)

        XCTAssertTrue(GitWorktree.ensureExcluded(NiruxShellView.excludedHandovers, repoRoot: linked))
        XCTAssertTrue(GitWorktree.ensureExcluded(NiruxShellView.excludedHandovers, repoRoot: repo))
        XCTAssertEqual(
            try String(contentsOfFile: exclude, encoding: .utf8),
            "# mine\n.claude-handover.md\n# Nirux handovers (New Task…)\n.codex-handover.md\n"
        )
        // In a folder of the worktree too, where a project's task starts.
        try FileManager.default.createDirectory(atPath: linked + "/sub", withIntermediateDirectories: true)
        for folder in [linked, linked + "/sub"] {
            for name in [".claude-handover.md", ".codex-handover.md"] {
                try "task".write(toFile: folder + "/" + name, atomically: true, encoding: .utf8)
            }
        }
        XCTAssertEqual(try gitOutput(["status", "--porcelain"], at: linked), "")

        // Never written through a link.
        try FileManager.default.removeItem(atPath: exclude)
        try FileManager.default.createSymbolicLink(atPath: exclude, withDestinationPath: root + "/elsewhere")
        XCTAssertFalse(GitWorktree.ensureExcluded(NiruxShellView.excludedHandovers, repoRoot: repo))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/elsewhere"))
    }

    func testRejectsInvalidBranchNames() {
        for branch in ["", "-b", "--detach", "a..b", "a b", "a~1", "feat/", "@{-1}"] {
            let result = GitWorktree.create(branch: branch, repoRoot: repo)
            XCTAssertNil(result.path, branch)
            XCTAssertNotNil(result.error, branch)
        }
        XCTAssertTrue(GitWorktree.isValidBranchName("feat/x-1", repoRoot: repo))
    }
}
