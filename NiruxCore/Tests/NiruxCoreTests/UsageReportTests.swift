import Foundation
@testable import NiruxCore
import Testing

struct UsageReportTests {
    @Test func oneShotRunsAreLoggedPerDayAndReadAsOneSessionEach() throws {
        let home = UsageFixture.temporaryFolder()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let folder = home + "/usage"
        let now = Date().timeIntervalSince1970.rounded()
        let old = folder + "/" + NiruxOneShotLog.fileName(at: now - 40 * 86_400)
        try UsageFixture.write(["{}"], to: old)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -40 * 86_400)], ofItemAtPath: old)

        let counts = TokenCounts(input: 3, output: 40, cacheWrite: 9_000, cacheRead: 1_000)
        NiruxOneShotLog.append(client: "NiruxTurnEnd", model: "claude-sonnet-5-5", counts: counts, at: now, in: folder)
        NiruxOneShotLog.append(client: "NiruxExplain", model: nil, counts: counts, contextTokens: 6_000, at: now, in: folder)
        #expect(!FileManager.default.fileExists(atPath: old))

        var ledger = UsageLedger(sources: UsageSources(home: home, niruxOneShots: folder))
        let caughtUp = ledger.refresh(since: now - 86_400)
        #expect(caughtUp)
        let sessions = ledger.sessions
        let day = String(NiruxOneShotLog.fileName(at: now).dropLast(".jsonl".count))
        #expect(sessions.map(\.key) == [UsageSessionKey(.nirux, day + "#0"), UsageSessionKey(.nirux, day + "#1")])
        #expect(sessions.map(\.events) == [
            [UsageEvent(timestamp: now, model: "claude-sonnet-5-5", counts: counts)],
            [UsageEvent(timestamp: now, counts: counts, contextTokens: 6_000)]
        ])
    }

    @Test func aReportSplitsSpendBySourceDayTaskAndSpace() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        // Saturday 2026-11-21 12:00 UTC.
        let now: TimeInterval = 1_795_262_400
        func event(_ hoursAgo: Double, input: Int, context: Int? = nil, subagent: String? = nil) -> UsageEvent {
            UsageEvent(timestamp: now - hoursAgo * 3_600, model: "claude-opus-5-5", counts: TokenCounts(input: input),
                       contextTokens: context, subagentID: subagent)
        }
        let task = UsageAttribution(spaceID: "space", taskID: "task")
        let sessions = [
            UsageSession(key: UsageSessionKey(.claude, "old"), attribution: task, contextTokens: 50_000, events: [event(30, input: 100)]),
            UsageSession(
                key: UsageSessionKey(.claude, "new"), attribution: task, contextTokens: 300_000, subagents: 1,
                events: [event(2, input: 1_000, context: 300_000), event(1, input: 10, subagent: "a")]
            ),
            UsageSession(
                key: UsageSessionKey(.codex, "x"), attribution: UsageAttribution(spaceID: "space"),
                rateLimits: CodexRateLimits(reportedAt: now - 60), events: [event(13, input: 200)]
            ),
            UsageSession(key: UsageSessionKey(.nirux, "one-shots"), events: [event(200, input: 7)])
        ]
        let report = UsageReport(sessions: sessions, now: now, calendar: calendar)

        #expect(UsageReport.since(now: now, calendar: calendar) == now - 12 * 3_600 - 6 * 86_400)
        #expect(report.day.total.weightedTokens == 1_210)
        #expect(report.day.total.heavyContextWeightedTokens == 1_000)
        #expect(report.week.sources.mapValues(\.weightedTokens) == [.claude: 1_100, .subagents: 10, .codex: 200])
        #expect(report.week.tasks.mapValues(\.weightedTokens) == ["task": 1_110])
        #expect(report.week.spaces.mapValues(\.weightedTokens) == ["space": 1_310])
        #expect(report.days.count == 7)
        // Codex's response came 13 hours ago, the evening before.
        #expect(report.days[5].sources == [.claude: 100, .codex: 200])
        #expect(report.days[6].sources == [.claude: 1_000, .subagents: 10])
        #expect(report.latestSessions["task"]?.key == UsageSessionKey(.claude, "new"))
        #expect(report.latestSessions["task"]?.contextTokens == 300_000)
        #expect(report.latestSessions["task"]?.lastResponseAt == now - 7_200)
        #expect(report.latestSessions["task"]?.subagents == 1)
        #expect(report.codexLimits?.reportedAt == now - 60)
    }
}
