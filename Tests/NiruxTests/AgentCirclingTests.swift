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

        // A command nothing names is told from another by its text alone:
        // a description or a time limit that changes between two tries
        // doesn't make it another command.
        let loop: [String: Any] = ["command": "for t in a b; do ./check $t || exit 1; done", "description": "Run the checks"]
        let again = loop.merging(["description": "Re-run the checks", "timeout": 60_000]) { $1 }
        let other = loop.merging(["command": "for t in a b c; do ./check $t || exit 1; done"]) { $1 }
        let first = toolEvent("PostToolUseFailure", input: loop, ["error": "Exit code 1"])
        XCTAssertNil(first?.toolFamily)
        XCTAssertNotNil(first?.toolCommandKey)
        XCTAssertEqual(first?.toolCommandKey, toolEvent("PostToolUseFailure", input: again, ["error": "Exit code 1"])?.toolCommandKey)
        XCTAssertNotEqual(first?.toolCommandKey, toolEvent("PostToolUseFailure", input: other, ["error": "Exit code 1"])?.toolCommandKey)
        XCTAssertNil(failed.toolCommandKey, "a named command counts with its program's")

        // (Not Edit's "String to replace not found": Claude refuses that
        // call before running it, and no hook fires.)
        let fetch = toolEvent("PostToolUseFailure", tool: "WebFetch", input: ["url": "https://example.test"], ["error": "Request failed with status code 503"])
        XCTAssertEqual(fetch?.toolEnd, "failed")
        XCTAssertNil(fetch?.toolFamily, "the tool's name stands for it")
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
        let killed = "Exit code 143\nCommand timed out after 2s"
        XCTAssertEqual(end("PostToolUseFailure", ["error": killed, "is_interrupt": false]), "hung", "headless: killed there")
        XCTAssertEqual(end("PostToolUseFailure", ["error": "Exit code 1", "is_timeout": true]), "hung", "should Claude say so itself")
        XCTAssertEqual(end("PostToolUseFailure", ["error": killed, "is_interrupt": true]), "interrupted", "Esc is the user's")
        XCTAssertEqual(
            end("PostToolUseFailure", ["error": "Exit code 1\nXCTAssertEqual failed: (\"\(killed)\")"]), "failed",
            "the words in the command's own output: a test log, a grep of the code that reads them"
        )

        XCTAssertNil(end("PostToolUse", input: ["command": "npm run dev", "run_in_background": true], ["tool_response": moved]), "asked for")
        let reasons = ["backgroundedByUser", "backgroundedToDeliverMessage", "backgroundedByTurnAbort", "assistantAutoBackgrounded"]
        for reason in reasons + ["backgroundedForAReasonALaterClaudeAdds"] {
            XCTAssertNil(end("PostToolUse", ["tool_response": moved.merging([reason: true]) { $1 }]), reason)
        }
        XCTAssertNil(end("PostToolUse", tool: "Agent", input: ["description": "review"], ["tool_response": moved]), "not a command")
        XCTAssertEqual(end("PostToolUseFailure", tool: "WebFetch", input: ["url": "https://example.test"], ["error": killed]), "failed", "not a command")
    }

    /// Waiting for CI or a server repeats a command that "fails" until
    /// there is something, and a long sleep outlasts its time limit on
    /// purpose: not an agent going in circles.
    func testACommandThatWaitsNeitherFailsNorHangs() {
        let waits = [
            "sleep 60; gh run view 99 --json status", "echo waiting; sleep 30; gh pr view 3", "cd repo && \\\n  gh pr checks 412",
            "git push && gh pr checks 412 --watch", "gh run watch 5 --exit-status", "until curl -sf localhost:3000; do sleep 2; done",
            "\"$NIRUX_CLI_PATH\" --mission tell --to web --message \"rebase on main\"",
            "for i in 1 2 3; do\n  curl -sf :3000 && break\n  sleep 2\ndone"
        ]
        let moved: [String: Any] = ["stdout": "", "interrupted": false, "backgroundTaskId": "b12", "timedOutAfterMs": 120_000]
        for command in waits {
            XCTAssertTrue(AgentShellCommand(command).isWait, command)
            XCTAssertEqual(toolEvent("PostToolUseFailure", input: ["command": command], ["error": "Exit code 8"])?.toolEnd, "waited", command)
            let killed = toolEvent("PostToolUseFailure", input: ["command": command], ["error": "Exit code 143\nCommand timed out after 2m 0s"])
            XCTAssertEqual(killed?.toolEnd, "waited", command)
            XCTAssertEqual(toolEvent("PostToolUse", input: ["command": command], ["tool_response": moved])?.toolEnd, "waited", command)
            XCTAssertNil(toolEvent("PostToolUse", input: ["command": command], ["tool_response": ["stdout": "ok"]])?.toolEnd, command)
        }
        // A sleep somewhere in a command, or written into a file, doesn't
        // make it a wait: restarting a server and probing it is an attempt.
        let attempts = [
            "swift build", "gh pr view 3", "gh run view 99", "echo 'sleep 5' > run.sh", "timeout 120 swift test",
            "./start.sh & sleep 3; curl -sf :3000/health", "cat > run.sh <<'EOF'\nsleep 5\n./run\nEOF\nbash run.sh",
            "pkill -f Nirux; sleep 1; swift run 2>&1 | tail -20"
        ]
        for command in attempts {
            XCTAssertFalse(AgentShellCommand(command).isWait, command)
            XCTAssertEqual(toolEvent("PostToolUseFailure", input: ["command": command], ["error": "Exit code 1"])?.toolEnd, "failed", command)
        }
    }

    func testCommandsAreNamedByTheProgramTheyRun() {
        let names: [(command: String, name: String?)] = [
            ("swift build", "swift build"),
            ("cd /Users/me/proj && swift build 2>&1 | tail -20", "swift build"),
            ("cd x 2>&1 && swift test --filter Foo", "swift test"),
            ("FOO=1 BAR=2 timeout -k 5 120 swift build -c release", "swift build"),
            ("MSG=\"hello world\" VERSION=$(git describe --tags) swift build", "swift build"),
            ("env -u NAME node build.js", "node"),
            ("timeout 10 7z x a.7z", "7z"),
            ("git -C /tmp/repo status --short", "git status"),
            ("git -c user.name=x commit -m 'a; b && c'", "git commit"),
            ("git add -A && git commit -m x && git push", "git commit"),
            ("git add -A", "git add"),
            ("git --no-pager log -3", "git log"),
            ("git push && gh pr checks 412 --watch", "git push"),
            ("cd repo && \\\n  gh pr checks 412", "gh pr checks"),
            ("sleep 60; gh run view 99 --json status", "gh run view"),
            ("gh -R owner/repo pr checks 3 --watch", "gh pr checks"),
            ("gh api repos/x/y", "gh api"),
            ("# build the app; then test it\nswift build # quick", "swift build"),
            ("/usr/bin/python3 - <<'EOF'\nimport os\nprint(1); x = 2\nEOF", "python3"),
            ("echo \"a; rm -rf x\" && npm --prefix web run build", "npm run build"),
            ("npm run test:unit -- --watch", "npm run test:unit"),
            ("docker compose -f a.yml up -d", "docker compose up"),
            // An option nobody listed may take the next word as its value.
            ("kubectl --token abc123def456 get pods", "kubectl"),
            ("echo x &> /dev/null; cargo +nightly test", "cargo test"),
            ("pkill -f Nirux; rm -rf out; swift run", "swift run"),
            ("cd /repo || exit 1; swift build", "swift build"),
            ("(cd sub && make -j8 test)", "make test"),
            ("{ \"/usr/local/bin/gh\" pr checks 3; }", "gh pr checks"),
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
            XCTAssertEqual(AgentShellCommand(command).family, name, command)
        }
    }

    // MARK: - What a turn's calls add up to

    private var machine = AgentStatusMachine()
    private var clock: TimeInterval = 1_000

    private func send(
        _ name: AgentHookEvent.Name, tool: String? = nil, key: String? = nil, end: String? = nil, family: String? = nil,
        agent: String? = nil, source: String? = nil
    ) {
        clock += 1
        _ = machine.apply(AgentHookEvent(
            kind: .claude, name: name, sessionID: "s", source: source, toolName: tool, toolEnd: end,
            toolFamily: family, toolCommandKey: key, agentID: agent, timestamp: clock
        ), isUserFocused: false)
    }

    private func startTurn() {
        send(.sessionStart, source: "startup")
        send(.userPromptSubmit)
    }

    /// A shell command by its program; another tool by its name.
    private func call(_ what: String, _ end: AgentToolEnd? = nil, agent: String? = nil) {
        let isTool = what.first?.isUppercase == true
        send(.postToolUse, tool: isTool ? what : "Bash", end: end?.rawValue, family: isTool ? nil : what, agent: agent)
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

        for _ in 1..<AgentCirclingWatch.callsThatClearHangs {
            call("grep")
            call("sleep", .waited)
        }
        XCTAssertEqual(machine.circlingHint, .hung(count: 4), "still close: polls aren't calls that got past them")
        call("grep")
        XCTAssertNil(machine.circlingHint, "it moved on")
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
        call("swift build", .failed)
        XCTAssertEqual(machine.circlingHint, .failing(name: "swift build", count: 5), "other commands between, passing or not")
        call("swift build", .failed)
        XCTAssertEqual(machine.circlingHint, .failing(name: "swift build", count: 6))
        call("swift build")
        XCTAssertNil(machine.circlingHint, "it passed")

        for _ in 1...5 { call("WebFetch", .failed) }
        XCTAssertEqual(machine.circlingHint, .failing(name: "WebFetch", count: 5), "any tool")
    }

    /// Esc, a run past its limit, a wait, and an end only a newer receiver
    /// knows are neither a failure nor a pass.
    func testWhatIsNeitherAFailureNorAPassLeavesTheRowAsItIs() {
        startTurn()
        for neutral in ["interrupted", "hung", "waited", "an end a newer receiver wrote"] {
            send(.userPromptSubmit)
            for _ in 1...4 { call("swift build", .failed) }
            send(.postToolUse, tool: "Bash", end: neutral, family: "swift build")
            XCTAssertNil(machine.circlingHint, "\(neutral) is no failure")
            call("swift build", .failed)
            XCTAssertEqual(machine.circlingHint, .failing(name: "swift build", count: 5), "\(neutral) is no pass")
        }
    }

    /// A loop the agent left no longer shows; one that takes many calls
    /// between two tries (reads, edits) still adds up.
    func testTheHintGoesOnceTheAgentMovedOnAndComesBackWithTheNextFailure() {
        startTurn()
        for _ in 1...5 { call("gh pr merge", .failed) }
        for _ in 1..<AgentCirclingWatch.callsThatHideFailures { call("grep") }
        XCTAssertEqual(machine.circlingHint, .failing(name: "gh pr merge", count: 5))
        call("grep")
        XCTAssertNil(machine.circlingHint, "it moved on")
        call("gh pr merge", .failed)
        XCTAssertEqual(machine.circlingHint, .failing(name: "gh pr merge", count: 6), "it didn't")

        send(.userPromptSubmit)
        for round in 1...5 {
            for _ in 1...(AgentCirclingWatch.callsThatHideFailures + 5) { call("Read") }
            call("swift test", .failed)
            XCTAssertEqual(machine.circlingHint, round < 5 ? nil : .failing(name: "swift test", count: 5), "round \(round)")
        }

        // A check that answers "no" by failing, run now and then through a
        // long turn, isn't a row of failures.
        send(.userPromptSubmit)
        for check in 1...5 {
            call("pgrep", .failed)
            XCTAssertNil(machine.circlingHint, "check \(check)")
            for _ in 1...AgentCirclingWatch.callsThatEndFailures { call("Read") }
        }
    }

    /// Memory stays bounded through a turn of hundreds of failing commands.
    func testTheCommandThatFailedLongestAgoIsForgotten() {
        var watch = AgentCirclingWatch()
        let last = "cmd\(AgentCirclingWatch.maxStreaks)"
        for index in 0...AgentCirclingWatch.maxStreaks {
            watch.noteCallEnded(key: "cmd\(index)", name: "cmd\(index)", end: .failed, at: TimeInterval(index))
        }
        for step in 1..<AgentCirclingWatch.failureThreshold {
            watch.noteCallEnded(key: last, name: last, end: .failed, at: 100 + TimeInterval(step))
            watch.noteCallEnded(key: "cmd0", name: "cmd0", end: .failed, at: 200 + TimeInterval(step))
        }
        XCTAssertEqual(
            watch.hint, .failing(name: last, count: AgentCirclingWatch.failureThreshold),
            "the first one, which failed last, started again from one"
        )
    }

    /// A command nothing names counts only with its exact repeats.
    func testACommandNothingNamesCountsWithItsExactRepeats() {
        startTurn()
        for index in 1...6 { send(.postToolUse, tool: "Bash", key: "loop-\(index)", end: "failed") }
        XCTAssertNil(machine.circlingHint, "six different loops that failed")
        for _ in 1...5 { send(.postToolUse, tool: "Bash", key: "same", end: "failed") }
        XCTAssertEqual(machine.circlingHint, .failing(name: nil, count: 5))
        send(.postToolUse, tool: "Bash", key: "another")
        XCTAssertEqual(machine.circlingHint, .failing(name: nil, count: 5), "another one passing says nothing of it")
        send(.postToolUse, tool: "Bash", key: "same")
        XCTAssertNil(machine.circlingHint)
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
        _ = machine.tick(fgName: "zsh", isUserFocused: false, now: Date(timeIntervalSince1970: clock + 1))
        XCTAssertEqual(machine.circlingHint, .hung(count: 3), "a suspended claude's turn goes on (^Z, Ctrl-G's editor)")
        _ = machine.tick(fgName: "codex", isUserFocused: false, now: Date(timeIntervalSince1970: clock + 2))
        XCTAssertNil(machine.circlingHint)

        for _ in 1...3 { call("ls", .hung) }
        machine.reset()
        XCTAssertNil(machine.circlingHint, "a new shell in the terminal")
    }

    func testTheLastOfHangingAndFailingIsShown() {
        startTurn()
        for _ in 1...5 { call("npm publish", .failed) }
        for _ in 1...3 { call("ls", .hung) }
        XCTAssertEqual(machine.circlingHint, .hung(count: 3))
        call("npm publish", .failed)
        XCTAssertEqual(machine.circlingHint, .failing(name: "npm publish", count: 6))
    }

    // MARK: - What the row shows

    private func column(_ index: Int, _ status: AgentStatus, minutes: Int = 23, circling: AgentCirclingHint? = nil) -> ColumnInfo {
        ColumnInfo(
            index: index, processName: "claude", abbreviatedCwd: "~/app", isFocused: false, isWebView: false,
            webTitle: nil, terminalTitle: nil, agentStatus: status, isEditor: false, editorFileName: nil,
            agentElapsedSeconds: status == .working ? TimeInterval(minutes * 60) : nil,
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
    /// that waits on the user, and this one doesn't. What failed and how
    /// often fits the row; the tooltip says the rest.
    @MainActor
    func testTheRowSaysItInGreyInPlaceOfWorking() throws {
        let hint = AgentCirclingHint.failing(name: "swift build", count: 5)
        XCTAssertEqual(hint.statusText, "Stuck? · swift build failed 5×")
        let circling = workspace([column(0, .working, minutes: 3), column(1, .working, minutes: 45, circling: hint)])
        XCTAssertEqual(circling.rowSummary.status, SidebarStatusLine(text: hint.statusText, tone: .neutral, detail: hint.detail))
        XCTAssertEqual(circling.rowSummary.mark, .working)
        XCTAssertEqual(circling.rowSummary.trailing, .turn("45m"), "how long that agent's turn has run, not the other one's")
        XCTAssertEqual(circling.rowSummary.focusColumn, 1, "a click on the row brings it up")
        XCTAssertEqual(circling.cardState, .working)
        XCTAssertNil(circling.attention, "nothing alerts")
        // The collapsed sidebar's tooltip says it too.
        XCTAssertEqual(circling.railTooltip, SidebarRailTooltip(
            title: "Fix login", detail: "2 agents working · 45m", detailColor: Theme.Color.working, note: hint.statusText
        ))
        XCTAssertNil(workspace([column(0, .working)]).railTooltip.note)
        XCTAssertNil(workspace([column(0, .working)]).rowSummary.focusColumn)

        @MainActor func line(_ hint: AgentCirclingHint, subtask: Bool = false) throws -> NSTextField {
            var info = workspace([column(0, .working, circling: hint)])
            if subtask { info.parentTitle = "Sign-in" }
            let result = SidebarWorkspaceCardRenderer(workspace: info, sidebarWidth: 260, yOffset: 500).render()
            return try XCTUnwrap(result.views.compactMap { $0 as? NSTextField }.first { $0.stringValue == hint.statusText })
        }
        let label = try line(hint)
        XCTAssertEqual(label.attributedStringValue.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, Theme.Color.textSecondary)
        XCTAssertEqual(label.toolTip, "\(hint.statusText)\nIn this turn, swift build failed 5 times in a row. The agent goes on: Nirux only tells you.")
        // In a sub-task's narrower row too, as its cell draws it.
        let shown: [AgentCirclingHint] = [
            hint, .hung(count: 3), .failing(name: nil, count: 5), .failing(name: "npm run build", count: 5),
            .failing(name: "mcp__claude-in-chrome__computer", count: 5)
        ]
        for (hint, subtask) in shown.flatMap({ [($0, false), ($0, true)] }) {
            let label = try line(hint, subtask: subtask)
            let needed = try XCTUnwrap(label.cell).cellSize(forBounds: NSRect(x: 0, y: 0, width: 10_000, height: label.frame.height)).width
            XCTAssertLessThanOrEqual(needed, label.frame.width, "\(hint.statusText) isn't cut\(subtask ? " in a sub-task's row" : "")")
        }
        XCTAssertLessThan(try line(hint, subtask: true).frame.width, label.frame.width)
        XCTAssertEqual(try line(.hung(count: 3)).toolTip, "Stuck? · 3 timeouts\n3 commands of this turn ran past their time limit, "
            + "close together. The agent goes on: Nirux only tells you.")
        XCTAssertEqual(AgentCirclingHint.failing(name: nil, count: 5).statusText, "Stuck? · a command failed 5×")
        XCTAssertEqual(AgentCirclingHint.failing(name: "mcp__claude-in-chrome__computer", count: 5).statusText, "Stuck? · computer failed 5×")

        XCTAssertEqual(
            workspace([column(0, .needsAttention), column(1, .working, circling: hint)]).rowSummary.status.text, "Needs you · Which?",
            "what waits on the user comes first"
        )
        XCTAssertEqual(workspace([column(0, .idle, circling: hint)]).rowSummary.status.text, "fix/login", "only while it works")
    }
}
