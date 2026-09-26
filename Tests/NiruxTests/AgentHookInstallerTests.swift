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

    private func symlink(_ relative: String, to destination: String) throws {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: destination)
    }

    private func linkDestination(_ relative: String) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: home.appendingPathComponent(relative).path)
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

    // MARK: - Hook command execution

    private var receiverOutput: URL { home.appendingPathComponent("receiver.out") }

    /// Stand-in for the Nirux binary: records its argv, parent PID and stdin.
    /// The path holds a space and a quote to exercise the command quoting.
    private func makeFakeReceiver() throws -> String {
        let url = home.appendingPathComponent("My Apps/Ni'rux")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        #!/bin/sh
        { printf '%s\\n' "$@"; echo "ppid=$PPID"; cat; } > '\(receiverOutput.path)'
        """.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    /// Runs argv the way the agents do (no shell of our own), with `env` as
    /// the whole environment and `stdin` from a file. Returns the exit status.
    private func run(_ argv: [String], env: [String: String], stdin: String = "") throws -> Int32 {
        let input = home.appendingPathComponent("stdin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try stdin.write(to: input, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: argv[0])
        process.arguments = Array(argv.dropFirst())
        process.environment = env.merging(["PATH": "/usr/bin:/bin"]) { current, _ in current }
        process.standardInput = try FileHandle(forReadingFrom: input)
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private let niruxEnv = ["NIRUX_AGENT_UUID": "uuid-1"]

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

    func testClaudeHookCommandFormat() {
        XCTAssertEqual(
            AgentHookInstaller.claudeHookCommand(executablePath: "/Apps/Nirux"),
            #"if [ -n "$NIRUX_AGENT_UUID" ] && [ -x '/Apps/Nirux' ]; then '/Apps/Nirux' --hook claude; fi"#
        )
    }

    func testClaudeHookCommandRunsReceiverOnlyInNiruxTerminals() throws {
        let receiver = try makeFakeReceiver()
        let command = AgentHookInstaller.claudeHookCommand(executablePath: receiver)
        let payload = #"{"hook_event_name":"Stop"}"#

        XCTAssertEqual(try run(["/bin/sh", "-c", command], env: [:], stdin: payload), 0)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: receiverOutput.path),
            "outside Nirux the binary must not even launch"
        )
        XCTAssertEqual(try run(["/bin/sh", "-c", command], env: ["NIRUX_AGENT_UUID": ""], stdin: payload), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: receiverOutput.path))

        XCTAssertEqual(try run(["/bin/sh", "-c", command], env: niruxEnv, stdin: payload), 0)
        let output = try String(contentsOf: receiverOutput, encoding: .utf8)
        XCTAssertTrue(output.hasPrefix("--hook\nclaude\n"), output)
        XCTAssertTrue(output.hasSuffix(payload), "payload reaches the receiver on stdin")
    }

    func testClaudeHookCommandIsSilentNoOpWhenBinaryMissing() throws {
        let command = AgentHookInstaller.claudeHookCommand(
            executablePath: home.appendingPathComponent("gone/Nirux").path)
        XCTAssertEqual(try run(["/bin/sh", "-c", command], env: niruxEnv), 0)
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

    func testClaudeReplacesUnguardedCommandFromOlderBuilds() {
        let legacy = #"if [ -x \"/Apps/Nirux\" ]; then \"/Apps/Nirux\" --hook claude; fi"#
        let groups = AgentHookInstaller.claudeHookEvents.map {
            #""\#($0)": [{"matcher": "", "hooks": [{"type": "command", "command": "\#(legacy)"}]}]"#
        }
        write(#"{"hooks": {\#(groups.joined(separator: ", "))}}"#, ".claude/settings.json")

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

    func testClaudeOutputIsDeterministicWithUnescapedSlashes() throws {
        write(#"{"zeta": "https://example.com/a", "alpha": 1}"#, ".claude/settings.json")
        AgentHookInstaller.installClaudeHooks(executablePath: "/Apps/Nirux", home: home)
        let text = read(".claude/settings.json")
        XCTAssertFalse(text.contains(#"\/"#), text)
        XCTAssertTrue(text.contains(#""https://example.com/a""#))
        let alpha = try XCTUnwrap(text.range(of: #""alpha""#))
        let zeta = try XCTUnwrap(text.range(of: #""zeta""#))
        XCTAssertLessThan(alpha.lowerBound, zeta.lowerBound, "sorted keys")
    }

    func testClaudeUnparsableSettingsUntouched() {
        write("{ not json ,,", ".claude/settings.json")
        AgentHookInstaller.installClaudeHooks(executablePath: "/Apps/Nirux", home: home)
        XCTAssertEqual(read(".claude/settings.json"), "{ not json ,,")
    }

    func testClaudeUnreadableSettingsUntouched() throws {
        write(#"{"model": "opus"}"#, ".claude/settings.json")
        let path = home.appendingPathComponent(".claude/settings.json").path
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path)
        AgentHookInstaller.installClaudeHooks(executablePath: "/Apps/Nirux", home: home)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
        XCTAssertEqual(read(".claude/settings.json"), #"{"model": "opus"}"#, "never replaced by a fresh file")
    }

    func testClaudeWritesThroughSymlinkedSettings() throws {
        write(#"{"model": "opus"}"#, "dotfiles/claude-settings.json")
        try symlink(".claude/settings.json", to: "../dotfiles/claude-settings.json")

        AgentHookInstaller.installClaudeHooks(executablePath: "/Apps/Nirux", home: home)

        XCTAssertEqual(linkDestination(".claude/settings.json"), "../dotfiles/claude-settings.json", "link kept")
        let settings = claudeSettings()
        XCTAssertEqual(settings["model"] as? String, "opus")
        XCTAssertEqual(
            hookCommands(settings, event: "Stop"),
            [AgentHookInstaller.claudeHookCommand(executablePath: "/Apps/Nirux")]
        )
    }

    func testClaudeDanglingSymlinkCreatesItsTarget() throws {
        write("", "dotfiles/.keep")
        try symlink(".claude/settings.json", to: home.appendingPathComponent("dotfiles/settings.json").path)

        AgentHookInstaller.installClaudeHooks(executablePath: "/Apps/Nirux", home: home)

        XCTAssertNotNil(linkDestination(".claude/settings.json"), "link kept")
        XCTAssertFalse(read("dotfiles/settings.json").isEmpty)
    }

    func testClaudeSymlinkLoopUntouched() throws {
        try symlink(".claude/settings.json", to: "loop.json")
        try symlink(".claude/loop.json", to: "settings.json")

        AgentHookInstaller.installClaudeHooks(executablePath: "/Apps/Nirux", home: home)

        XCTAssertEqual(linkDestination(".claude/settings.json"), "loop.json")
        XCTAssertEqual(linkDestination(".claude/loop.json"), "settings.json")
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
            #"notify = ["/bin/sh", "-c", 'if [ -n "$NIRUX_AGENT_UUID" ] && [ -x "$0" ]; then exec "$0" --hook codex "$@"; fi', "/Apps/Nirux"]"#
                + "\n"
        )
    }

    func testCodexNotifyEscapesPathForTOML() {
        XCTAssertTrue(
            AgentHookInstaller.codexNotifyLine(executablePath: #"/A "q"\b/Nirux"#)
                .hasSuffix(#", "/A \"q\"\\b/Nirux"]"#)
        )
    }

    func testCodexNotifyRunsReceiverOnlyInNiruxTerminals() throws {
        let receiver = try makeFakeReceiver()
        // What Codex spawns: the notify argv plus the payload as last arg.
        let payload = #"{"type":"agent-turn-complete"}"#
        let argv = ["/bin/sh", "-c", AgentHookInstaller.codexNotifyScript, receiver, payload]

        XCTAssertEqual(try run(argv, env: [:]), 0)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: receiverOutput.path),
            "outside Nirux the binary must not even launch"
        )

        XCTAssertEqual(try run(argv, env: niruxEnv), 0)
        let lines = try String(contentsOf: receiverOutput, encoding: .utf8).components(separatedBy: "\n")
        XCTAssertEqual(Array(lines.prefix(3)), ["--hook", "codex", payload])
        XCTAssertEqual(
            lines.dropFirst(3).first, "ppid=\(ProcessInfo.processInfo.processIdentifier)",
            "exec: the receiver's parent must be the agent, not an intermediate shell"
        )
    }

    func testCodexNotifyIsSilentNoOpWhenBinaryMissing() throws {
        let argv = [
            "/bin/sh", "-c", AgentHookInstaller.codexNotifyScript,
            home.appendingPathComponent("gone/Nirux").path, "{}"
        ]
        XCTAssertEqual(try run(argv, env: niruxEnv), 0)
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
        write("model = \"gpt-5\"\nnotify = [\"/old/Nirux\", \"--hook\", \"codex\"]\n", ".codex/config.toml")
        AgentHookInstaller.installCodexNotify(executablePath: "/new/Nirux", home: home)
        XCTAssertEqual(
            read(".codex/config.toml"),
            "model = \"gpt-5\"\n" + AgentHookInstaller.codexNotifyLine(executablePath: "/new/Nirux") + "\n"
        )
    }

    func testCodexUnreadableConfigUntouched() throws {
        // Not UTF-8: previously treated as missing and replaced wholesale.
        let original = Data([0x6D, 0x6F, 0x64, 0x65, 0x6C, 0x20, 0x3D, 0x20, 0x22, 0xE9, 0x22, 0x0A])
        let url = home.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try original.write(to: url)
        AgentHookInstaller.installCodexNotify(executablePath: "/Apps/Nirux", home: home)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testCodexWritesThroughSymlinkedConfig() throws {
        write("model = \"gpt-5\"\n", "dotfiles/codex.toml")
        try symlink(".codex/config.toml", to: "../dotfiles/codex.toml")

        AgentHookInstaller.installCodexNotify(executablePath: "/Apps/Nirux", home: home)

        XCTAssertEqual(linkDestination(".codex/config.toml"), "../dotfiles/codex.toml", "link kept")
        XCTAssertTrue(
            read("dotfiles/codex.toml").contains(AgentHookInstaller.codexNotifyLine(executablePath: "/Apps/Nirux")))
    }

    // MARK: - Opt-out

    func testSkipEnvLeavesConfigsUntouched() {
        AgentHookInstaller.installAll(
            executablePath: "/Apps/Nirux", home: home, environment: ["NIRUX_SKIP_HOOK_INSTALL": "1"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".codex").path))
    }

    func testSkipEnvZeroOrEmptyStillInstalls() {
        XCTAssertFalse(AgentHookInstaller.isInstallDisabled(environment: [:]))
        XCTAssertFalse(AgentHookInstaller.isInstallDisabled(environment: ["NIRUX_SKIP_HOOK_INSTALL": ""]))
        XCTAssertFalse(AgentHookInstaller.isInstallDisabled(environment: ["NIRUX_SKIP_HOOK_INSTALL": "0"]))
        AgentHookInstaller.installAll(
            executablePath: "/Apps/Nirux", home: home, environment: ["NIRUX_SKIP_HOOK_INSTALL": "0"])
        XCTAssertFalse(read(".claude/settings.json").isEmpty)
        XCTAssertFalse(read(".codex/config.toml").isEmpty)
    }
}
