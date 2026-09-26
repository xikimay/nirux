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
}
