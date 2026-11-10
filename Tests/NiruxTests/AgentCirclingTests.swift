import AppKit
import XCTest
@testable import Nirux

/// A working agent that may be going in circles says so in grey on its row
/// (`AgentCirclingHint`): what the hook receiver keeps of a tool call's
/// end, what a turn's calls add up to, and what the row shows.
final class AgentCirclingTests: XCTestCase {
    // MARK: - What the receiver keeps of a call's end

    private func toolEvent(
        _ hook: String, tool: String = "Bash", input: [String: Any] = ["command": "swift build"], _ more: [String: Any] = [:]
    ) -> AgentHookEvent? {
        let payload: [String: Any] = [
            "hook_event_name": hook, "session_id": "s", "cwd": "/tmp/proj", "tool_name": tool, "tool_input": input
        ]
        return AgentHookEvent(
            kind: .claude, payload: payload.merging(more) { $1 }, env: ["NIRUX_AGENT_UUID": "uuid-1"], now: 7
        )
    }

    /// The payloads are Claude Code 2.1.321's, as its hooks sent them.
    func testAFailedCallSaysSoAndNamesItsProgram() throws {
        let failed = try XCTUnwrap(toolEvent(
            "PostToolUseFailure", input: ["command": "cd /tmp/proj && swift build 2>&1"],
            ["error": "Exit code 1\nerror: no such module 'Secrets'", "is_interrupt": false]
        ))
        XCTAssertEqual(failed.toolEnd, "failed")
        XCTAssertEqual(failed.toolFamily, "swift build")
        let queued = String(decoding: try JSONEncoder().encode(failed), as: UTF8.self)
        XCTAssertFalse(queued.contains("no such module"), "the error stays in the receiver")

        let ran = toolEvent("PostToolUse", ["tool_response": ["stdout": "Build complete!", "interrupted": false]])
        XCTAssertNil(ran?.toolEnd)
        XCTAssertEqual(ran?.toolFamily, "swift build", "a success ends its failures in a row")
        XCTAssertEqual(toolEvent("PostToolUseFailure", ["error": "Exit code 1"])?.toolEnd, "failed", "older Claude: no is_interrupt")
        XCTAssertEqual(toolEvent("PostToolUseFailure", ["error": "x", "is_interrupt": true])?.toolEnd, "interrupted")

        let edit = toolEvent("PostToolUseFailure", tool: "Edit", input: ["file_path": "/tmp/proj/a.swift"], ["error": "String to replace not found"])
        XCTAssertEqual(edit?.toolEnd, "failed")
        XCTAssertNil(edit?.toolFamily, "the tool's name stands for it")
        for hook in ["PreToolUse", "PermissionRequest"] {
            XCTAssertNil(toolEvent(hook)?.toolEnd, hook)
            XCTAssertNil(toolEvent(hook)?.toolFamily, hook)
        }
    }

    func testACommandPastItsTimeLimitIsHungHoweverClaudeReportsIt() {
        func end(_ hook: String, tool: String = "Bash", input: [String: Any] = ["command": "ls /Volumes/x"], _ more: [String: Any]) -> String? {
            toolEvent(hook, tool: tool, input: input, more)?.toolEnd
        }
        let moved: [String: Any] = ["stdout": "", "stderr": "", "interrupted": false, "backgroundTaskId": "b12"]
        XCTAssertEqual(end("PostToolUse", ["tool_response": moved.merging(["timedOutAfterMs": 120_000]) { $1 }]), "hung", "interactive, 2.1.321")
        XCTAssertEqual(end("PostToolUse", ["tool_response": moved.merging(["assistantAutoBackgrounded": false]) { $1 }]), "hung", "2.1.111")
        XCTAssertEqual(
            end("PostToolUseFailure", input: ["command": "sleep 9", "timeout": 2_000],
                ["error": "Exit code 143\nCommand timed out after 2s", "is_interrupt": false]),
            "hung", "headless: killed there"
        )
        XCTAssertEqual(end("PostToolUseFailure", ["error": "Exit code 143\nCommand timed out after 2s", "is_interrupt": true]), "interrupted")

        XCTAssertNil(end("PostToolUse", input: ["command": "npm run dev", "run_in_background": true], ["tool_response": moved]), "asked for")
        for reason in ["backgroundedByUser", "backgroundedToDeliverMessage", "backgroundedByTurnAbort", "assistantAutoBackgrounded"] {
            XCTAssertNil(end("PostToolUse", ["tool_response": moved.merging([reason: true]) { $1 }]), reason)
        }
        XCTAssertNil(end("PostToolUse", tool: "Agent", input: ["description": "review"], ["tool_response": moved]), "not a command")
        XCTAssertEqual(
            end("PostToolUseFailure", tool: "WebFetch", input: ["url": "https://example.test"], ["error": "Command timed out after 2s"]),
            "failed", "not a command"
        )
    }

