import XCTest
@testable import Nirux

/// Search Everywhere in Claude transcripts (see TranscriptSearch), on
/// throwaway files: what is searched, what is kept, and the bounds.
final class TranscriptSearchTests: XCTestCase {
    private var folder = ""

    override func setUpWithError() throws {
        try super.setUpWithError()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("nirux-transcripts-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: folder)
        super.tearDown()
    }

    private func line(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    private func prompt(_ text: Any, at timestamp: String = "2026-10-04T10:00:00.000Z", extra: [String: Any] = [:]) throws -> String {
        try line(["type": "user", "timestamp": timestamp, "message": ["role": "user", "content": text]].merging(extra) { $1 })
    }

    private func answer(_ parts: [[String: Any]], extra: [String: Any] = [:]) throws -> String {
        try line(["type": "assistant", "message": ["role": "assistant", "content": parts]].merging(extra) { $1 })
    }

    private func write(_ lines: [String], trailingNewline: Bool = true) throws -> String {
        let path = folder + "/\(UUID().uuidString).jsonl"
        try (lines.joined(separator: "\n") + (trailingNewline ? "\n" : "")).write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    private func search(_ needle: String, in path: String, limit: Int = 5, maxBytes: Int = TranscriptSearch.maxBytesPerTranscript,
                        chunkSize: Int = TranscriptSearch.chunkSize, budget: inout TranscriptSearch.Budget) -> TranscriptSearch.Result? {
        TranscriptSearch.search(needle, transcriptAt: path, limit: limit, budget: &budget, maxBytes: maxBytes, chunkSize: chunkSize)
    }

    private func search(_ needle: String, in path: String, limit: Int = 5) -> TranscriptSearch.Result? {
        var budget = TranscriptSearch.Budget.standard()
        return search(needle, in: path, limit: limit, budget: &budget)
    }

    /// What the user typed and Claude answered; not tool calls, tool
    /// output, thinking, task notifications, command output, summaries,
    /// API errors, meta or subagent lines.
    func testOnlyWhatTheUserTypedAndClaudeAnsweredIsSearched() throws {
        let path = try write([
            try prompt("Fix the BILLING rounding", extra: ["origin": ["kind": "human"]]),
            try answer([["type": "thinking", "thinking": "billing thoughts"], ["type": "tool_use", "text": "billing", "input": [:]]]),
            try prompt([["type": "tool_result", "content": "billing.swift:12"]]),
            try prompt("billing caveat", extra: ["isMeta": true]),
            try prompt("<task-notification>billing done</task-notification>", extra: ["origin": ["kind": "task-notification"]]),
            try prompt("billing, from another session", extra: ["origin": ["kind": "peer"]]),
            try prompt("<local-command-stdout>billing</local-command-stdout>"),
            try prompt("Summary: billing work so far", extra: ["isCompactSummary": true]),
            try prompt("billing shown in the transcript only", extra: ["isVisibleInTranscriptOnly": true]),
            try prompt([["type": "text", "text": "[Request interrupted by user]"]]),
            try prompt("<bash-stdout>billing.swift</bash-stdout><bash-stderr></bash-stderr>"),
            try prompt([
                ["type": "text", "text": "<system-reminder>billing reminder</system-reminder>"],
                ["type": "text", "text": "also check the billing totals"]
            ]),
            try prompt("<command-name>/review</command-name><command-args>the billing parser</command-args>"),
            try prompt("<command-message>review</command-message><command-name>/review</command-name><command-args></command-args>"),
            try answer([["type": "text", "text": "API Error: billing"]], extra: ["isApiErrorMessage": true]),
            try answer([["type": "text", "text": "subagent billing"]], extra: ["isSidechain": true]),
            "{ not json billing",
            try line(["type": "attachment", "attachment": [
                "type": "queued_command", "commandMode": "prompt", "prompt": "and the billing tests",
                "origin": ["kind": "human"], "timestamp": "2026-10-04T10:05:00.000Z"
            ]]),
            try line(["type": "attachment", "attachment": [
                "type": "queued_command", "commandMode": "prompt", "prompt": "peer billing", "origin": ["kind": "peer"]
            ]]),
            try answer([["type": "text", "text": "Done: the billing module rounds up now."]])
        ])
        let result = try XCTUnwrap(search("billing", in: path, limit: 10))
        XCTAssertEqual(
            result.matches.map(\.excerpt),
            ["Done: the billing module rounds up now.", "and the billing tests", "the billing parser",
             "also check the billing totals", "Fix the BILLING rounding"]
        )
        XCTAssertEqual(result.matches.map(\.role), [.claude, .user, .user, .user, .user])
        XCTAssertEqual(result.total, 5)
        XCTAssertEqual(result.matches.last?.highlight, NSRange(location: 8, length: 7))
        XCTAssertEqual(result.matches[1].timestamp, ISO8601DateFormatter().date(from: "2026-10-04T10:05:00Z"))
        XCTAssertEqual(search("interrupted", in: path)?.total, 0)
        XCTAssertFalse(result.isCut)
        XCTAssertFalse(result.isPartial)
    }

    /// The name it was given, and Claude's own title; the last of each wins.
    func testBothTitlesAreRead() throws {
        let path = try write([
            try line(["type": "custom-title", "customTitle": "feat/x · web"]),
            try line(["type": "ai-title", "aiTitle": "Old title"]),
            try line(["type": "ai-title", "aiTitle": "Fix billing rounding"]),
            // A tool's input with a "-title" key is no title.
            try answer([["type": "text", "text": "page needle"]], extra: ["meta": ["page-title": "x"]])
        ])
        let result = try XCTUnwrap(search("needle", in: path))
        XCTAssertEqual(result.customTitle, "feat/x · web")
        XCTAssertEqual(result.aiTitle, "Fix billing rounding")
        XCTAssertEqual(result.total, 1)
    }

    /// JSON writes quotes, backslashes and newlines escaped: the needle is
    /// looked for the way it is written.
    func testANeedleWithQuotesOrBackslashesMatches() throws {
        let path = try write([try prompt("run print(\"hi\") in C:\\Users\nthen stop")])
        XCTAssertEqual(search("print(\"hi\")", in: path)?.total, 1)
        XCTAssertEqual(search("C:\\Users", in: path)?.total, 1)
        XCTAssertEqual(search("Users\nthen", in: path)?.total, 1)
    }

    func testTheNewestMatchesAreKeptAndAllCounted() throws {
        let path = try write(
            try (1...7).map { try prompt("needle \($0)", at: "2026-10-04T10:00:0\($0)Z") }, trailingNewline: false
        )
        let result = try XCTUnwrap(search("needle", in: path, limit: 3))
        XCTAssertEqual(result.total, 7)
        XCTAssertEqual(result.matches.map(\.excerpt), ["needle 7", "needle 6", "needle 5"])
        // Without milliseconds too.
        XCTAssertEqual(result.matches.first?.timestamp, ISO8601DateFormatter().date(from: "2026-10-04T10:00:07Z"))
    }

    /// A line past `maxLineBytes` is a tool's: skipped whole, whether it
    /// spans chunks or fits in one, the next one read.
    func testAnOversizedLineIsSkipped() throws {
        let huge = String(repeating: "x", count: TranscriptSearch.maxLineBytes) + " needle"
        let path = try write([try prompt(huge), try prompt("small needle")])
        for chunkSize in [TranscriptSearch.chunkSize, 3 * TranscriptSearch.chunkSize] {
            var budget = TranscriptSearch.Budget.standard()
            let result = try XCTUnwrap(search("needle", in: path, chunkSize: chunkSize, budget: &budget))
            XCTAssertEqual(result.matches.map(\.excerpt), ["small needle"], "chunks of \(chunkSize)")
        }
    }

    /// Only the end of a long transcript is read: a line cut by the start
    /// is skipped, a line starting there is read.
    func testALongTranscriptIsReadFromItsEnd() throws {
        let lines = [try prompt("old needle")] + (0..<20).map { _ in try! prompt("filler") }
            + [try prompt("cut needle"), try prompt("new needle")]
        let path = try write(lines)
        let lastTwo = lines.suffix(2).joined(separator: "\n").utf8.count + 1
        func excerpts(maxBytes: Int) throws -> [String] {
            var budget = TranscriptSearch.Budget.standard()
            let result = try XCTUnwrap(search("needle", in: path, maxBytes: maxBytes, budget: &budget))
            XCTAssertTrue(result.isPartial)
            return result.matches.map(\.excerpt)
        }
        XCTAssertEqual(try excerpts(maxBytes: lastTwo), ["new needle", "cut needle"])
        XCTAssertEqual(try excerpts(maxBytes: lastTwo - 5), ["new needle"])
    }

    /// From the start, a line the limit cuts isn't handed over.
    func testAHeadReadStopsAtTheLastWholeLine() throws {
        let path = try write(["a", "bb", "ccc"])
        func lines(maxBytes: Int) -> [String] {
            var budget = TranscriptSearch.Budget.standard()
            var lines: [String] = []
            _ = TranscriptSearch.readLines(transcriptAt: path, budget: &budget, maxBytes: maxBytes, fromStart: true) {
                lines.append(String(bytes: $0, encoding: .utf8) ?? "")
            }
            return lines
        }
        XCTAssertEqual(lines(maxBytes: 4), ["a"])
        XCTAssertEqual(lines(maxBytes: 5), ["a", "bb"])
        XCTAssertEqual(lines(maxBytes: 100), ["a", "bb", "ccc"])
    }

    func testTheBudgetAndACancelStopTheRead() throws {
        let path = try write(try (1...50).map { try prompt("needle \($0)") })
        var budget = TranscriptSearch.Budget(bytes: 200, deadline: ProcessInfo.processInfo.systemUptime + 60)
        let result = try XCTUnwrap(search("needle", in: path, chunkSize: 128, budget: &budget))
        XCTAssertTrue(result.isCut)
        XCTAssertLessThan(result.total, 50)
        XCTAssertTrue(budget.isSpent)
        var late = TranscriptSearch.Budget(bytes: .max, deadline: ProcessInfo.processInfo.systemUptime - 1)
        XCTAssertEqual(search("needle", in: path, budget: &late)?.total, 0)

        var open = TranscriptSearch.Budget.standard()
        var reads = 0
        let cancelled = TranscriptSearch.search(
            "needle", transcriptAt: path, limit: 5, budget: &open,
            isCancelled: { reads += 1; return reads > 1 }, chunkSize: 128
        )
        XCTAssertEqual(cancelled?.isCut, true)
        XCTAssertLessThan(cancelled?.total ?? 50, 50)
    }

    func testWhatCantBeReadGivesNothing() throws {
        XCTAssertNil(search("needle", in: folder + "/missing.jsonl"))
        let target = try write([try prompt("needle")])
        let link = folder + "/link.jsonl"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
        XCTAssertNil(search("needle", in: link))
    }
}
