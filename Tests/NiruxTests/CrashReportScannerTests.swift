import XCTest
@testable import Nirux

final class CrashReportScannerTests: XCTestCase {
    private typealias Fixtures = CrashReportFixtures
    private var root: URL!
    private var reports: URL { root.appendingPathComponent("DiagnosticReports", isDirectory: true) }
    private var markerURL: URL { root.appendingPathComponent("state/crash-reports-seen.json") }
    private let hookBody = Fixtures.body(procRole: "Unspecified", parentProc: "node")

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nirux-crash-report-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var scanner: CrashReportScanner { scanner(markerURL: markerURL) }

    private func scanner(markerURL: URL) -> CrashReportScanner {
        CrashReportScanner(bundleID: Fixtures.bundleID, processName: "Nirux", directory: reports, markerURL: markerURL)
    }

    private func allCandidates() throws -> [CrashReportCandidate] {
        scanner.candidates(in: try FileManager.default.contentsOfDirectory(atPath: reports.path))
    }

    private func seenIncidents() -> Set<String> {
        Set(scanner.loadMarker()?.seen.values.map { $0 } ?? [])
    }

    @discardableResult
    private func writeReport(
        _ name: String,
        incidentID: String? = UUID().uuidString,
        timestamp: String? = Fixtures.timestamp,
        bundleID: String? = Fixtures.bundleID,
        bugType: String? = "309",
        body: String = Fixtures.body,
        modified: Date? = nil
    ) throws -> URL {
        let url = reports.appendingPathComponent(name)
        let header = Fixtures.header(incidentID: incidentID, timestamp: timestamp, bundleID: bundleID, bugType: bugType)
        try Fixtures.report(header: header, body: body).write(to: url)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
        return url
    }

    // MARK: - Detection

    func testNoReports() throws {
        XCTAssertNil(scanner.check(), "first check: nothing to report")
        XCTAssertEqual(scanner.loadMarker(), CrashReportMarker(seen: [:]))
        XCTAssertNil(scanner.check())

        try writeReport("Nirux-2026-09-27-111448.ips", incidentID: "A")
        let notice = try XCTUnwrap(scanner.check(), "any report is new once the marker exists")
        XCTAssertEqual(notice.report.header.incidentID, "A")
        XCTAssertEqual(notice.reportCount, 1)
    }

    func testFirstCheckOnlyRecordsExistingReports() throws {
        try writeReport("Nirux-2026-09-26-080000.ips", incidentID: "old", timestamp: "2026-09-26 08:00:00.00 +0200")
        try writeReport("Nirux-2026-09-27-111448.ips", incidentID: "A")

        XCTAssertNil(scanner.check(), "reports older than the feature are not news")
        XCTAssertNil(scanner.check())
        XCTAssertEqual(scanner.loadMarker()?.seen, [
            "Nirux-2026-09-26-080000.ips": "old",
            "Nirux-2026-09-27-111448.ips": "A"
        ])
    }

    func testNewReportShowsOnce() throws {
        try writeReport("Nirux-2026-09-26-080000.ips", incidentID: "old", timestamp: "2026-09-26 08:00:00.00 +0200")
        XCTAssertNil(scanner.check())

        let url = try writeReport("Nirux-2026-09-27-111448.ips", incidentID: "A")
        let notice = try XCTUnwrap(scanner.check())
        XCTAssertEqual(notice.reportURL.lastPathComponent, url.lastPathComponent)
        XCTAssertEqual(notice.report.header.incidentID, "A")
        XCTAssertTrue(notice.report.hasBody)
        XCTAssertEqual(notice.reportCount, 1)
        XCTAssertEqual(notice.headline, "EXC_BREAKPOINT in NiruxShellView.inspectForPanel")
        let reportLine = try XCTUnwrap(notice.summary.components(separatedBy: "\n").last)
        XCTAssertTrue(reportLine.hasPrefix("Report: /"), "a full path: \(reportLine)")
        XCTAssertTrue(reportLine.hasSuffix("/DiagnosticReports/Nirux-2026-09-27-111448.ips"), reportLine)

        XCTAssertNil(scanner.check(), "already shown")
        XCTAssertNil(scanner.check())
    }

