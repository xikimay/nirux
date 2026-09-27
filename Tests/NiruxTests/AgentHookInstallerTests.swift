import XCTest
@testable import Nirux

final class AgentHookInstallerTests: XCTestCase {
    private var home: URL!
    private let niruxEnv = ["NIRUX_AGENT_UUID": "uuid-1"]

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

    private func modificationDate(_ relative: String) throws -> Date {
        let path = home.appendingPathComponent(relative).path
        return try XCTUnwrap(FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)
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
        let output = AgentHookInstaller.shellQuoted(receiverOutput.path)
        try """
        #!/bin/sh
        { printf '%s\\n' "$@"; echo "ppid=$PPID"; cat; } > \(output)
        """.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    /// Runs argv the way the agents do (no shell of our own), with `env` as
    /// the whole environment and `stdin` from a file. Returns the exit
    /// status, or -1 if the process hangs.
    private func runHook(_ argv: [String], env: [String: String], stdin: String = "") throws -> Int32 {
        let input = home.appendingPathComponent("stdin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try stdin.write(to: input, atomically: true, encoding: .utf8)
        let inputHandle = try FileHandle(forReadingFrom: input)
        defer { try? inputHandle.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: argv[0])
        process.arguments = Array(argv.dropFirst())
        process.environment = env.merging(["PATH": "/usr/bin:/bin"]) { current, _ in current }
        process.standardInput = inputHandle
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        guard exited.wait(timeout: .now() + 20) == .success else {
            process.terminate()
            XCTFail("\(argv) hung")
            return -1
        }
        return process.terminationStatus
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

    func testClaudeHookCommandFormat() {
        XCTAssertEqual(
            AgentHookInstaller.claudeHookCommand(executablePath: "/Apps/Nirux"),
            #"if [ -n "$NIRUX_AGENT_UUID" ] && [ -x '/Apps/Nirux' ]; then '/Apps/Nirux' --hook claude; "#
                + "else /bin/cat >/dev/null; fi"
        )
    }

    func testClaudeHookCommandRunsReceiverOnlyInNiruxTerminals() throws {
        let receiver = try makeFakeReceiver()
        let command = AgentHookInstaller.claudeHookCommand(executablePath: receiver)
        let payload = #"{"hook_event_name":"Stop"}"#

        XCTAssertEqual(try runHook(["/bin/sh", "-c", command], env: [:], stdin: payload), 0)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: receiverOutput.path),
            "outside Nirux the binary must not even launch"
        )
        XCTAssertEqual(try runHook(["/bin/sh", "-c", command], env: ["NIRUX_AGENT_UUID": ""], stdin: payload), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: receiverOutput.path))

        XCTAssertEqual(try runHook(["/bin/sh", "-c", command], env: niruxEnv, stdin: payload), 0)
        let output = try String(contentsOf: receiverOutput, encoding: .utf8)
        XCTAssertTrue(output.hasPrefix("--hook\nclaude\n"), output)
        XCTAssertTrue(output.hasSuffix(payload), "payload reaches the receiver on stdin")
    }

    func testClaudeHookCommandIsSilentNoOpWhenBinaryMissing() throws {
        let command = AgentHookInstaller.claudeHookCommand(
            executablePath: home.appendingPathComponent("gone/Nirux").path)
        XCTAssertEqual(try runHook(["/bin/sh", "-c", command], env: niruxEnv), 0)
    }

