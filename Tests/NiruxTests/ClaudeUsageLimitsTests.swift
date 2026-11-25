import XCTest
@testable import Nirux

final class ClaudeUsageLimitsTests: XCTestCase {
    /// 2026-10-03 14:00:00 UTC, a Saturday.
    private let now: TimeInterval = 1_791_036_000
    private let hour: TimeInterval = 3600
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nirux-usage-limits-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private var fileURL: URL { directory.appendingPathComponent("claude-usage-limits.json") }

    /// A status line payload as Claude Code 2.1.288 sends it after a
    /// response (trimmed): the limits sit beside the session's own state.
    private func payload(fiveHour: Any?, sevenDay: Any? = nil) -> [String: Any] {
        var limits: [String: Any] = [:]
        if let fiveHour { limits["five_hour"] = fiveHour }
        if let sevenDay { limits["seven_day"] = sevenDay }
        return [
            "session_id": "s1",
            "model": ["id": "claude-haiku-4-5-20251001", "display_name": "Haiku 4.5"],
            "context_window": ["used_percentage": 12],
            "rate_limits": limits
        ]
    }

    private func reading(_ percent: Double, resetsIn: TimeInterval) -> [String: Any] {
        ["used_percentage": percent, "resets_at": now + resetsIn]
    }

    private func window(_ percent: Double, resetsAt: TimeInterval, reportedAt: TimeInterval? = nil) -> ClaudeUsageLimits.Window {
        .init(usedPercentage: percent, resetsAt: resetsAt, reportedAt: reportedAt ?? now)
    }

    // MARK: - Reading the status line payload

    func testReadsTheLimitsOfAStatusLinePayload() throws {
        let limits = try XCTUnwrap(ClaudeUsageLimits(
            statusLinePayload: payload(fiveHour: reading(25, resetsIn: hour), sevenDay: reading(18, resetsIn: 72 * hour)),
            now: now
        ))
        XCTAssertEqual(limits.fiveHour, window(25, resetsAt: now + hour))
        XCTAssertEqual(limits.sevenDay, window(18, resetsAt: now + 72 * hour))
    }

    /// Before a session's first response, with an API key, or with values
    /// Claude Code itself would drop, there is nothing to show.
    func testIgnoresWindowsItCannotUse() {
        XCTAssertNil(ClaudeUsageLimits(statusLinePayload: ["session_id": "s1"], now: now), "first run: no rate_limits")
        XCTAssertNil(ClaudeUsageLimits(statusLinePayload: ["rate_limits": NSNull()], now: now))
        XCTAssertNil(ClaudeUsageLimits(statusLinePayload: payload(fiveHour: nil), now: now))
        XCTAssertNil(ClaudeUsageLimits(statusLinePayload: payload(fiveHour: reading(25, resetsIn: -1)), now: now), "already reset")
        XCTAssertNil(ClaudeUsageLimits(statusLinePayload: payload(fiveHour: reading(25, resetsIn: 400 * 24 * hour)), now: now))
        XCTAssertNil(ClaudeUsageLimits(
            statusLinePayload: payload(fiveHour: ["used_percentage": "25", "resets_at": now + hour]), now: now
        ))

        let partial = ClaudeUsageLimits(
            statusLinePayload: payload(fiveHour: ["resets_at": now + hour], sevenDay: reading(1_000_000, resetsIn: hour)),
            now: now
        )
        XCTAssertNil(partial?.fiveHour)
        XCTAssertEqual(partial?.sevenDay?.usedPercentage, ClaudeUsageLimits.maximumPercentage, "a wild value is capped")
    }

    func testCurrentDropsTheWindowsThatReset() {
        let limits = ClaudeUsageLimits(fiveHour: window(90, resetsAt: now + hour), sevenDay: window(50, resetsAt: now + 50 * hour))
        XCTAssertEqual(limits.current(at: now + hour - 1), limits)
        XCTAssertEqual(limits.current(at: now + hour), ClaudeUsageLimits(sevenDay: limits.sevenDay))
        XCTAssertNil(limits.current(at: now + 50 * hour))
    }

