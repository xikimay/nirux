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

    func testOutputLeftAtExitIsKeptWhileDescendantHoldsPipes() throws {
        let pidFile = directory.appendingPathComponent("descendant.pid")
        let script = try makeScript("""
        sleep 30 &
        printf '%s' "$!" > '\(pidFile.path)'
        head -c 60000 /dev/zero | tr '\\0' o
        exit 0
        """)
        defer { killDescendant(recordedIn: pidFile) }

        let result = try XCTUnwrap(BoundedProcess.run(
            executableURL: script,
            arguments: [],
            currentDirectoryURL: directory,
            timeout: 20
        ))

        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertEqual(result.standardOutput, Data(repeating: UInt8(ascii: "o"), count: 60000))
    }

    func testRunawayDescendantIsNeitherBufferedNorKeptAlive() throws {
        let pidFile = directory.appendingPathComponent("descendant.pid")
        let script = try makeScript("""
        yes &
        printf '%s' "$!" > '\(pidFile.path)'
        printf out
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
        XCTAssertLessThan(result.standardOutput.count, 4 << 20)
        // Past the discard allowance the pipe is closed on it.
        let pid = try XCTUnwrap(pid_t(String(contentsOf: pidFile, encoding: .utf8)))
        let deadline = Date().addingTimeInterval(10)
        while kill(pid, 0) == 0, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertNotEqual(kill(pid, 0), 0, "runaway descendant is still alive")
    }

    func testStandardOutputPastTheLimitStopsTheProcess() throws {
        let script = try makeScript("""
        head -c \(Self.largeOutputSize) /dev/zero | tr '\\0' o
        sleep 20
        """)

        let startedAt = Date()
        let limited = BoundedProcess.run(
            executableURL: script,
            arguments: [],
            currentDirectoryURL: directory,
            timeout: 20,
            maxStandardOutputBytes: Self.largeOutputSize - 1
        )

        XCTAssertNil(limited)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 5)
        let exact = try XCTUnwrap(BoundedProcess.run(
            executableURL: try makeScript("head -c \(Self.largeOutputSize) /dev/zero | tr '\\0' o"),
            arguments: [],
            currentDirectoryURL: directory,
            timeout: 20,
            maxStandardOutputBytes: Self.largeOutputSize
        ))
        XCTAssertEqual(exact.standardOutput.count, Self.largeOutputSize)
    }

    func testTooManyArgumentsFailInsteadOfRaising() throws {
        // Process.run() raises an Objective-C exception past 4,096
        // arguments, which would crash the app.
        let result = BoundedProcess.run(
            executableURL: URL(fileURLWithPath: "/bin/echo"),
            arguments: Array(repeating: "x", count: 5_000),
            currentDirectoryURL: directory,
            timeout: 10
        )

        XCTAssertNil(result)
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

    /// Standard input much larger than a pipe's buffer, written while the
    /// child writes as much back: neither side waits on the other. Each
    /// chunk of output is reported as it is read.
    func testStandardInputIsWrittenWhileOutputIsRead() throws {
        let input = Data((0..<Self.largeOutputSize * 4).map { UInt8(truncatingIfNeeded: $0 % 251) })
        let chunks = Chunks()
        let outcome = try XCTUnwrap(BoundedProcess.execute(
            executableURL: URL(fileURLWithPath: "/bin/cat"),
            arguments: [],
            currentDirectoryURL: directory,
            standardInput: input,
            timeout: 10,
            onStandardOutput: { chunks.append($0) }
        ))

        XCTAssertNil(outcome.stop)
        XCTAssertEqual(outcome.terminationStatus, 0)
        XCTAssertEqual(outcome.standardOutput, input)
        XCTAssertEqual(chunks.data, input)
    }

    /// A child that exits without reading its input ends the write: no
    /// SIGPIPE, which would kill Nirux.
    func testChildThatDoesntReadItsInputEndsTheWrite() throws {
        let outcome = try XCTUnwrap(BoundedProcess.execute(
            executableURL: try makeScript("printf done"),
            arguments: [],
            currentDirectoryURL: directory,
            standardInput: Data(repeating: 1, count: Self.largeOutputSize * 4),
            timeout: 10
        ))

        XCTAssertEqual(outcome.terminationStatus, 0)
        XCTAssertEqual(String(decoding: outcome.standardOutput, as: UTF8.self), "done")
    }

    /// A descendant that keeps the child's standard input open without
    /// reading it doesn't hold the run: it returns once the child exits,
    /// and the writer lets go of the pipe though the descendant still runs.
    func testDescendantHoldingStandardInputDoesntHoldTheRun() throws {
        let pidFile = directory.appendingPathComponent("pid")
        defer { killDescendant(recordedIn: pidFile) }
        let script = try makeScript("""
        exec 3<&0
        sleep 30 <&3 3<&- >/dev/null 2>&1 &
        echo $! > '\(pidFile.path)'
        printf done
        """)

        let descriptors = Self.openDescriptorCount()
        let startedAt = Date()
        let outcome = try XCTUnwrap(BoundedProcess.execute(
            executableURL: script,
            arguments: [],
            currentDirectoryURL: directory,
            standardInput: Data(repeating: 1, count: Self.largeOutputSize * 4),
            timeout: 20
        ))

        XCTAssertEqual(outcome.terminationStatus, 0)
        XCTAssertEqual(String(decoding: outcome.standardOutput, as: UTF8.self), "done")
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 10)
        // The writer gives up within its 50 ms poll and closes its end.
        let deadline = Date().addingTimeInterval(5)
        while Self.openDescriptorCount() > descriptors, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        XCTAssertLessThanOrEqual(Self.openDescriptorCount(), descriptors)
    }

    /// A replaced environment holds only what it lists: none of Nirux's
    /// variables (here, the test runner's) reach the child.
    func testReplacedEnvironmentHoldsOnlyItsVariables() throws {
        XCTAssertNotNil(ProcessInfo.processInfo.environment["PATH"])
        let outcome = try XCTUnwrap(BoundedProcess.execute(
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: [],
            currentDirectoryURL: directory,
            environment: .replaced(["ONLY": "this"]),
            timeout: 10
        ))

        XCTAssertEqual(String(decoding: outcome.standardOutput, as: UTF8.self), "ONLY=this\n")
    }

    /// A run cancelled once it wrote stops at once, and keeps what the
    /// child wrote.
    func testCancelledRunStopsAndKeepsItsOutput() throws {
        let script = try makeScript("""
        printf first
        exec sleep 30
        """)
        let cancellation = BoundedProcess.Cancellation()

        let startedAt = Date()
        let outcome = try XCTUnwrap(BoundedProcess.execute(
            executableURL: script,
            arguments: [],
            currentDirectoryURL: directory,
            timeout: 30,
            cancellation: cancellation,
            onStandardOutput: { _ in cancellation.cancel() }
        ))

        XCTAssertEqual(outcome.stop, .cancelled)
        XCTAssertNil(outcome.terminationStatus)
        XCTAssertEqual(String(decoding: outcome.standardOutput, as: UTF8.self), "first")
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 10)
    }

    /// A child that closed its output but runs on is still cancelled.
    func testCancelAfterTheChildClosedItsOutput() throws {
        let script = try makeScript("""
        exec >/dev/null 2>&1
        exec sleep 30
        """)
        let cancellation = BoundedProcess.Cancellation()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { cancellation.cancel() }

        let startedAt = Date()
        let outcome = try XCTUnwrap(BoundedProcess.execute(
            executableURL: script,
            arguments: [],
            currentDirectoryURL: directory,
            timeout: 30,
            cancellation: cancellation
        ))

        XCTAssertEqual(outcome.stop, .cancelled)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 10)
    }

    /// A run that times out, or writes past its limit, keeps what the
    /// child wrote until then: `run` returns nil for both, as before.
    func testStoppedRunsKeepTheirOutput() throws {
        let timedOut = try XCTUnwrap(BoundedProcess.execute(
            executableURL: try makeScript("printf first\nexec sleep 30"),
            arguments: [],
            currentDirectoryURL: directory,
            timeout: 3
        ))
        XCTAssertEqual(timedOut.stop, .timedOut)
        XCTAssertEqual(String(decoding: timedOut.standardOutput, as: UTF8.self), "first")

        let limited = try XCTUnwrap(BoundedProcess.execute(
            executableURL: try makeScript("head -c \(Self.largeOutputSize) /dev/zero | tr '\\0' o\nexec sleep 30"),
            arguments: [],
            currentDirectoryURL: directory,
            timeout: 20,
            maxStandardOutputBytes: 1_000
        ))
        XCTAssertEqual(limited.stop, .outputLimit)
        XCTAssertGreaterThan(limited.standardOutput.count, 1_000)
        XCTAssertTrue(limited.standardOutput.allSatisfy { $0 == UInt8(ascii: "o") })
    }
}

/// Chunks of output, appended on the waiting thread.
private final class Chunks: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = Data()

    func append(_ chunk: Data) {
        lock.withLock { stored.append(chunk) }
    }

    var data: Data {
        lock.withLock { stored }
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

    /// The test process's open descriptors.
    static func openDescriptorCount() -> Int {
        (0..<Int32(getdtablesize())).filter { fcntl($0, F_GETFD) != -1 }.count
    }

    func killDescendant(recordedIn pidFile: URL) {
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return }
        kill(pid, SIGKILL)
    }
}
