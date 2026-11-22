import XCTest
@testable import Nirux

/// docs/design/projects.md, section 5: what a space's defaults apply, and how
/// defaults.json is read and written (SpaceDefaultsStore).
final class SpaceDefaultsTests: XCTestCase {
    private var stateDirectory: URL!

    override func setUpWithError() throws {
        stateDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("nirux-defaults-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let stateDirectory { try? FileManager.default.removeItem(at: stateDirectory) }
        super.tearDown()
    }

    private func store(_ spaceID: String = "space-1") throws -> SpaceDefaultsStore {
        try XCTUnwrap(SpaceDefaultsStore(spaceID: spaceID, stateDirectory: stateDirectory))
    }

    private func variable(_ name: String, _ value: String) -> SpaceDefaults.EnvironmentVariable {
        SpaceDefaults.EnvironmentVariable(name: name, value: value)
    }

    // MARK: - Precedence and environment

    func testTheSpaceWinsOverSettingsAndClaudeCodeIsTheTaskAgentByDefault() {
        var defaults = SpaceDefaults()
        XCTAssertEqual(defaults.claudeMode(settings: .acceptEdits), .acceptEdits)
        XCTAssertEqual(defaults.codexMode(settings: .fullAuto), .fullAuto)
        XCTAssertEqual(defaults.agyMode(settings: .auto), .auto)
        XCTAssertEqual(defaults.taskAgent, .claude)
        defaults.claudeLaunchMode = .plan
        defaults.codexLaunchMode = .readOnly
        defaults.agyLaunchMode = .default
        defaults.agent = .codex
        XCTAssertEqual(defaults.claudeMode(settings: .acceptEdits), .plan)
        XCTAssertEqual(defaults.codexMode(settings: .fullAuto), .readOnly)
        XCTAssertEqual(defaults.agyMode(settings: .auto), .default)
        XCTAssertEqual(defaults.taskAgent, .codex)
    }

    /// Literal values, each valid name once (the first), never NIRUX_.
    func testShellsGetValidVariablesOnlyAsTyped() {
        let defaults = SpaceDefaults(environment: [
            variable("API_URL", "http://localhost:4000"),
            variable("PATH", "$PATH:/opt/bin"),
            variable("NIRUX_WORKSPACE_ID", "spoofed"),
            variable("nirux_cli_path", "/tmp/x"),
            variable("1BAD", "x"),
            variable("", "orphan"),
            variable("API_URL", "second"),
            variable("NUL", "a\0b")
        ])
        XCTAssertEqual(defaults.effectiveEnvironment, ["API_URL": "http://localhost:4000", "PATH": "$PATH:/opt/bin"])
        XCTAssertEqual(defaults.environmentProblems.count, 6, defaults.environmentProblems.joined(separator: "\n"))
        XCTAssertTrue(defaults.environmentProblems.contains("API_URL is set twice: the first one applies."))
        XCTAssertNotNil(SpaceDefaults.problem(name: "NIRUX_WORKSPACE_ID", value: "")?.range(of: "reserved"))
        XCTAssertNil(SpaceDefaults.problem(name: "_Private9", value: "any value = fine"))
    }

    /// Written all the same, but said: names that steer the shell or the
    /// agents, and values that look expanded.
    func testSurprisingVariablesAreWarnedAbout() {
        XCTAssertNotNil(SpaceDefaults.warning(name: "PATH", value: "/opt/bin")?.range(of: "shell"))
        XCTAssertNotNil(SpaceDefaults.warning(name: "TERM_PROGRAM", value: "x"))
        XCTAssertNotNil(SpaceDefaults.warning(name: "ANTHROPIC_API_KEY", value: "sk")?.range(of: "every agent"))
        XCTAssertNotNil(SpaceDefaults.warning(name: "API_URL", value: "$HOST:4000")?.range(of: "literal"))
        XCTAssertNil(SpaceDefaults.warning(name: "API_URL", value: "http://localhost:4000"))
        let defaults = SpaceDefaults(environment: [variable("PATH", "/x"), variable("PATH", "/y"), variable("NIRUX_A", "$B")])
        XCTAssertEqual(defaults.environmentWarnings.count, 1, "the variable that applies, once")
        XCTAssertEqual(defaults.effectiveEnvironment, ["PATH": "/x"])
    }

    // MARK: - The file

    func testAMissingFileGivesNoDefaults() throws {
        let loaded = try store().load()
        XCTAssertEqual(loaded.status, .missing)
        XCTAssertEqual(loaded.defaults, SpaceDefaults())
        XCTAssertTrue(loaded.isWritable)
        XCTAssertEqual(SpaceDefaultsStore.defaults(forSpace: "space-1", stateDirectory: stateDirectory), SpaceDefaults())
        XCTAssertNil(SpaceDefaultsStore(spaceID: "../escape", stateDirectory: stateDirectory))
    }

    /// Written 0600 from the start, only what is set, read back the same.
    func testSaveWritesAPrivateFileThatReadsBack() throws {
        let store = try store()
        let defaults = SpaceDefaults(
            agent: .codex, claudeLaunchMode: .plan, codexLaunchMode: nil, agyLaunchMode: .acceptEdits,
            environment: [variable("TOKEN", "s3cr3t"), variable("URL", "https://example.com/a")]
        )
        let saved = try store.save(defaults, replacing: store.load()).get()
        XCTAssertEqual(saved.defaults, defaults)
        let attributes = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
        let text = try String(contentsOf: store.fileURL, encoding: .utf8)
        XCTAssertFalse(text.contains("codexLaunchMode"), text)
        XCTAssertTrue(text.contains("\"schemaVersion\" : 1"), text)
        XCTAssertTrue(text.contains("https://example.com/a"), "slashes unescaped")
        let loaded = store.load()
        XCTAssertEqual(loaded.status, .loaded)
        XCTAssertEqual(loaded.defaults, defaults)
        XCTAssertEqual(loaded.contents, saved.contents)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: store.fileURL.deletingLastPathComponent().path)
        XCTAssertEqual(leftovers, [SpaceDefaultsStore.fileName], "no temporary file left")
    }

