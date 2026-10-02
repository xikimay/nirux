import XCTest
@testable import Nirux

/// The usage limits indicator's status line in ~/.claude/settings.json: in
/// only while the option is on, and never in place of the user's own.
final class ClaudeStatusLineInstallerTests: XCTestCase {
    private var home: URL!
    private let appBundle = URL(fileURLWithPath: "/Applications/Nirux.app")
    private let devBuild = URL(fileURLWithPath: "/src/nirux/.build/debug")

    override func setUp() {
        super.setUp()
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("nirux-statusline-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: home)
        super.tearDown()
    }

    private var settingsURL: URL { home.appendingPathComponent(".claude/settings.json") }

    private func writeSettings(_ text: String) throws {
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: settingsURL, atomically: true, encoding: .utf8)
    }

    private func settingsText() -> String {
        (try? String(contentsOf: settingsURL, encoding: .utf8)) ?? ""
    }

    private func settings() -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(settingsText().utf8))) as? [String: Any] ?? [:]
    }

    private func statusLineCommand() -> String? {
        (settings()["statusLine"] as? [String: Any])?["command"] as? String
    }

    // MARK: - Install and take back

    func testInstalledWhileOnAndTakenBackWhenOff() throws {
        try writeSettings(#"{"effortLevel": "high", "hooks": {}}"#)

        let installed = AgentHookInstaller.installClaudeStatusLine(enabled: true, executablePath: "/Apps/Nirux", home: home)
        XCTAssertEqual(installed, .nirux)
        XCTAssertEqual(settings()["statusLine"] as? [String: String], [
            "type": "command",
            "command": AgentHookInstaller.claudeStatusLineCommand(executablePath: "/Apps/Nirux")
        ])
        XCTAssertEqual(AgentHookInstaller.claudeStatusLineState(home: home), .nirux)

        XCTAssertEqual(AgentHookInstaller.installClaudeStatusLine(enabled: false, home: home), .none)
        XCTAssertNil(settings()["statusLine"])
        XCTAssertEqual(settings()["effortLevel"] as? String, "high", "the rest of the file stays")
        XCTAssertNotNil(settings()["hooks"])
    }

    /// Theirs too when it calls Nirux among other things, or carries keys
    /// Nirux doesn't write: only Nirux's exact entry is Nirux's.
    func testTheUsersOwnStatusLineIsNeverTouched() throws {
        let nirux = AgentHookInstaller.claudeStatusLineCommand(executablePath: "/Apps/Nirux")
        let chained = #"input=$(cat); echo "$input" | '/Apps/Nirux' --hook claude --statusline; echo "$input" | ~/.claude/sl.sh"#
        let owns: [[String: Any]] = [
            ["type": "command", "command": "~/.claude/statusline.sh", "padding": 0],
            ["type": "command", "command": chained],
            ["type": "command", "command": nirux, "padding": 1],
            ["type": "command", "command": nirux + "; ~/.claude/statusline.sh"]
        ]
        for own in owns {
            let text = String(decoding: try JSONSerialization.data(withJSONObject: ["statusLine": own]), as: UTF8.self)
            try writeSettings(text)
            XCTAssertEqual(AgentHookInstaller.installClaudeStatusLine(enabled: true, home: home), .foreign, "\(own)")
            XCTAssertEqual(AgentHookInstaller.installClaudeStatusLine(enabled: false, home: home), .foreign, "\(own)")
            XCTAssertEqual(settingsText(), text)
        }
    }

    /// The old path holds a space and quotes, as an app moved anywhere may.
    func testRefreshesAMovedAppOnceAndLeavesItBe() throws {
        let old = AgentHookInstaller.claudeStatusLineCommand(executablePath: "/Users/me/My 'Apps'/Nirux.app/Contents/MacOS/Nirux")
        let text = String(decoding: try JSONSerialization.data(
            withJSONObject: ["statusLine": ["type": "command", "command": old]]
        ), as: UTF8.self)
        try writeSettings(text)
        XCTAssertEqual(AgentHookInstaller.claudeStatusLineState(home: home), .nirux)
        XCTAssertEqual(AgentHookInstaller.installClaudeStatusLine(enabled: true, executablePath: "/Apps/Nirux", home: home), .nirux)
        XCTAssertEqual(statusLineCommand(), AgentHookInstaller.claudeStatusLineCommand(executablePath: "/Apps/Nirux"))

        let written = try FileManager.default.attributesOfItem(atPath: settingsURL.path)[.systemFileNumber] as? Int
        AgentHookInstaller.installClaudeStatusLine(enabled: true, executablePath: "/Apps/Nirux", home: home)
        let again = try FileManager.default.attributesOfItem(atPath: settingsURL.path)[.systemFileNumber] as? Int
        XCTAssertEqual(written, again, "an up-to-date status line isn't rewritten")
    }

    func testLeavesAFileItCannotReadAlone() throws {
        try writeSettings("{ // JSON5 comment\n}")
        XCTAssertEqual(AgentHookInstaller.installClaudeStatusLine(enabled: true, home: home), .unreadable)
        XCTAssertEqual(settingsText(), "{ // JSON5 comment\n}")
    }

    func testOffCreatesNoSettingsFile() {
        XCTAssertEqual(AgentHookInstaller.installClaudeStatusLine(enabled: false, home: home), .none)
        XCTAssertFalse(FileManager.default.fileExists(atPath: settingsURL.path))
    }

    /// At launch: only the app bundle manages it, and only when told what
    /// the option says.
    func testInstallAllFollowsTheOption() {
        AgentHookInstaller.installAll(
            executablePath: "/Apps/Nirux", home: home, environment: [:], bundleURL: devBuild,
            claudeVersion: nil, claudeStatusLine: true
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: settingsURL.path), "a dev build leaves it alone")

        AgentHookInstaller.installAll(
            executablePath: "/Apps/Nirux", home: home, environment: [:], bundleURL: appBundle,
            claudeVersion: nil, claudeStatusLine: true
        )
        XCTAssertEqual(AgentHookInstaller.claudeStatusLineState(home: home), .nirux)
        AgentHookInstaller.installAll(executablePath: "/Apps/Nirux", home: home, environment: [:], bundleURL: appBundle, claudeVersion: nil)
        XCTAssertEqual(AgentHookInstaller.claudeStatusLineState(home: home), .nirux, "nil: as it is")
        AgentHookInstaller.installAll(
            executablePath: "/Apps/Nirux", home: home, environment: [:], bundleURL: appBundle,
            claudeVersion: nil, claudeStatusLine: false
        )
        XCTAssertEqual(AgentHookInstaller.claudeStatusLineState(home: home), .none)
        XCTAssertFalse(hookCommands().isEmpty, "the hooks stay")

        // A copy on a state of its own has its own option: it leaves the
        // installed app's status line alone.
        AgentHookInstaller.installClaudeStatusLine(enabled: true, executablePath: "/Apps/Nirux", home: home)
        let scratch = ["NIRUX_STATE_DIR": home.appendingPathComponent("state").path]
        AgentHookInstaller.installAll(
            executablePath: "/Other/Nirux", home: home, environment: scratch, bundleURL: appBundle,
            claudeVersion: nil, claudeStatusLine: false
        )
        XCTAssertEqual(statusLineCommand(), AgentHookInstaller.claudeStatusLineCommand(executablePath: "/Apps/Nirux"))
        XCTAssertNil(AgentHookInstaller.applyClaudeStatusLine(enabled: false, environment: scratch, bundleURL: appBundle))
        XCTAssertEqual(AgentHookInstaller.claudeStatusLineState(home: home), .nirux)
    }

    private func hookCommands() -> [String] {
        let hooks = settings()["hooks"] as? [String: Any] ?? [:]
        return hooks.values.flatMap { groups in
            (groups as? [[String: Any]] ?? []).flatMap { group in
                (group["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
            }
        }
    }

    // MARK: - The command, run as Claude Code runs it

    /// The installed command, against the real binary: it records the
    /// limits only in Nirux terminals, and prints nothing either way, so the
    /// status line stays blank.
    func testCommandRecordsTheLimitsOnlyInNiruxTerminals() throws {
        let nirux = try niruxExecutable()
        let command = AgentHookInstaller.claudeStatusLineCommand(executablePath: nirux)
        // Spelled as a Claude hook: a build without the indicator (a
        // rollback at the same path) drops a hook payload naming no event
        // and exits, instead of launching its UI on every response.
        XCTAssertTrue(command.contains(AgentHookInstaller.shellQuoted(nirux) + " --hook claude --statusline;"))
        let stateDir = home.appendingPathComponent("state")
        let limitsFile = stateDir.appendingPathComponent("claude-usage-limits.json")
        let resetsAt = Int(Date().timeIntervalSince1970) + 3600
        let payload = #"{"session_id":"s1","rate_limits":{"five_hour":{"used_percentage":25,"resets_at":\#(resetsAt)}}}"#

        let outside = try run(command, env: ["NIRUX_STATE_DIR": stateDir.path], stdin: payload)
        XCTAssertEqual(outside.status, 0)
        XCTAssertEqual(outside.stdout, "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: limitsFile.path), "outside Nirux nothing is recorded")

        let inside = try run(command, env: ["NIRUX_STATE_DIR": stateDir.path, "NIRUX_AGENT_UUID": "column-1"], stdin: payload)
        XCTAssertEqual(inside.status, 0)
        XCTAssertEqual(inside.stdout, "")
        let recorded = try XCTUnwrap(ClaudeUsageLimitsFile.load(from: limitsFile))
        XCTAssertEqual(recorded.fiveHour?.usedPercentage, 25)
        XCTAssertEqual(recorded.fiveHour?.resetsAt, TimeInterval(resetsAt))
    }

    /// Runs `command` through `sh -c` with `env` as the whole environment.
    private func run(_ command: String, env: [String: String], stdin: String) throws -> (status: Int32, stdout: String) {
        let input = home.appendingPathComponent("stdin-\(UUID().uuidString)")
        try stdin.write(to: input, atomically: true, encoding: .utf8)
        let inputHandle = try FileHandle(forReadingFrom: input)
        defer { try? inputHandle.close() }
        let output = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = env.merging(["PATH": "/usr/bin:/bin"]) { current, _ in current }
        process.standardInput = inputHandle
        process.standardOutput = output
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        let stdout = output.fileHandleForReading.readDataToEndOfFile()
        guard exited.wait(timeout: .now() + 20) == .success else {
            process.terminate()
            XCTFail("\(command) hung")
            return (-1, "")
        }
        return (process.terminationStatus, String(decoding: stdout, as: UTF8.self))
    }
}
