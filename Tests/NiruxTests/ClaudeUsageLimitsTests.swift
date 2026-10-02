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

    // MARK: - Merging reports

    /// An idle session reports the numbers of its last response again: they
    /// must not replace newer, higher ones.
    func testMergeKeepsTheHigherReadingOfAWindow() {
        let resets = now + 2 * hour
        let current = ClaudeUsageLimits(fiveHour: window(40, resetsAt: resets, reportedAt: now - 60))

        let idle = current.merging(ClaudeUsageLimits(fiveHour: window(30, resetsAt: resets)))
        XCTAssertEqual(idle.fiveHour?.usedPercentage, 40)
        let same = current.merging(ClaudeUsageLimits(fiveHour: window(40, resetsAt: resets + 30)))
        XCTAssertEqual(same.fiveHour?.reportedAt, now - 60, "a tie may be an idle session: keep the earlier report")
        let busier = current.merging(ClaudeUsageLimits(fiveHour: window(45, resetsAt: resets + 30)))
        XCTAssertEqual(busier.fiveHour, window(45, resetsAt: resets + 30))
    }

    func testMergeMovesToALaterWindowAndIgnoresAnEarlierOne() {
        let current = ClaudeUsageLimits(fiveHour: window(90, resetsAt: now + hour), sevenDay: window(50, resetsAt: now + 50 * hour))
        let later = current.merging(ClaudeUsageLimits(fiveHour: window(5, resetsAt: now + 6 * hour)))
        XCTAssertEqual(later.fiveHour?.usedPercentage, 5, "a new 5-hour window began")
        XCTAssertEqual(later.sevenDay?.usedPercentage, 50, "a report without a window keeps the known one")

        let stale = later.merging(ClaudeUsageLimits(fiveHour: window(95, resetsAt: now + hour)))
        XCTAssertEqual(stale.fiveHour?.usedPercentage, 5, "a reading of the window before is old news")
    }

    func testCurrentDropsTheWindowsThatReset() {
        let limits = ClaudeUsageLimits(fiveHour: window(90, resetsAt: now + hour), sevenDay: window(50, resetsAt: now + 50 * hour))
        XCTAssertEqual(limits.current(at: now + hour - 1), limits)
        XCTAssertEqual(limits.current(at: now + hour), ClaudeUsageLimits(sevenDay: limits.sevenDay))
        XCTAssertNil(limits.current(at: now + 50 * hour))
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

    func testRecordFoldsTheReportsOfSeveralSessions() throws {
        let env = ["NIRUX_AGENT_UUID": "column-1"]
        let first = try JSONSerialization.data(withJSONObject: payload(fiveHour: reading(30, resetsIn: hour)))
        let second = try JSONSerialization.data(
            withJSONObject: payload(fiveHour: reading(25, resetsIn: hour), sevenDay: reading(10, resetsIn: 90 * hour))
        )
        XCTAssertTrue(ClaudeStatusLineCLI.record(payload: first, env: env, now: now, url: fileURL))
        XCTAssertTrue(ClaudeStatusLineCLI.record(payload: second, env: env, now: now + 5, url: fileURL))

        let stored = try XCTUnwrap(ClaudeUsageLimitsFile.load(from: fileURL))
        XCTAssertEqual(stored.fiveHour, window(30, resetsAt: now + hour), "the idle session's 25% loses")
        XCTAssertEqual(stored.sevenDay, window(10, resetsAt: now + 90 * hour, reportedAt: now + 5))
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
        XCTAssertFalse(ClaudeUsageLimitsFile.record(ClaudeUsageLimits(fiveHour: window(30, resetsAt: now + hour)), now: now, at: fileURL))
        XCTAssertLessThan(Date().timeIntervalSince(start), ClaudeUsageLimitsFile.lockWait + 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    // MARK: - Monitor

    @MainActor
    func testMonitorShowsWhatStillAppliesAndPicksUpNewReports() throws {
        let monitor = ClaudeUsageLimitsMonitor(url: fileURL)
        var shown: [ClaudeUsageLimits?] = []
        monitor.onUpdate = { shown.append($0) }
        let clock = Date(timeIntervalSince1970: now)

        ClaudeUsageLimitsFile.record(ClaudeUsageLimits(fiveHour: window(30, resetsAt: now + hour)), now: now, at: fileURL)
        monitor.refresh(now: clock)
        XCTAssertTrue(shown.isEmpty, "off: nothing is read")

        monitor.setEnabled(true)
        defer { monitor.setEnabled(false) }
        monitor.refresh(now: clock)
        XCTAssertEqual(shown.last??.fiveHour?.usedPercentage, 30)

        ClaudeUsageLimitsFile.record(ClaudeUsageLimits(fiveHour: window(35, resetsAt: now + hour)), now: now, at: fileURL)
        monitor.refresh(now: clock)
        XCTAssertEqual(shown.last??.fiveHour?.usedPercentage, 35, "a rewrite is read again")

        monitor.refresh(now: clock.addingTimeInterval(hour))
        XCTAssertEqual(shown.last, .some(nil), "the window reset")

        monitor.setEnabled(false)
        XCTAssertEqual(shown.last, .some(nil))
    }

    @MainActor
    func testIndicatorHidesWithoutLimitsAndTurnsNearTheLimit() {
        let indicator = ClaudeUsageIndicator()
        indicator.update(limits: ClaudeUsageLimits(fiveHour: window(42, resetsAt: now + hour)), now: now)
        XCTAssertFalse(indicator.isHidden)
        XCTAssertEqual(indicator.label.stringValue, "5h 42%")
        XCTAssertNotEqual(indicator.label.textColor, .niruxNearLimit)
        XCTAssertGreaterThanOrEqual(indicator.view.frame.width, indicator.label.frame.maxX)

        indicator.update(limits: ClaudeUsageLimits(fiveHour: window(85, resetsAt: now + hour)), now: now)
        XCTAssertEqual(indicator.label.textColor, .niruxNearLimit)

        indicator.update(limits: nil, now: now)
        XCTAssertTrue(indicator.isHidden)
    }
}
