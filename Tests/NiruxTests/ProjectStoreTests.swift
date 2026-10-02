import XCTest
@testable import Nirux

final class ProjectStoreTests: XCTestCase {
    private var directory: URL!
    private var fileURL: URL { directory.appendingPathComponent("projects.json") }

    private let work = WorkspaceProfile(id: "work", name: "Work", colorHex: "#9ECE6A")
    private let home = WorkspaceProfile(id: "home", name: "Home", colorHex: "#E0AF68")
    private let main = WorkspaceProfile.defaultProfile

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

    @MainActor
    private func savedStore(_ profiles: [WorkspaceProfile]...) -> ProjectStore {
        let store = ProjectStore(fileURL: fileURL)
        _ = store.load(mirror: nil, markerPresent: false)
        for version in profiles { store.save(version) }
        return store
    }

    @MainActor
    func testFirstLaunchMigratesFromTheStateMirrorAndWritesAPrivateFile() throws {
        let store = ProjectStore(fileURL: fileURL)
        let loaded = store.load(mirror: [main, work], markerPresent: false)
        XCTAssertEqual(loaded, [main, work])

        XCTAssertTrue(store.save(loaded))
        XCTAssertTrue(store.isFileCurrent)

        guard case .ok(let file, _) = ProjectStore.read(fileURL) else { return XCTFail("file not written") }
        XCTAssertEqual(file.schemaVersion, ProjectStore.schemaVersion)
        XCTAssertEqual(file.projects, [main, work])
        let permissions = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }

    @MainActor
    func testWithTheMarkerTheFileWinsOverTheMirror() {
        _ = savedStore([main, work, home])

        let loaded = ProjectStore(fileURL: fileURL).load(mirror: [main], markerPresent: true)

        // An empty space the mirror doesn't list is still there.
        XCTAssertEqual(loaded.map(\.id), [main.id, "work", "home"])
    }

    @MainActor
    func testWithoutTheMarkerAnOlderBuildsRenamesAndNewSpacesAreMerged() {
        let store = savedStore([main, work, home])
        store.markDeleted("gone")
        store.save([main, work, home])

        var renamed = work
        renamed.name = "Work renamed"
        let created = WorkspaceProfile(id: "new", name: "Home", colorHex: "#BB9AF7")
        let revived = WorkspaceProfile(id: "gone", name: "Gone", colorHex: "#F7768E")
        let reloaded = ProjectStore(fileURL: fileURL)
        let loaded = reloaded.load(mirror: [main, renamed, created, revived], markerPresent: false)

        XCTAssertEqual(loaded.map(\.id), [main.id, "work", "home", "new"])
        XCTAssertEqual(loaded.first { $0.id == "work" }?.name, "Work renamed")
        XCTAssertEqual(loaded.first { $0.id == "new" }?.name, "Home 2", "names stay unique")
        XCTAssertEqual(reloaded.deletedIDs, ["gone"], "a deleted space doesn't come back from the mirror")
    }

    @MainActor
    func testANewerSchemaIsReadButNeverWrittenAndLeavesTheMarkerOut() throws {
        try writeFile("""
        {"schemaVersion": 99, "projects": [{"id": "work", "name": "Work", "colorHex": "#9ECE6A", "anchors": []}],
         "deletedIDs": []}
        """)
        let before = try Data(contentsOf: fileURL)
        let store = ProjectStore(fileURL: fileURL)

        XCTAssertEqual(store.load(mirror: nil, markerPresent: true), [work])
        XCTAssertFalse(store.save([main, home]))

        XCTAssertEqual(store.availability, .readOnlyNewerSchema(99))
        XCTAssertFalse(store.isFileCurrent, "state.json must not claim the file is current")
        XCTAssertEqual(try Data(contentsOf: fileURL), before)

        // Next launch: no marker, so this session's edits come from the mirror.
        let next = ProjectStore(fileURL: fileURL).load(mirror: [main, home], markerPresent: false)
        XCTAssertEqual(next.map(\.id), ["work", main.id, "home"])
    }

