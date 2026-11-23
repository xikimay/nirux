import Foundation
import NiruxCore
import Testing

struct CodexAgyUsageTests {
    @Test func codexCountsEachResponseOnceWithItsCachedInputApart() throws {
        let folder = UsageFixture.temporaryFolder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let first = ["input_tokens": 20_000, "cached_input_tokens": 15_000, "output_tokens": 200]
        let second = ["input_tokens": 30_000, "cached_input_tokens": 28_000, "output_tokens": 50]
        let both = ["input_tokens": 50_000, "cached_input_tokens": 43_000, "output_tokens": 250]
        try UsageFixture.write([
            UsageFixture.json(["type": "session_meta", "payload": ["id": "thread-1", "cwd": "/Users/dev/app"]]),
            UsageFixture.json(["type": "turn_context", "payload": ["model": "gpt-6.2-astra", "cwd": "/elsewhere"]]),
            UsageFixture.codexTokenCount(time: "2026-11-21T11:00:10.000Z", last: first, total: first),
            UsageFixture.codexTokenCount(time: "2026-11-21T11:00:11.000Z", last: first, total: first),
            UsageFixture.codexTokenCount(time: "2026-11-21T11:00:20.000Z", last: second, total: both)
        ], to: folder + "/rollout.jsonl")

        var reader = TranscriptLineReader<CodexRolloutUsageParser>(path: folder + "/rollout.jsonl")
        let caughtUp = reader.readAppended()
        #expect(caughtUp)
        let parser = reader.parser
        #expect(parser.sessionID == "thread-1")
        #expect(parser.cwd == "/Users/dev/app")
        #expect(parser.contextWindow == 258_000)
        #expect(parser.rateLimits?.primary?.usedPercent == 42.5)
        #expect(parser.rateLimits?.secondary == nil)
        #expect(parser.events.map(\.counts) == [
            TokenCounts(input: 5_000, output: 200, cacheRead: 15_000),
            TokenCounts(input: 2_000, output: 50, cacheRead: 28_000)
        ])
        #expect(parser.events.map(\.contextTokens) == [20_000, 30_000])
        #expect(parser.events.allSatisfy { $0.model == "gpt-6.2-astra" })
    }

    @Test func agyCountsPlannerResponsesWhoseInputLeavesOutTheCache() throws {
        let folder = UsageFixture.temporaryFolder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        try UsageFixture.write([
            UsageFixture.json(["type": "USER_INPUT", "created_at": "2026-11-23T17:00:00Z", "input_tokens": 99]),
            UsageFixture.agyResponse(time: "2026-11-23T17:00:02Z", input: 2_500, cacheRead: 9_500, output: 310),
            UsageFixture.json(["type": "GENERIC", "created_at": "2026-11-23T17:00:03Z", "output_tokens": 7])
        ], to: folder + "/transcript_full.jsonl")

        var reader = TranscriptLineReader<AgyTranscriptUsageParser>(path: folder + "/transcript_full.jsonl")
        let caughtUp = reader.readAppended()
        #expect(caughtUp)
        #expect(reader.parser.events == [
            UsageEvent(timestamp: 1_795_453_202, model: "gemini-4-neon-high", counts: TokenCounts(input: 2_500, output: 310, cacheRead: 9_500))
        ])
    }
}