    func testCommandsAreNamedByTheProgramTheyRun() {
        let names: [(command: String, name: String?)] = [
            ("swift build", "swift build"),
            ("cd /Users/me/proj && swift build 2>&1 | tail -20", "swift build"),
            ("cd x 2>&1 && swift test --filter Foo", "swift test"),
            ("FOO=1 BAR=2 timeout -k 5 120 swift build -c release", "swift build"),
            ("env -u NAME node build.js", "node"),
            ("git -C /tmp/repo status --short", "git status"),
            ("git -c user.name=x commit -m 'a; b && c'", "git commit"),
            ("sleep 60; gh run view 99 --json status", "gh run view"),
            ("gh -R owner/repo pr checks 3 --watch", "gh pr checks"),
            ("gh api repos/x/y", "gh api"),
            ("/usr/bin/python3 - <<'EOF'\nimport os\nprint(1); x = 2\nEOF", "python3"),
            ("echo \"a; rm -rf x\" && npm --prefix web run build", "npm run"),
            ("echo x &> /dev/null; cargo +nightly test", "cargo test"),
            ("(cd sub && make -j8 test)", "make test"),
            ("./scripts/run-tests.sh Foo", "run-tests.sh"),
            ("swift script.swift arg", "swift"),
            ("! grep -q x file", "grep"),
            ("mkdir -p out && echo hi", "mkdir"),
            ("for f in *.swift; do swiftc $f; done", nil),
            ("\"$NIRUX_CLI_PATH\" --mission ask --message hi", nil),
            ("FOO=bar", nil),
            ("", nil)
        ]
        for (command, name) in names {
            XCTAssertEqual(AgentToolOutcome.family(ofCommand: command), name, command)
        }
    }

    // MARK: - What a turn's calls add up to

    private var machine = AgentStatusMachine()
    private var clock: TimeInterval = 1_000

    private func send(
        _ name: AgentHookEvent.Name, tool: String? = nil, end: AgentToolEnd? = nil, family: String? = nil,
        agent: String? = nil, source: String? = nil
    ) {
        clock += 1
        _ = machine.apply(AgentHookEvent(
            kind: .claude, name: name, sessionID: "s", source: source, toolName: tool, toolEnd: end?.rawValue,
            toolFamily: family, agentID: agent, timestamp: clock
        ), isUserFocused: false)
    }

    private func startTurn() {
        send(.sessionStart, source: "startup")
        send(.userPromptSubmit)
    }

    /// A shell command by its program; another tool by its name.
    private func call(_ what: String, _ end: AgentToolEnd? = nil, agent: String? = nil) {
        let isTool = what.first?.isUppercase == true
        send(.postToolUse, tool: isTool ? what : "Bash", end: end, family: isTool ? nil : what, agent: agent)
    }