    func testSeveralNewReportsShowTheNewest() throws {
        XCTAssertNil(scanner.check())
        try writeReport("Nirux-2026-09-27-090000.ips", incidentID: "first", timestamp: "2026-09-27 09:00:00.00 +0200")
        try writeReport("Nirux-2026-09-27-100000.ips", incidentID: "second", timestamp: "2026-09-27 10:00:00.00 +0200")

        let notice = try XCTUnwrap(scanner.check())
        XCTAssertEqual(notice.report.header.incidentID, "second")
        XCTAssertEqual(notice.reportCount, 2)
        XCTAssertTrue(notice.summary.contains("\n1 earlier crash report in the same folder.\n"))
        XCTAssertNil(scanner.check())
    }

    /// Reports don't reach the disk in the order they are stamped: a big
    /// one can land after a smaller, later one was already seen.
    func testReportLandingOutOfOrderIsStillNews() throws {
        XCTAssertNil(scanner.check())
        try writeReport("Nirux-2026-09-27-100030.ips", incidentID: "later", timestamp: "2026-09-27 10:00:30.50 +0200")
        XCTAssertEqual(try XCTUnwrap(scanner.check()).report.header.incidentID, "later")

        try writeReport("Nirux-2026-09-27-100030.000.ips", incidentID: "earlier", timestamp: "2026-09-27 10:00:30.10 +0200")
        XCTAssertEqual(try XCTUnwrap(scanner.check()).report.header.incidentID, "earlier")
        XCTAssertNil(scanner.check())
    }

    func testDuplicateIncidentCountsOnce() throws {
        XCTAssertNil(scanner.check())
        let written = Date()
        try writeReport("Nirux-2026-09-27-111448.ips", incidentID: "A", modified: written)
        try writeReport("Nirux-2026-09-27-111448.000.ips", incidentID: "A", modified: written)

        let notice = try XCTUnwrap(scanner.check())
        XCTAssertEqual(notice.reportCount, 1)
        XCTAssertEqual(notice.reportURL.lastPathComponent, "Nirux-2026-09-27-111448.000.ips")
        XCTAssertEqual(scanner.loadMarker()?.seen.count, 2, "both files are recorded, neither is read again")
        XCTAssertNil(scanner.check())
    }

    /// Two crashes a few seconds apart, written in the same instant: the
    /// `.000` suffix only avoids the name collision.
    func testSameInstantReportsAreDistinctCrashes() throws {
        XCTAssertNil(scanner.check())
        let written = Date()
        try writeReport("Nirux-2026-09-27-111448.ips", incidentID: "earlier", modified: written)
        try writeReport("Nirux-2026-09-27-111448.000.ips", incidentID: "later", modified: written.addingTimeInterval(0.065))

        let notice = try XCTUnwrap(scanner.check())
        XCTAssertEqual(notice.reportCount, 2)
        XCTAssertEqual(notice.report.header.incidentID, "later", "the later write is the later crash")
        XCTAssertNil(scanner.check())
    }

    func testEqualWriteTimesGoByTheCollisionSuffix() throws {
        XCTAssertNil(scanner.check())
        let written = Date()
        try writeReport("Nirux-2026-09-27-111448.001.ips", incidentID: "third", modified: written)
        try writeReport("Nirux-2026-09-27-111448.ips", incidentID: "first", modified: written)
        try writeReport("Nirux-2026-09-27-111448.000.ips", incidentID: "second", modified: written)

        XCTAssertEqual(try allCandidates().map(\.key), ["third", "second", "first"])
        XCTAssertEqual(try XCTUnwrap(scanner.check()).report.header.incidentID, "third")
    }

