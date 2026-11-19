import XCTest
@testable import Nirux

/// Where the user is still in the loop: the prompts a space logs, and the
/// lines the recap proposes (Space Settings › Safety).
final class LoopRecapTests: XCTestCase {
    private func entries(_ count: Int, _ tool: String, _ target: String?, mode: String = "default", at time: TimeInterval = 1_000) -> [LoopLog.Entry] {
        Array(repeating: LoopLog.Entry(time: time, tool: tool, target: target, mode: mode), count: count)
    }

    private func group(_ tool: String, _ target: String?, count: Int = 3, autoOnly: Bool = false, exact: Int? = nil) -> LoopRecap.Group {
        LoopRecap.Group(tool: tool, target: target, count: count, autoOnly: autoOnly, exactCount: exact ?? count)
    }

    func testPromptsGroupByToolAndTargetOverThePeriod() {
        let log = entries(2, "Bash", "swift build", at: 10) + entries(4, "Bash", "swift build", at: 500)
            + entries(5, "WebFetch", "example.com", mode: "auto", at: 600) + entries(1, "WebFetch", "example.com", at: 700)
            + [LoopLog.Entry(time: 800, tool: "AskUserQuestion", target: "x", mode: "auto"), LoopLog.Entry(time: 900, tool: "AskUserQuestion", target: nil, mode: nil)]
        XCTAssertEqual(LoopRecap.groups(log, since: 100), [
            group("WebFetch", "example.com", count: 6, exact: 0),
            group("Bash", "swift build", count: 4, exact: 0),
            group("AskUserQuestion", nil, count: 2, exact: 0)
        ])
        let exact = [LoopLog.Entry(time: 1, tool: "Bash", target: "swift build", mode: nil, exact: true)]
        XCTAssertEqual(LoopRecap.groups(exact + entries(2, "Bash", "swift build"), since: 0).first?.exactCount, 1)
        XCTAssertEqual(LoopRecap.groups(entries(3, "WebFetch", "example.com", mode: "auto"), since: 0).first?.autoOnly, true)
    }

    /// Only what Nirux knows reads, builds or tests, and only from prompts
    /// a line would cover exactly.
    func testOnlyKnownSafeCommandsAreProposed() {
        XCTAssertEqual(group("Bash", "swift build").proposal, .allow("Bash(swift build:*)"))
        XCTAssertEqual(group("PowerShell", "npm test").proposal, .allow("PowerShell(npm test:*)"))
        XCTAssertEqual(group("Bash", "git status").proposal, .allow("Bash(git status:*)"))
        XCTAssertEqual(group("Bash", "npm run build").proposal, .allow("Bash(npm run build:*)"))
        XCTAssertEqual(group("Bash", "gh pr view").proposal, .allow("Bash(gh pr view:*)"))
        XCTAssertEqual(group("Bash", "xcrun simctl list").proposal, .allow("Bash(xcrun simctl list:*)"))
        XCTAssertEqual(group("WebFetch", "developer.apple.com").proposal, .allow("WebFetch(domain:developer.apple.com)"))
        XCTAssertEqual(
            group("WebFetch", "developer.apple.com", autoOnly: true).proposal, .environment("**Trusted domain**: developer.apple.com")
        )

        XCTAssertNil(group("Bash", "swift build", count: 2).proposal, "fewer than three prompts")
        XCTAssertNil(group("Bash", "swift build", count: 5, exact: 2).proposal, "most of them inside longer commands")
        XCTAssertNil(group("WebFetch", "developer.apple.com", count: 5, exact: 0).proposal, "a domain cut short")
        XCTAssertNil(group("Bash", nil).proposal, "a command Nirux couldn't name")
        let unknown = [
            // Run anything, or hooks and aliases.
            "git submodule", "git bisect", "git commit", "git merge", "git pull", "git am", "git cherry-pick", "git push",
            "git reset", "git config", "docker compose run",
            // Stand for many commands.
            "docker container", "docker volume", "swift package", "uv pip", "kubectl config", "git", "npm", "npm run", "aws",
            // Publish, install, run workflows.
            "pnpm publish", "yarn publish", "bun publish", "gh release create", "gh pr merge", "gh workflow run",
            "gh extension install", "cargo install", "pip install", "go generate",
            // Shells, interpreters, and the rest Nirux doesn't know.
            "python3", "swift", "bash", "rm", "sudo", "curl", "source", "find", "uv run python", "npx tsx", "xcodebuild"
        ]
        for program in unknown {
            XCTAssertNil(group("Bash", program).proposal, program)
        }
        for tool in ["mcp__nirux__queue_merge", "mcp__browser__javascript_tool", "mcp__linear__delete_issue"] {
            XCTAssertNil(group(tool, nil).proposal, tool)
        }
        XCTAssertNil(group("Edit", "outside the folder").proposal)
        XCTAssertNil(group("AskUserQuestion", nil, count: 9).proposal)
    }