    /// The one stuck agent of the month measured: `ls`, `stat` and `test`
    /// hung on a dead path, and it stopped each of them.
    func testThreeHungCommandsInATurnSayTheAgentMayBeStuck() {
        startTurn()
        for command in ["ls", "ls"] {
            call(command, .hung)
            call("TaskOutput")
            call("TaskStop")
        }
        XCTAssertNil(machine.circlingHint, "two happen in ordinary turns")
        call("stat", .hung)
        XCTAssertEqual(machine.circlingHint, .hung(count: 3))
        call("TaskStop")
        call("stat", .hung)
        XCTAssertEqual(machine.circlingHint, .hung(count: 4))

        for _ in 1..<AgentCirclingWatch.callsThatClearHangs { call("grep") }
        XCTAssertEqual(machine.circlingHint, .hung(count: 4), "still close")
        call("grep")
        XCTAssertNil(machine.circlingHint, "it got past them")
        for _ in 1...2 { call("ls", .hung) }
        XCTAssertNil(machine.circlingHint, "later ones count from zero")
    }

    func testFiveFailuresInARowOfOneCommandSayItGoesInCircles() {
        startTurn()
        for _ in 1...4 {
            call("Edit")
            call("swift build", .failed)
        }
        XCTAssertNil(machine.circlingHint)
        call("swift test")
        call("swift build", .interrupted)
        call("swift build", .hung)
        XCTAssertNil(machine.circlingHint, "Esc and a hung run aren't failures")
        call("swift build", .failed)
        XCTAssertEqual(machine.circlingHint, .failing(what: "swift build", count: 5), "nor do they, or another command passing, end the row")
        call("swift build", .failed)
        XCTAssertEqual(machine.circlingHint, .failing(what: "swift build", count: 6))
        call("swift build")
        XCTAssertNil(machine.circlingHint, "it passed")

        for _ in 1...5 { call("Edit", .failed) }
        XCTAssertEqual(machine.circlingHint, .failing(what: "Edit", count: 5), "any tool")
    }

    func testOnlyTheMainAgentsCallsOfTheTurnCount() {
        startTurn()
        for _ in 1...3 { call("ls", .hung, agent: "sub") }
        for _ in 1...5 { call("swift build", .failed, agent: "sub") }
        XCTAssertNil(machine.circlingHint, "a subagent's say nothing of the task's agent")

        for _ in 1...3 { call("ls", .hung) }
        for _ in 1...5 { call("swift build", .failed) }
        XCTAssertNotNil(machine.circlingHint)
        send(.userPromptSubmit, agent: "sub")
        send(.sessionStart, source: "compact")
        XCTAssertNotNil(machine.circlingHint, "the turn goes on")
        send(.userPromptSubmit)
        XCTAssertNil(machine.circlingHint, "a new turn")

        for _ in 1...3 { call("ls", .hung) }
        send(.stop)
        XCTAssertNil(machine.circlingHint, "the turn is over")
        for _ in 1...2 { call("ls", .hung) }
        XCTAssertNil(machine.circlingHint, "what Claude goes on with by itself counts from zero")

        // A claude that dies mid-turn sends no Stop: its calls aren't those
        // of the agent that works in the column next.
        call("ls", .hung)
        _ = machine.tick(fgName: "claude", isUserFocused: false, now: Date(timeIntervalSince1970: clock))
        XCTAssertEqual(machine.circlingHint, .hung(count: 3))
        _ = machine.tick(fgName: "codex", isUserFocused: false, now: Date(timeIntervalSince1970: clock + 1))
        XCTAssertNil(machine.circlingHint)
    }

    func testTheLastOfHangingAndFailingIsShown() {
        startTurn()
        for _ in 1...5 { call("npm publish", .failed) }
        for _ in 1...3 { call("ls", .hung) }
        XCTAssertEqual(machine.circlingHint, .hung(count: 3))
        call("npm publish", .failed)
        XCTAssertEqual(machine.circlingHint, .failing(what: "npm publish", count: 6))
    }

    /// Memory stays bounded through a turn of hundreds of commands.
    func testTheCommandThatFailedLongestAgoIsForgotten() {
        var watch = AgentCirclingWatch()
        for index in 0...AgentCirclingWatch.maxStreaks {
            watch.noteCallEnded(what: "cmd\(index)", end: .failed, at: TimeInterval(index))
        }
        for step in 1..<AgentCirclingWatch.failureThreshold {
            watch.noteCallEnded(what: "cmd\(AgentCirclingWatch.maxStreaks)", end: .failed, at: 100 + TimeInterval(step))
            watch.noteCallEnded(what: "cmd0", end: .failed, at: 200 + TimeInterval(step))
        }
        XCTAssertEqual(
            watch.hint, .failing(what: "cmd\(AgentCirclingWatch.maxStreaks)", count: AgentCirclingWatch.failureThreshold),
            "the first one, which failed last, started again from one"
        )
    }