    @MainActor
    func testANewerSchemaThatDoesNotDecodeHereIsStillNeverWritten() throws {
        try writeFile(#"{"schemaVersion": 2, "projects": {"format": "changed"}}"#)
        let before = try Data(contentsOf: fileURL)
        let store = ProjectStore(fileURL: fileURL)

        XCTAssertEqual(store.load(mirror: [main, work], markerPresent: false), [main, work])
        store.save([main])

        XCTAssertEqual(store.availability, .readOnlyNewerSchema(2))
        XCTAssertEqual(try Data(contentsOf: fileURL), before)
    }

    @MainActor
    func testAnUnreadableFileIsSetAsideAndTheMirrorIsTrustedWithTheMarker() throws {
        _ = savedStore([main, work], [main, work, home]) // .bak holds [main, work]
        try writeFile("{ not json")

        let reloaded = ProjectStore(fileURL: fileURL)
        let loaded = reloaded.load(mirror: [main, work, home], markerPresent: true)

        // The marker says projects.json held the mirror's spaces; .bak is older.
        XCTAssertEqual(loaded.map(\.id), [main.id, "work", "home"])
        let corrupt = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("projects.corrupt.") }
        XCTAssertEqual(corrupt.count, 1)
        XCTAssertEqual(reloaded.availability, .writable)
    }

    @MainActor
    func testAMissingFileFallsBackToTheBackup() throws {
        _ = savedStore([main, work, home], [main, work]) // .bak holds [main, work, home]
        try FileManager.default.removeItem(at: fileURL)

        // With the marker, the mirror is the latest list: a space only the
        // backup has is left out (not recorded as deleted: the mirror could be
        // an older state.json backup).
        let withMarker = ProjectStore(fileURL: fileURL)
        XCTAssertEqual(withMarker.load(mirror: [main, work], markerPresent: true).map(\.id), [main.id, "work"])
        XCTAssertTrue(withMarker.deletedIDs.isEmpty)

        // Without it (an older build saved last), the backup and mirror merge.
        let withoutMarker = ProjectStore(fileURL: fileURL)
        XCTAssertEqual(
            withoutMarker.load(mirror: [main, work], markerPresent: false).map(\.id),
            [main.id, "work", "home"]
        )
    }

    @MainActor
    func testADirectoryInPlaceOfTheFileIsNeverReplaced() throws {
        try FileManager.default.createDirectory(at: fileURL, withIntermediateDirectories: true)
        let store = ProjectStore(fileURL: fileURL)

        XCTAssertEqual(store.load(mirror: [main, work], markerPresent: true), [main, work])
        XCTAssertFalse(store.save([main]))
        XCTAssertEqual(store.availability, .readOnlyUnreadable)
    }

