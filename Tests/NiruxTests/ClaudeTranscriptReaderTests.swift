import XCTest
@testable import Nirux

final class ClaudeTranscriptReaderTests: XCTestCase {
    private var directory: URL!
    private var file: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nirux-transcript-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        file = directory.appendingPathComponent("session.jsonl")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ text: String) throws {
        try Data(text.utf8).write(to: file)
    }

    private func append(_ text: String) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    func testReadsOnlyWhatWasAppendedAndWaitsForUnfinishedLines() throws {
        let first = TranscriptLine.response(id: "msg_1", cacheRead: 10_000, output: 5)
        let second = TranscriptLine.response(id: "msg_2", cacheRead: 20_000, output: 7)
        try write(first + "\n" + String(second.prefix(40)))
        var reader = ClaudeTranscriptReader(path: file.path, chunkSize: 7)

        XCTAssertTrue(reader.readAppended())
        XCTAssertEqual(reader.usage.responses, 1)
        XCTAssertEqual(reader.usage.contextTokens, 10_002)

        XCTAssertTrue(reader.readAppended())
        XCTAssertEqual(reader.usage.responses, 1, "nothing new")

        try append(String(second.dropFirst(40)))
        XCTAssertTrue(reader.readAppended())
        XCTAssertEqual(reader.usage.responses, 1, "the line has no newline yet")

        try append("\n")
        XCTAssertTrue(reader.readAppended())
        XCTAssertEqual(reader.usage.responses, 2)
        XCTAssertEqual(reader.usage.totals.output, 12)
        XCTAssertEqual(reader.usage.contextTokens, 20_002)
    }

    func testBudgetSplitsACatchUpAcrossReads() throws {
        let lines = (1...50).map { TranscriptLine.response(id: "msg_\($0)", cacheRead: $0 * 1_000, output: 1) }
        try write(lines.joined(separator: "\n") + "\n")
        var reader = ClaudeTranscriptReader(path: file.path, chunkSize: 64)

        var reads = 1
        while !reader.readAppended(budget: 1_000) { reads += 1 }
        XCTAssertGreaterThan(reads, 5)
        XCTAssertEqual(reader.usage.responses, 50)
        XCTAssertEqual(reader.usage.contextTokens, 50_002)
    }

    func testStartsOverWhenTheFileIsReplacedOrTruncated() throws {
        try write(TranscriptLine.response(id: "msg_1", cacheRead: 90_000, output: 5) + "\n")
        var reader = ClaudeTranscriptReader(path: file.path)
        XCTAssertTrue(reader.readAppended())
        XCTAssertEqual(reader.usage.responses, 1)

        // Replaced (new inode), even with a longer file.
        let replacement = directory.appendingPathComponent("replacement.jsonl")
        let lines = [
            TranscriptLine.response(id: "msg_a", cacheRead: 1_000, output: 1),
            TranscriptLine.response(id: "msg_b", cacheRead: 2_000, output: 1)
        ]
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: replacement)
        _ = try FileManager.default.replaceItemAt(file, withItemAt: replacement)
        XCTAssertTrue(reader.readAppended())
        XCTAssertEqual(reader.usage.responses, 2)
        XCTAssertEqual(reader.usage.peakContextTokens, 2_002)

        // Truncated in place.
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data((TranscriptLine.response(id: "msg_c", cacheRead: 3_000, output: 1) + "\n").utf8))
        try handle.close()
        XCTAssertTrue(reader.readAppended())
        XCTAssertEqual(reader.usage.responses, 1)
        XCTAssertEqual(reader.usage.contextTokens, 3_002)
    }

    func testOverlongLinesAreSkippedWhole() throws {
        let huge = TranscriptLine.response(
            id: "msg_huge", cacheRead: 500_000, output: 9,
            extra: ["padding": String(repeating: "x", count: 5_000)]
        )
        let small = TranscriptLine.response(id: "msg_small", cacheRead: 4_000, output: 1)
        try write(small + "\n" + huge + "\n" + small.replacingOccurrences(of: "msg_small", with: "msg_next") + "\n")
        for chunkSize in [16, 1_000, 64 * 1024] {
            var reader = ClaudeTranscriptReader(path: file.path, chunkSize: chunkSize, maxLineBytes: 2_000)
            XCTAssertTrue(reader.readAppended())
            XCTAssertEqual(reader.usage.responses, 2, "chunk \(chunkSize)")
            XCTAssertEqual(reader.usage.peakContextTokens, 4_002, "chunk \(chunkSize)")
        }
    }

    func testMissingOrNonRegularFilesLeaveTheUsageAlone() throws {
        var missing = ClaudeTranscriptReader(path: file.path)
        XCTAssertTrue(missing.readAppended())
        XCTAssertEqual(missing.usage, ClaudeSessionUsage())

        var folder = ClaudeTranscriptReader(path: directory.path)
        XCTAssertTrue(folder.readAppended())
        XCTAssertEqual(folder.usage, ClaudeSessionUsage())

        // Written lazily: the file appears after the session binds.
        try write(TranscriptLine.response(id: "msg_1", cacheRead: 1_000) + "\n")
        XCTAssertTrue(missing.readAppended())
        XCTAssertEqual(missing.usage.responses, 1)
    }

    @MainActor
    func testFollowerReportsOnTheMainActorAndStopsOnceCancelled() throws {
        try write(TranscriptLine.response(id: "msg_1", cacheRead: 30_000, output: 3) + "\n")
        let follower = ClaudeUsageFollower(path: file.path, owner: self)
        let reported = expectation(description: "usage")
        follower.refresh { usage in
            MainActor.assertIsolated()
            XCTAssertEqual(usage.contextTokens, 30_002)
            reported.fulfill()
        }
        wait(for: [reported], timeout: 5)

        // A fresh follower (no throttle yet) proves `cancel`, not the
        // minimum interval, is what silences it.
        let cancelled = ClaudeUsageFollower(path: file.path, owner: self)
        cancelled.cancel()
        let silent = expectation(description: "no report after cancel")
        silent.isInverted = true
        cancelled.refresh { _ in silent.fulfill() }
        wait(for: [silent], timeout: 0.3)

        // Cancelled while its read is in flight.
        let midRead = ClaudeUsageFollower(path: file.path, owner: self)
        let dropped = expectation(description: "no report for a read cancelled in flight")
        dropped.isInverted = true
        midRead.refresh { _ in dropped.fulfill() }
        midRead.cancel()
        wait(for: [dropped], timeout: 0.3)
    }

    @MainActor
    func testFollowerStopsWhenItsOwnerIsGone() throws {
        try write(TranscriptLine.response(id: "msg_1", cacheRead: 30_000, output: 3) + "\n")
        var owner: NSObject? = NSObject()
        let follower = ClaudeUsageFollower(path: file.path, owner: owner!)
        owner = nil
        let silent = expectation(description: "no report once the owner is gone")
        silent.isInverted = true
        follower.refresh { _ in silent.fulfill() }
        wait(for: [silent], timeout: 0.3)
    }

    @MainActor
    func testFollowerReportsOnlyOnceCaughtUp() throws {
        // More than one default budget: the catch-up takes several reads.
        let line = TranscriptLine.response(
            id: "msg_old", cacheRead: 5_000, output: 1,
            extra: ["padding": String(repeating: "x", count: 1_000_000)]
        )
        let history = (0..<20).map { line.replacingOccurrences(of: "msg_old", with: "msg_\($0)") }
        let last = TranscriptLine.response(id: "msg_last", cacheRead: 42_000, output: 1)
        try write((history + [last]).joined(separator: "\n") + "\n")

        let follower = ClaudeUsageFollower(path: file.path, owner: self)
        let reported = expectation(description: "usage")
        follower.refresh { usage in
            XCTAssertEqual(usage.responses, 21, "never a mid-history snapshot")
            XCTAssertEqual(usage.contextTokens, 42_002)
            reported.fulfill()
        }
        wait(for: [reported], timeout: 10)
    }
}
