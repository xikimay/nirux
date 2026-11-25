import Foundation
@testable import NiruxCore
import Testing

struct QuotaPaceTests {
    let now: TimeInterval = 1_795_000_000
    let span = QuotaPace.sessionSpan

    /// Readings every 5 minutes, ending now, of the window resetting at `resetsAt`.
    func readings(_ percents: [Double], every step: TimeInterval = 300, resetsAt: TimeInterval) -> [QuotaReading] {
        percents.enumerated().map { index, percent in
            QuotaReading(time: now - Double(percents.count - 1 - index) * step, usedPercent: percent, resetsAt: resetsAt)
        }
    }

    @Test func aSteadyClimbRunsOutBeforeTheResetRoundedDownToFiveMinutes() {
        // 1 point a minute from 60 %: full in 40 minutes, the reset is in an hour.
        let climb = readings([45, 50, 55, 60], resetsAt: now + 3_600)
        #expect(QuotaPace.forecast(climb, span: span, now: now) == .runsOut(at: ((now + 2_400) / 300).rounded(.down) * 300))
        // Half the pace: about 90 % at the reset.
        let slow = readings([52.5, 55, 57.5, 60], resetsAt: now + 3_600)
        #expect(QuotaPace.forecast(slow, span: span, now: now) == .atReset(percent: 90))
    }

    @Test func tooFewReadingsOrTooShortASpanTellNothing() {
        // Two readings 15 minutes apart.
        #expect(QuotaPace.forecast(readings([45, 60], every: 900, resetsAt: now + 3_600), span: span, now: now) == .unknown)
        // Three readings over 10 minutes only.
        #expect(QuotaPace.forecast(readings([50, 55, 60], resetsAt: now + 3_600), span: span, now: now) == .unknown)
        #expect(QuotaPace.forecast(readings([40, 50, 55, 60], resetsAt: now + 3_600), span: span, now: now) != .unknown)
    }

    @Test func noReadingWithinTheSpanIsQuietAndAFullWindowIsReached() {
        let old = [QuotaReading(time: now - 3_600, usedPercent: 30, resetsAt: now + 3_600)]
        #expect(QuotaPace.forecast(old, span: span, now: now) == .quiet)
        #expect(QuotaPace.forecast(readings([90, 95, 100], resetsAt: now + 600), span: span, now: now) == .reached)
        // A window that reset leaves nothing to forecast.
        #expect(QuotaPace.forecast(readings([10, 20, 30], resetsAt: now - 1), span: span, now: now) == .unknown)
    }

    @Test func readingsOfThePreviousWindowDoNotCount() {
        // The window reset 10 minutes ago: the readings at 95 % belong to the old one.
        let previous = readings([93, 95], every: 300, resetsAt: now - 600).map { reading in
            QuotaReading(time: reading.time - 900, usedPercent: reading.usedPercent, resetsAt: reading.resetsAt)
        }
        let current = readings([1, 2, 3, 4], resetsAt: now + 4 * 3_600)
        #expect(QuotaPace.forecast(previous + current, span: span, now: now) == .atReset(percent: 52))
    }

    @Test func theRunsOutTimeHoldsUntilItMovesByMoreThanTenMinutes() {
        let climb = readings([45, 50, 55, 60], resetsAt: now + 3_600)
        guard case .runsOut(let fresh) = QuotaPace.forecast(climb, span: span, now: now) else {
            Issue.record("no forecast")
            return
        }
        let shown = fresh - 600
        #expect(QuotaPace.forecast(climb, span: span, now: now, previous: .runsOut(at: shown)) == .runsOut(at: shown))
        #expect(QuotaPace.forecast(climb, span: span, now: now, previous: .runsOut(at: shown - 300)) == .runsOut(at: fresh))
        // A held time that went by gives way.
        let later = now + 1_200
        let forecast = QuotaPace.forecast(climb, span: span + 1_200, now: later, previous: .runsOut(at: later - 60))
        guard case .runsOut(let moved) = forecast else {
            Issue.record("no forecast")
            return
        }
        #expect(moved > later)
    }

