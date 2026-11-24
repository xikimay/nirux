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

    /// Under the column, never imposed: why, then Compact and Fresh start,
    /// which arm like Allow / Deny and click only for that offer.
    func testAHeavyClaudeColumnOffersACompactionOrAFreshStart() throws {
        let offer = ContextOffer(reason: .heavy, contextTokens: 312_000, lastResponseAt: 100)
        var column = ColumnInfo(
            index: 0, processName: "claude", abbreviatedCwd: "~/p", isFocused: false, isWebView: false,
            webTitle: nil, terminalTitle: nil, agentStatus: .idle, isEditor: false, editorFileName: nil
        )
        column.contextOffer = offer
        let info = WorkspaceInfo(
            id: "ws", index: 0, title: "check-video", profileID: WorkspaceProfile.defaultID, isInactive: false,
            columnCount: 1, focusedColumn: 0, gitBranch: nil, notification: nil, isActive: false,
            columns: [column], prInfo: nil, diffStats: nil, purpose: nil, nextStep: nil, blocker: nil,
            phase: .active, lastSummary: nil, lastActivityAt: nil
        )
        XCTAssertEqual(info.cardActions, [.contextOffer(columnIndex: 0, offer)])
        XCTAssertEqual(offer.text, "Each message rereads 312k")
        XCTAssertEqual(
            ContextOffer(reason: .cold, contextTokens: 160_000, lastResponseAt: 100).text, "Cache expired: 160k to write again"
        )

        let result = SidebarWorkspaceCardRenderer(workspace: info, sidebarWidth: 260, yOffset: 800).render()
        let keys = [ContextOffer.Choice.compact, .freshStart].map {
            SidebarHoverTarget.contextOfferButtonKey(workspaceIndex: 0, columnIndex: 0, offer: offer, choice: $0)
        }
        XCTAssertEqual(Set(result.approvalButtons.keys), Set(keys))
        XCTAssertEqual(800 - result.bottomY, SidebarExpandedMetrics.workspaceHeight(for: info, sidebarWidth: 260), accuracy: 0.5)

        let compact = SidebarHitRegion.contextOffer(workspaceIndex: 0, columnIndex: 0, offer: offer, choice: .compact)
        func click(_ released: SidebarHitRegion?, count: Int = 1) -> SidebarContextOfferClick? {
            SidebarView.contextOfferClick(pressed: compact, released: released, clickCount: count, armedAtPress: true, armedAtRelease: true)
        }
        XCTAssertEqual(click(compact), SidebarContextOfferClick(workspaceIndex: 0, columnIndex: 0, choice: .compact))
        XCTAssertNil(click(.contextOffer(workspaceIndex: 0, columnIndex: 0, offer: offer, choice: .freshStart)), "released on the other")
        var later = offer
        later.lastResponseAt = 200
        XCTAssertNil(click(.contextOffer(workspaceIndex: 0, columnIndex: 0, offer: later, choice: .compact)), "another response came")
        XCTAssertNil(click(compact, count: 2))
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