    /// The file is only ever written by the receiver, but a hand edit or a
    /// corrupt one must not crash the title bar (it converts to integers).
    func testCurrentRejectsWhatClaudeCodeCouldNotHaveSent() throws {
        try Data(#"""
        {"limits": {"fiveHour": {"usedPercentage": 1e300, "resetsAt": \#(now + hour), "reportedAt": \#(now)},
                    "sevenDay": {"usedPercentage": 18, "resetsAt": 4102444800, "reportedAt": \#(now)}}}
        """#.utf8).write(to: fileURL)
        let current = try XCTUnwrap(ClaudeUsageLimitsFile.load(from: fileURL)?.current(at: now))
        XCTAssertEqual(current.fiveHour?.usedPercentage, ClaudeUsageLimits.maximumPercentage)
        XCTAssertEqual(current.fiveHour?.displayedPercent, 999)
        XCTAssertNil(current.sevenDay, "a reset decades out never expires: dropped")
    }

    // MARK: - Display

    /// Readings every 5 minutes up to now.
    private func climb(_ percents: [Double], resetsAt: TimeInterval) -> [QuotaReading] {
        percents.enumerated().map { QuotaReading(time: now - Double(percents.count - 1 - $0.offset) * 300, usedPercent: $0.element, resetsAt: resetsAt) }
    }

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_GB")
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    func testTitleSaysTheBindingLimitsPace() throws {
        func title(_ percents: [Double], length: TimeInterval = 5 * 3600, resetsIn: TimeInterval) throws -> UsageText.QuotaTitle {
            let limit = try XCTUnwrap(QuotaLimit(agent: .claude, length: length, readings: climb(percents, resetsAt: now + resetsIn), now: now))
            return UsageText.title(limit, now: now, calendar: utc)
        }
        // A point a minute from 60 %: full by 14:40, before its reset at 15:00.
        XCTAssertEqual(try title([45, 50, 55, 60], resetsIn: hour), .init(text: "⚠︎ 5h full by 14:40", tone: .runsOut))
        XCTAssertEqual(try title([52.5, 55, 57.5, 60], resetsIn: hour), .init(text: "5h 60% · ≈ 90%", tone: .normal))
        XCTAssertEqual(try title([98, 99, 100], length: 7 * 86_400, resetsIn: 99 * hour), .init(text: "⚠︎ 7d full until Wed 17:00", tone: .runsOut))
        // Without a forecast: a warning from 80 %, as the number shows it.
        XCTAssertEqual(try title([79.4], resetsIn: hour), .init(text: "5h 79%", tone: .normal))
        XCTAssertEqual(try title([79.5], resetsIn: hour), .init(text: "⚠︎ 5h 80%", tone: .warning))
        // A forecast that holds needs no warning at 85 %.
        XCTAssertEqual(try title([85, 85, 85, 85], resetsIn: hour), .init(text: "5h 85%", tone: .normal))
        XCTAssertEqual(try title([99.6, 99.6, 99.6, 99.6], resetsIn: hour), .init(text: "⚠︎ 5h 100%", tone: .warning), "full, even holding")
    }

    func testRemainingTimeRoundsUpToTheMinute() {
        XCTAssertEqual(ClaudeUsageLimits.remainingText(20), "1m")
        XCTAssertEqual(ClaudeUsageLimits.remainingText(45 * 60), "45m")
        XCTAssertEqual(ClaudeUsageLimits.remainingText(2 * hour), "2h")
        XCTAssertEqual(ClaudeUsageLimits.remainingText(2 * hour + 9 * 60 + 1), "2h 10m")
        XCTAssertEqual(ClaudeUsageLimits.remainingText(48 * hour), "2d")
    }

    // MARK: - The shared file

    /// Runs the receiver on a status line payload from the `claude` with
    /// pid `process` in `column`.
    @discardableResult
    private func report(
        _ column: String, process: pid_t = 100, session: String = "s1",
        api: Double, fiveHour: Double?, sevenDay: Double?, at time: TimeInterval
    ) throws -> ClaudeUsageLimits? {
        var object = payload(
            fiveHour: fiveHour.map { reading($0, resetsIn: hour) }, sevenDay: sevenDay.map { reading($0, resetsIn: 90 * hour) }
        )
        object["session_id"] = session
        object["cost"] = ["total_api_duration_ms": api, "total_cost_usd": 0.08]
        XCTAssertTrue(ClaudeStatusLineCLI.record(
            payload: try JSONSerialization.data(withJSONObject: object), env: ["NIRUX_AGENT_UUID": column], now: time,
            claude: ProcessInstance(pid: process, startedAt: 1000), url: fileURL
        ))
        return ClaudeUsageLimitsFile.load(from: fileURL)?.current(at: time)
    }

    /// The latest news wins, whichever session brings it. A status line
    /// that runs again without a new response repeats old numbers, which
    /// must not come back over newer ones: while the session is idle, once
    /// a window reset (Claude Code then leaves that window out), after
    /// `/clear` (the API time starts over) or `/resume` (it takes the
    /// resumed session's).
    func testRecordKeepsTheLatestNewsAndIgnoresRepeats() throws {
        try report("a", api: 2700, fiveHour: 30, sevenDay: 18, at: now)
        var stored = try XCTUnwrap(try report("b", api: 900, fiveHour: 35, sevenDay: 25, at: now + 60))
        XCTAssertEqual(stored.fiveHour, window(35, resetsAt: now + hour, reportedAt: now + 60))

        stored = try XCTUnwrap(try report("a", api: 2700, fiveHour: 30, sevenDay: 18, at: now + 300))
        XCTAssertEqual(stored.fiveHour?.usedPercentage, 35, "a's prompt cache expired: a repeat")

        let afterReset = now + hour + 60
        stored = try XCTUnwrap(try report("a", api: 2700, fiveHour: nil, sevenDay: 18, at: afterReset))
        XCTAssertEqual(stored, ClaudeUsageLimits(sevenDay: window(25, resetsAt: now + 90 * hour, reportedAt: now + 60)))
        stored = try XCTUnwrap(try report("a", session: "s2", api: 0, fiveHour: nil, sevenDay: 18, at: afterReset + 60))
        XCTAssertEqual(stored.sevenDay?.usedPercentage, 25, "/clear: a repeat")
        stored = try XCTUnwrap(try report("a", session: "s3", api: 50_000, fiveHour: nil, sevenDay: 18, at: afterReset + 70))
        XCTAssertEqual(stored.sevenDay?.usedPercentage, 25, "/resume: a repeat")

        // A response is news, even with numbers seen before (a is signed in
        // to another account, say).
        stored = try XCTUnwrap(try report("a", session: "s3", api: 50_400, fiveHour: nil, sevenDay: 18, at: afterReset + 120))
        XCTAssertEqual(stored.sevenDay, window(18, resetsAt: now + 90 * hour, reportedAt: afterReset + 120))
    }

    /// Two `claude`s in one column (tmux in a Nirux terminal) keep apart.
    func testRecordTellsTwoClaudesInOneColumnApart() throws {
        try report("a", process: 100, api: 2700, fiveHour: 30, sevenDay: 18, at: now)
        try report("a", process: 200, api: 900, fiveHour: 35, sevenDay: 25, at: now + 60)
        let stored = try XCTUnwrap(try report("a", process: 100, api: 2700, fiveHour: 30, sevenDay: 18, at: now + 300))
        XCTAssertEqual(stored.fiveHour?.usedPercentage, 35, "the first one's idle repeat")
    }

    /// News goes to the day's readings log for the pace: a changed reading
    /// at once, the same one again only after the heartbeat, an idle repeat
    /// never. Turning the option off forgets the log with the rest.
    func testRecordLogsNewsForThePace() throws {
        let folder = ClaudeUsageLimitsFile.readingsFolder(beside: fileURL)
        func logged(_ window: String = "five_hour") -> [Double] {
            QuotaReadingLog.read(in: folder, since: 0)[window]?.map(\.usedPercent) ?? []
        }
        try report("a", api: 100, fiveHour: 30, sevenDay: 18, at: now)
        try report("a", api: 200, fiveHour: 30, sevenDay: 18, at: now + 60)
        XCTAssertEqual(logged(), [30], "a new claude's first report waits for its next response; that one logs")
        try report("a", api: 300, fiveHour: 31, sevenDay: 18, at: now + 120)
        let beat = now + 120 + ClaudeUsageLimitsFile.readingHeartbeat
        try report("a", api: 400, fiveHour: 31, sevenDay: 18, at: beat)
        try report("a", api: 400, fiveHour: 31, sevenDay: 18, at: beat + ClaudeUsageLimitsFile.readingHeartbeat)
        XCTAssertEqual(logged(), [30, 31, 31], "its prompt cache expired: a repeat, not a reading")
        XCTAssertEqual(logged("seven_day"), [18, 18])
        try report("a", session: "s2", api: 50_000, fiveHour: 12, sevenDay: 18, at: beat + 700)
        XCTAssertEqual(logged(), [30, 31, 31], "/resume of an older session: its numbers are old")

        ClaudeUsageLimitsFile.remove(at: fileURL)
        XCTAssertEqual(QuotaReadingLog.read(in: folder, since: 0), [:])
    }

    func testRecordTakesNothingFromOutsideNiruxOrWithoutLimits() throws {
        let report = try JSONSerialization.data(withJSONObject: payload(fiveHour: reading(30, resetsIn: hour)))
        XCTAssertFalse(ClaudeStatusLineCLI.record(payload: report, env: [:], now: now, url: fileURL))
        XCTAssertFalse(ClaudeStatusLineCLI.record(payload: report, env: ["NIRUX_AGENT_UUID": ""], now: now, url: fileURL))
        XCTAssertFalse(ClaudeStatusLineCLI.record(
            payload: Data(#"{"session_id":"s1"}"#.utf8), env: ["NIRUX_AGENT_UUID": "column-1"], now: now, url: fileURL
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    /// A writer stuck holding the lock must not hang every status line run.
    func testRecordGivesUpWhenTheLockStaysHeld() throws {
        let lock = open(fileURL.path + ".lock", O_RDWR | O_CREAT, 0o600)
        XCTAssertGreaterThanOrEqual(lock, 0)
        XCTAssertEqual(flock(lock, LOCK_EX), 0)
        defer { close(lock) }

        let start = Date()
        let report = ClaudeStatusLineReport(limits: ClaudeUsageLimits(fiveHour: window(30, resetsAt: now + hour)))
        XCTAssertFalse(ClaudeUsageLimitsFile.record(report, from: "column-1", now: now, at: fileURL))
        XCTAssertLessThan(Date().timeIntervalSince(start), ClaudeUsageLimitsFile.lockWait + 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    // MARK: - Monitor

    @MainActor
    func testMonitorShowsWhatStillAppliesAndPicksUpNewReports() throws {
        var reporting = true
        let monitor = ClaudeUsageLimitsMonitor(url: fileURL, isReporting: { reporting })
        var shown: [ClaudeUsageLimits?] = []
        monitor.onUpdate = { limits, _ in shown.append(limits) }
        let clock = Date(timeIntervalSince1970: now)
        func record(_ percent: Double) {
            let limits = ClaudeUsageLimits(fiveHour: window(percent, resetsAt: now + hour))
            ClaudeUsageLimitsFile.record(ClaudeStatusLineReport(limits: limits), from: nil, now: now, at: fileURL)
        }

        record(30)
        monitor.refresh(now: clock)
        XCTAssertTrue(shown.isEmpty, "off: nothing is read")

        monitor.setEnabled(true)
        defer { monitor.setEnabled(false) }
        monitor.refresh(now: clock)
        XCTAssertEqual(shown.last??.fiveHour?.usedPercentage, 30)

        record(35)
        monitor.refresh(now: clock)
        XCTAssertEqual(shown.last??.fiveHour?.usedPercentage, 35, "a rewrite is read again")
        XCTAssertEqual(monitor.readings["five_hour"]?.map(\.usedPercent), [30, 35], "the pace's readings come with it")

        reporting = false
        monitor.refresh(now: clock)
        XCTAssertEqual(shown.last, .some(nil), "a status line of the user's own: no more reports, nothing shown")
        reporting = true

        monitor.refresh(now: clock.addingTimeInterval(hour))
        XCTAssertEqual(shown.last, .some(nil), "the window reset")

        monitor.setEnabled(false)
        XCTAssertEqual(shown.last, .some(nil))
    }

    /// The binding limit and its pace: red once it runs out before its
    /// reset, its agent's windows in the meters, Codex only when it binds.
    @MainActor
    func testIndicatorNamesTheBindingLimitAndItsPace() {
        let indicator = ClaudeUsageIndicator()
        indicator.calendar = utc
        let claude = ClaudeUsageLimits(fiveHour: window(60, resetsAt: now + hour), sevenDay: window(20, resetsAt: now + 90 * hour))
        indicator.update(limits: claude, readings: ["five_hour": climb([45, 50, 55, 60], resetsAt: now + hour)], now: now)
        XCTAssertEqual(indicator.label.stringValue, "⚠︎ 5h full by 14:40")
        XCTAssertEqual(indicator.label.textColor, Theme.Color.error)
        XCTAssertEqual(indicator.meters.limits.map(\.length), [5 * hour, 7 * 24 * hour])
        XCTAssertEqual(indicator.meters.limits.map(QuotaMeterView.projected), [100, 20], "the hatch runs to the reset's forecast")
        XCTAssertTrue(indicator.view.toolTip?.contains("5h: full by 14:40, before its reset at 15:00") == true)
        XCTAssertTrue(indicator.view.toolTip?.contains("Claude 7d: 20% used, resets Wed 08:00 (in 3d 18h)") == true, "every window, from what's shown")
        XCTAssertTrue(indicator.view.accessibilityLabel()?.contains("7d 20% used") == true, "VoiceOver hears every window")
        // A `/resume` of an older session left 12 % in the file: the logged readings still tell the pace.
        let resumed = ClaudeUsageLimits(fiveHour: window(12, resetsAt: now + hour), sevenDay: window(20, resetsAt: now + 90 * hour))
        indicator.update(limits: resumed, readings: ["five_hour": climb([45, 50, 55, 60], resetsAt: now + hour)], now: now)
        XCTAssertEqual(indicator.label.stringValue, "⚠︎ 5h full by 14:40")

        indicator.update(limits: claude, readings: ["five_hour": climb([52.5, 55, 57.5, 60], resetsAt: now + hour)], now: now)
        XCTAssertEqual(indicator.label.stringValue, "5h 60% · ≈ 90%")
        XCTAssertNotEqual(indicator.label.textColor, Theme.Color.error)

        // Codex, nearly full, binds over a Claude that holds.
        let codex = CodexRateLimits(primary: .init(usedPercent: 99, minutes: 300, resetsAt: now + hour), reportedAt: now)
        let codexReadings = [98, 98.5, 99].enumerated().map { QuotaReading(time: now - Double(2 - $0.offset) * 450, usedPercent: $0.element, resetsAt: now + hour) }
        indicator.update(codex: codex, readings: [300: codexReadings], now: now)
        XCTAssertEqual(indicator.label.stringValue, "⚠︎ Codex 5h full by 14:15")
        XCTAssertEqual(indicator.meters.limits.map(\.agent), [.codex])
    }

    /// A click (or VoiceOver's press) opens every limit with its meter,
    /// pace and reset, Antigravity's as not published, and the Usage window.
    @MainActor
    func testPopoverListsEveryLimitAndOpensTheUsageWindow() throws {
        let indicator = ClaudeUsageIndicator()
        indicator.calendar = utc
        var presented = 0
        indicator.presentPopover = { _, _ in presented += 1 }
        var usageOpened = 0
        indicator.onShowUsage = { usageOpened += 1 }
        let claude = ClaudeUsageLimits(fiveHour: window(60, resetsAt: now + hour), sevenDay: window(20, resetsAt: now + 90 * hour))
        indicator.update(limits: claude, readings: ["five_hour": climb([45, 50, 55, 60], resetsAt: now + hour)], now: now)
        indicator.update(codex: CodexRateLimits(primary: .init(usedPercent: 12, minutes: 300, resetsAt: now + 3 * hour), reportedAt: now - 60), now: now)

        XCTAssertTrue(indicator.view.accessibilityPerformPress())
        XCTAssertEqual(presented, 1)
        // The same words keep the same views.
        let firstRow = indicator.popoverContent.view.subviews.first?.subviews.first
        indicator.popoverContent.update(limits: indicator.limits, now: now, calendar: utc)
        XCTAssertTrue(indicator.popoverContent.view.subviews.first?.subviews.first === firstRow)
        let texts = indicator.popoverContent.texts
        for expected in [
            "Claude · 5-hour window", "60%", "⚠︎ Full by 14:40, 20m before it resets at 15:00",
            "Claude · week", "20%", "Codex · 5-hour window", "12%", "Resets at 17:00 (in 3h)",
            "Antigravity", "Not published: agy shows its quota only in its own /usage."
        ] {
            XCTAssertTrue(texts.contains(expected), "\(expected) in \(texts)")
        }
        XCTAssertEqual(texts.firstIndex(of: "Claude · week").map { $0 < texts.firstIndex(of: "Codex · 5-hour window")! }, true)
        func buttons(in view: NSView) -> [NiruxButton] { ((view as? NiruxButton).map { [$0] } ?? []) + view.subviews.flatMap(buttons) }
        let usage = try XCTUnwrap(buttons(in: indicator.popoverContent.view).first { $0.title == "Usage…" })
        usage.performClick(nil)
        XCTAssertEqual(usageOpened, 1)
        // The click that closed the transient popover doesn't open it again.
        indicator.popoverDidClose(Notification(name: NSPopover.didCloseNotification))
        XCTAssertTrue(indicator.view.accessibilityPerformPress())
        XCTAssertEqual(presented, 1)

        let holding = try XCTUnwrap(QuotaLimit(agent: .claude, length: 5 * hour, readings: climb([52.5, 55, 57.5, 60], resetsAt: now + hour), now: now))
        XCTAssertEqual(UsageText.detail(holding, now: now, calendar: utc).text, "≈ 90% when it resets at 15:00 (in 1h)")
    }

    /// The tasks spending the session, under the limits, each with its
    /// actions; an action goes out with its task.
    @MainActor
    func testPopoverListsWhatSpendsTheSessionWithItsActions() throws {
        let indicator = ClaudeUsageIndicator()
        indicator.calendar = utc
        indicator.presentPopover = { _, _ in }
        let row = QuotaBurnRow(
            workspaceID: "task-1", title: "Search index rewrite", share: 0.64, points: 7.2, tokens: 2.4e6,
            cause: "Each message rereads 612k · 6 subagents", actions: [.compactAtTurnEnd(column: UUID()), .contextOffer(.freshStart, column: UUID())]
        )
        var askedWith: [QuotaReading]?
        indicator.burnRows = { readings in
            askedWith = readings
            return [row]
        }
        var taken: [String] = []
        indicator.onBurnAction = { id, action in taken.append("\(id) \(action.title)") }
        let readings = climb([45, 50, 55, 60], resetsAt: now + hour)
        indicator.update(limits: ClaudeUsageLimits(fiveHour: window(60, resetsAt: now + hour)), readings: ["five_hour": readings], now: now)
        XCTAssertTrue(indicator.view.accessibilityPerformPress())
        XCTAssertEqual(askedWith, readings, "calibrated on the 5-hour readings")
        let texts = indicator.popoverContent.texts
        for expected in ["What spends your session · last 30 min", "Search index rewrite", "≈ 7%", "Each message rereads 612k · 6 subagents", "Compact at turn end", "Fresh start"] {
            XCTAssertTrue(texts.contains(expected), "\(expected) in \(texts)")
        }
        func buttons(in view: NSView) -> [NiruxButton] { ((view as? NiruxButton).map { [$0] } ?? []) + view.subviews.flatMap(buttons) }
        try XCTUnwrap(buttons(in: indicator.popoverContent.view).first { $0.title == "Compact at turn end" }).performClick(nil)
        XCTAssertEqual(taken, ["task-1 Compact at turn end"])
    }

    func testAQueuedCompactWaitsForRestAndYieldsToADraft() {
        XCTAssertEqual(QueuedCompact.of(nil), .drop, "its claude left")
        XCTAssertEqual(QueuedCompact.of(LeadHoldings(isBusy: true)), .wait)
        XCTAssertEqual(QueuedCompact.of(LeadHoldings(hasDialog: true)), .wait)
        XCTAssertEqual(QueuedCompact.of(LeadHoldings(hasQuestion: true)), .wait)
        XCTAssertEqual(QueuedCompact.of(LeadHoldings(isBusy: true, hasDraft: true)), .yield, "the user's words win")
        XCTAssertEqual(QueuedCompact.of(LeadHoldings()), .send)
    }

    @MainActor
    func testIndicatorHidesWithoutLimitsAndTurnsNearTheLimit() {
        let indicator = ClaudeUsageIndicator()
        indicator.update(limits: ClaudeUsageLimits(fiveHour: window(42, resetsAt: now + hour)), now: now)
        XCTAssertTrue(indicator.isShowing)
        XCTAssertEqual(indicator.label.stringValue, "5h 42%")
        XCTAssertNotEqual(indicator.label.textColor, .niruxWarning)
        XCTAssertGreaterThanOrEqual(indicator.view.frame.width, indicator.label.frame.maxX)

        indicator.update(limits: ClaudeUsageLimits(fiveHour: window(85, resetsAt: now + hour)), now: now)
        // Near the limit: a warning, in the text's colour, never orange (it reads as amber).
        XCTAssertEqual(indicator.label.stringValue, "⚠︎ 5h 85%")
        XCTAssertEqual(indicator.label.textColor, .niruxWarning)

        // The controller's isHidden does nothing for a trailing accessory:
        // the view itself must take no room and show nothing.
        indicator.update(limits: nil, now: now)
        XCTAssertFalse(indicator.isShowing)
        XCTAssertTrue(indicator.view.isHidden)
        XCTAssertEqual(indicator.view.frame.width, 0)
    }
}