    @MainActor
    func testNothingIsSavedBeforeLoading() {
        let store = ProjectStore(fileURL: fileURL)

        XCTAssertFalse(store.save([main]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    @MainActor
    func testDecodingIsLenientAndDropsDuplicateIDs() throws {
        try writeFile("""
        {"projects": [{"id": "work", "name": "Work"}, {"name": "no id"}, {"id": "bare"}, {"id": "work"}],
         "future": true}
        """)
        let loaded = ProjectStore(fileURL: fileURL).load(mirror: nil, markerPresent: true)

        XCTAssertEqual(loaded.map(\.id), ["work", "bare"])
        XCTAssertEqual(loaded.first?.colorHex, WorkspaceProfile.colorHex(for: 0))
        XCTAssertEqual(loaded.last?.name, "project")
    }

    @MainActor
    func testAFileWithFieldsThisBuildDoesNotKnowIsNeverRewritten() throws {
        // A newer build added a field without bumping the schema: rewriting
        // would strip it.
        try writeFile(##"""
        {"schemaVersion": 1, "deletedIDs": [],
         "projects": [{"id": "work", "name": "Work", "colorHex": "#9ECE6A", "anchors": ["x"]}]}
        """##)
        let before = try Data(contentsOf: fileURL)
        let store = ProjectStore(fileURL: fileURL)

        XCTAssertEqual(store.load(mirror: nil, markerPresent: true), [work])
        XCTAssertFalse(store.save([main, work]))
        XCTAssertEqual(try Data(contentsOf: fileURL), before)
    }

    @MainActor
    func testABackupFromANewerBuildMakesTheStoreReadOnly() throws {
        try Data(##"{"schemaVersion": 3, "projects": [{"id": "work", "name": "Work", "colorHex": "#9ECE6A"}]}"##.utf8)
            .write(to: fileURL.appendingPathExtension("bak"))
        let store = ProjectStore(fileURL: fileURL)

        _ = store.load(mirror: [main], markerPresent: false)
        XCTAssertEqual(store.availability, .readOnlyNewerSchema(3))
    }

    @MainActor
    func testDeletionsWrittenByAnotherInstanceAreKept() throws {
        let first = savedStore([main, work, home])
        let second = ProjectStore(fileURL: fileURL)
        _ = second.load(mirror: nil, markerPresent: true)
        second.markDeleted("home")
        second.save([main, work])

        first.save([main, work, WorkspaceProfile(id: "x", name: "X", colorHex: "#BB9AF7")])

        guard case .ok(let file, _) = ProjectStore.read(fileURL) else { return XCTFail("unreadable") }
        XCTAssertEqual(file.deletedIDs, ["home"])
    }

    @MainActor
    func testASpaceDroppedWithItsBriefComesBackUnderItsName() throws {
        func writeBrief(_ id: String, _ text: String) throws {
            let url = try XCTUnwrap(SpaceBrief.briefURL(spaceID: id, stateDirectory: directory))
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        try writeBrief("lost", "<!--\nBrief for the space \"Witch Cat\": goals, priorities\n-->\n- Post on Fridays.")
        try writeBrief("empty", "<!--\nBrief for the space \"Nothing\": goals\n-->\n")
        try writeBrief("gone", "<!--\nBrief for the space \"Gone\": goals\n-->\nRule.")
        // Written by the current template, which says "project".
        let fresh = try XCTUnwrap(SpaceBrief.ensureBriefFile(spaceID: "new", spaceName: "Night Owl", stateDirectory: directory))
        try Data((try String(contentsOf: fresh, encoding: .utf8) + "- Ship at dawn.").utf8).write(to: fresh)
        let store = savedStore([main, work])
        store.markDeleted("gone")
        store.save([main, work])

        let loaded = ProjectStore(fileURL: fileURL).load(mirror: nil, markerPresent: true)

        // Only a brief with content, and never a deleted space's.
        XCTAssertEqual(loaded.map(\.id), [main.id, "work", "lost", "new"])
        XCTAssertEqual(loaded.map(\.name).suffix(2), ["Witch Cat", "Night Owl"])
        XCTAssertEqual(Set(loaded.map { $0.colorHex.uppercased() }).count, loaded.count, "each takes a free color")
    }

    @MainActor
    func testSaveOnlyRewritesTheFileWhenSomethingChanged() throws {
        let store = savedStore([main, work])
        let inode = { try FileManager.default.attributesOfItem(atPath: self.fileURL.path)[.systemFileNumber] as? Int }
        let first = try inode()

        XCTAssertTrue(store.save([main, work]))
        XCTAssertEqual(try inode(), first, "an atomic rewrite would change the inode")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.backupURL.path))

        // A new launch reading the same file doesn't rewrite it either.
        let reloaded = ProjectStore(fileURL: fileURL)
        _ = reloaded.load(mirror: nil, markerPresent: true)
        XCTAssertTrue(reloaded.save([main, work]))
        XCTAssertEqual(try inode(), first)
    }

    @MainActor
    func testAFileANewerInstanceWroteMeanwhileIsNotOverwritten() throws {
        let store = savedStore([main, work])
        try writeFile(##"{"schemaVersion": 2, "projects": [{"id": "work", "name": "Work", "colorHex": "#9ECE6A"}]}"##)
        let newer = try Data(contentsOf: fileURL)

        XCTAssertFalse(store.save([main, work, home]))
        XCTAssertEqual(try Data(contentsOf: fileURL), newer)
        XCTAssertEqual(store.availability, .readOnlyNewerSchema(2))
    }

    @MainActor
    func testASpaceThisInstanceStillListsIsNotRecordedAsDeleted() throws {
        let first = savedStore([main, work])
        let second = ProjectStore(fileURL: fileURL)
        _ = second.load(mirror: nil, markerPresent: true)
        second.markDeleted("work")
        second.save([main])

        first.save([main, work])

        guard case .ok(let file, _) = ProjectStore.read(fileURL) else { return XCTFail("unreadable") }
        XCTAssertEqual(file.projects.map(\.id), [main.id, "work"])
        XCTAssertTrue(file.deletedIDs.isEmpty)
    }

    @MainActor
    func testABriefDoesNotBringBackASpaceTheMirrorDroppedOrTheDefaultSpace() throws {
        for id in ["home", WorkspaceProfile.defaultID] {
            let url = try XCTUnwrap(SpaceBrief.briefURL(spaceID: id, stateDirectory: directory))
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("<!--\nBrief for the space \"X\": goals\n-->\nRule.".utf8).write(to: url)
        }
        _ = savedStore([main, work, home], [main, work]) // .bak holds home
        try FileManager.default.removeItem(at: fileURL)

        let loaded = ProjectStore(fileURL: fileURL).load(mirror: [work], markerPresent: true)

        XCTAssertEqual(loaded.map(\.id), ["work"], "home was dropped; the default space is added by the store")
    }
}
