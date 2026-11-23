import Foundation
import NiruxCore
import Testing

struct ClaudeUsageTests {
    @Test func aSessionReadsItsSubagentsFilesAndKeepsSidechainLinesForThem() throws {
        let folder = UsageFixture.temporaryFolder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let main = folder + "/session.jsonl"
        try UsageFixture.write([
            UsageFixture.claudeUser(cwd: "/Users/dev/app"),
            UsageFixture.claudeResponse(id: "m1", time: "2026-11-20T10:00:00.000Z", cacheWrite: 30_000, hourCacheWrite: 25_000),
            UsageFixture.claudeResponse(id: "inline", time: "2026-11-20T10:00:01.000Z", cacheRead: 90_000, sidechain: true)
        ], to: main)
        try UsageFixture.write([
            UsageFixture.claudeResponse(id: "a1", time: "2026-11-20T10:00:02.500Z", cacheRead: 5_000, sidechain: true)
        ], to: folder + "/session/subagents/agent-a.jsonl")

        var reader = ClaudeSessionReader(path: main)
        var caughtUp = reader.readAppended()
        #expect(caughtUp)
        #expect(reader.sessionID == "session")
        #expect(reader.main.parser.cwd == "/Users/dev/app")
        #expect(reader.main.parser.usage.contextTokens == 30_002)
        #expect(reader.main.parser.events.first?.counts.hourCacheWrite == 25_000)
        #expect(reader.events.map(\.subagentID) == [nil, "agent-a"])
        #expect(reader.events.map(\.timestamp) == [1_795_168_800, 1_795_168_802.5])

        try UsageFixture.write([
            UsageFixture.claudeResponse(id: "b1", time: "2026-11-20T10:01:00.000Z", cacheRead: 7_000, sidechain: true)
        ], to: folder + "/session/subagents/agent-b.jsonl")
        // Replaced: read again from the start, still as a subagent's.
        try UsageFixture.write([
            UsageFixture.claudeResponse(id: "a2", time: "2026-11-20T10:02:00.000Z", cacheRead: 1_000, sidechain: true)
        ], to: folder + "/session/subagents/agent-a.jsonl")
        caughtUp = reader.readAppended()
        #expect(caughtUp)
        #expect(reader.subagents["agent-a"]?.parser.events.map(\.contextTokens) == [1_002])
        #expect(reader.events.compactMap(\.subagentID).sorted() == ["agent-a", "agent-b"])
    }

    @Test func aLinkIsNeverRead() throws {
        let folder = UsageFixture.temporaryFolder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        try UsageFixture.write([UsageFixture.claudeResponse(id: "m1", time: "2026-11-20T10:00:00Z", cacheRead: 9_000)], to: folder + "/real.jsonl")
        try FileManager.default.createSymbolicLink(atPath: folder + "/link.jsonl", withDestinationPath: folder + "/real.jsonl")

        var reader = ClaudeSessionReader(path: folder + "/link.jsonl")
        let caughtUp = reader.readAppended()
        #expect(caughtUp)
        #expect(reader.events.isEmpty)
    }
}
