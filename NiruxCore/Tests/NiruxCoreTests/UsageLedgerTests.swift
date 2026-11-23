import Foundation
@testable import NiruxCore
import Testing

struct UsageLedgerTests {
    @Test func refreshFollowsTheTranscriptsOfEveryAgentWrittenSinceItsStart() throws {
        let home = UsageFixture.temporaryFolder()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let sources = UsageSources(home: home)
        let project = sources.claudeProjects + "/-Users-dev-app"
        try UsageFixture.write([
            UsageFixture.claudeUser(cwd: "/Users/dev/app"),
            UsageFixture.claudeResponse(id: "m1", time: "2026-11-21T10:00:00.000Z", cacheWrite: 40_000)
        ], to: project + "/claude-1.jsonl")
        try UsageFixture.write([
            UsageFixture.claudeResponse(id: "s1", time: "2026-11-21T10:01:00.000Z", cacheRead: 9_000, sidechain: true)
        ], to: project + "/claude-1/subagents/agent-a.jsonl")
        let waiting = project + "/claude-waiting.jsonl"
        try UsageFixture.write([UsageFixture.claudeResponse(id: "w1", time: "2026-11-01T10:00:00.000Z", cacheRead: 9_000)], to: waiting)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -30 * 86_400)], ofItemAtPath: waiting)
        try UsageFixture.write([
            UsageFixture.claudeResponse(id: "ws1", time: "2026-11-21T10:02:00.000Z", cacheRead: 3_000, sidechain: true)
        ], to: project + "/claude-waiting/subagents/agent-b.jsonl")
        let old = project + "/claude-old.jsonl"
        try UsageFixture.write([UsageFixture.claudeResponse(id: "o1", time: "2026-10-01T10:00:00.000Z", cacheRead: 9_000)], to: old)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -30 * 86_400)], ofItemAtPath: old)
        let usage = ["input_tokens": 20_000, "cached_input_tokens": 15_000, "output_tokens": 200]
        try UsageFixture.write([
            UsageFixture.json(["type": "session_meta", "payload": ["id": "codex-1", "cwd": "/Users/dev/app.feat-a"]]),
            UsageFixture.codexTokenCount(time: "2026-11-21T11:00:10.000Z", last: usage, total: usage)
        ], to: sources.codexSessions + "/2026/11/21/rollout-2026-11-21-codex-1.jsonl")
        try UsageFixture.write(
            [UsageFixture.agyResponse(time: "2026-11-21T12:00:00Z", input: 30_000, cacheRead: 50_000, output: 300)],
            to: sources.agyBrain + "/agy-1/.system_generated/logs/transcript_full.jsonl"
        )

        var ledger = UsageLedger(sources: sources, catalog: UsageCatalog(spaces: [.init(id: "space", repositories: ["/Users/dev/app"])]))
        let weekAgo = Date().timeIntervalSince1970 - 7 * 86_400
        // A budget smaller than any file: one read at a time, every file in turn.
        var refreshes = 1
        while !ledger.refresh(since: weekAgo, budget: 200) { refreshes += 1 }
        #expect(refreshes > 3)
        let sessions = ledger.sessions.sorted { $0.key.id < $1.key.id }
        #expect(sessions.map(\.key) == [
            UsageSessionKey(.agy, "agy-1"), UsageSessionKey(.claude, "claude-1"),
            UsageSessionKey(.claude, "claude-waiting"), UsageSessionKey(.codex, "codex-1")
        ])
        #expect(sessions.map(\.attribution.spaceID) == [nil, "space", nil, "space"])
        #expect(sessions.map(\.subagents) == [0, 1, 1, 0])
        #expect(sessions.map(\.contextTokens) == [80_000, 40_002, 9_002, 20_000])

        var caughtUp = ledger.refresh(since: weekAgo)
        #expect(caughtUp)
        #expect(ledger.sessions.sorted { $0.key.id < $1.key.id } == sessions)
        caughtUp = ledger.refresh(since: Date().timeIntervalSince1970 + 60)
        #expect(caughtUp)
        #expect(ledger.sessions.isEmpty)
    }

    @Test func aSessionGoesToItsRecordedTaskElseToTheInnermostTaskOrSpaceFolder() {
        let catalog = UsageCatalog(
            spaces: [
                .init(id: "space", repositories: ["/repos/app"], folders: ["/sites/web"]),
                .init(id: "ios", repositories: ["/repos/app.ios"])
            ],
            tasks: [
                .init(id: "lead", spaceID: "space", folder: "/repos/app"),
                .init(id: "feature", spaceID: "space", folder: "/repos/app.feat-a"),
                .init(id: "closed", spaceID: "space", folder: "/repos/app.feat-a"),
                .init(id: "bound", spaceID: "other", folder: "/elsewhere")
            ],
            sessionTasks: [UsageSessionKey(.codex, "recorded"): "bound"]
        )
        let attributor = UsageAttributor(catalog)
        func attribution(_ cwd: String?, session: String = "any") -> UsageAttribution {
            attributor.attribution(UsageSessionKey(.codex, session), cwd: cwd)
        }
        #expect(attribution("/repos/app/Sources", session: "recorded") == UsageAttribution(spaceID: "other", taskID: "bound"))
        #expect(attribution("/repos/app/Sources") == UsageAttribution(spaceID: "space", taskID: "lead"))
        #expect(attribution("/repos/app.feat-a/Sources") == UsageAttribution(spaceID: "space", taskID: "feature"))
        #expect(attribution("/repos/app.feat-gone") == UsageAttribution(spaceID: "space"))
        #expect(attribution("/repos/app.ios.feat-b/Sources") == UsageAttribution(spaceID: "ios"))
        #expect(attribution("/sites/web/blog") == UsageAttribution(spaceID: "space"))
        #expect(attribution("/repos/app2") == UsageAttribution())
        #expect(attribution(nil) == UsageAttribution())
    }

    @Test func summariesSplitWhatSubagentsSpentAndFindColdRewritesPerStream() {
        func event(_ time: TimeInterval, cacheWrite: Int = 0, hour: Bool = false, input: Int = 0, subagent: String? = nil) -> UsageEvent {
            let counts = TokenCounts(input: input, output: 10, cacheWrite: cacheWrite, hourCacheWrite: hour ? cacheWrite : 0)
            return UsageEvent(timestamp: time, model: "claude-opus-5-5", counts: counts, subagentID: subagent)
        }
        let claude = UsageSession(
            key: UsageSessionKey(.claude, "c"), attribution: UsageAttribution(spaceID: "space", taskID: "task"), subagents: 1,
            events: [
                event(0, cacheWrite: 30_000), event(100, cacheWrite: 30_000), event(1_100, cacheWrite: 50_000),
                event(200, cacheWrite: 25_000, subagent: "x"), event(1_000, cacheWrite: 25_000, subagent: "x")
            ]
        )
        let codex = UsageSession(key: UsageSessionKey(.codex, "x"), events: [event(500, input: 40_000), event(900, input: 40_000)])
        // Hour-long entries outlive a 20 minute pause, not a 2 hour one.
        let lead = UsageSession(
            key: UsageSessionKey(.claude, "lead"),
            events: [event(0, cacheWrite: 30_000, hour: true), event(1_200, cacheWrite: 30_000), event(8_400, cacheWrite: 30_000, hour: true)]
        )
        #expect([lead].summary(since: 0).coldRewrites == 1)
        #expect([lead].summary(since: 0).coldRewriteWeightedTokens == 30_000 * 2)

        let total = [claude, codex].summary(since: 0)
        #expect(total.calls == 7)
        #expect(total.sessions.count == 2)
        #expect(total.subagents == ["c/x"])
        #expect(total.subagentWeightedTokens == 2 * (25_000 * 1.25 + 50))
        // The session's own pause from 100 to 1,100 s; the subagent's from 200 to 1,000 s; Codex's from 500 to 900 s.
        #expect(total.coldRewrites == 3)
        #expect(total.coldRewriteWeightedTokens == 50_000 * 1.25 + 25_000 * 1.25 + 40_000)

        let recent = [claude, codex].summaries(since: 950) { session, _ in session.attribution.taskID }
        #expect(recent.keys.sorted() == ["task"])
        #expect(recent["task"]?.calls == 2)
        #expect(recent["task"]?.coldRewrites == 2)
        #expect(recent["task"]?.peakContextTokens == 50_000)
        #expect(TokenCounts(input: 1, output: 1, cacheRead: 40).weighted(model: "claude-sonnet-5-5") == 4)
        #expect(TokenCounts(input: 2, output: 1, cacheWrite: 4, cacheRead: 40, hourCacheWrite: 2).weighted(model: "claude-fable-5-2") == 29)
    }
}
