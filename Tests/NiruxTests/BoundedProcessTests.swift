import XCTest
@testable import Nirux

final class BoundedProcessTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testCapturedStandardErrorIsDrainedAlongsideStandardOutput() throws {
        // Fills stderr first: a reader that waited on stdout alone would
        // leave the child blocked on a full stderr pipe forever.
        let script = try makeScript("""
        head -c \(Self.largeOutputSize) /dev/zero | tr '\\0' e >&2
        head -c \(Self.largeOutputSize) /dev/zero | tr '\\0' o
        exit 3
        """)

        let result = try XCTUnwrap(BoundedProcess.run(
            executableURL: script,
            arguments: [],
            currentDirectoryURL: directory,
            timeout: 10,
            captureStandardError: true
        ))

        XCTAssertEqual(result.terminationStatus, 3)
        XCTAssertEqual(result.standardOutput, Data(repeating: UInt8(ascii: "o"), count: Self.largeOutputSize))
        XCTAssertEqual(result.standardError, Data(repeating: UInt8(ascii: "e"), count: Self.largeOutputSize))
    }

    func testStandardErrorIsDiscardedUnlessCaptured() throws {
        let script = try makeScript("""
        head -c \(Self.largeOutputSize) /dev/zero | tr '\\0' e >&2
        printf out
        """)

        let result = try XCTUnwrap(BoundedProcess.run(
            executableURL: script,
            arguments: [],
            currentDirectoryURL: directory,
            timeout: 10
        ))

        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertEqual(String(data: result.standardOutput, encoding: .utf8), "out")
        XCTAssertTrue(result.standardError.isEmpty)
    }

    func testBackgroundJobHoldingPipesNeitherDelaysResultNorDies() throws {
        let marker = directory.appendingPathComponent("survived")
        let script = try makeScript("""
        printf out
        printf err >&2
        (sleep 3; echo late; echo late >&2; echo survived > '\(marker.path)') &
        exit 0
        """)

        let startedAt = Date()
        let result = try XCTUnwrap(BoundedProcess.run(
            executableURL: script,
            arguments: [],
            currentDirectoryURL: directory,
            timeout: 20,
            captureStandardError: true
        ))

        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 3)
        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertEqual(String(data: result.standardOutput, encoding: .utf8), "out")
        XCTAssertEqual(String(data: result.standardError, encoding: .utf8), "err")
        // Its late writes land in pipes we no longer read; they must not
        // kill it with SIGPIPE.
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: marker.path), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    func testDescendantWritingForeverIsNotBufferedWithoutBound() throws {
        let pidFile = directory.appendingPathComponent("descendant.pid")
        let script = try makeScript("""
        printf out
        yes &
        printf '%s' "$!" > '\(pidFile.path)'
        exit 0
        """)
        defer { killDescendant(recordedIn: pidFile) }

        let startedAt = Date()
        let result = try XCTUnwrap(BoundedProcess.run(
            executableURL: script,
            arguments: [],
            currentDirectoryURL: directory,
            timeout: 20
        ))

        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 5)
        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertTrue(result.standardOutput.starts(with: Data("out".utf8)))
        XCTAssertLessThan(result.standardOutput.count, 4 << 20)
    }

    func testHungProcessWithCapturedStandardErrorTimesOut() throws {
        let script = try makeScript("""
        [ "$1" = warm ] && exit 0
        trap '' TERM
        while :; do :; done
        """)
        // A fresh file's first exec can be slow; warm it so the trap is in
        // place before SIGTERM and only SIGKILL can end the script.
        _ = BoundedProcess.run(
            executableURL: script,
            arguments: ["warm"],
            currentDirectoryURL: directory,
            timeout: 10
        )

        let startedAt = Date()
        let result = BoundedProcess.run(
            executableURL: script,
            arguments: [],
            currentDirectoryURL: directory,
            timeout: 1,
            captureStandardError: true
        )

        let elapsed = Date().timeIntervalSince(startedAt)
        XCTAssertNil(result)
        XCTAssertGreaterThan(elapsed, 1.2, "SIGTERM should have been ignored")
        XCTAssertLessThan(elapsed, 4)
    }
}

private extension BoundedProcessTests {
    /// Several times the 64 KiB pipe buffer.
    static let largeOutputSize = 512 * 1024

    func makeScript(_ body: String) throws -> URL {
        let script = directory.appendingPathComponent("script-\(UUID().uuidString)")
        try "#!/bin/sh\n\(body)\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    func killDescendant(recordedIn pidFile: URL) {
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return }
        kill(pid, SIGKILL)
    }
}