    @Test func aLimitAboutToFillNeverShowsATimeGoneByNorAHundredAtItsReset() {
        // 97 % a minute ago, a point a minute: full in 2 minutes.
        let fast = (0..<4).map { QuotaReading(time: now - 60 - Double(3 - $0) * 300, usedPercent: 82 + Double($0) * 5, resetsAt: now + 3_600) }
        guard case .runsOut(let at) = QuotaPace.forecast(fast, span: span, now: now) else {
            Issue.record("no forecast")
            return
        }
        #expect(at >= now)
        // 99.7 % at the reset: not full.
        let near = readings([99.1, 99.3, 99.5], every: 450, resetsAt: now + 600)
        #expect(QuotaPace.forecast(near, span: span, now: now) == .atReset(percent: 99))
    }

    @Test func theBindingLimitIsTheOneThatStopsTheAgentsFirst() throws {
        func limit(_ agent: QuotaLimit.Agent, _ length: TimeInterval, _ percents: [Double], resetsIn: TimeInterval) throws -> QuotaLimit {
            try #require(QuotaLimit(agent: agent, length: length, readings: readings(percents, resetsAt: now + resetsIn), now: now))
        }
        let week = try limit(.claude, 7 * 86_400, [70, 70, 70, 70], resetsIn: 86_400)
        let session = try limit(.claude, 5 * 3_600, [52.5, 55, 57.5, 60], resetsIn: 3_600)
        let codex = try limit(.codex, 5 * 3_600, [30, 30, 30, 30], resetsIn: 3_600)
        #expect(session.forecast == .atReset(percent: 90))
        #expect(QuotaLimit.binding([codex, week, session])?.id == session.id, "90 % at its reset beats 30 %")
        // Half a point every 5 minutes: the week is full in under 5 hours.
        let climbingWeek = try limit(.claude, 7 * 86_400, [70, 70.5, 71, 71.5], resetsIn: 86_400)
        #expect(climbingWeek.runsOut && !session.runsOut)
        #expect(QuotaLimit.binding([session, climbingWeek])?.id == climbingWeek.id)
        let fast = try limit(.claude, 5 * 3_600, [45, 50, 55, 60], resetsIn: 3_600)
        #expect(QuotaLimit.binding([climbingWeek, fast])?.id == fast.id, "it runs out first")
        let full = try limit(.codex, 5 * 3_600, [98, 99, 100], resetsIn: 600)
        #expect(QuotaLimit.binding([fast, full, climbingWeek])?.id == full.id)
        #expect(QuotaLimit(agent: .claude, length: 3_600, readings: readings([10], resetsAt: now - 1), now: now) == nil)
    }

    @Test func theWeekTakesItsPaceOverADay() {
        #expect(QuotaPace.span(forWindowOf: 5 * 3_600) == QuotaPace.sessionSpan)
        #expect(QuotaPace.span(forWindowOf: 7 * 86_400) == QuotaPace.weekSpan)
        #expect(QuotaPace.elapsed(resetsAt: now + 3_600, length: 5 * 3_600, now: now) == 0.8)
    }

    @Test func theLogKeepsNumbersOnlyAndDropsDaysPastItsKeep() throws {
        let folder = UsageFixture.temporaryFolder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let old = folder + "/" + QuotaReadingLog.fileName(at: now - 9 * 86_400)
        try UsageFixture.write(["{}"], to: old)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: now - 9 * 86_400)], ofItemAtPath: old)

        let fiveHour = QuotaReading(time: now, usedPercent: 42, resetsAt: now + 3_600)
        let week = QuotaReading(time: now, usedPercent: 71, resetsAt: now + 86_400)
        QuotaReadingLog.append(["five_hour": fiveHour, "seven_day": week], in: folder)
        QuotaReadingLog.append(["five_hour": QuotaReading(time: now + 60, usedPercent: 43, resetsAt: now + 3_600)], in: folder)

        #expect(!FileManager.default.fileExists(atPath: old))
        let line = try String(contentsOfFile: folder + "/" + QuotaReadingLog.fileName(at: now), encoding: .utf8).split(separator: "\n")[0]
        let keys = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]).keys.sorted()
        #expect(keys == ["resets_at", "time", "used", "window"])
        let read = QuotaReadingLog.read(in: folder, since: now - 3_600)
        #expect(read["five_hour"]?.map(\.usedPercent) == [42, 43])
        #expect(read["seven_day"] == [week])
        #expect(QuotaReadingLog.read(in: folder, since: now + 30)["five_hour"]?.count == 1)
        QuotaReadingLog.removeAll(in: folder)
        #expect(QuotaReadingLog.read(in: folder, since: 0).isEmpty)
    }
}
