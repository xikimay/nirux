import XCTest
@testable import Nirux

/// Where the user is still in the loop: the prompts a space logs, and the
/// lines the recap proposes (Space Settings › Safety).
final class LoopRecapTests: XCTestCase {
    private func entries(_ count: Int, _ tool: String, _ target: String?, mode: String = "default", at time: TimeInterval = 1_000) -> [LoopLog.Entry] {
        Array(repeating: LoopLog.Entry(time: time, tool: tool, target: target, mode: mode), count: count)
    }

    private func group(_ tool: String, _ target: String?, count: Int = 3, autoOnly: Bool = false) -> LoopRecap.Group {
        LoopRecap.Group(tool: tool, target: target, count: count, autoOnly: autoOnly)
    }

    func testPromptsGroupByToolAndTargetOverThePeriod() {
        let log = entries(2, "Bash", "swift build", at: 10) + entries(4, "Bash", "swift build", at: 500)
            + entries(5, "WebFetch", "example.com", mode: "auto", at: 600) + entries(1, "WebFetch", "example.com", at: 700)
            + [LoopLog.Entry(time: 800, tool: "AskUserQuestion", target: "x", mode: "auto"), LoopLog.Entry(time: 900, tool: "AskUserQuestion", target: nil, mode: nil)]
        XCTAssertEqual(LoopRecap.groups(log, since: 100), [
            group("WebFetch", "example.com", count: 6),
            group("Bash", "swift build", count: 4),
            group("AskUserQuestion", nil, count: 2)
        ])
        XCTAssertEqual(LoopRecap.groups(entries(3, "WebFetch", "example.com", mode: "auto"), since: 0).first?.autoOnly, true)
    }

    func testEachGroupProposesAtMostOneLine() {
        XCTAssertEqual(group("Bash", "swift build").proposal, .allow("Bash(swift build:*)"))
        XCTAssertEqual(group("PowerShell", "npm test").proposal, .allow("PowerShell(npm test:*)"))
        XCTAssertEqual(group("Bash", "gh run view").proposal, .allow("Bash(gh run view:*)"))
        XCTAssertEqual(group("Bash", "docker compose up").proposal, .allow("Bash(docker compose up:*)"))
        XCTAssertEqual(group("Bash", "git status").proposal, .allow("Bash(git status:*)"))
        XCTAssertEqual(group("Bash", "npm run build").proposal, .allow("Bash(npm run build:*)"))
        XCTAssertEqual(group("Bash", "gh pr view").proposal, .allow("Bash(gh pr view:*)"))
        XCTAssertEqual(group("Bash", "make lint").proposal, .allow("Bash(make lint:*)"))
        XCTAssertEqual(group("WebFetch", "developer.apple.com").proposal, .allow("WebFetch(domain:developer.apple.com)"))
        XCTAssertEqual(
            group("WebFetch", "developer.apple.com", autoOnly: true).proposal, .environment("**Trusted domain**: developer.apple.com")
        )
        XCTAssertEqual(group("mcp__linear__create_issue", nil).proposal, .allow("mcp__linear__create_issue"))

        XCTAssertNil(group("Bash", "swift build", count: 2).proposal, "fewer than three prompts")
        XCTAssertNil(group("Bash", nil).proposal, "a command Nirux couldn't name")
        let refused = [
            "python3", "swift", "bash", "rm", "sudo", "curl", "source", "find", "git push", "git reset", "git clean",
            "git worktree", "git switch", "git config",
            // What stands for many commands: a program alone, or one whose subcommand Nirux couldn't read.
            "git", "pnpm", "npm", "gh pr", "npm run", "make", "aws", "terraform", "xcodebuild",
            // What runs any code through a subcommand.
            "uv run python", "xcrun python3 x.py", "npm exec", "npm x", "npx tsx", "docker exec web", "kubectl exec",
            "docker run alpine", "uv tool", "gh api", "go run main.go"
        ]
        for program in refused {
            XCTAssertNil(group("Bash", program).proposal, program)
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
        let build = try XCTUnwrap(event("Bash", ["command": "cd /work/app && swift build --product SecretThing"]))
        let entry = try XCTUnwrap(LoopLog.entry(of: build))
        XCTAssertEqual(entry, LoopLog.Entry(time: 1_000, tool: "Bash", target: "swift build", mode: "default"))
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(entry), as: UTF8.self).contains("SecretThing"))

        XCTAssertNil(event("Bash", ["command": "for f in *.txt; do wc -l \"$f\"; done"])?.promptTarget)
        XCTAssertEqual(event("Bash", ["command": "cd /tmp && sudo launchctl list"])?.promptTarget, "sudo", "never the program it runs")
        XCTAssertEqual(event("Bash", ["command": "/usr/bin/sudo launchctl list"])?.promptTarget, "sudo")
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
            LoopLog.append(.init(time: now - age * day, tool: tool, target: nil, mode: nil), spaceID: "S1", stateDirectory: state)
        }
        let url = try XCTUnwrap(LoopLog.fileURL(spaceID: "S1", stateDirectory: state))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(LoopLog.load(spaceID: "S1", stateDirectory: state).map(\.tool), ["old", "margin", "kept"])

        LoopLog.append(.init(time: now, tool: "new", target: nil, mode: nil), spaceID: "S1", stateDirectory: state)
        XCTAssertEqual(LoopLog.load(spaceID: "S1", stateDirectory: state).map(\.tool), ["kept", "new"])
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int, 0o600)

        LoopLog.trim(spaceID: "S1", now: now + 40 * day, stateDirectory: state)
        XCTAssertEqual(LoopLog.load(spaceID: "S1", stateDirectory: state), [], "at launch too, without a new prompt")
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