    func testCollisionIndex() {
        XCTAssertEqual(CrashReportCandidate.collisionIndex("Nirux-2026-09-27-111448.ips"), -1)
        XCTAssertEqual(CrashReportCandidate.collisionIndex("Nirux-2026-09-27-111448.000.ips"), 0)
        XCTAssertEqual(CrashReportCandidate.collisionIndex("Nirux-2026-09-27-111448.012.ips"), 12)
        XCTAssertEqual(CrashReportCandidate.collisionIndex("Nirux-2026-09-27-111448.x1.ips"), -1)
        XCTAssertEqual(CrashReportCandidate.collisionIndex("Nirux-1.99999999999999999999999.ips"), -1)
        XCTAssertEqual(CrashReportCandidate.collisionIndex("Nirux.ips"), -1)
    }

    /// `Nirux --hook` is the app's own binary: its crashes carry the bundle
    /// ID, but the app didn't crash.
    func testHookCrashesAreNotAppCrashes() throws {
        XCTAssertNil(scanner.check())
        try writeReport("Nirux-2026-09-27-111448.ips", incidentID: "hook", body: hookBody)
        XCTAssertNil(scanner.check())
        XCTAssertEqual(seenIncidents(), ["hook"], "read once, not at every check")

        try writeReport("Nirux-2026-09-27-120000.ips", incidentID: "app", timestamp: "2026-09-27 12:00:00.00 +0200")
        try writeReport(
            "Nirux-2026-09-27-120500.ips", incidentID: "later-hook", timestamp: "2026-09-27 12:05:00.00 +0200",
            body: hookBody
        )
        let notice = try XCTUnwrap(scanner.check(), "a later hook crash doesn't hide the app's")
        XCTAssertEqual(notice.report.header.incidentID, "app")
        XCTAssertEqual(notice.reportCount, 1)
        XCTAssertNil(scanner.check())
    }

    func testReportStillBeingWrittenIsLookedAtAgain() throws {
        let now = Date()
        XCTAssertNil(scanner.check(now: now))
        let body = Fixtures.body
        let url = try writeReport("Nirux-2026-09-27-111448.ips", incidentID: "A", body: String(body.prefix(200)), modified: now)

        XCTAssertNil(scanner.check(now: now), "maybe still being written")
        XCTAssertEqual(seenIncidents(), [])

        try Fixtures.report(header: Fixtures.header(incidentID: "A"), body: body).write(to: url)
        let notice = try XCTUnwrap(scanner.check(now: now.addingTimeInterval(30)))
        XCTAssertTrue(notice.report.hasBody)
        XCTAssertNil(scanner.check(now: now.addingTimeInterval(60)))
    }

    func testTruncatedReportShowsOnceItIsOld() throws {
        let now = Date()
        XCTAssertNil(scanner.check(now: now))
        let body = Fixtures.body
        try writeReport("Nirux-2026-09-27-111448.ips", incidentID: "A", body: String(body.prefix(200)), modified: now)
        XCTAssertNil(scanner.check(now: now))

        let notice = try XCTUnwrap(scanner.check(now: now.addingTimeInterval(CrashReportScanner.writeGrace)))
        XCTAssertFalse(notice.report.hasBody)
        XCTAssertEqual(notice.headline, "no details in the report")
        XCTAssertTrue(notice.summary.contains("only its header was parsed"))
        XCTAssertNil(scanner.check(now: now.addingTimeInterval(CrashReportScanner.writeGrace * 2)))
    }

