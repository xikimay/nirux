import XCTest
@testable import Nirux

final class AgentHookInstallerTests: XCTestCase {
    private var home: URL!

    override func setUp() {
        super.setUp()
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("nirux-hook-installer-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: home)
        super.tearDown()
    }

    private func write(_ text: String, _ relative: String) {
        let url = home.appendingPathComponent(relative)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func read(_ relative: String) -> String {
        (try? String(contentsOf: home.appendingPathComponent(relative), encoding: .utf8)) ?? ""
    }

    private func claudeSettings() -> [String: Any] {
        let data = Data(read(".claude/settings.json").utf8)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private func hookCommands(_ settings: [String: Any], event: String) -> [String] {
        let hooks = settings["hooks"] as? [String: Any] ?? [:]
        let groups = hooks[event] as? [[String: Any]] ?? []
        return groups.flatMap { group in
            (group["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
        }
    }

    // MARK: - Claude

    func testClaudeFreshInstallCoversAllEvents() {
        AgentHookInstaller.installClaudeHooks(executablePath: "/Apps/Nirux", home: home)
        let settings = claudeSettings()
        for event in AgentHookInstaller.claudeHookEvents {
            XCTAssertEqual(
                hookCommands(settings, event: event),
                [AgentHookInstaller.claudeHookCommand(executablePath: "/Apps/Nirux")],
                event
            )
        }
    }

    func testClaudeHookCommandGuardsMissingBinary() {
        let command = AgentHookInstaller.claudeHookCommand(executablePath: "/Apps/Nirux")
        XCTAssertTrue(command.contains("if [ -x \"/Apps/Nirux\" ]"), "silent no-op when uninstalled")
        XCTAssertTrue(command.contains("--hook claude"))
        XCTAssertTrue(command.hasSuffix("fi"))
    }

    func testClaudePreservesUserHooksAndRefreshesStalePath() {
        write("""
        {
          "model": "opus",
          "hooks": {
            "PreToolUse": [
              {"matcher": "Bash", "hooks": [{"type": "command", "command": "/usr/local/bin/linter"}]},
              {"matcher": "", "hooks": [{"type": "command", "command": "\\"/old/path/Nirux\\" --hook claude"}]}
            ],
            "Stop": [
              {"hooks": [{"type": "command", "command": "/old/path/Nirux --hook claude"}]}
            ]
          }
        }
        """, ".claude/settings.json")

        AgentHookInstaller.installClaudeHooks(executablePath: "/new/Nirux", home: home)
        let settings = claudeSettings()

        XCTAssertEqual(settings["model"] as? String, "opus")
        let preToolCommands = hookCommands(settings, event: "PreToolUse")
        XCTAssertTrue(preToolCommands.contains("/usr/local/bin/linter"), "user hook preserved")
        XCTAssertEqual(
            preToolCommands.filter { $0.contains("--hook claude") },
            [AgentHookInstaller.claudeHookCommand(executablePath: "/new/Nirux")]
        )
        XCTAssertEqual(
            hookCommands(settings, event: "Stop"),
            [AgentHookInstaller.claudeHookCommand(executablePath: "/new/Nirux")]
        )
    }

    func testClaudeInstallIsIdempotent() throws {
        AgentHookInstaller.installClaudeHooks(executablePath: "/Apps/Nirux", home: home)
        let first = read(".claude/settings.json")
        let settingsPath = home.appendingPathComponent(".claude/settings.json").path
        let mtime1 = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: settingsPath)[.modificationDate] as? Date)
        Thread.sleep(forTimeInterval: 0.01)
        AgentHookInstaller.installClaudeHooks(executablePath: "/Apps/Nirux", home: home)
        let mtime2 = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: settingsPath)[.modificationDate] as? Date)
        XCTAssertEqual(first, read(".claude/settings.json"))
        XCTAssertEqual(mtime1, mtime2, "no rewrite when nothing changed")
    }

    func testClaudeUnparsableSettingsUntouched() {
        write("{ not json ,,", ".claude/settings.json")
        AgentHookInstaller.installClaudeHooks(executablePath: "/Apps/Nirux", home: home)
        XCTAssertEqual(read(".claude/settings.json"), "{ not json ,,")
    }

    func testClaudeHooksRunSyncForDeterministicOrder() {
        // Async hooks can land out of order (a PreToolUse after its turn's
        // Stop would wedge the status machine in "working").
        AgentHookInstaller.installClaudeHooks(executablePath: "/Apps/Nirux", home: home)
        let settings = claudeSettings()
        let hooks = settings["hooks"] as? [String: Any] ?? [:]
        for event in AgentHookInstaller.claudeHookEvents {
            let groups = hooks[event] as? [[String: Any]] ?? []
            for group in groups {
                for hook in group["hooks"] as? [[String: Any]] ?? [] {
                    XCTAssertNil(hook["async"], "\(event) must be sync")
                }
            }
        }
    }

    // MARK: - Codex

    func testCodexCreatesMissingConfig() {
        AgentHookInstaller.installCodexNotify(executablePath: "/Apps/Nirux", home: home)
        XCTAssertEqual(
            read(".codex/config.toml"),
            "notify = [\"/Apps/Nirux\", \"--hook\", \"codex\"]\n"
        )
    }

    func testCodexInsertsBeforeFirstTable() {
        write("model = \"gpt-5\"\n\n[features]\nfoo = true\n", ".codex/config.toml")
        AgentHookInstaller.installCodexNotify(executablePath: "/Apps/Nirux", home: home)
        let lines = read(".codex/config.toml").components(separatedBy: "\n")
        let notifyIdx = lines.firstIndex { $0.hasPrefix("notify =") }!
        let tableIdx = lines.firstIndex { $0.hasPrefix("[features]") }!
        XCTAssertLessThan(notifyIdx, tableIdx, "top-level key must not land inside a table")
        XCTAssertTrue(lines.contains("model = \"gpt-5\""))
    }

    func testCodexForeignNotifyUntouched() {
        let original = "notify = [\"/usr/local/bin/my-notify\"]\n"
        write(original, ".codex/config.toml")
        AgentHookInstaller.installCodexNotify(executablePath: "/Apps/Nirux", home: home)
        XCTAssertEqual(read(".codex/config.toml"), original)
    }

    func testCodexRefreshesStaleNiruxPath() {
        write("notify = [\"/old/Nirux\", \"--hook\", \"codex\"]\n", ".codex/config.toml")
        AgentHookInstaller.installCodexNotify(executablePath: "/new/Nirux", home: home)
        XCTAssertEqual(read(".codex/config.toml"), "notify = [\"/new/Nirux\", \"--hook\", \"codex\"]\n")
    }
}
