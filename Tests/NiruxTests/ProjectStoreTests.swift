import XCTest
@testable import Nirux

@MainActor
final class ProjectStoreTests: XCTestCase {
    private var directory: URL!
    private var fileURL: URL { directory.appendingPathComponent("projects.json") }

    private let work = WorkspaceProfile(id: "work", name: "Work", colorHex: "#9ECE6A")
    private let home = WorkspaceProfile(id: "home", name: "Home", colorHex: "#E0AF68")

    override func setUpWithError() throws {
        // The caches directory keeps file permissions through atomic writes;
        // /tmp doesn't (see PersistenceBackupTests).
        let caches = try XCTUnwrap(FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first)
        directory = caches.appendingPathComponent("nirux-project-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func writeFile(_ json: String) throws {
        try Data(json.utf8).write(to: fileURL)
    }

    func testFirstLaunchMigratesFromTheStateMirrorAndWritesAPrivateFile() throws {
        let store = ProjectStore(fileURL: fileURL)
        let loaded = store.load(mirror: [WorkspaceProfile.defaultProfile, work], markerPresent: false)
        XCTAssertEqual(loaded, [WorkspaceProfile.defaultProfile, work])

        store.save(loaded)

        guard case .ok(let file) = ProjectStore.read(fileURL) else { return XCTFail("file not written") }
        XCTAssertEqual(file.schemaVersion, ProjectStore.schemaVersion)
        XCTAssertEqual(file.projects, [WorkspaceProfile.defaultProfile, work])
        let permissions = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }

    func testWithTheMarkerTheFileWinsOverTheMirror() {
        let store = ProjectStore(fileURL: fileURL)
        store.save([WorkspaceProfile.defaultProfile, work, home])

        let reloaded = ProjectStore(fileURL: fileURL)
        let loaded = reloaded.load(mirror: [WorkspaceProfile.defaultProfile], markerPresent: true)

        // An empty space the mirror doesn't list is still there.
        XCTAssertEqual(loaded.map(\.id), [WorkspaceProfile.defaultID, "work", "home"])
    }

    func testWithoutTheMarkerAnOlderBuildsRenamesAndNewSpacesAreMerged() {
        let store = ProjectStore(fileURL: fileURL)
        store.save([WorkspaceProfile.defaultProfile, work, home])
        store.markDeleted("gone")
        store.save([WorkspaceProfile.defaultProfile, work, home])

        var renamed = work
        renamed.name = "Work renamed"
        let created = WorkspaceProfile(id: "new", name: "New", colorHex: "#BB9AF7")
        let revived = WorkspaceProfile(id: "gone", name: "Gone", colorHex: "#F7768E")
        let reloaded = ProjectStore(fileURL: fileURL)
        let loaded = reloaded.load(
            mirror: [WorkspaceProfile.defaultProfile, renamed, created, revived],
            markerPresent: false
        )

        XCTAssertEqual(loaded.map(\.id), [WorkspaceProfile.defaultID, "work", "home", "new"])
        XCTAssertEqual(loaded.first { $0.id == "work" }?.name, "Work renamed")
        XCTAssertEqual(reloaded.deletedIDs, ["gone"], "a deleted space doesn't come back from the mirror")
    }

    func testANewerSchemaIsReadButNeverWritten() throws {
        try writeFile("""
        {"schemaVersion": 99, "projects": [{"id": "work", "name": "Work", "colorHex": "#9ECE6A", "anchors": []}],
         "deletedIDs": []}
        """)
        let before = try Data(contentsOf: fileURL)
        let store = ProjectStore(fileURL: fileURL)

        let loaded = store.load(mirror: nil, markerPresent: true)
        store.save([WorkspaceProfile.defaultProfile])

        XCTAssertEqual(loaded, [work])
        XCTAssertEqual(store.availability, .readOnlyNewerSchema(99))
        XCTAssertEqual(try Data(contentsOf: fileURL), before)
    }

    func testAnUnreadableFileIsSetAsideAndTheBackupIsUsed() throws {
        let store = ProjectStore(fileURL: fileURL)
        store.save([WorkspaceProfile.defaultProfile, work])
        store.save([WorkspaceProfile.defaultProfile, work, home]) // keeps the previous version as .bak
        try writeFile("{ not json")

        let reloaded = ProjectStore(fileURL: fileURL)
        let loaded = reloaded.load(mirror: [WorkspaceProfile.defaultProfile], markerPresent: true)

        XCTAssertEqual(loaded.map(\.id), [WorkspaceProfile.defaultID, "work"])
        let corrupt = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("projects.corrupt.") }
        XCTAssertEqual(corrupt.count, 1)
        XCTAssertEqual(reloaded.availability, .writable)
    }

    func testDecodingIsLenient() throws {
        try writeFile("""
        {"projects": [{"id": "work", "name": "Work"}, {"name": "no id"}, {"id": "bare"}], "future": true}
        """)
        let loaded = ProjectStore(fileURL: fileURL).load(mirror: nil, markerPresent: true)

        XCTAssertEqual(loaded.map(\.id), ["work", "bare"])
        XCTAssertEqual(loaded.first?.colorHex, WorkspaceProfile.colorHex(for: 0))
        XCTAssertEqual(loaded.last?.name, "space")
    }

    func testSaveOnlyWritesWhenSomethingChanged() throws {
        let store = ProjectStore(fileURL: fileURL)
        store.save([WorkspaceProfile.defaultProfile, work])
        let firstWrite = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date

        Thread.sleep(forTimeInterval: 1.1)
        store.save([WorkspaceProfile.defaultProfile, work])

        let secondWrite = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date
        XCTAssertEqual(firstWrite, secondWrite)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.backupURL.path), "no change, no backup")
    }
}
