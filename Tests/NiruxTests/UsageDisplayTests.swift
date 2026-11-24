import XCTest
@testable import Nirux

final class UsageDisplayTests: XCTestCase {
    private let now: TimeInterval = 1_795_262_400

    private func event(_ secondsAgo: TimeInterval, input: Int, context: Int? = nil, subagent: String? = nil) -> UsageEvent {
        UsageEvent(timestamp: now - secondsAgo, model: "claude-opus-5-5", counts: TokenCounts(input: input), contextTokens: context, subagentID: subagent)
    }

    func testTokenCountsReadShortAndRoundAtEachUnit() {
        let values: [Double] = [0, 950, 999.6, 142_400, 999_499, 999_500, 4_240_000, 9_949_999, 9_950_000, 999_499_999, 1_050_000_000]
        XCTAssertEqual(values.map(UsageText.tokens), ["0", "950", "1k", "142k", "999k", "1.0M", "4.2M", "9.9M", "10M", "999M", "1.05G"])
        XCTAssertEqual([-5, .nan].map(UsageText.tokens), ["0", "0"])
        XCTAssertEqual(UsageText.share(29, of: 100), "29%")
        XCTAssertEqual(UsageText.share(1, of: 0), "0%")
    }

    func testCodexWindowsThatResetAreLeftOutAndTheShortestComesFirst() {
        let limits = CodexRateLimits(
            primary: .init(usedPercent: 64.4, minutes: 10_080, resetsAt: now + 3_600),
            secondary: .init(usedPercent: 12, minutes: 300, resetsAt: now + 60),
            reportedAt: now
        )
        XCTAssertEqual(UsageText.codexWindows(limits, now: now).map(\.name), ["5h", "7d"])
        XCTAssertEqual(UsageText.codexWindows(limits, now: now).map(\.percent), [12, 64])
        XCTAssertEqual(UsageText.codexWindows(limits, now: now + 61).map(\.name), ["7d"])
    }

    func testATaskRowReadsItsLatestSessionsContextAndItsWeek() throws {
        let session = UsageSession(
            key: UsageSessionKey(.claude, "s"), attribution: UsageAttribution(spaceID: "space", taskID: "task"), contextTokens: 300_000,
            events: [event(7_200, input: 4_200_000, context: 300_000), event(7_000, input: 100_000, subagent: "a")]
        )
        let report = UsageReport(sessions: [session], now: now)
        XCTAssertNil(SidebarTaskUsage(report, taskID: "other"))
        let usage = try XCTUnwrap(SidebarTaskUsage(report, taskID: "task"))
        XCTAssertEqual(usage.text, "300k · 4.3M")
        XCTAssertTrue(usage.isContextHeavy)
        let lines = usage.toolTip(now: now).components(separatedBy: "\n")
        XCTAssertTrue(lines.contains("Idle for 2h: its cache expired, the next message writes it again"))
        XCTAssertTrue(lines.contains("Subagents: 2%"))
        XCTAssertTrue(lines.contains("Past 280k of context: 98%"))
    }

    /// From the soft cap, the row warns and its tooltip says why; under it,
    /// it says nothing of subagents.
    func testARowWarnsOnceItsSessionReachesTheSubagentsSoftCap() throws {
        func usage(subagents: Int) throws -> SidebarTaskUsage {
            let session = UsageSession(
                key: UsageSessionKey(.claude, "s"), attribution: UsageAttribution(spaceID: "space", taskID: "task"), contextTokens: 90_000,
                subagents: subagents, events: [event(60, input: 90_000, context: 90_000)]
            )
            return try XCTUnwrap(SidebarTaskUsage(UsageReport(sessions: [session], now: now), taskID: "task"))
        }
        let under = try usage(subagents: SidebarTaskUsage.subagentSoftCap - 1)
        XCTAssertFalse(under.isWarning)
        XCTAssertFalse(under.toolTip(now: now).contains("subagents in its latest session"))
        let capped = try usage(subagents: SidebarTaskUsage.subagentSoftCap)
        XCTAssertTrue(capped.isWarning)
        XCTAssertFalse(capped.isContextHeavy)
        XCTAssertTrue(capped.toolTip(now: now).components(separatedBy: "\n")
            .contains("5 subagents in its latest session: past 5, separate work costs less as a task"))
    }

    func testTheUsageWindowRanksTasksAndCountsWhatTheyLeaveOut() {
        let sessions = [
            UsageSession(key: UsageSessionKey(.claude, "a"), attribution: UsageAttribution(spaceID: "space", taskID: "lead"),
                         events: [event(60, input: 600)]),
            UsageSession(key: UsageSessionKey(.claude, "b"), attribution: UsageAttribution(spaceID: "space", taskID: "closed"),
                         events: [event(60, input: 300)]),
            UsageSession(key: UsageSessionKey(.codex, "c"), attribution: UsageAttribution(spaceID: "space"), events: [event(60, input: 100)])
        ]
        let week = UsageReport(sessions: sessions, now: now).week
        let names = UsageNames(tasks: ["lead": .init(title: "Lead", isLead: true)], spaces: ["space": "Nirux"])
        XCTAssertEqual(UsageReportText.headline(week), "1k tokens · 3 responses · 3 sessions")
        XCTAssertEqual(UsageReportText.sections(week, names: names).map(\.title), ["By agent", "Causes (they overlap)", "Tasks", "Spaces"])
        let rows = Dictionary(uniqueKeysWithValues: UsageReportText.sections(week, names: names).map { ($0.title, $0.rows) })
        XCTAssertEqual(rows["By agent"], [["Claude", "900", "90%"], ["Codex", "100", "10%"]])
        XCTAssertEqual(rows["Causes (they overlap)"]?.last, ["Leads", "600", "60%"])
        XCTAssertEqual(rows["Tasks"], [
            ["Lead", "600", "60%", "peak 600", ""], ["Closed task", "300", "30%", "peak 300", ""], ["Outside tasks", "100", "10%"]
        ])
        XCTAssertEqual(rows["Spaces"], [["Nirux", "1k", "100%"]])
    }
}
