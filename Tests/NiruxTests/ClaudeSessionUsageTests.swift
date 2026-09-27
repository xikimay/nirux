import XCTest
@testable import Nirux

/// Transcript lines shaped like Claude Code's (only the fields the parser
/// reads, plus some noise it must ignore).
enum TranscriptLine {
    static func response(
        id: String?,
        input: Int = 2,
        cacheWrite: Int = 0,
        cacheRead: Int = 0,
        output: Int = 10,
        model: String = "claude-opus-5-5",
        sidechain: Bool = false,
        block: Int = 0,
        extra: [String: Any] = [:]
    ) -> String {
        var message: [String: Any] = [
            "model": model,
            "role": "assistant",
            "content": [["type": "text", "text": "never kept"]],
            "usage": [
                "input_tokens": input,
                "cache_creation_input_tokens": cacheWrite,
                "cache_read_input_tokens": cacheRead,
                "output_tokens": output,
                "service_tier": "standard"
            ]
        ]
        if let id { message["id"] = id }
        var object: [String: Any] = [
            "type": "assistant",
            "isSidechain": sidechain,
            "apiBlockIndex": block,
            "message": message,
            "requestId": "req_\(id ?? "none")"
        ]
        object.merge(extra) { $1 }
        return json(object)
    }

    static func compactBoundary() -> String {
        json([
            "type": "system",
            "subtype": "compact_boundary",
            "isSidechain": false,
            "compactMetadata": ["trigger": "auto", "preTokens": 180_000, "postTokens": 2_000]
        ])
    }

    static func user(_ text: String) -> String {
        json(["type": "user", "message": ["role": "user", "content": text]])
    }

    static func json(_ object: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            .flatMap { String(bytes: $0, encoding: .utf8) } ?? ""
    }
}

final class ClaudeSessionUsageTests: XCTestCase {
    private func parse(_ lines: [String]) -> ClaudeSessionUsage {
        var parser = ClaudeTranscriptUsageParser()
        for line in lines { parser.consume(line: Data(line.utf8)) }
        return parser.usage
    }

    // MARK: - Parser

    func testBlocksOfOneResponseCountOnceWithTheLatestUsage() {
        let usage = parse([
            TranscriptLine.response(id: "msg_1", input: 3, cacheWrite: 1_000, cacheRead: 20_000, output: 1, block: 0),
            TranscriptLine.response(id: "msg_1", input: 3, cacheWrite: 1_000, cacheRead: 20_000, output: 250, block: 1),
            TranscriptLine.response(id: "msg_1", input: 3, cacheWrite: 1_000, cacheRead: 20_000, output: 250, block: 2)
        ])
        XCTAssertEqual(usage.responses, 1)
        XCTAssertEqual(usage.totals, ClaudeTokenCounts(input: 3, output: 250, cacheWrite: 1_000, cacheRead: 20_000))
        XCTAssertEqual(usage.contextTokens, 21_003)
        XCTAssertEqual(usage.model, "claude-opus-5-5")
    }

    func testResponsesSumAndTheContextIsTheLatestOne() {
        let usage = parse([
            TranscriptLine.response(id: "msg_1", input: 2, cacheWrite: 30_000, cacheRead: 0, output: 100),
            TranscriptLine.user("tool result"),
            TranscriptLine.response(id: "msg_2", input: 2, cacheWrite: 500, cacheRead: 30_000, output: 40)
        ])
        XCTAssertEqual(usage.responses, 2)
        XCTAssertEqual(usage.totals, ClaudeTokenCounts(input: 4, output: 140, cacheWrite: 30_500, cacheRead: 30_000))
        XCTAssertEqual(usage.contextTokens, 30_502)
        XCTAssertEqual(usage.peakContextTokens, 30_502)
    }

    func testStrayRepeatOfAnEarlierResponseIsNotCountedAgain() {
        let first = TranscriptLine.response(id: "msg_1", cacheRead: 10_000, output: 5)
        let usage = parse([first, TranscriptLine.response(id: "msg_2", cacheRead: 12_000, output: 7), first])
        XCTAssertEqual(usage.responses, 2)
        XCTAssertEqual(usage.totals.output, 12)
        XCTAssertEqual(usage.contextTokens, 12_002)
    }

    func testResponsesWithoutIDsCountEachLine() {
        let line = TranscriptLine.response(id: nil, cacheRead: 1_000, output: 5, extra: ["requestId": NSNull()])
        let usage = parse([line, line])
        XCTAssertEqual(usage.responses, 2)
        XCTAssertEqual(usage.totals.output, 10)
    }

    func testSubagentSyntheticAndErrorLinesAreSkipped() {
        let usage = parse([
            TranscriptLine.response(id: "msg_1", cacheRead: 50_000, output: 5),
            TranscriptLine.response(id: "msg_side", cacheRead: 900_000, output: 99, sidechain: true),
            TranscriptLine.response(id: "synthetic", input: 0, output: 0, model: "<synthetic>"),
            TranscriptLine.response(id: "err", cacheRead: 70_000, extra: ["isApiErrorMessage": true]),
            TranscriptLine.response(id: "empty", input: 0, cacheWrite: 0, cacheRead: 0, output: 0)
        ])
        XCTAssertEqual(usage.responses, 1)
        XCTAssertEqual(usage.contextTokens, 50_002)
        XCTAssertEqual(usage.peakContextTokens, 50_002)
        XCTAssertEqual(usage.model, "claude-opus-5-5")
    }