    func testClaudeHookCommandDrainsLargePayloadWhenSkipping() throws {
        // Claude reports a hook that closes stdin before its payload is fully
        // written (EPIPE) as failed. Past the 64 KB pipe buffer the writer
        // blocks, so a skipping hook must still read everything: `head` dies
        // of SIGPIPE (pipefail status 141) otherwise.
        let command = AgentHookInstaller.claudeHookCommand(
            executablePath: home.appendingPathComponent("gone/Nirux").path)
        let pipeline = #"set -o pipefail; head -c 300000 /dev/zero | /bin/sh -c "$1""#
        XCTAssertEqual(try runHook(["/bin/bash", "-c", pipeline, "_", command], env: [:]), 0, "outside Nirux")
        XCTAssertEqual(try runHook(["/bin/bash", "-c", pipeline, "_", command], env: niruxEnv), 0, "binary missing")
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

    func testClaudeReplacesEveryOlderNiruxFormat() {
        let legacy = [
            #"\"/Apps/Nirux\" --hook claude"#,
            #"if [ -x \"/Apps/Nirux\" ]; then \"/Apps/Nirux\" --hook claude; fi"#,
            #"if [ -n \"$NIRUX_AGENT_UUID\" ] && [ -x '/Old/Nirux' ]; then '/Old/Nirux' --hook claude; fi"#
        ].map { #"{"type": "command", "command": "\#($0)"}"# }
        let groups = AgentHookInstaller.claudeHookEvents.map {
            #""\#($0)": [{"matcher": "", "hooks": [\#(legacy.joined(separator: ", "))]}]"#
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

    func testClaudeKeepsOtherToolsHookClaudeCommands() {
        write("""
        {"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "/usr/local/bin/othertool --hook claude"}]}]}}
        """, ".claude/settings.json")
        AgentHookInstaller.installClaudeHooks(executablePath: "/Apps/Nirux", home: home)
        XCTAssertEqual(
            hookCommands(claudeSettings(), event: "Stop"),
            [
                "/usr/local/bin/othertool --hook claude",
                AgentHookInstaller.claudeHookCommand(executablePath: "/Apps/Nirux")
            ]
        )
    }

    func testClaudeInstallIsIdempotent() throws {
        AgentHookInstaller.installClaudeHooks(executablePath: "/Apps/Nirux", home: home)
        let first = read(".claude/settings.json")
        let mtime1 = try modificationDate(".claude/settings.json")
        Thread.sleep(forTimeInterval: 0.01)
        AgentHookInstaller.installClaudeHooks(executablePath: "/Apps/Nirux", home: home)
        XCTAssertEqual(first, read(".claude/settings.json"))
        XCTAssertEqual(mtime1, try modificationDate(".claude/settings.json"), "no rewrite when nothing changed")
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
        try XCTSkipIf(geteuid() == 0, "root reads mode-000 files")
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
            #"notify = ["/bin/sh", "-c", 'if [ -n "$NIRUX_AGENT_UUID" ] && [ -x "$0" ]; "#
                + #"then exec "$0" --hook codex "$@"; fi', "/Apps/Nirux"]"# + "\n"
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

        XCTAssertEqual(try runHook(argv, env: [:]), 0)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: receiverOutput.path),
            "outside Nirux the binary must not even launch"
        )

        XCTAssertEqual(try runHook(argv, env: niruxEnv), 0)
        let lines = try String(contentsOf: receiverOutput, encoding: .utf8).components(separatedBy: "\n")
        XCTAssertEqual(Array(lines.prefix(3)), ["--hook", "codex", payload])
        // Catches a missing `exec` only where /bin/sh is bash (macOS and CI):
        // zsh and dash exec a trailing command on their own.
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
        XCTAssertEqual(try runHook(argv, env: niruxEnv), 0)
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
        for original in [
            "notify = [\"/usr/local/bin/my-notify\"]\n",
            // Mentions `--hook` and lives under ~/.codex, but isn't Nirux's.
            "notify = [\"/Users/me/.codex/notify.sh\", \"--hook-kind\", \"turn\"]\n"
        ] {
            write(original, ".codex/config.toml")
            AgentHookInstaller.installCodexNotify(executablePath: "/Apps/Nirux", home: home)
            XCTAssertEqual(read(".codex/config.toml"), original)
        }
    }

    func testCodexWrappedNotifyUntouched() {
        // Replacing only the first line of a wrapped array would leave the
        // rest dangling and Codex unable to parse its config.
        let original = """
        notify = ["/bin/sh", "-c", 'if [ -n "$NIRUX_AGENT_UUID" ] && [ -x "$0" ]; then exec "$0" --hook codex "$@"; fi',
          "/old/Nirux"]

        """
        write(original, ".codex/config.toml")
        AgentHookInstaller.installCodexNotify(executablePath: "/Apps/Nirux", home: home)
        XCTAssertEqual(read(".codex/config.toml"), original)
    }

    func testCodexRefreshesStaleNiruxPath() {
        let newLine = AgentHookInstaller.codexNotifyLine(executablePath: "/new/Nirux")
        for stale in [
            "notify = [\"/old/Nirux\", \"--hook\", \"codex\"]",
            AgentHookInstaller.codexNotifyLine(executablePath: "/old/Nirux")
        ] {
            write("model = \"gpt-5\"\n\(stale)\n", ".codex/config.toml")
            AgentHookInstaller.installCodexNotify(executablePath: "/new/Nirux", home: home)
            XCTAssertEqual(read(".codex/config.toml"), "model = \"gpt-5\"\n\(newLine)\n", stale)
        }
    }

    func testCodexInstallIsIdempotent() throws {
        write("model = \"gpt-5\"\n", ".codex/config.toml")
        AgentHookInstaller.installCodexNotify(executablePath: "/Apps/Nirux", home: home)
        let first = read(".codex/config.toml")
        let mtime1 = try modificationDate(".codex/config.toml")
        Thread.sleep(forTimeInterval: 0.01)
        AgentHookInstaller.installCodexNotify(executablePath: "/Apps/Nirux", home: home)
        XCTAssertEqual(first, read(".codex/config.toml"))
        XCTAssertEqual(mtime1, try modificationDate(".codex/config.toml"), "no rewrite when nothing changed")
    }

    func testCodexKeepsCRLFLineEndings() throws {
        write("model = \"gpt-5\"\r\nnotify = [\"/old/Nirux\", \"--hook\", \"codex\"]\r\n", ".codex/config.toml")
        AgentHookInstaller.installCodexNotify(executablePath: "/Apps/Nirux", home: home)
        let newLine = AgentHookInstaller.codexNotifyLine(executablePath: "/Apps/Nirux")
        XCTAssertEqual(read(".codex/config.toml"), "model = \"gpt-5\"\r\n\(newLine)\r\n")

        let mtime1 = try modificationDate(".codex/config.toml")
        Thread.sleep(forTimeInterval: 0.01)
        AgentHookInstaller.installCodexNotify(executablePath: "/Apps/Nirux", home: home)
        XCTAssertEqual(mtime1, try modificationDate(".codex/config.toml"), "no rewrite on relaunch")
    }

    func testCodexAppendsATerminatedLine() {
        // No [table] to insert before: the entry becomes the last line, and
        // must never leave the file ending in a bare \r (invalid TOML).
        let notify = AgentHookInstaller.codexNotifyLine(executablePath: "/Apps/Nirux")
        let cases = [
            ("", "\(notify)\n"),
            ("model = 1\n", "model = 1\n\(notify)\n"),
            ("model = 1", "model = 1\n\(notify)\n"),
            ("model = 1\r\n", "model = 1\r\n\(notify)\r\n"),
            ("model = 1\r\nfoo = 2", "model = 1\r\nfoo = 2\r\n\(notify)\r\n")
        ]
        for (original, expected) in cases {
            write(original, ".codex/config.toml")
            AgentHookInstaller.installCodexNotify(executablePath: "/Apps/Nirux", home: home)
            XCTAssertEqual(read(".codex/config.toml"), expected, original.debugDescription)
        }
    }

    func testCodexRefreshKeepsTheLinesOwnEnding() {
        let notify = AgentHookInstaller.codexNotifyLine(executablePath: "/Apps/Nirux")
        write("model = 1\r\nnotify = [\"/old/Nirux\", \"--hook\", \"codex\"]", ".codex/config.toml")
        AgentHookInstaller.installCodexNotify(executablePath: "/Apps/Nirux", home: home)
        XCTAssertEqual(read(".codex/config.toml"), "model = 1\r\n\(notify)", "unterminated last line gets no \\r")
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

    // MARK: - When to install

    private let appBundle = URL(fileURLWithPath: "/Applications/Nirux.app")
    private let devBuild = URL(fileURLWithPath: "/src/nirux/.build/arm64-apple-macosx/debug")

    func testOnlyAppBundlesInstallByDefault() {
        XCTAssertTrue(AgentHookInstaller.shouldInstall(environment: [:], bundleURL: appBundle))
        XCTAssertFalse(AgentHookInstaller.shouldInstall(environment: [:], bundleURL: devBuild), "swift run")
    }

    func testInstallFlags() {
        let force = ["NIRUX_FORCE_HOOK_INSTALL": "1"]
        XCTAssertTrue(AgentHookInstaller.shouldInstall(environment: force, bundleURL: devBuild))
        XCTAssertFalse(
            AgentHookInstaller.shouldInstall(environment: ["NIRUX_FORCE_HOOK_INSTALL": "0"], bundleURL: devBuild))
        for value in ["1", "true", "YES"] {
            XCTAssertFalse(
                AgentHookInstaller.shouldInstall(environment: ["NIRUX_SKIP_HOOK_INSTALL": value], bundleURL: appBundle),
                value
            )
        }
        for value in ["", "0", "false", "no"] {
            XCTAssertTrue(
                AgentHookInstaller.shouldInstall(environment: ["NIRUX_SKIP_HOOK_INSTALL": value], bundleURL: appBundle),
                value
            )
        }
        XCTAssertFalse(
            AgentHookInstaller.shouldInstall(
                environment: force.merging(["NIRUX_SKIP_HOOK_INSTALL": "1"]) { $1 }, bundleURL: devBuild),
            "an explicit opt-out wins"
        )
    }

    func testInstallAllLeavesConfigsUntouchedWhenSkipped() {
        AgentHookInstaller.installAll(executablePath: "/Apps/Nirux", home: home, environment: [:], bundleURL: devBuild)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".codex").path))

        AgentHookInstaller.installAll(executablePath: "/Apps/Nirux", home: home, environment: [:], bundleURL: appBundle)
        XCTAssertFalse(read(".claude/settings.json").isEmpty)
        XCTAssertFalse(read(".codex/config.toml").isEmpty)
    }