    // MARK: - What the row shows

    func testTheHintNamesWhatFailed() {
        XCTAssertEqual(AgentCirclingHint.hung(count: 3).statusText, "May be stuck · 3 commands hung")
        XCTAssertEqual(
            AgentCirclingHint.failing(what: "swift build", count: 6).statusText, "May be going in circles · swift build failed 6 times"
        )
        XCTAssertEqual(
            AgentCirclingHint.failing(what: "Bash", count: 5).statusText, "May be going in circles · 5 commands failed",
            "commands nothing names"
        )
        XCTAssertEqual(
            AgentCirclingHint.failing(what: "mcp__claude-in-chrome__computer", count: 5).statusText,
            "May be going in circles · computer failed 5 times"
        )
    }

    private func column(_ index: Int, _ status: AgentStatus, circling: AgentCirclingHint? = nil) -> ColumnInfo {
        ColumnInfo(
            index: index, processName: "claude", abbreviatedCwd: "~/app", isFocused: false, isWebView: false,
            webTitle: nil, terminalTitle: nil, agentStatus: status, isEditor: false, editorFileName: nil,
            agentElapsedSeconds: status == .working ? 1_380 : nil,
            attentionReason: status == .needsAttention ? .question("Which?") : nil, circling: circling
        )
    }

    @MainActor
    private func workspace(_ columns: [ColumnInfo]) -> WorkspaceInfo {
        WorkspaceInfo(
            id: "ws", index: 4, title: "Fix login", profileID: WorkspaceProfile.defaultID, isInactive: false,
            columnCount: columns.count, focusedColumn: 0, gitBranch: "fix/login", notification: nil, isActive: false,
            columns: columns, prInfo: nil, diffStats: nil, purpose: nil, nextStep: nil, blocker: nil, phase: .active,
            lastSummary: nil, lastActivityAt: nil
        )
    }

    /// Grey like "Working", whose place it takes: amber is for an agent
    /// that waits on the user, and this one doesn't.
    @MainActor
    func testTheRowSaysItInGreyInPlaceOfWorking() throws {
        let hint = AgentCirclingHint.failing(what: "swift build", count: 5)
        let circling = workspace([column(0, .working), column(1, .working, circling: hint)])
        XCTAssertEqual(circling.rowSummary.status, SidebarStatusLine(text: hint.statusText, tone: .neutral, detail: hint.detail))
        XCTAssertEqual(circling.rowSummary.mark, .working)
        XCTAssertEqual(circling.rowSummary.trailing, .turn("23m"), "how long the turn has run, as for Working")
        XCTAssertEqual(circling.cardState, .working)
        XCTAssertNil(circling.attention, "nothing alerts")

        let result = SidebarWorkspaceCardRenderer(workspace: circling, sidebarWidth: 260, yOffset: 500).render()
        let line = try XCTUnwrap(result.views.compactMap { $0 as? NSTextField }.first { $0.stringValue == hint.statusText })
        XCTAssertEqual(line.attributedStringValue.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, Theme.Color.textSecondary)
        XCTAssertEqual(line.toolTip, "\(hint.statusText)\nIn this turn, swift build failed 5 times in a row. The agent goes on: Nirux only tells you.")
        XCTAssertEqual(AgentCirclingHint.hung(count: 3).detail, "3 commands of this turn ran past their time limit. The agent goes on: Nirux only tells you.")

        XCTAssertEqual(
            workspace([column(0, .needsAttention), column(1, .working, circling: hint)]).rowSummary.status.text, "Needs you · Which?",
            "what waits on the user comes first"
        )
        XCTAssertEqual(workspace([column(0, .idle, circling: hint)]).rowSummary.status.text, "fix/login", "only while it works")
    }
}
