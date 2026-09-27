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

        XCTAssertEqual(EditorColumn.gitOriginalContent(of: file.path, cwd: directory.path, mode: .head), branchTip)
        XCTAssertEqual(EditorColumn.gitOriginalContent(of: file.path, cwd: directory.path, mode: .branch), base)
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

    func testBranchBaseRefIsWhereTheBranchForkedFromMain() throws {
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

    func commit(_ path: String, message: String) throws {
        try git(["add", path])
        try git([
            "-c", "user.name=Nirux Tests",
            "-c", "user.email=nirux@example.test",
            "-c", "commit.gpgsign=false",
            "commit", "-qm", message
        ])
    }

    /// Setup only, with small output: read to EOF before waiting on exit.
    @discardableResult
    func git(_ arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "GitCommandTests.Git", code: Int(process.terminationStatus))
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