    // MARK: - Receiver (end to end)

    /// `swift test` builds the app executable next to the test bundle.
    private func niruxExecutable() throws -> String {
        let url = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("Nirux")
        return try XCTUnwrap(
            FileManager.default.isExecutableFile(atPath: url.path) ? url.path : nil,
            "Nirux executable not found at \(url.path)"
        )
    }

    func testReceiverQueuesOnlyEventsFromNiruxTerminals() throws {
        let nirux = try niruxExecutable()
        let stateDir = home.appendingPathComponent("state")
        let events = stateDir.appendingPathComponent("hook-events.jsonl")
        let state = ["NIRUX_STATE_DIR": stateDir.path]
        let claudePayload = #"{"hook_event_name":"Stop","session_id":"s1"}"#
        let codexPayload = #"{"type":"agent-turn-complete","thread-id":"t1"}"#

        // Hook entries from older builds launch the receiver unguarded.
        XCTAssertEqual(try runHook([nirux, "--hook", "claude"], env: state, stdin: claudePayload), 0)
        XCTAssertEqual(try runHook([nirux, "--hook", "codex", codexPayload], env: state), 0)
        XCTAssertEqual((try? String(contentsOf: events, encoding: .utf8)) ?? "", "", "no UUID, nothing queued")

        let inNirux = state.merging(niruxEnv) { $1 }
        XCTAssertEqual(try runHook([nirux, "--hook", "claude"], env: inNirux, stdin: claudePayload), 0)
        XCTAssertEqual(try runHook([nirux, "--hook", "codex", codexPayload], env: inNirux), 0)
        let queued = try String(contentsOf: events, encoding: .utf8)
            .split(separator: "\n")
            .map { try JSONDecoder().decode(AgentHookEvent.self, from: Data($0.utf8)) }
        XCTAssertEqual(queued.map(\.name), [.stop, .turnComplete])
        XCTAssertEqual(queued.map(\.agentUUID), ["uuid-1", "uuid-1"])
    }
}

