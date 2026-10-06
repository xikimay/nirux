import Darwin
import XCTest
@testable import Nirux

/// Exercises the real /tmp: the source rules are about that directory.
final class HandoverFileTests: XCTestCase {
    private var cleanup: [String] = []
    private var worktree: String!

    override func setUpWithError() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nirux-handover-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        worktree = directory.path
        cleanup.append(directory.path)
    }

    override func tearDown() {
        for path in cleanup {
            try? FileManager.default.removeItem(atPath: path)
        }
        cleanup = []
    }

    private func tmpPath(_ prefix: String = HandoverFile.filenamePrefix) -> String {
        let path = "/tmp/\(prefix)test-\(UUID().uuidString).md"
        cleanup.append(path)
        return path
    }

    private func write(_ content: String, to path: String) throws {
        try content.write(toFile: path, atomically: false, encoding: .utf8)
    }

    private func transfer(_ source: String) -> Result<Data, HandoverFile.TransferError> {
        HandoverFile.transfer(from: source, toDirectory: worktree, filename: ".claude-handover.md")
    }

    private func failure(_ source: String) -> HandoverFile.TransferError? {
        if case .failure(let error) = transfer(source) { return error }
        return nil
    }

    private var destination: String { worktree + "/.claude-handover.md" }

    func testMovesRegularFileIntoWorktree() throws {
        let source = tmpPath()
        try write("# Session Handover\n", to: source)

        XCTAssertEqual(String(decoding: try transfer(source).get(), as: UTF8.self), "# Session Handover\n", "what was moved")
        XCTAssertEqual(try String(contentsOfFile: destination, encoding: .utf8), "# Session Handover\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source))
        let permissions = try FileManager.default.attributesOfItem(atPath: destination)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }

    func testPrivateTmpSpellingIsAccepted() throws {
        let source = tmpPath()
        try write("handover", to: source)
        XCTAssertNoThrow(try transfer("/private" + source).get())
        XCTAssertEqual(try String(contentsOfFile: destination, encoding: .utf8), "handover")
    }

    func testRejectsSymlinkToAnotherFile() throws {
        let victim = worktree + "/victim.txt"
        try write("private", to: victim)
        let source = tmpPath()
        try FileManager.default.createSymbolicLink(atPath: source, withDestinationPath: victim)

        XCTAssertEqual(failure(source), .cannotOpen(ELOOP))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination))
        XCTAssertEqual(try String(contentsOfFile: victim, encoding: .utf8), "private")
    }

    func testRejectsHardLinkedFile() throws {
        let original = tmpPath("nirux-other-")
        try write("private", to: original)
        let source = tmpPath()
        XCTAssertEqual(link(original, source), 0)

        XCTAssertEqual(failure(source), .multipleLinks)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source))
    }

    func testRejectsFifoWithoutBlocking() throws {
        let source = tmpPath()
        XCTAssertEqual(mkfifo(source, 0o600), 0)
        XCTAssertEqual(failure(source), .notRegularFile)
    }

    func testRejectsOversizedFile() throws {
        let source = tmpPath()
        try Data(repeating: 0x61, count: HandoverFile.maxBytes + 1).write(to: URL(fileURLWithPath: source))
        XCTAssertEqual(failure(source), .tooLarge)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source))
    }

    func testRejectsPathsOutsideTmp() throws {
        let outside = worktree + "/\(HandoverFile.filenamePrefix)x.md"
        try write("handover", to: outside)
        XCTAssertEqual(failure(outside), .notAllowedPath)

        let unprefixed = tmpPath("notes-")
        try write("handover", to: unprefixed)
        XCTAssertEqual(failure(unprefixed), .notAllowedPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination))
    }

    func testDestinationSymlinkIsReplacedNotFollowed() throws {
        // A repo could commit `.claude-handover.md` as a symlink to a
        // user file; writing the handover must not go through it.
        let victim = worktree + "/victim.txt"
        try write("private", to: victim)
        try FileManager.default.createSymbolicLink(atPath: destination, withDestinationPath: victim)
        let source = tmpPath()
        try write("handover", to: source)

        XCTAssertNoThrow(try transfer(source).get())
        XCTAssertEqual(try String(contentsOfFile: victim, encoding: .utf8), "private")
        let type = try FileManager.default.attributesOfItem(atPath: destination)[.type] as? FileAttributeType
        XCTAssertEqual(type, .typeRegular)
        XCTAssertEqual(try String(contentsOfFile: destination, encoding: .utf8), "handover")
    }

    func testEmptySourceIsPrivateUnguessableAndAccepted() throws {
        let source = try XCTUnwrap(HandoverFile.makeEmptySource(agent: "claude"))
        cleanup.append(source)
        XCTAssertTrue(source.hasPrefix("/tmp/nirux-handover-claude-"))
        XCTAssertNotEqual(source, HandoverFile.makeEmptySource(agent: "claude").map { cleanup.append($0); return $0 })
        let attributes = try FileManager.default.attributesOfItem(atPath: source)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(attributes[.size] as? Int, 0)

        try write("filled by the agent", to: source)
        XCTAssertNoThrow(try transfer(source).get())
        XCTAssertEqual(try String(contentsOfFile: destination, encoding: .utf8), "filled by the agent")
    }

    func testEmptyFileIsNotADeliveredHandover() throws {
        let source = tmpPath()
        try write("", to: source)
        XCTAssertEqual(failure(source), .empty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination))
    }

    func testComposedHandoverIsPrivateAndNeverWrittenThroughASymlink() throws {
        let victim = worktree + "/victim.txt"
        try write("private", to: victim)
        try FileManager.default.createSymbolicLink(atPath: destination, withDestinationPath: victim)

        XCTAssertNoThrow(try HandoverFile.deliver("# Task", toDirectory: worktree, filename: ".claude-handover.md").get())
        XCTAssertEqual(try String(contentsOfFile: victim, encoding: .utf8), "private")
        let attributes = try FileManager.default.attributesOfItem(atPath: destination)
        XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeRegular)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(try String(contentsOfFile: destination, encoding: .utf8), "# Task")
    }

    func testReplacesStaleHandover() throws {
        try write("stale", to: destination)
        let source = tmpPath()
        try write("fresh", to: source)
        XCTAssertNoThrow(try transfer(source).get())
        XCTAssertEqual(try String(contentsOfFile: destination, encoding: .utf8), "fresh")
    }
}
