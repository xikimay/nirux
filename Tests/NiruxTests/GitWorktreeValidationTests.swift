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

    func testNewWorktreeIgnoresHandoverFiles() throws {
        // A repository whose template left no info/ folder.
        try FileManager.default.removeItem(atPath: repo + "/.git/info")

        let created = try XCTUnwrap(GitWorktree.create(branch: "feat/x", repoRoot: repo).path)
        try git(["check-ignore", "-q", ".claude-handover.md"], at: created)
        try git(["check-ignore", "-q", ".codex-handover.md"], at: created)
        try git(["check-ignore", "-q", ".claude-handover.md"], at: repo)
        // Only the handovers Nirux writes, at the top level.
        XCTAssertThrowsError(try git(["check-ignore", "-q", "docs/.claude-handover.md"], at: created))

        // Reusing a worktree made before this change covers it too.
        try "".write(toFile: repo + "/.git/info/exclude", atomically: true, encoding: .utf8)
        XCTAssertEqual(GitWorktree.create(branch: "feat/x", repoRoot: repo).path, created)
        try git(["check-ignore", "-q", ".claude-handover.md"], at: created)
    }

    func testHandoverExcludeKeepsExistingPatternsAndAddsEachNameOnce() throws {
        let exclude = repo + "/.git/info/exclude"
        try "# mine\n*.log".write(toFile: exclude, atomically: true, encoding: .utf8)

        let linked = try XCTUnwrap(GitWorktree.create(branch: "feat/x", repoRoot: repo).path)
        XCTAssertNil(GitWorktree.create(branch: "feat/x", repoRoot: repo).error)
        XCTAssertNil(GitWorktree.create(branch: "feat/y", repoRoot: linked).error)

        XCTAssertEqual(
            try String(contentsOfFile: exclude, encoding: .utf8),
            "# mine\n*.log\n/.claude-handover.md\n/.codex-handover.md\n"
        )
    }

    func testHandoverExcludeAppendsToBytesItCannotDecode() throws {
        let exclude = repo + "/.git/info/exclude"
        let latin1 = Data("# caf".utf8) + Data([0xE9]) + Data("\r\n/.claude-handover.md\r\n".utf8)
        try latin1.write(to: URL(fileURLWithPath: exclude))

        XCTAssertNil(GitWorktree.create(branch: "feat/x", repoRoot: repo).error)

        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: exclude)), latin1 + Data("/.codex-handover.md\n".utf8))
    }

    func testHandoverExcludeDoesNotWriteThroughASymlink() throws {
        let target = root + "/elsewhere"
        try "keep\n".write(toFile: target, atomically: true, encoding: .utf8)
        let exclude = repo + "/.git/info/exclude"
        try FileManager.default.removeItem(atPath: exclude)
        try FileManager.default.createSymbolicLink(atPath: exclude, withDestinationPath: target)

        XCTAssertNil(GitWorktree.create(branch: "feat/x", repoRoot: repo).error)

        XCTAssertEqual(try String(contentsOfFile: target, encoding: .utf8), "keep\n")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: exclude), target)
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

    func testRejectsInvalidBranchNames() {
        for branch in ["", "-b", "--detach", "a..b", "a b", "a~1", "feat/", "@{-1}"] {
            let result = GitWorktree.create(branch: branch, repoRoot: repo)
            XCTAssertNil(result.path, branch)
            XCTAssertNotNil(result.error, branch)
        }
        XCTAssertTrue(GitWorktree.isValidBranchName("feat/x-1", repoRoot: repo))
    }
}