    /// docs/design/pr-follow-up.md: on unless turned off; a value this build
    /// can't read is off, and never rewritten.
    func testTheFollowUpIsOnUnlessTurnedOff() throws {
        let store = try store()
        XCTAssertTrue(store.load().defaults.followsUpPullRequests)
        XCTAssertTrue(SpaceDefaults(prFollowUp: nil).followsUpPullRequests)
        XCTAssertTrue(SpaceDefaults(prFollowUp: true).followsUpPullRequests)
        let saved = try store.save(SpaceDefaults(prFollowUp: false), replacing: store.load()).get()
        XCTAssertFalse(saved.defaults.followsUpPullRequests)
        XCTAssertFalse(store.load().defaults.followsUpPullRequests, "read back: only false turns it off")
        XCTAssertTrue(try String(contentsOf: store.fileURL, encoding: .utf8).contains("\"prFollowUp\" : false"))
        try Data(#"{"prFollowUp": "yes"}"#.utf8).write(to: store.fileURL)
        let unreadable = store.load()
        XCTAssertFalse(unreadable.defaults.followsUpPullRequests)
        XCTAssertEqual(unreadable.status, .readOnly(.unknownSettings(["prFollowUp"])))
    }

    /// Another Nirux saved since the window read the file: left alone.
    func testAFileChangedSinceLoadedIsNotOverwritten() throws {
        let store = try store()
        let before = store.load()
        _ = try store.save(SpaceDefaults(agent: .codex)).get()
        XCTAssertEqual(store.save(SpaceDefaults(agent: .claude), replacing: before), .failure(.changedSinceLoaded))
        XCTAssertEqual(store.load().defaults.agent, .codex)
    }

    /// A newer Nirux's file still applies what this build reads, but is
    /// never rewritten; so are unknown keys and values.
    func testFilesFromANewerNiruxApplyButAreNeverWritten() throws {
        let store = try store()
        try FileManager.default.createDirectory(at: store.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let cases: [(String, SpaceDefaultsStore.ReadOnlyReason)] = [
            (#"{"schemaVersion": 2, "claudeLaunchMode": "plan", "environment": [{"name": "A", "value": "1"}]}"#, .newerSchema(2)),
            (#"{"claudeLaunchMode": "plan", "leadAgent": "future"}"#, .unknownSettings(["leadAgent"])),
            (#"{"claudeLaunchMode": "plan", "leadAgent": "gemini"}"#, .unknownSettings(["leadAgent"])),
            (#"{"claudeLaunchMode": "plan", "setupTimeout": 30}"#, .unknownSettings(["setupTimeout"])),
            (#"{"claudeLaunchMode": "plan", "codexLaunchMode": "turbo"}"#, .unknownSettings(["codexLaunchMode"])),
            (#"{"claudeLaunchMode": "plan", "agyLaunchMode": "turbo"}"#, .unknownSettings(["agyLaunchMode"])),
            (#"{"claudeLaunchMode": "plan", "environment": [{"name": "A", "value": "1", "secret": true}]}"#,
             .unknownSettings(["environment"]))
        ]
        for (text, reason) in cases {
            try Data(text.utf8).write(to: store.fileURL)
            let loaded = store.load()
            XCTAssertEqual(loaded.status, .readOnly(reason), text)
            XCTAssertEqual(loaded.defaults.claudeLaunchMode, .plan, text)
            XCTAssertEqual(store.save(SpaceDefaults(), replacing: loaded), .failure(.readOnly(reason)), text)
            XCTAssertEqual(try String(contentsOf: store.fileURL, encoding: .utf8), text)
        }
        try Data(cases[0].0.utf8).write(to: store.fileURL)
        XCTAssertEqual(SpaceDefaultsStore.defaults(forSpace: "space-1", stateDirectory: stateDirectory).effectiveEnvironment, ["A": "1"])
    }

    /// An unreadable file is copied aside, 0600, before a save replaces it.
    func testAnUnreadableFileIsKeptAsideBeforeItIsReplaced() throws {
        let store = try store()
        let folder = store.fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: store.fileURL)
        let loaded = store.load()
        XCTAssertEqual(loaded.status, .unreadable)
        _ = try store.save(SpaceDefaults(agent: .codex), replacing: loaded).get()
        let copies = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix("defaults.corrupt.") }
        XCTAssertEqual(copies.count, 1)
        guard let copy = copies.first.map({ folder.appendingPathComponent($0) }) else { return }
        XCTAssertEqual(try String(contentsOf: copy, encoding: .utf8), "{ not json")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: copy.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(store.load().defaults.agent, .codex)
    }

    func testALinkIsNeitherReadNorReplaced() throws {
        let store = try store()
        let folder = store.fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let elsewhere = stateDirectory.appendingPathComponent("elsewhere.json")
        try Data(#"{"agent": "codex"}"#.utf8).write(to: elsewhere)
        try FileManager.default.createSymbolicLink(at: store.fileURL, withDestinationURL: elsewhere)
        XCTAssertEqual(store.load().status, .readOnly(.notARegularFile))
        XCTAssertEqual(store.save(SpaceDefaults()), .failure(.readOnly(.notARegularFile)))
        XCTAssertEqual(try String(contentsOf: elsewhere, encoding: .utf8), #"{"agent": "codex"}"#)
    }

    /// The daily pass is on after 06:00 unless the file says; an hour it
    /// can't take keeps the file read-only, and a file it can't read turns
    /// the pass off.
    func testTheDailyPassSetting() throws {
        XCTAssertTrue(SpaceDefaults().dailyPassIsOn)
        XCTAssertEqual(SpaceDefaults().dailyPassHour, DailyPass.defaultHour)
        let set = SpaceDefaultsStore.decode(Data(#"{"leadDailyPass": false, "leadDailyPassHour": 9}"#.utf8))
        XCTAssertEqual(set.status, .loaded)
        XCTAssertFalse(set.defaults.dailyPassIsOn)
        XCTAssertEqual(set.defaults.dailyPassHour, 9)
        let written = try JSONSerialization.jsonObject(with: JSONEncoder().encode(set.defaults)) as? [String: Any]
        XCTAssertEqual(written?["leadDailyPassHour"] as? Int, 9)
        let odd = SpaceDefaultsStore.decode(Data(#"{"leadDailyPassHour": 24}"#.utf8))
        XCTAssertEqual(odd.status, .readOnly(.unknownSettings(["leadDailyPassHour"])))
        XCTAssertEqual(odd.defaults.dailyPassHour, DailyPass.defaultHour)
        XCTAssertFalse(odd.defaults.dailyPassIsOn, "an hour it can't read: off")
        XCTAssertFalse(SpaceDefaultsStore.unreadDefaults.dailyPassIsOn)
    }

    /// A deleted space's defaults, setup scripts, proposed rules and logs go;
    /// its brief stays, and its Claude settings stay empty for the launch
    /// lines that name them.
    func testADeletedSpaceLeavesNoSecretsBehind() throws {
        let store = try store()
        _ = try store.save(SpaceDefaults(environment: [variable("TOKEN", "s3cr3t")])).get()
        let folder = store.fileURL.deletingLastPathComponent()
        try Data("x".utf8).write(to: folder.appendingPathComponent("defaults.corrupt.1-abc.json"))
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("setup"), withIntermediateDirectories: true)
        try Data("npm ci\n".utf8).write(to: folder.appendingPathComponent("setup/web-1.sh"))
        try Data("Goals.\n".utf8).write(to: folder.appendingPathComponent("brief.md"))
        for name in [RuleProposalStore.fileName, LoopLog.lines.fileName, ReviewFindings.lines.fileName, DailyPassState.fileName] {
            try Data("{}\n".utf8).write(to: folder.appendingPathComponent(name))
        }
        let settings = folder.appendingPathComponent(ClaudeSpaceSettings.fileName)
        try Data(#"{"autoMode": {"environment": ["**Trusted repo**: /Users/me/app"]}}"#.utf8).write(to: settings)
        SpaceDefaultsStore.removeFiles(ofSpace: "space-1", stateDirectory: stateDirectory)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: folder.path)), ["brief.md", ClaudeSpaceSettings.fileName])
        XCTAssertEqual((try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])?.isEmpty, true)
    }

    // MARK: - Workspaces opened from outside

    /// Kept in state.json only when true, so older states read as started
    /// in Nirux.
    func testStartedOutsideNiruxIsKeptAcrossLaunches() throws {
        let outside = PersistedWorkspace(title: "t", cwd: "/tmp", columns: [], focusedColumnIndex: 0, startedOutsideNirux: true)
        let inside = PersistedWorkspace(title: "t", cwd: "/tmp", columns: [], focusedColumnIndex: 0)
        let decoder = JSONDecoder()
        XCTAssertTrue(try decoder.decode(PersistedWorkspace.self, from: JSONEncoder().encode(outside)).startedOutsideNirux)
        let insideData = try JSONEncoder().encode(inside)
        XCTAssertFalse(String(decoding: insideData, as: UTF8.self).contains("startedOutsideNirux"))
        XCTAssertFalse(try decoder.decode(PersistedWorkspace.self, from: insideData).startedOutsideNirux)
    }

    /// A request the user confirmed (no launch ID) came from outside; one
    /// from a Nirux terminal didn't.
    func testAConfirmedRequestCameFromOutside() throws {
        let url = try XCTUnwrap(URL(string: "nirux://new-workspace?cwd=/tmp&profile=abc"))
        let request = try XCTUnwrap(NiruxURLRequest(url: url))
        XCTAssertFalse(request.cameFromOutside)
        XCTAssertTrue(request.restrictedForConfirmation().cameFromOutside)
    }
}
