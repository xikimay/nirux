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
        for (event, _) in AgentHookInstaller.claudeHookEvents {
            XCTAssertEqual(
                hookCommands(settings, event: event),
                ["\"/Apps/Nirux\" --hook claude"],
                event
            )
        }
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
        XCTAssertEqual(preToolCommands.filter { $0.contains("--hook claude") }, ["\"/new/Nirux\" --hook claude"])
        XCTAssertEqual(hookCommands(settings, event: "Stop"), ["\"/new/Nirux\" --hook claude"])
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

    func testClaudeAsyncFlags() {
        AgentHookInstaller.installClaudeHooks(executablePath: "/Apps/Nirux", home: home)
        let settings = claudeSettings()
        let hooks = settings["hooks"] as? [String: Any] ?? [:]
        let preTool = (hooks["PreToolUse"] as? [[String: Any]])?.first ?? [:]
        let preToolHook = (preTool["hooks"] as? [[String: Any]])?.first ?? [:]
        XCTAssertEqual(preToolHook["async"] as? Bool, true)
        let stop = (hooks["Stop"] as? [[String: Any]])?.first ?? [:]
        let stopHook = (stop["hooks"] as? [[String: Any]])?.first ?? [:]
        XCTAssertNil(stopHook["async"])
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
