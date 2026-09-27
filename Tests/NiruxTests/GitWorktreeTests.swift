import XCTest
@testable import Nirux

final class GitWorktreeTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testGitRunFullReturnsOutputLargerThanPipeBuffers() {
        // Real git, via a shell alias, writing well past the 64 KiB pipe
        // buffer on stderr before stdout (as a chatty hook would).
        let size = 256 * 1024
        let spew = "!head -c \(size) /dev/zero | tr '\\0' e >&2; head -c \(size) /dev/zero | tr '\\0' o"

        let result = GitWorktree.gitRunFull(
            ["-c", "alias.spew=\(spew)", "spew"],
            cwd: directory.path,
            timeout: 10
        )

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout, String(repeating: "o", count: size))
        XCTAssertEqual(result.stderr, String(repeating: "e", count: size))
    }

    func testGitRunFullReportsGitThatNeverFinishes() throws {
        let fakeGit = directory.appendingPathComponent("hung-git")
        try "#!/bin/sh\ntrap '' TERM\nwhile :; do :; done\n"
            .write(to: fakeGit, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeGit.path)

        let startedAt = Date()
        let result = GitWorktree.gitRunFull(
            ["worktree", "add", "-b", "feature", directory.appendingPathComponent("wt").path],
            cwd: directory.path,
            gitPath: fakeGit.path,
            timeout: 0.1
        )

        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 3)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(result.stderr, "git could not start or timed out after 0.1s")
    }

    /// Runs a git write in the test repo, pinned against a developer's global
    /// config: hooks (core.hooksPath, templates) and commit or tag signing
    /// would otherwise make it fail or behave differently.
    private func isolatedGit(_ args: [String]) -> Int32 {
        let pinned = [
            "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false", "-c", "tag.gpgSign=false",
            "-c", "user.name=t", "-c", "user.email=t@t"
        ]
        return GitWorktree.gitRunFull(pinned + args, cwd: directory.path).status
    }

    func testCurrentBranchReadsCheckedOutBranchAndNilWhenDetached() {
        let repo = directory.path
        XCTAssertEqual(isolatedGit(["init", "-q", "--template=", "-b", "feat/names"]), 0)
        XCTAssertEqual(isolatedGit(["commit", "-q", "--allow-empty", "-m", "x"]), 0)

        // A tag with the branch's name must not turn it into "heads/feat/names".
        XCTAssertEqual(isolatedGit(["tag", "feat/names"]), 0)
        XCTAssertEqual(GitWorktree.currentBranch(at: repo), "feat/names")

        // On a case-insensitive volume (the macOS default), the same folder
        // typed in another case is still that checkout.
        if FileManager.default.fileExists(atPath: repo.uppercased()) {
            XCTAssertEqual(GitWorktree.currentBranch(at: repo.uppercased()), "feat/names")
        }

        // A plain folder inside the checkout is not a checkout of its own.
        let inner = directory.appendingPathComponent("inner")
        XCTAssertNoThrow(try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true))
        XCTAssertNil(GitWorktree.currentBranch(at: inner.path))

        XCTAssertEqual(isolatedGit(["checkout", "-q", "--detach"]), 0)
        XCTAssertNil(GitWorktree.currentBranch(at: repo))
    }

    func testCurrentBranchIsNilOutsideARepository() {
        XCTAssertNil(GitWorktree.currentBranch(at: directory.path))
        XCTAssertNil(GitWorktree.currentBranch(at: directory.appendingPathComponent("gone").path))
    }

    func testGitRunFullReportsMissingDirectory() {
        let missing = directory.appendingPathComponent("gone").path

        let result = GitWorktree.gitRunFull(["status"], cwd: missing)

        XCTAssertNotEqual(result.status, 0)
        XCTAssertEqual(result.stderr, "No such directory: \(missing)")
    }
}
