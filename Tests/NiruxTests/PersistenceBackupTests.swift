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
        // Not the system temp directory: there Foundation's atomic write
        // drops an existing file's permissions, while in ~/Library (where
        // state.json lives) it keeps them, which once hid a bug.
        directory = try FileManager.default
            .url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
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
        let first = contents("state.json")
        XCTAssertEqual(contents("state.backup.1.json"), first)
        XCTAssertNil(contents("state.backup.2.json"))

        XCTAssertTrue(Persistence.save(state("two"), now: date(day: 1)))
        let written = try fileNumber("state.json")
        XCTAssertTrue(Persistence.save(state("two"), now: date(day: 1)))

        XCTAssertEqual(try fileNumber("state.json"), written, "identical save rewrote state.json")
        XCTAssertEqual(contents("state.backup.1.json"), contents("state.json"))
        XCTAssertEqual(contents("state.backup.2.json"), first)
        XCTAssertNil(contents("state.backup.3.json"))
        XCTAssertEqual(Persistence.load()?.workspaces.first?.title, "two")
    }

    func testBackupsMirrorTheLatestStateAndKeepTheFourBeforeIt() throws {
        for index in 0...6 {
            XCTAssertTrue(Persistence.save(state("s\(index)"), now: date(day: 1)))
        }

        XCTAssertEqual(try title("state.backup.1.json"), "s6")
        XCTAssertEqual(try title("state.backup.5.json"), "s2")
        XCTAssertNil(contents("state.backup.6.json"))
    }

    func testFailedSavesLeaveTheBackupsAlone() throws {
        XCTAssertTrue(Persistence.save(state("a"), now: date(day: 1)))
        XCTAssertTrue(Persistence.save(state("b"), now: date(day: 1)))
        // Only state.json refuses writes; the backups next to it still could
        // be written, so nothing but the save order protects them.
        let statePath = directory.appendingPathComponent("state.json").path
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: statePath)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: statePath) }

        for attempt in 1...3 {
            XCTAssertFalse(Persistence.save(state("c\(attempt)"), now: date(day: 1)))
        }

        XCTAssertEqual(try title("state.json"), "b")
        XCTAssertEqual(try title("state.backup.1.json"), "b")
        XCTAssertEqual(try title("state.backup.2.json"), "a")
        XCTAssertNil(contents("state.backup.3.json"))
    }

    func testStateWrittenByAnotherBuildIsKeptInTheBackups() throws {
        XCTAssertTrue(Persistence.save(state("ours"), now: date(day: 1)))
        try write(try encoded("theirs"), "state.json")

        // Our own state is unchanged: only theirs is new.
        XCTAssertTrue(Persistence.save(state("ours"), now: date(day: 1)))

        XCTAssertEqual(try title("state.json"), "ours")
        XCTAssertEqual(try title("state.backup.1.json"), "ours")
        XCTAssertEqual(try title("state.backup.2.json"), "theirs")
    }

    func testSaveRefusesWhenAnotherBuildsStateCannotBeBackedUp() throws {
        for index in 1...5 {
            XCTAssertTrue(Persistence.save(state("s\(index)"), now: date(day: 1)))
        }
        try write(try encoded("theirs"), "state.json")
        let newestBackup = directory.appendingPathComponent("state.backup.1.json").path
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: newestBackup)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: newestBackup) }

        for attempt in 1...3 {
            XCTAssertFalse(Persistence.save(state("next \(attempt)"), now: date(day: 1)))
        }

        XCTAssertEqual(try title("state.json"), "theirs")
        XCTAssertEqual(try (1...5).map { try title("state.backup.\($0).json") }, ["s5", "s4", "s3", "s2", "s1"])
        XCTAssertEqual(files(prefix: Persistence.stagingPrefix), [])
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
        XCTAssertNil(contents("state.backup.2.json"))
    }

    func testDailySnapshotsFromBeforeTheClockWentBackArePrunedFirst() throws {
        for day in 20...26 {
            try write(try encoded("before the clock went back"), "state.daily.2026-03-\(day).json")
        }

        for day in 1...5 {
            XCTAssertTrue(Persistence.save(state("day \(day)"), now: date(day: day)))
            XCTAssertTrue(Persistence.save(state("day \(day)"), now: date(day: day, hour: 13)))
        }

        XCTAssertEqual(files(prefix: "state.daily."), [
            "state.daily.2026-03-01.json", "state.daily.2026-03-02.json", "state.daily.2026-03-03.json",
            "state.daily.2026-03-04.json", "state.daily.2026-03-05.json",
            "state.daily.2026-03-25.json", "state.daily.2026-03-26.json"
        ])
        // Recovery tries the real days before the future-dated ones.
        try write(unreadable, "state.json")
        for index in 1...5 {
            try write(unreadable, "state.backup.\(index).json")
        }
        XCTAssertEqual(Persistence.load(now: date(day: 5))?.workspaces.first?.title, "day 5")
    }

    func testDailySnapshotSweepsStagingFilesLeftByACrash() throws {
        let stale = directory.appendingPathComponent("\(Persistence.stagingPrefix)crashed.json")
        let recent = directory.appendingPathComponent("\(Persistence.stagingPrefix)in-flight.json")
        try Data("stale".utf8).write(to: stale)
        try Data("recent".utf8).write(to: recent)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-7_200)], ofItemAtPath: stale.path)

        XCTAssertTrue(Persistence.save(state("today"), now: date(day: 1)))

        XCTAssertEqual(files(prefix: Persistence.stagingPrefix), [recent.lastPathComponent])
    }

    // MARK: - Load fallback

    func testLoadRecoversTheLatestSaveWhenStateBreaksWhileRunning() throws {
        XCTAssertTrue(Persistence.save(state("a"), now: date(day: 1)))
        XCTAssertTrue(Persistence.save(state("b"), now: date(day: 1)))

        try write(unreadable, "state.json")

        XCTAssertEqual(Persistence.load()?.workspaces.first?.title, "b")
    }

    func testLoadDoesNotServeARecoveryMadeBeforeTheLastSave() throws {
        try write(unreadable, "state.json")
        try write(encoded("old backup"), "state.backup.1.json")
        XCTAssertEqual(Persistence.load()?.workspaces.first?.title, "old backup")
        XCTAssertTrue(Persistence.save(state("saved"), now: date(day: 1)))

        // The same unreadable bytes come back, e.g. another build rewrites them.
        try write(unreadable, "state.json")

        XCTAssertEqual(Persistence.load()?.workspaces.first?.title, "saved")
    }

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

    func testLoadDoesNotReuseAnotherDirectorysRecovery() throws {
        try write(unreadable, "state.json")
        try write(encoded("first"), "state.backup.1.json")
        XCTAssertEqual(Persistence.load()?.workspaces.first?.title, "first")

        let other = directory.deletingLastPathComponent()
            .appendingPathComponent("nirux-backups-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: other) }
        try unreadable.write(to: other.appendingPathComponent("state.json"))
        try encoded("second").write(to: other.appendingPathComponent("state.backup.1.json"))
        setenv("NIRUX_STATE_DIR", other.path, 1)

        XCTAssertEqual(Persistence.load()?.workspaces.first?.title, "second")
    }

    // MARK: - Unusable state.json

    func testSaveSetsUndecodableStateAsideAndKeepsEveryBackup() throws {
        try write(unreadable, "state.json")
        try write(encoded("backup 1"), "state.backup.1.json")
        try write(encoded("backup 2"), "state.backup.2.json")
        let backups = [contents("state.backup.1.json"), contents("state.backup.2.json")]
        // Recovery must not make save mistake the undecodable file for a good one.
        XCTAssertEqual(Persistence.load()?.workspaces.first?.title, "backup 1")

        XCTAssertTrue(Persistence.save(state("recovered"), now: date(day: 3, hour: 14, minute: 5, second: 9)))

        XCTAssertEqual(contents("state.corrupt.2026-03-03-140509.json"), unreadable)
        // The undecodable file takes no backup slot; the backups only shift.
        XCTAssertEqual(try title("state.backup.1.json"), "recovered")
        XCTAssertEqual([contents("state.backup.2.json"), contents("state.backup.3.json")], backups)
        XCTAssertNil(contents("state.backup.4.json"))
        XCTAssertEqual(Persistence.load()?.workspaces.first?.title, "recovered")
    }

    func testIdenticalUndecodableStateIsSetAsideOnce() throws {
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

    func testSetAsideCopiesFromTheSameSecondArePrunedOldestFirst() throws {
        try write(Data("first".utf8), "state.corrupt.2026-03-01-120000.json")
        for suffix in 2...10 {
            try write(Data("copy \(suffix)".utf8), "state.corrupt.2026-03-01-120000-\(suffix).json")
        }
        try write(unreadable, "state.json")

        XCTAssertTrue(Persistence.save(state("fresh"), now: date(day: 1)))

        let copies = files(prefix: "state.corrupt.")
        XCTAssertEqual(copies.count, 10)
        XCTAssertFalse(copies.contains("state.corrupt.2026-03-01-120000.json"))
        XCTAssertTrue(copies.contains("state.corrupt.2026-03-01-120000-10.json"))
        XCTAssertEqual(contents("state.corrupt.2026-03-01-120000-11.json"), unreadable)
    }

    func testStateThatCannotBeReadIsLinkedAsideBeforeSaving() throws {
        try XCTSkipIf(getuid() == 0, "root reads files regardless of mode")
        try write(unreadable, "state.json")
        try write(encoded("backup 1"), "state.backup.1.json")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: directory.appendingPathComponent("state.json").path)

        XCTAssertTrue(Persistence.save(state("fresh"), now: date(day: 1)))

        let asideURL = directory.appendingPathComponent("state.corrupt.2026-03-01-120000.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: asideURL.path)
        XCTAssertEqual(contents(asideURL.lastPathComponent), unreadable)
        XCTAssertEqual(try title("state.json"), "fresh")
        XCTAssertEqual(try title("state.backup.1.json"), "fresh")
        XCTAssertEqual(try title("state.backup.2.json"), "backup 1")
        XCTAssertEqual(files(prefix: Persistence.stagingPrefix), [])

        // The new state.json doesn't inherit the unreadable mode.
        XCTAssertTrue(Persistence.save(state("fresh 2"), now: date(day: 1, hour: 13)))
        XCTAssertEqual(files(prefix: "state.corrupt."), [asideURL.lastPathComponent])
        XCTAssertEqual(try title("state.backup.2.json"), "fresh")
    }

    func testSavingOverStateNothingCanRecoverKeepsItAside() throws {
        try write(unreadable, "state.json")
        for index in 1...5 {
            try write(Data("newer build \(index)".utf8), "state.backup.\(index).json")
        }
        XCTAssertNil(Persistence.load())

        // What Settings does when load() finds nothing: save an otherwise empty state.
        XCTAssertTrue(Persistence.save(PersistedState(workspaces: [], activeWorkspaceIndex: 0), now: date(day: 1)))

        XCTAssertEqual(contents("state.corrupt.2026-03-01-120000.json"), unreadable)
        XCTAssertEqual(contents("state.backup.2.json"), Data("newer build 1".utf8))
    }

    func testDirectoryNamedStateIsNeverReplaced() throws {
        let stateDir = directory.appendingPathComponent("state.json")
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try write(Data("keep".utf8), "state.json/inside")

        XCTAssertFalse(Persistence.save(state("fresh"), now: date(day: 1)))

        XCTAssertEqual(contents("state.json/inside"), Data("keep".utf8))
        XCTAssertEqual(files(prefix: "state.corrupt."), [])
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
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = DateComponents(year: 2026, month: 3, day: day, hour: hour, minute: minute, second: second)
        return calendar.date(from: parts)!
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

    private func fileNumber(_ name: String) throws -> Int? {
        let path = directory.appendingPathComponent(name).path
        return try FileManager.default.attributesOfItem(atPath: path)[.systemFileNumber] as? Int
    }

    private func files(prefix: String) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasPrefix(prefix) }.sorted()
    }
}