    /// What a prompt is about, never its text: a program Nirux can't name
    /// has no target.
    func testAPromptKeepsItsProgramNeverItsCommand() throws {
        func event(_ tool: String, _ input: [String: Any], mode: String? = "default") -> AgentHookEvent? {
            var payload: [String: Any] = ["hook_event_name": "PermissionRequest", "tool_name": tool, "tool_input": input, "cwd": "/work/app"]
            payload["permission_mode"] = mode
            return AgentHookEvent(kind: .claude, payload: payload, env: [:], now: 1_000)
        }
        let build = try XCTUnwrap(event("Bash", ["command": "swift build --product SecretThing"]))
        let entry = try XCTUnwrap(LoopLog.entry(of: build))
        XCTAssertEqual(entry, LoopLog.Entry(time: 1_000, tool: "Bash", target: "swift build", mode: "default", exact: true))
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(entry), as: UTF8.self).contains("SecretThing"))

        // What `Bash(<target>:*)` wouldn't match counts, but proposes nothing.
        for command in ["git -C app status", "/usr/bin/git status", "npm --prefix web run build", "rm -rf .build && swift build",
                        "swift build > build.log", "time swift build"] {
            let prompt = try XCTUnwrap(event("Bash", ["command": command]))
            XCTAssertNotNil(prompt.promptTarget, command)
            XCTAssertEqual(prompt.promptExact, false, command)
        }
        XCTAssertEqual(event("Bash", ["command": "git status"])?.promptExact, true)
        let longHost = String(repeating: "a", count: 90) + ".dev"
        XCTAssertEqual(event("WebFetch", ["url": "https://\(longHost)/x"])?.promptExact, false, "cut short")
        XCTAssertEqual(event("WebFetch", ["url": "https://docs.swift.org/x"])?.promptExact, true)

        XCTAssertNil(event("Bash", ["command": "for f in *.txt; do wc -l \"$f\"; done"])?.promptTarget)
        XCTAssertEqual(event("Bash", ["command": "cd /tmp && sudo launchctl list"])?.promptTarget, "sudo", "never the program it runs")
        XCTAssertEqual(event("Bash", ["command": "/usr/bin/sudo launchctl list"])?.promptTarget, "sudo")
        XCTAssertEqual(event("Bash", ["command": "FOO=1 sudo ls"])?.promptTarget, "sudo")
        XCTAssertNotEqual(event("Bash", ["command": "grep -rn sudo Sources"])?.promptTarget, "sudo", "only where a command starts")
        XCTAssertNotEqual(event("Bash", ["command": "man su"])?.promptTarget, "su")
        XCTAssertEqual(event("Bash", ["command": "pnpm -F web build"])?.promptTarget, "pnpm")
        XCTAssertEqual(event("WebFetch", ["url": "https://Developer.Apple.com/documentation/x?q=1"])?.promptTarget, "developer.apple.com")
        XCTAssertEqual(event("Edit", ["file_path": "/etc/hosts"])?.promptTarget, "outside the folder")
        XCTAssertEqual(event("Write", ["file_path": "/work/app/Sources/a.swift"])?.promptTarget, "in the folder")
        XCTAssertNil(event("mcp__linear__create_issue", ["title": "Private title"])?.promptTarget)
        XCTAssertEqual(event("WebFetch", ["url": "https://a.dev"], mode: "auto")?.permissionMode, "auto")

        let stop = AgentHookEvent(kind: .claude, payload: ["hook_event_name": "PreToolUse", "tool_name": "Bash"], env: [:], now: 1)
        XCTAssertNil(stop.flatMap(LoopLog.entry(of:)), "only permission prompts")
    }

    /// 0600, and lines past 30 days go at the next append once the oldest
    /// is past it, keeping a day's margin so it rewrites once a day.
    func testTheLogKeepsThirtyDays() throws {
        let state = FileManager.default.temporaryDirectory.appendingPathComponent("nirux-loop-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: state) }
        let day: TimeInterval = 86_400
        let now: TimeInterval = 100 * day
        for (age, tool) in [(31.0, "old"), (29.5, "margin"), (28.0, "kept")] {
            LoopLog.lines.append(.init(time: now - age * day, tool: tool, target: nil, mode: nil), spaceID: "S1", stateDirectory: state)
        }
        let url = try XCTUnwrap(LoopLog.lines.fileURL(spaceID: "S1", stateDirectory: state))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(LoopLog.lines.load(spaceID: "S1", stateDirectory: state).map(\.tool), ["old", "margin", "kept"])

        LoopLog.lines.append(.init(time: now, tool: "new", target: nil, mode: nil), spaceID: "S1", stateDirectory: state)
        XCTAssertEqual(LoopLog.lines.load(spaceID: "S1", stateDirectory: state).map(\.tool), ["kept", "new"])
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int, 0o600)

        LoopLog.lines.trim(spaceID: "S1", now: now + 40 * day, stateDirectory: state)
        XCTAssertEqual(LoopLog.lines.load(spaceID: "S1", stateDirectory: state), [], "at launch too, without a new prompt")
    }

    /// A log it can't read is never written over; past its size limit,
    /// nothing is added until old lines go.
    func testTheLogNeverLosesItself() throws {
        let state = FileManager.default.temporaryDirectory.appendingPathComponent("nirux-loop-full-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: state) }
        let url = try XCTUnwrap(LoopLog.lines.fileURL(spaceID: "S1", stateDirectory: state))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let old = try JSONEncoder().encode(LoopLog.Entry(time: 1, tool: "Bash", target: "swift build", mode: nil)) + Data("\n".utf8)
        let now: TimeInterval = 100 * 86_400

        // Too large to read: neither trimmed nor added to.
        let huge = old + Data(repeating: UInt8(ascii: " "), count: LoopLog.lines.maxFileBytes + 100_000)
        try huge.write(to: url)
        LoopLog.lines.append(.init(time: now, tool: "Bash", target: "swift test", mode: nil), spaceID: "S1", stateDirectory: state)
        XCTAssertEqual(try Data(contentsOf: url), huge)
        XCTAssertTrue(LoopLog.lines.isFull(spaceID: "S1", stateDirectory: state))

        // Full but readable: nothing added, until the old lines go.
        let recent = try JSONEncoder().encode(LoopLog.Entry(time: now - 86_400, tool: "Bash", target: "swift build", mode: nil))
        try (recent + Data("\n".utf8) + Data(repeating: UInt8(ascii: "\n"), count: LoopLog.lines.maxFileBytes)).write(to: url)
        LoopLog.lines.append(.init(time: now, tool: "Bash", target: "swift test", mode: nil), spaceID: "S1", stateDirectory: state)
        XCTAssertEqual(LoopLog.lines.load(spaceID: "S1", stateDirectory: state).map(\.target), ["swift build"])
        try (old + Data(repeating: UInt8(ascii: "\n"), count: LoopLog.lines.maxFileBytes)).write(to: url)
        LoopLog.lines.append(.init(time: now, tool: "Bash", target: "swift test", mode: nil), spaceID: "S1", stateDirectory: state)
        XCTAssertEqual(LoopLog.lines.load(spaceID: "S1", stateDirectory: state).map(\.target), ["swift test"])
        XCTAssertFalse(LoopLog.lines.isFull(spaceID: "S1", stateDirectory: state))
    }

    /// Lines the user added go into the settings file, whatever the
    /// switches say.
    func testAddedLinesReachTheSettingsFile() throws {
        var defaults = SpaceDefaults()
        defaults.add(.allow("Bash(swift build:*)"))
        defaults.add(.allow("Bash(swift build:*)"))
        defaults.add(.environment("**Trusted domain**: developer.apple.com"))
        defaults.set(.trustRepositories, on: false)
        defaults.set(.denyIrreversible, on: false)
        XCTAssertEqual(defaults.addedLines, [.allow("Bash(swift build:*)"), .environment("**Trusted domain**: developer.apple.com")])
        let file = try XCTUnwrap(ClaudeSpaceSettings.file(defaults, repositories: [.init(path: "/a", remotes: [])]))
        XCTAssertEqual(file.permissions, .init(allow: ["Bash(swift build:*)"], deny: nil))
        XCTAssertEqual(file.autoMode?.environment, ["$defaults", "**Trusted domain**: developer.apple.com"])

        let loaded = SpaceDefaultsStore.decode(try JSONEncoder().encode(defaults))
        XCTAssertEqual(loaded.status, .loaded)
        XCTAssertEqual(loaded.defaults, defaults)
        XCTAssertEqual(
            SpaceDefaultsStore.decode(Data(#"{"schemaVersion": 1, "claudeAllow": "Bash(ls:*)"}"#.utf8)).status,
            .readOnly(.unknownSettings(["claudeAllow"]))
        )

        defaults.remove(.allow("Bash(swift build:*)"))
        defaults.remove(.environment("**Trusted domain**: developer.apple.com"))
        XCTAssertNil(ClaudeSpaceSettings.file(defaults, repositories: []))
    }
}