// MARK: - Event list changes

extension AgentHookInstallerTests {
    /// An install from before PermissionRequest/PostToolUse/SubagentStop
    /// joined the list gains them on the next launch; the user's own hooks
    /// on those events stay.
    func testClaudeRefreshAddsNewEventsAndKeepsUserHooks() {
        let stale = #"if [ -n \"$NIRUX_AGENT_UUID\" ] && [ -x '/Old/Nirux' ]; then '/Old/Nirux' --hook claude; fi"#
        let oldEvents = ["SessionStart", "UserPromptSubmit", "PreToolUse", "Notification", "Stop", "SessionEnd"]
        var groups = oldEvents.map {
            #""\#($0)": [{"matcher": "", "hooks": [{"type": "command", "command": "\#(stale)"}]}]"#
        }
        groups.append(#""PermissionRequest": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "/usr/local/bin/approver"}]}]"#)
        groups.append(#""PostToolUse": [{"matcher": "Edit", "hooks": [{"type": "command", "command": "/usr/local/bin/fmt"}]}]"#)
        write(#"{"hooks": {\#(groups.joined(separator: ", "))}}"#, ".claude/settings.json")

        AgentHookInstaller.installClaudeHooks(executablePath: "/Apps/Nirux", home: home)
        let settings = claudeSettings()
        let ours = AgentHookInstaller.claudeHookCommand(executablePath: "/Apps/Nirux")
        XCTAssertTrue(AgentHookInstaller.claudeHookEvents.contains("PermissionRequest"))
        XCTAssertTrue(AgentHookInstaller.claudeHookEvents.contains("PostToolUseFailure"))
        for event in AgentHookInstaller.claudeHookEvents {
            XCTAssertEqual(
                hookCommands(settings, event: event).filter { $0.contains("--hook claude") }, [ours], event
            )
        }
        XCTAssertEqual(hookCommands(settings, event: "PermissionRequest"), ["/usr/local/bin/approver", ours])
        XCTAssertEqual(hookCommands(settings, event: "PostToolUse"), ["/usr/local/bin/fmt", ours])
        // The receiver prints nothing: a PermissionRequest hook without a
        // `decision` leaves the dialog to the user.
        let hooks = settings["hooks"] as? [String: Any] ?? [:]
        let permissionGroups = hooks["PermissionRequest"] as? [[String: Any]] ?? []
        XCTAssertEqual(permissionGroups.first?["matcher"] as? String, "Bash", "user matcher untouched")
    }

    /// An event only another build listed (newer, before a downgrade; or
    /// one this build dropped) must not keep launching Nirux.
    func testClaudeRemovesItsEntriesFromUnlistedEvents() {
        let ours = #"if [ -n \"$NIRUX_AGENT_UUID\" ] && [ -x '/Old/Nirux' ]; then '/Old/Nirux' --hook claude; fi"#
        write(#"""
        {"hooks": {
          "PreCompact": [{"matcher": "", "hooks": [{"type": "command", "command": "\#(ours)"}]}],
          "TeammateIdle": [{"matcher": "", "hooks": [
            {"type": "command", "command": "\#(ours)"},
            {"type": "command", "command": "/usr/local/bin/notify"}
          ]}],
          "CwdChanged": [{"hooks": [{"type": "command", "command": "direnv export json"}]}],
          "FileChanged": []
        }}
        """#, ".claude/settings.json")

        AgentHookInstaller.installClaudeHooks(executablePath: "/Apps/Nirux", home: home)
        let settings = claudeSettings()
        let hooks = settings["hooks"] as? [String: Any] ?? [:]
        XCTAssertNil(hooks["PreCompact"], "emptied by the removal: gone")
        XCTAssertEqual(hookCommands(settings, event: "TeammateIdle"), ["/usr/local/bin/notify"])
        XCTAssertEqual(hookCommands(settings, event: "CwdChanged"), ["direnv export json"])
        XCTAssertNotNil(hooks["FileChanged"], "user keys without our entries stay as written")
    }
}
