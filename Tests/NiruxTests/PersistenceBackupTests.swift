import XCTest
@testable import Nirux

/// Recovery copies next to state.json (rotating backups, daily snapshots,
/// unreadable files set aside), exercised through a throwaway NIRUX_STATE_DIR.
final class PersistenceBackupTests: XCTestCase {
    private var directory: URL!
    private var previousStateDirectory: String?
    private let unreadable = Data(#"{"workspaces": "written by a newer build"}"#.utf8)

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nirux-backups-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        previousStateDirectory = ProcessInfo.processInfo.environment["NIRUX_STATE_DIR"]
        setenv("NIRUX_STATE_DIR", directory.path, 1)
    }

    override func tearDownWithError() throws {
        if let previousStateDirectory {
            setenv("NIRUX_STATE_DIR", previousStateDirectory, 1)
        } else {
            unsetenv("NIRUX_STATE_DIR")
        }
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    // MARK: - Rotating backups

    func testUnchangedSaveDoesNotRotateBackups() throws {
        XCTAssertTrue(Persistence.save(state("one"), now: date(day: 1)))
        XCTAssertTrue(Persistence.save(state("one"), now: date(day: 1)))
        XCTAssertNil(contents("state.backup.1.json"))

        let first = contents("state.json")
        XCTAssertTrue(Persistence.save(state("two"), now: date(day: 1)))
        XCTAssertTrue(Persistence.save(state("two"), now: date(day: 1)))

        XCTAssertEqual(contents("state.backup.1.json"), first)
        XCTAssertNil(contents("state.backup.2.json"))
        XCTAssertEqual(Persistence.load()?.workspaces.first?.title, "two")
    }

    func testBackupsKeepTheFiveLatestDistinctStates() throws {
        for index in 0...6 {
            XCTAssertTrue(Persistence.save(state("s\(index)"), now: date(day: 1)))
        }

        XCTAssertEqual(try title("state.backup.1.json"), "s5")
        XCTAssertEqual(try title("state.backup.5.json"), "s1")
        XCTAssertNil(contents("state.backup.6.json"))
    }

    // MARK: - Daily snapshots

    func testDailySnapshotKeepsTheFirstSaveOfEachDayForAWeek() throws {
        XCTAssertTrue(Persistence.save(state("morning"), now: date(day: 1, hour: 9)))
        XCTAssertTrue(Persistence.save(state("evening"), now: date(day: 1, hour: 18)))
        XCTAssertEqual(try title("state.daily.2026-03-01.json"), "morning")

        for day in 2...9 {
            XCTAssertTrue(Persistence.save(state("day \(day)"), now: date(day: day)))
        }

        XCTAssertEqual(files(prefix: "state.daily."), (3...9).map { String(format: "state.daily.2026-03-%02d.json", $0) })
        XCTAssertEqual(try title("state.daily.2026-03-09.json"), "day 9")
    }

    func testUnchangedSaveOnANewDayStillWritesItsSnapshot() throws {
        XCTAssertTrue(Persistence.save(state("idle"), now: date(day: 1)))
        XCTAssertTrue(Persistence.save(state("idle"), now: date(day: 2)))

        XCTAssertEqual(try title("state.daily.2026-03-02.json"), "idle")
        XCTAssertNil(contents("state.backup.1.json"))
    }

    // MARK: - Load fallback

    func testLoadRecoversFromTheNewestReadableBackupFirst() throws {
        try write(unreadable, "state.json")
        try write(unreadable, "state.backup.1.json")
        try write(encoded("backup 2"), "state.backup.2.json")
        try write(encoded("backup 3"), "state.backup.3.json")
        try write(encoded("daily"), "state.daily.2026-03-01.json")

        XCTAssertEqual(Persistence.load()?.workspaces.first?.title, "backup 2")
    }

    func testLoadFallsBackToTheNewestReadableDailySnapshot() throws {
        try write(unreadable, "state.json")
        for index in 1...5 {
            try write(unreadable, "state.backup.\(index).json")
        }
        try write(encoded("older"), "state.daily.2026-03-01.json")
        try write(encoded("newer"), "state.daily.2026-03-02.json")
        try write(unreadable, "state.daily.2026-03-03.json")

        XCTAssertEqual(Persistence.load()?.workspaces.first?.title, "newer")
    }

    func testLoadReturnsNilWhenNoCopyDecodes() throws {
        try write(unreadable, "state.json")
        try write(unreadable, "state.backup.1.json")

        XCTAssertNil(Persistence.load())
    }

    func testLoadSeesStateReplacedOnDisk() throws {
        XCTAssertTrue(Persistence.save(state("saved"), now: date(day: 1)))
        XCTAssertEqual(Persistence.load()?.workspaces.first?.title, "saved")

        try write(encoded("edited"), "state.json")

        XCTAssertEqual(Persistence.load()?.workspaces.first?.title, "edited")
    }

    // MARK: - Unreadable state.json

    func testSaveSetsUnreadableStateAsideAndLeavesBackupsUntouched() throws {
        try write(unreadable, "state.json")
        try write(encoded("backup 1"), "state.backup.1.json")
        try write(encoded("backup 2"), "state.backup.2.json")
        let backups = [contents("state.backup.1.json"), contents("state.backup.2.json")]
        // Recovery must not make save mistake the unreadable file for a good one.
        XCTAssertEqual(Persistence.load()?.workspaces.first?.title, "backup 1")

        XCTAssertTrue(Persistence.save(state("recovered"), now: date(day: 3, hour: 14, minute: 5, second: 9)))

        XCTAssertEqual(contents("state.corrupt.2026-03-03-140509.json"), unreadable)
        XCTAssertEqual([contents("state.backup.1.json"), contents("state.backup.2.json")], backups)
        XCTAssertNil(contents("state.backup.3.json"))
        XCTAssertEqual(Persistence.load()?.workspaces.first?.title, "recovered")

        // Once state.json decodes again, saves rotate as usual.
        XCTAssertTrue(Persistence.save(state("next"), now: date(day: 3)))
        XCTAssertEqual(try title("state.backup.1.json"), "recovered")
        XCTAssertEqual(try title("state.backup.2.json"), "backup 1")
    }

    func testIdenticalUnreadableStateIsSetAsideOnce() throws {
        try write(unreadable, "state.json")
        XCTAssertTrue(Persistence.save(state("a"), now: date(day: 1, hour: 10)))
        try write(unreadable, "state.json")
        XCTAssertTrue(Persistence.save(state("b"), now: date(day: 1, hour: 11)))
        XCTAssertEqual(files(prefix: "state.corrupt.").count, 1)

        try write(Data("not json".utf8), "state.json")
        XCTAssertTrue(Persistence.save(state("c"), now: date(day: 1, hour: 11)))

        XCTAssertEqual(files(prefix: "state.corrupt."), [
            "state.corrupt.2026-03-01-100000.json",
            "state.corrupt.2026-03-01-110000.json"
        ])
    }

    func testSetAsideCopiesArePrunedToTheTenNewest() throws {
        for hour in 0..<10 {
            try write(Data("old \(hour)".utf8), String(format: "state.corrupt.2026-03-01-%02d0000.json", hour))
        }
        try write(unreadable, "state.json")

        XCTAssertTrue(Persistence.save(state("fresh"), now: date(day: 2)))

        let copies = files(prefix: "state.corrupt.")
        XCTAssertEqual(copies.count, 10)
        XCTAssertFalse(copies.contains("state.corrupt.2026-03-01-000000.json"))
        XCTAssertEqual(contents("state.corrupt.2026-03-02-120000.json"), unreadable)
    }

    func testSaveNeverReplacesStateItCannotRead() throws {
        try XCTSkipIf(getuid() == 0, "root reads files regardless of mode")
        try write(unreadable, "state.json")
        let stateURL = directory.appendingPathComponent("state.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: stateURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: stateURL.path) }

        XCTAssertFalse(Persistence.save(state("blind"), now: date(day: 1)))

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: stateURL.path)
        XCTAssertEqual(contents("state.json"), unreadable)
    }

    // MARK: - Helpers

    private func state(_ title: String) -> PersistedState {
        PersistedState(
            workspaces: [PersistedWorkspace(title: title, cwd: "/tmp/project", columns: [], focusedColumnIndex: 0)],
            activeWorkspaceIndex: 0
        )
    }

    private func encoded(_ title: String) throws -> Data {
        try JSONEncoder().encode(state(title))
    }

    private func date(day: Int, hour: Int = 12, minute: Int = 0, second: Int = 0) -> Date {
        let parts = DateComponents(year: 2026, month: 3, day: day, hour: hour, minute: minute, second: second)
        return Calendar.current.date(from: parts)!
    }

    private func write(_ data: Data, _ name: String) throws {
        try data.write(to: directory.appendingPathComponent(name))
    }

    private func contents(_ name: String) -> Data? {
        try? Data(contentsOf: directory.appendingPathComponent(name))
    }

    private func title(_ name: String) throws -> String? {
        let data = try XCTUnwrap(contents(name), "\(name) missing")
        return try JSONDecoder().decode(PersistedState.self, from: data).workspaces.first?.title
    }

    private func files(prefix: String) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasPrefix(prefix) }.sorted()
    }
}
