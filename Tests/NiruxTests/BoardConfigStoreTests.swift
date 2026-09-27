import XCTest
@testable import Nirux

/// board.json on disk (see BoardConfigStore): what is read, what is never
/// written, and what is kept aside.
final class BoardConfigStoreTests: XCTestCase {
    private var stateDirectory: URL!
    private var store: BoardConfigStore!
    private var fileURL: URL { store.fileURL }
    private var folder: URL { fileURL.deletingLastPathComponent() }

    private let config = BoardConfig(
        repository: "xikimay/nirux",
        baseBranch: "main",
        requiredChecks: ["test"],
        postMergeWorkflow: .workflow("nightly.yml")
    )

    override func setUpWithError() throws {
        // The caches directory keeps file permissions through atomic writes;
        // /tmp doesn't (see ProjectStoreTests).
        let caches = try XCTUnwrap(FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first)
        stateDirectory = caches.appendingPathComponent("nirux-board-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        store = try XCTUnwrap(BoardConfigStore(spaceID: "space-1", stateDirectory: stateDirectory))
    }

    override func tearDownWithError() throws {
        if let folder = store?.fileURL.deletingLastPathComponent() {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        }
        try? FileManager.default.removeItem(at: stateDirectory)
    }

    private func write(_ text: String) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: fileURL)
    }

    private func contents() throws -> String {
        try String(contentsOf: fileURL, encoding: .utf8)
    }

    private func folderEntries() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    // MARK: - Location

    func testTheFileSitsNextToTheBrief() throws {
        let brief = try XCTUnwrap(SpaceBrief.briefURL(spaceID: "space-1", stateDirectory: stateDirectory))
        XCTAssertEqual(fileURL.deletingLastPathComponent(), brief.deletingLastPathComponent())
        XCTAssertEqual(fileURL.lastPathComponent, "board.json")
    }

    func testAnInvalidSpaceIDHasNoStore() {
        for id in ["", "..", "../space", "a/b", "space 1", "space\u{0}"] {
            XCTAssertNil(BoardConfigStore(spaceID: id, stateDirectory: stateDirectory), id)
        }
        XCTAssertNotNil(BoardConfigStore(spaceID: WorkspaceProfile.defaultID, stateDirectory: stateDirectory))
    }

    // MARK: - Reading

    func testAMissingFileIsNotConfigured() {
        let loaded = store.load()
        XCTAssertEqual(loaded.status, .missing)
        XCTAssertNil(loaded.config)
        XCTAssertTrue(loaded.isWritable)
        XCTAssertFalse(loaded.queueStartProblems.isEmpty)
    }

    func testASavedFileIsReadBack() throws {
        XCTAssertEqual(try store.save(config).get(), nil)

        let loaded = store.load()
        XCTAssertEqual(loaded, BoardConfigStore.Loaded(config: config, status: .loaded))
        XCTAssertEqual(loaded.queueStartProblems, [])
        let text = try contents()
        XCTAssertTrue(text.contains(#""repository" : "xikimay/nirux""#), "slashes aren't escaped: \(text)")
        let permissions = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }

    func testALenientFileGetsDefaultsAndStaysWritable() throws {
        try write(#"{"repository": "a/b"}"#)
        let loaded = store.load()
        XCTAssertEqual(loaded.status, .loaded)
        XCTAssertEqual(loaded.config, BoardConfig(repository: "a/b"))
        XCTAssertEqual(
            loaded.queueStartProblems,
            ["Set the base branch.", "Choose the post-merge workflow, or None."]
        )
    }

    func testANewerSchemaIsReadButNeverWritten() throws {
        let original = """
        {"schemaVersion": 2, "repository": "a/b", "baseBranch": "main", "postMergeWorkflow": "none"}
        """
        try write(original)

        let loaded = store.load()
        XCTAssertEqual(loaded.status, .readOnly(.newerSchema(2)))
        XCTAssertEqual(loaded.config?.repository, "a/b")
        XCTAssertFalse(loaded.isWritable)
        XCTAssertTrue(loaded.config?.canStartQueue == true)
        XCTAssertEqual(loaded.queueStartProblems.count, 1, "the queue refuses a newer schema")

        XCTAssertEqual(store.save(config), .failure(.readOnly(.newerSchema(2))))
        XCTAssertEqual(try contents(), original)
    }

    func testANewerSchemaThisBuildCantDecodeIsNotSetAside() throws {
        let original = #"{"schemaVersion": 3, "requiredChecks": {"any": ["test"]}}"#
        try write(original)

        let loaded = store.load()
        XCTAssertEqual(loaded.status, .readOnly(.newerSchema(3)))
        XCTAssertNil(loaded.config)
        XCTAssertEqual(store.save(config), .failure(.readOnly(.newerSchema(3))))
        XCTAssertEqual(try contents(), original)
        XCTAssertEqual(try folderEntries(), ["board.json"])
    }

    func testUnknownKeysMakeTheFileReadOnly() throws {
        let original = #"{"repository": "a/b", "requireReviews": true, "labels": []}"#
        try write(original)

        let loaded = store.load()
        XCTAssertEqual(loaded.status, .readOnly(.unknownKeys(["labels", "requireReviews"])))
        XCTAssertEqual(loaded.config?.repository, "a/b")
        XCTAssertEqual(store.save(config), .failure(.readOnly(.unknownKeys(["labels", "requireReviews"]))))
        XCTAssertEqual(try contents(), original)
    }

    /// The safest rule: the method reads as `merge` for display, but the
    /// file is never rewritten (Save would silently turn it into `merge`)
    /// and the queue won't start until the user fixes it by hand.
    func testAnUnsupportedMergeMethodMakesTheFileReadOnlyAndStopsTheQueue() throws {
        for method in ["rebase", "fast-forward"] {
            let original = """
            {"repository": "a/b", "baseBranch": "main", "postMergeWorkflow": "none", "mergeMethod": "\(method)"}
            """
            try write(original)

            let loaded = store.load()
            XCTAssertEqual(loaded.status, .readOnly(.unsupportedMergeMethod(method)))
            XCTAssertEqual(loaded.config?.mergeMethod, .merge)
            XCTAssertEqual(loaded.queueStartProblems.count, 1)
            XCTAssertTrue(loaded.queueStartProblems[0].contains(method))
            XCTAssertEqual(store.save(config), .failure(.readOnly(.unsupportedMergeMethod(method))))
            XCTAssertEqual(try contents(), original)
        }
    }

    // MARK: - Unreadable files

    func testAnUnreadableFileIsCopiedAsideOnlyWhenSaveReplacesIt() throws {
        let original = #"{"repository": "a/b", "checksTimeoutMinutes": "thirty"}"#
        try write(original)

        let loaded = store.load()
        XCTAssertEqual(loaded, BoardConfigStore.Loaded(config: nil, status: .unreadable))
        XCTAssertTrue(loaded.isWritable)
        _ = store.load()
        XCTAssertEqual(try folderEntries(), ["board.json"], "loading copies nothing")

        let copy = try XCTUnwrap(try store.save(config).get())
        XCTAssertEqual(try String(contentsOf: copy, encoding: .utf8), original)
        XCTAssertTrue(copy.lastPathComponent.hasPrefix("board.corrupt."))
        XCTAssertEqual(copy.pathExtension, "json")
        XCTAssertEqual(copy.deletingLastPathComponent().standardizedFileURL, folder.standardizedFileURL)
        XCTAssertEqual(store.load().config, config)
        XCTAssertEqual(try folderEntries().count, 2)
    }

    func testAnUnreadableFileIsNeverReplacedWhenTheCopyFails() throws {
        let original = "not json"
        try write(original)
        // Nothing can be created in the folder: neither the copy nor the
        // replacement.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)

        guard case .failure(.couldNotSetAside) = store.save(config) else {
            return XCTFail("saved over an unreadable file without a copy")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        XCTAssertEqual(try contents(), original)
        XCTAssertEqual(try folderEntries(), ["board.json"])
    }

    func testAFileWhoseBytesCantBeReadIsNeverReplaced() throws {
        try write("{}")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fileURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path) }

        XCTAssertEqual(store.load().status, .unreadable)
        guard case .failure(.couldNotSetAside) = store.save(config) else {
            return XCTFail("replaced a file it couldn't copy")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        XCTAssertEqual(try contents(), "{}")
    }

    func testAFolderInPlaceOfTheFileIsNeitherReadNorReplaced() throws {
        try FileManager.default.createDirectory(at: fileURL, withIntermediateDirectories: true)

        XCTAssertEqual(store.load(), BoardConfigStore.Loaded(config: nil, status: .readOnly(.notARegularFile)))
        XCTAssertEqual(store.save(config), .failure(.readOnly(.notARegularFile)))
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertEqual(try folderEntries(), ["board.json"], "no copy of a folder")
    }

    func testALinkInPlaceOfTheFileIsNeitherReadNorReplaced() throws {
        let target = stateDirectory.appendingPathComponent("elsewhere.json")
        try Data("{}".utf8).write(to: target)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: fileURL, withDestinationURL: target)

        XCTAssertEqual(store.load().status, .readOnly(.notARegularFile))
        XCTAssertEqual(store.save(config), .failure(.readOnly(.notARegularFile)))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: fileURL.path), target.path)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "{}")
    }

    func testATooLargeFileIsNeitherReadNorReplaced() throws {
        try write("{}" + String(repeating: " ", count: BoardConfigStore.maxFileBytes))

        XCTAssertEqual(store.load(), BoardConfigStore.Loaded(config: nil, status: .readOnly(.tooLarge)))
        XCTAssertEqual(store.save(config), .failure(.readOnly(.tooLarge)))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int,
                       BoardConfigStore.maxFileBytes + 2)
    }

    // MARK: - Writing

    /// Replaced by a rename: a reader holding the old file still sees it
    /// whole, and nothing is left behind.
    func testSavingReplacesTheFileAtomically() throws {
        XCTAssertNoThrow(try store.save(config).get())
        let reader = try FileHandle(forReadingFrom: fileURL)
        defer { try? reader.close() }
        let before = try contents()

        var changed = config
        changed.baseBranch = "develop"
        changed.requiredChecks = ["build", "test"]
        XCTAssertNoThrow(try store.save(changed).get())

        XCTAssertEqual(String(decoding: try reader.readToEnd() ?? Data(), as: UTF8.self), before)
        XCTAssertEqual(store.load().config, changed)
        XCTAssertEqual(try folderEntries(), ["board.json"])
    }

    func testSavingCreatesTheSpaceFolderAndLeavesTheBriefAlone() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertNoThrow(try store.save(config).get())
        XCTAssertEqual(try folderEntries(), ["board.json"])

        let brief = try XCTUnwrap(SpaceBrief.ensureBriefFile(
            spaceID: "space-1", spaceName: "Space", stateDirectory: stateDirectory
        ))
        let briefText = try String(contentsOf: brief, encoding: .utf8)
        XCTAssertNoThrow(try store.save(config).get())
        XCTAssertEqual(try String(contentsOf: brief, encoding: .utf8), briefText)
    }
}