    func testIgnoresOtherAppsBuildsAndReportKinds() throws {
        XCTAssertNil(scanner.check())
        try writeReport("Nirux-2026-09-27-120000.ips", bundleID: nil)
        try writeReport("Nirux-2026-09-27-120001.ips", bundleID: "com.example.nirux-dev")
        try writeReport("Nirux-2026-09-27-120002.ips", bugType: "288")
        try writeReport("NiruxHelper-2026-09-27-120003.ips")
        try writeReport("Other-2026-09-27-120004.ips")
        try writeReport("Nirux-2026-09-27-120005.diag")
        try FileManager.default.createDirectory(
            at: reports.appendingPathComponent("Nirux-2026-09-27-120006.ips"), withIntermediateDirectories: true
        )
        try Data("garbage".utf8).write(to: reports.appendingPathComponent("Nirux-2026-09-27-120007.ips"))

        XCTAssertEqual(try allCandidates(), [])
        XCTAssertNil(scanner.check())
    }

    func testMalformedTimestampFallsBackToTheFile() throws {
        XCTAssertNil(scanner.check())
        for (index, timestamp) in ["2026-09-27 . +0200", "2026-09-27 .. +0200", "."].enumerated() {
            try writeReport("Nirux-2026-09-27-11144\(index).ips", incidentID: "bad-\(index)", timestamp: timestamp)
        }
        XCTAssertEqual(try allCandidates().count, 3)
        XCTAssertEqual(try XCTUnwrap(scanner.check()).reportCount, 3)
    }

    func testReportWithoutTimestampOrIncidentUsesTheFile() throws {
        XCTAssertNil(scanner.check())
        let modified = Date().addingTimeInterval(-30)
        try writeReport("Nirux-2026-09-27-111448.ips", incidentID: nil, timestamp: nil, modified: modified)

        let candidate = try XCTUnwrap(try allCandidates().first)
        XCTAssertEqual(candidate.key, "Nirux-2026-09-27-111448.ips")
        XCTAssertEqual(candidate.date.timeIntervalSince1970, modified.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertNotNil(scanner.check())
        XCTAssertNil(scanner.check())
    }

    func testSeenFilesAreNotOpenedAgain() throws {
        let url = try writeReport("Nirux-2026-09-27-111448.ips", incidentID: "A")
        XCTAssertNil(scanner.check())
        try Fixtures.report(header: Fixtures.header(incidentID: "rewritten")).write(to: url)
        XCTAssertNil(scanner.check())
    }

    func testGoneFilesAreForgotten() throws {
        let old = try writeReport("Nirux-2026-09-26-080000.ips", incidentID: "old")
        XCTAssertNil(scanner.check())
        try FileManager.default.removeItem(at: old)
        try writeReport("Nirux-2026-09-27-111448.ips", incidentID: "A")

        XCTAssertNotNil(scanner.check())
        XCTAssertEqual(scanner.loadMarker()?.seen, ["Nirux-2026-09-27-111448.ips": "A"])
    }

    func testUnreadableMarkerStartsOver() throws {
        try writeReport("Nirux-2026-09-27-111448.ips", incidentID: "A")
        try FileManager.default.createDirectory(at: markerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: markerURL)

        XCTAssertNil(scanner.check(), "no spam of old crashes after a damaged marker")
        XCTAssertEqual(seenIncidents(), ["A"])
    }

    /// Showing a crash the marker can't remember would show it at every launch.
    func testMarkerThatCannotBeSavedShowsNothing() throws {
        let locked = root.appendingPathComponent("locked", isDirectory: true)
        let lockedScanner = scanner(markerURL: locked.appendingPathComponent("crash-reports-seen.json"))
        XCTAssertNil(lockedScanner.check())
        try writeReport("Nirux-2026-09-27-111448.ips", incidentID: "A")

        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        XCTAssertNil(lockedScanner.check())
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)
        XCTAssertEqual(try XCTUnwrap(lockedScanner.check()).report.header.incidentID, "A", "still unseen")
    }

