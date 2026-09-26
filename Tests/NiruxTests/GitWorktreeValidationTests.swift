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
        XCTAssertNil(GitWorktree.create(branch: "feat/x", repoRoot: plain).path)
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
        XCTAssertTrue(GitWorktree.isRepositoryTopLevel(alias))
    }

    func testLinkedWorktreeIsStillAcceptedAsRepo() throws {
        // Agents running in a worktree pass its own top level (unchanged
        // behavior; resolving the main repo is a separate change).
        let created = try XCTUnwrap(GitWorktree.create(branch: "feat/x", repoRoot: repo).path)
        XCTAssertTrue(GitWorktree.isRepositoryTopLevel(created))
        let nested = GitWorktree.create(branch: "feat/y", repoRoot: created)
        XCTAssertNil(nested.error)
        XCTAssertEqual(nested.path, root + "/repo.feat-x.feat-y")
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
