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
        XCTAssertEqual(current.titleText, "5h 999%")
        XCTAssertNil(current.sevenDay, "a reset decades out never expires: dropped")
    }

    // MARK: - Display

    func testTitleShowsTheReportedWindowsAndTurnsAtEightyPercent() {
        let both = ClaudeUsageLimits(fiveHour: window(42.4, resetsAt: now + hour), sevenDay: window(79.4, resetsAt: now + 9 * hour))
        XCTAssertEqual(both.titleText, "5h 42% · 7d 79%")
        XCTAssertFalse(both.isNearLimit)

        let near = ClaudeUsageLimits(sevenDay: window(79.5, resetsAt: now + 9 * hour))
        XCTAssertEqual(near.titleText, "7d 80%")
        XCTAssertTrue(near.isNearLimit, "the color agrees with the number shown")
    }

    func testTooltipGivesEachResetAndWhenItWasReported() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_GB")
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let limits = ClaudeUsageLimits(
            fiveHour: window(25, resetsAt: now + 2 * hour + 600, reportedAt: now - 300),
            sevenDay: window(18, resetsAt: now + 99 * hour, reportedAt: now - 300)
        )
        XCTAssertEqual(limits.tooltip(now: now, calendar: calendar).components(separatedBy: "\n"), [
            "Claude plan usage limits",
            "5-hour window: 25% used, resets at 16:10 (in 2h 10m)",
            "Weekly limit: 18% used, resets Wed 17:00 (in 4d 3h)",
            "Last reported at 13:55 by a Claude session in Nirux.",
            "Use elsewhere (claude.ai, another Mac) counts from the next report."
        ])
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

        reporting = false
        monitor.refresh(now: clock)
        XCTAssertEqual(shown.last, .some(nil), "a status line of the user's own: no more reports, nothing shown")
        reporting = true

        monitor.refresh(now: clock.addingTimeInterval(hour))
        XCTAssertEqual(shown.last, .some(nil), "the window reset")

        monitor.setEnabled(false)
        XCTAssertEqual(shown.last, .some(nil))
    }

    @MainActor
    func testIndicatorHidesWithoutLimitsAndTurnsNearTheLimit() {
        let indicator = ClaudeUsageIndicator()
        indicator.update(limits: ClaudeUsageLimits(fiveHour: window(42, resetsAt: now + hour)), now: now)
        XCTAssertTrue(indicator.isShowing)
        XCTAssertEqual(indicator.label.stringValue, "5h 42%")
        XCTAssertNotEqual(indicator.label.textColor, .niruxNearLimit)
        XCTAssertGreaterThanOrEqual(indicator.view.frame.width, indicator.label.frame.maxX)

        indicator.update(limits: ClaudeUsageLimits(fiveHour: window(85, resetsAt: now + hour)), now: now)
        XCTAssertEqual(indicator.label.textColor, .niruxNearLimit)

        // The controller's isHidden does nothing for a trailing accessory:
        // the view itself must take no room and show nothing.
        indicator.update(limits: nil, now: now)
        XCTAssertFalse(indicator.isShowing)
        XCTAssertTrue(indicator.view.isHidden)
        XCTAssertEqual(indicator.view.frame.width, 0)
    }
}