    func testCompactionClearsTheContextUntilTheNextResponse() {
        var parser = ClaudeTranscriptUsageParser()
        parser.consume(line: Data(TranscriptLine.response(id: "msg_1", cacheRead: 180_000).utf8))
        parser.consume(line: Data(TranscriptLine.compactBoundary().utf8))
        XCTAssertNil(parser.usage.contextTokens)
        XCTAssertEqual(parser.usage.titleBarText, "ctx —")
        XCTAssertEqual(parser.usage.responses, 1)

        parser.consume(line: Data(TranscriptLine.response(id: "msg_2", cacheWrite: 20_000).utf8))
        XCTAssertEqual(parser.usage.contextTokens, 20_002)
        XCTAssertEqual(parser.usage.peakContextTokens, 180_002)
    }

    func testUnknownAndMalformedLinesAreIgnored() {
        let usage = parse([
            "",
            "not json \"usage\"",
            "[\"usage\", 1]",
            "{\"type\":\"assistant\",\"message\":{\"usage\":\"none\"}}",
            "{\"type\":\"assistant\",\"message\":{\"usage\":{\"input_tokens\":\"12\"}}}",
            "{\"type\":\"assistant\",\"message\":\"usage\"}",
            "{\"type\":\"future-kind\",\"usage\":{\"input_tokens\":5}}",
            "{\"type\":\"assistant\",\"message\":{\"id\":\"m\",\"usage\":{\"input_tokens\":5",
            TranscriptLine.user("\"usage\" appears in plain text")
        ])
        XCTAssertEqual(usage, ClaudeSessionUsage())
        XCTAssertNil(usage.titleBarText)
    }

    func testHugeCountsAreClampedInsteadOfOverflowing() {
        let line = TranscriptLine.response(id: nil, input: 1, cacheRead: 0, output: 0, extra: ["requestId": NSNull()])
            .replacingOccurrences(of: "\"output_tokens\":0", with: "\"output_tokens\":9223372036854775807")
            .replacingOccurrences(of: "\"cache_read_input_tokens\":0", with: "\"cache_read_input_tokens\":1e300")
        var parser = ClaudeTranscriptUsageParser()
        for _ in 0..<3 { parser.consume(line: Data(line.utf8)) }
        XCTAssertEqual(parser.usage.responses, 3)
        XCTAssertEqual(parser.usage.totals.output, 3 * Int(Int32.max))
    }

    // MARK: - Window and display

    func testWindowIsOnlyKnownOnceTheContextProvesTheExtendedOne() {
        var usage = parse([TranscriptLine.response(id: "msg_1", cacheRead: 150_000)])
        XCTAssertNil(usage.contextWindow)
        XCTAssertNil(usage.contextFraction)
        XCTAssertEqual(usage.titleBarText, "ctx 150k")
        XCTAssertFalse(usage.isNearlyFull)

        usage = parse([
            TranscriptLine.response(id: "msg_1", cacheRead: 250_000),
            TranscriptLine.compactBoundary(),
            TranscriptLine.response(id: "msg_2", cacheRead: 40_000)
        ])
        XCTAssertEqual(usage.contextWindow, 1_000_000)
        XCTAssertEqual(usage.titleBarText, "ctx 4%")

        usage = parse([TranscriptLine.response(id: "msg_1", cacheRead: 850_000)])
        XCTAssertEqual(usage.titleBarText, "ctx 85%")
        XCTAssertTrue(usage.isNearlyFull)
    }

    func testTooltipDetailsContextModelAndSessionTotals() {
        let known = parse([
            TranscriptLine.response(id: "msg_1", input: 3, cacheWrite: 12_000, cacheRead: 200_000, output: 1_500),
            TranscriptLine.response(id: "msg_2", input: 1, cacheWrite: 400, cacheRead: 212_000, output: 48_000)
        ])
        XCTAssertEqual(known.tooltip, """
        Context: 212,401 tokens, 21% of the 1,000,000 window
        Model: claude-opus-5-5
        Session (2 responses): 50k output · 4 input · 412k cache read · 12k cache write
        """)

        let unknown = parse([TranscriptLine.response(id: "msg_1", input: 5, cacheRead: 9_000, output: 1)])
        XCTAssertEqual(unknown.tooltip, """
        Context: 9,005 tokens (window not known yet: 200k or 1M, depending on the model and account)
        Model: claude-opus-5-5
        Session (1 response): 1 output · 5 input · 9k cache read · 0 cache write
        """)
    }

    func testCompactFormats() {
        XCTAssertEqual(ClaudeSessionUsage.compactCount(0), "0")
        XCTAssertEqual(ClaudeSessionUsage.compactCount(999), "999")
        XCTAssertEqual(ClaudeSessionUsage.compactCount(1_000), "1k")
        XCTAssertEqual(ClaudeSessionUsage.compactCount(8_440), "8.4k")
        XCTAssertEqual(ClaudeSessionUsage.compactCount(9_960), "10k")
        XCTAssertEqual(ClaudeSessionUsage.compactCount(124_300), "124k")
        XCTAssertEqual(ClaudeSessionUsage.compactCount(999_600), "1M")
        XCTAssertEqual(ClaudeSessionUsage.compactCount(1_240_000), "1.2M")
        XCTAssertEqual(ClaudeSessionUsage.percent(0.62), "62%")
        XCTAssertEqual(ClaudeSessionUsage.percent(0.001), "<1%")
        XCTAssertEqual(ClaudeSessionUsage.percent(0), "0%")
        XCTAssertEqual(ClaudeSessionUsage.groupedCount(0), "0")
        XCTAssertEqual(ClaudeSessionUsage.groupedCount(212), "212")
        XCTAssertEqual(ClaudeSessionUsage.groupedCount(212_400), "212,400")
        XCTAssertEqual(ClaudeSessionUsage.groupedCount(1_000_000), "1,000,000")
    }
}
