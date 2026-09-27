import XCTest
@testable import Nirux

final class GitCommandTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testStatusLargerThanPipeBuffersIsReadInFull() throws {
        // What the editor's Changes section runs, on enough untracked files
        // (long names) to print several times the 64 KiB pipe buffer.
        try git(["init", "-q"])
        let names = (0..<1_400).map { String(format: "%04d-", $0) + String(repeating: "x", count: 195) }
        for name in names {
            try Data().write(to: directory.appendingPathComponent(name))
        }

        let output = try XCTUnwrap(GitCommand.output(
            ["status", "--porcelain", "--untracked-files=all"],
            cwd: directory.path,
            timeout: 30
        ))

        XCTAssertGreaterThan(output.utf8.count, Self.largeOutputSize)
        XCTAssertEqual(output.split(separator: "\n").map { String($0.dropFirst(3)) }, names)
    }

    func testDiffOriginalsLargerThanPipeBuffersAreReadInFull() throws {
        let file = directory.appendingPathComponent("large.txt")
        let base = Self.largeText("base")
        let branchTip = Self.largeText("branch tip")
        try git(["init", "-q", "-b", "main"])
        try base.write(to: file, atomically: true, encoding: .utf8)
        try commit("large.txt", message: "base")
        try git(["checkout", "-q", "-b", "feature"])
        try branchTip.write(to: file, atomically: true, encoding: .utf8)
        try commit("large.txt", message: "branch tip")
        try Self.largeText("working copy").write(to: file, atomically: true, encoding: .utf8)

        XCTAssertEqual(originalContent(of: file, mode: .head), .text(branchTip))
        XCTAssertEqual(originalContent(of: file, mode: .branch), .text(base))
    }

    func testDiffOriginalOverTheLimitIsSizedButNotLoaded() throws {
        // Deleted, so only the blob's own size can flag it as too large.
        let file = directory.appendingPathComponent("large.txt")
        let base = Self.largeText("base")
        try git(["init", "-q", "-b", "main"])
        try base.write(to: file, atomically: true, encoding: .utf8)
        try commit("large.txt", message: "base")
        try FileManager.default.removeItem(at: file)

        XCTAssertEqual(
            originalContent(of: file, mode: .head, maxBytes: 64 * 1024),
            .tooLarge(byteCount: UInt64(base.utf8.count))
        )
        XCTAssertEqual(originalContent(of: file, mode: .head), .text(base))
    }

    func testUntrackedFileDiffsAgainstAnEmptyOriginal() throws {
        let file = directory.appendingPathComponent("new.txt")
        try git(["init", "-q", "-b", "main"])
        try "tracked\n".write(to: directory.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        try commit("tracked.txt", message: "base")
        try "new\n".write(to: file, atomically: true, encoding: .utf8)

        XCTAssertEqual(originalContent(of: file, mode: .head), .text(""))
        XCTAssertEqual(originalContent(of: file, mode: .branch), .text(""))
    }

    func testStatusLeavesTheIndexUntouched() throws {
        // A touched but unchanged file: plain `git status` would refresh
        // and rewrite the index, holding index.lock meanwhile.
        let file = directory.appendingPathComponent("file.txt")
        try git(["init", "-q"])
        try "content\n".write(to: file, atomically: true, encoding: .utf8)
        try commit("file.txt", message: "base")
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_577_836_800)],
            ofItemAtPath: file.path
        )
        let index = directory.appendingPathComponent(".git/index")
        let indexBefore = try Data(contentsOf: index)

        XCTAssertEqual(GitCommand.output(["status", "--porcelain"], cwd: directory.path), "")
        XCTAssertEqual(try Data(contentsOf: index), indexBefore)
    }

    func testLargeStandardErrorNeitherStallsGitNorLeaksIntoOutput() {
        // Real git, via a shell alias, writing well past the pipe buffer on
        // stderr before stdout (as a chatty hook would).
        let spew = "!head -c \(Self.largeOutputSize) /dev/zero | tr '\\0' e >&2; printf done"

        let output = GitCommand.output(
            ["-c", "alias.spew=\(spew)", "spew"],
            cwd: directory.path,
            timeout: 10
        )

        XCTAssertEqual(output, "done")
    }

    func testFailingGitReturnsNil() throws {
        try git(["init", "-q"])

        XCTAssertNil(GitCommand.output(["show", "HEAD:missing.txt"], cwd: directory.path))
    }

    func testGitThatNeverFinishesTimesOut() throws {
        let fakeGit = directory.appendingPathComponent("hung-git")
        try "#!/bin/sh\ntrap '' TERM\nwhile :; do :; done\n"
            .write(to: fakeGit, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeGit.path)

        let startedAt = Date()
        let output = GitCommand.output(["status"], cwd: directory.path, gitPath: fakeGit.path, timeout: 0.1)

        XCTAssertNil(output)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 3)
    }

    func testBranchBaseRefFallsBackToMainWithoutUpstream() throws {
        try git(["init", "-q", "-b", "main"])
        try "base\n".write(to: directory.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        try commit("file.txt", message: "base")
        let forkPoint = try git(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        try git(["checkout", "-q", "-b", "feature"])
        try "feature\n".write(to: directory.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        try commit("file.txt", message: "feature")

        XCTAssertEqual(GitCommand.branchBaseRef(cwd: directory.path), forkPoint)
    }

    func testBranchBaseRefIsNilWithoutUpstreamOrDefaultBranch() throws {
        try git(["init", "-q", "-b", "trunk"])
        try "base\n".write(to: directory.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        try commit("file.txt", message: "base")

        XCTAssertNil(GitCommand.branchBaseRef(cwd: directory.path))
    }
}

private extension GitCommandTests {
    /// Several times the 64 KiB pipe buffer.
    static let largeOutputSize = 256 * 1024

    static func largeText(_ label: String) -> String {
        var text = ""
        var line = 0
        while text.utf8.count <= largeOutputSize {
            text += "\(label) line \(line)\n"
            line += 1
        }
        return text
    }

    func originalContent(
        of file: URL,
        mode: EditorDiffMode,
        maxBytes: UInt64 = EditorFileLimits.maxEditableBytes
    ) -> EditorColumn.DiffOriginal? {
        EditorColumn.gitOriginalContent(of: file.path, cwd: directory.path, mode: mode, maxBytes: maxBytes)
    }

    func commit(_ path: String, message: String) throws {
        try git(["add", path])
        try git([
            "-c", "user.name=Nirux Tests",
            "-c", "user.email=nirux@example.test",
            "-c", "commit.gpgsign=false",
            "-c", "core.hooksPath=/dev/null",
            "commit", "-qm", message
        ])
    }

    /// Fixture setup, with git's own error in the thrown one.
    @discardableResult
    func git(_ arguments: [String]) throws -> String {
        let result = try XCTUnwrap(BoundedProcess.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: arguments,
            currentDirectoryURL: directory,
            timeout: 30,
            captureStandardError: true
        ))
        guard result.terminationStatus == 0 else {
            let message = String(data: result.standardError, encoding: .utf8) ?? ""
            throw NSError(
                domain: "GitCommandTests.Git",
                code: Int(result.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")): \(message)"]
            )
        }
        return String(data: result.standardOutput, encoding: .utf8) ?? ""
    }
}