    /// macOS creates the folder with the account's first report: that
    /// first crash is news, not the state of things to record.
    func testFirstCrashOfTheAccountShows() throws {
        try FileManager.default.removeItem(at: reports)
        XCTAssertNil(scanner.check())
        XCTAssertEqual(scanner.loadMarker(), CrashReportMarker())

        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        try writeReport("Nirux-2026-09-27-111448.ips", incidentID: "A")
        XCTAssertEqual(try XCTUnwrap(scanner.check()).report.header.incidentID, "A")
    }

    func testUnreadableReportsFolderChangesNothing() throws {
        try writeReport("Nirux-2026-09-27-111448.ips", incidentID: "A")
        try FileManager.default.setAttributes([.posixPermissions: 0o300], ofItemAtPath: reports.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: reports.path) }
        XCTAssertNil(scanner.check())
        XCTAssertNil(scanner.loadMarker())
    }

    func testDuplicateIncidentShowsTheCompleteFile() throws {
        XCTAssertNil(scanner.check())
        let written = Date().addingTimeInterval(-600)
        try writeReport("Nirux-2026-09-27-111448.ips", incidentID: "A", modified: written)
        try writeReport(
            "Nirux-2026-09-27-111448.000.ips", incidentID: "A", body: String(Fixtures.body.prefix(200)),
            modified: written.addingTimeInterval(1)
        )
        let notice = try XCTUnwrap(scanner.check())
        XCTAssertTrue(notice.report.hasBody)
        XCTAssertEqual(notice.reportURL.lastPathComponent, "Nirux-2026-09-27-111448.ips")
    }

    func testModificationDateAheadOfTheClockIsNotWaitedFor() throws {
        let now = Date()
        XCTAssertNil(scanner.check(now: now))
        try writeReport(
            "Nirux-2026-09-27-111448.ips", incidentID: "A", body: String(Fixtures.body.prefix(200)),
            modified: now.addingTimeInterval(3 * 24 * 3600)
        )
        XCTAssertFalse(try XCTUnwrap(scanner.check(now: now)).report.hasBody)
    }

    // MARK: - Marker and notice

    func testMarkerRecordsAndForgets() {
        func candidate(_ name: String, _ key: String) -> CrashReportCandidate {
            CrashReportCandidate(
                url: URL(fileURLWithPath: "/r/\(name)"), header: CrashReportHeader(),
                date: Date(timeIntervalSince1970: 0), modified: nil, key: key
            )
        }
        let marker = CrashReportMarker(seen: ["a.ips": "A", "gone.ips": "G"])
        XCTAssertFalse(marker.isNew(candidate("a.000.ips", "A")), "another file of a seen incident")
        XCTAssertTrue(marker.isNew(candidate("a.ips", "B")))

        let next = marker.recording([candidate("b.ips", "B")], listing: ["a.ips", "b.ips"])
        XCTAssertEqual(next, CrashReportMarker(seen: ["a.ips": "A", "b.ips": "B"]))
    }

    func testNoticesMerge() throws {
        let report = try XCTUnwrap(CrashReportParser.report(from: Fixtures.report()))
        func notice(_ name: String, at time: TimeInterval, count: Int) -> CrashNotice {
            CrashNotice(
                report: report, reportURL: URL(fileURLWithPath: "/r/\(name)"),
                date: Date(timeIntervalSince1970: time), reportCount: count
            )
        }
        let older = notice("old.ips", at: 10, count: 1), newer = notice("new.ips", at: 20, count: 2)
        XCTAssertEqual(older.merged(with: newer).reportURL.lastPathComponent, "new.ips")
        XCTAssertEqual(newer.merged(with: older).reportURL.lastPathComponent, "new.ips")
        XCTAssertEqual(older.merged(with: newer).reportCount, 3)
    }

    func testMarkerSurvivesItsFile() throws {
        let marker = CrashReportMarker(seen: ["Nirux-2026-09-27-111448.ips": "A"])
        XCTAssertEqual(try JSONDecoder().decode(CrashReportMarker.self, from: JSONEncoder().encode(marker)), marker)
    }
}
