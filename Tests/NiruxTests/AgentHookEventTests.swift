import XCTest
@testable import Nirux

final class AgentHookEventTests: XCTestCase {
    private let env = ["NIRUX_AGENT_UUID": "uuid-1", "NIRUX_WORKSPACE_ID": "ws-1"]

    func testClaudePreToolUse() {
        let payload: [String: Any] = [
            "hook_event_name": "PreToolUse",
            "session_id": "sess-42",
            "cwd": "/tmp/proj",
            "tool_name": "Bash"
        ]
        let event = AgentHookEvent(kind: .claude, payload: payload, env: env, now: 1000)
        XCTAssertEqual(event?.name, .preToolUse)
        XCTAssertEqual(event?.kind, .claude)
        XCTAssertEqual(event?.agentUUID, "uuid-1")
        XCTAssertEqual(event?.workspaceID, "ws-1")
        XCTAssertEqual(event?.sessionID, "sess-42")
        XCTAssertEqual(event?.cwd, "/tmp/proj")
        XCTAssertEqual(event?.detail, "Bash")
        XCTAssertEqual(event?.timestamp, 1000)
    }

    func testClaudeLifecycleEvents() {
        let cases: [(String, AgentHookEvent.Name)] = [
            ("SessionStart", .sessionStart),
            ("UserPromptSubmit", .userPromptSubmit),
            ("Notification", .notification),
            ("Stop", .stop),
            ("SessionEnd", .sessionEnd)
        ]
        for (hookName, expected) in cases {
            let payload: [String: Any] = ["hook_event_name": hookName, "session_id": "s", "cwd": "/x"]
            let event = AgentHookEvent(kind: .claude, payload: payload, env: env, now: 1)
            XCTAssertEqual(event?.name, expected, hookName)
        }
    }

    func testClaudeNotificationMessageCaptured() {
        let payload: [String: Any] = [
            "hook_event_name": "Notification",
            "message": "Claude needs your permission to use Bash"
        ]
        let event = AgentHookEvent(kind: .claude, payload: payload, env: env, now: 1)
        XCTAssertEqual(event?.detail, "Claude needs your permission to use Bash")
    }

    func testUnknownClaudeHookIgnored() {
        let payload: [String: Any] = ["hook_event_name": "PreCompact", "session_id": "s"]
        XCTAssertNil(AgentHookEvent(kind: .claude, payload: payload, env: env, now: 1))
        XCTAssertNil(AgentHookEvent(kind: .claude, payload: ["nope": 1], env: env, now: 1))
    }

    // MARK: - Permission, tool and notification details

    private func claudeEvent(_ payload: [String: Any], env: [String: String]? = nil) -> AgentHookEvent? {
        AgentHookEvent(kind: .claude, payload: payload, env: env ?? self.env, now: 7)
    }

    func testPermissionRequestCapturesCleanExcerptAndCallKey() throws {
        let command = "git push origin main\n\u{1B}[31mrm -rf build\u{202E}"
        let request = try XCTUnwrap(claudeEvent([
            "hook_event_name": "PermissionRequest",
            "session_id": "s",
            "tool_name": "Bash",
            "tool_input": ["command": command, "description": "Push"],
            "agent_id": "sub-1"
        ]))
        XCTAssertEqual(request.name, .permissionRequest)
        XCTAssertEqual(request.toolName, "Bash")
        XCTAssertEqual(request.detail, "Bash")
        XCTAssertEqual(request.toolSummary, "git push origin main [31mrm -rf build")
        XCTAssertEqual(request.agentID, "sub-1")

        // The call's PostToolUse carries the same input (in any key order).
        let done = try XCTUnwrap(claudeEvent([
            "hook_event_name": "PostToolUse",
            "tool_name": "Bash",
            "tool_input": ["description": "Push", "command": command],
            "tool_response": ["stdout": "ok"],
            "tool_use_id": "toolu_1",
            "agent_id": "sub-1"
        ]))
        XCTAssertEqual(done.name, .postToolUse)
        XCTAssertEqual(done.toolKey, request.toolKey)
        let other = try XCTUnwrap(claudeEvent([
            "hook_event_name": "PostToolUseFailure",
            "tool_name": "Bash",
            "tool_input": ["command": "git push origin main"],
            "error": "Exit code 1"
        ]))
        XCTAssertEqual(other.name, .postToolUse, "a failed call is over too")
        XCTAssertNotEqual(other.toolKey, request.toolKey)
    }

    func testPreToolUseCarriesNoInputExcerpt() throws {
        let event = try XCTUnwrap(claudeEvent([
            "hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_input": ["command": "ls"]
        ]))
        XCTAssertEqual(event.toolName, "Bash")
        XCTAssertNil(event.toolSummary)
        XCTAssertNil(event.toolKey)
    }

    func testFileToolExcerptDropsProjectAndHomePrefixes() {
        let env = self.env.merging(["HOME": "/Users/me"]) { $1 }
        let inProject = claudeEvent([
            "hook_event_name": "PermissionRequest", "cwd": "/Users/me/proj",
            "tool_name": "Edit", "tool_input": ["file_path": "/Users/me/proj/Sources/App.swift"]
        ], env: env)
        XCTAssertEqual(inProject?.toolSummary, "Sources/App.swift")
        let inHome = claudeEvent([
            "hook_event_name": "PermissionRequest", "cwd": "/Users/me/proj",
            "tool_name": "Write", "tool_input": ["file_path": "/Users/me/.zshrc"]
        ], env: env)
        XCTAssertEqual(inHome?.toolSummary, "~/.zshrc")
    }

    func testAskUserQuestionExcerptIsTheQuestion() {
        let event = claudeEvent([
            "hook_event_name": "PermissionRequest",
            "tool_name": "AskUserQuestion",
            "tool_input": ["questions": [["question": "Which database?", "header": "DB", "options": []]]]
        ])
        XCTAssertEqual(event?.toolSummary, "Which database?")
    }

    func testLongInputIsBoundedAndNeverStored() throws {
        let content = String(repeating: "secret ", count: 50_000)
        let event = try XCTUnwrap(claudeEvent([
            "hook_event_name": "PermissionRequest",
            "tool_name": "Bash",
            "tool_input": ["command": content]
        ]))
        XCTAssertLessThanOrEqual(try XCTUnwrap(event.toolSummary).count, AgentToolInput.maxSummaryLength)
        XCTAssertTrue(try XCTUnwrap(event.toolSummary).hasSuffix("…"))
        let line = try JSONEncoder().encode(event)
        XCTAssertLessThan(line.count, 1_000, "the queue line holds an excerpt, not the input")
    }

    /// Two Greps for one pattern in different places are different calls:
    /// one finishing must not clear the other's dialog.
    func testCallKeyReadsTheWholeInput() {
        let etc = AgentToolInput.key(toolName: "Grep", input: ["pattern": "TODO", "path": "/etc"])
        let src = AgentToolInput.key(toolName: "Grep", input: ["pattern": "TODO", "path": "./src"])
        XCTAssertNotEqual(etc, src)
        // Answering rewrites these inputs: the question, or the name alone.
        let asked = AgentToolInput.key(toolName: "AskUserQuestion", input: ["questions": [["question": "DB?"]]])
        let answered = AgentToolInput.key(
            toolName: "AskUserQuestion", input: ["questions": [["question": "DB?"]], "answers": ["DB?": "Postgres"]]
        )
        XCTAssertEqual(asked, answered)
        XCTAssertEqual(
            AgentToolInput.key(toolName: "ExitPlanMode", input: ["plan": "v1"]),
            AgentToolInput.key(toolName: "ExitPlanMode", input: ["plan": "v2, edited"])
        )
    }

    /// Runs inside a sync hook: a long command followed by a sea of
    /// whitespace must not cost a recount per scalar.
    func testCleanIsLinearOnHugeWhitespace() {
        let input = String(repeating: "x", count: 600) + String(repeating: " ", count: 500_000) + "y"
        let start = Date()
        XCTAssertEqual(AgentText.clean(input, maxLength: 160), String(repeating: "x", count: 159) + "…")
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
    }

    func testMCPToolKeyIgnoresKeyOrder() {
        let first = AgentToolInput.key(toolName: "mcp__github__create_issue", input: ["title": "A", "body": "B"])
        let second = AgentToolInput.key(toolName: "mcp__github__create_issue", input: ["body": "B", "title": "A"])
        XCTAssertEqual(first, second)
        XCTAssertNotEqual(first, AgentToolInput.key(toolName: "mcp__github__create_issue", input: ["title": "C"]))
        XCTAssertNil(AgentToolInput.summary(toolName: "mcp__github__create_issue", input: ["title": "A"], cwd: nil, home: nil))
    }

    func testNotificationTypeAndCleanMessage() {
        let event = claudeEvent([
            "hook_event_name": "Notification",
            "notification_type": "permission_prompt",
            "message": "Claude needs\n\tyour permission\u{07}"
        ])
        XCTAssertEqual(event?.notificationType, "permission_prompt")
        XCTAssertEqual(event?.detail, "Claude needs your permission")
    }

    func testSubagentStopCarriesItsAgentID() {
        let event = claudeEvent(["hook_event_name": "SubagentStop", "agent_id": "sub-9", "agent_type": "Explore"])
        XCTAssertEqual(event?.name, .subagentStop)
        XCTAssertEqual(event?.agentID, "sub-9")
        XCTAssertNil(claudeEvent(["hook_event_name": "Stop", "agent_id": ""])?.agentID)
    }

    func testDetailedEventRoundTripsThroughJSONLine() throws {
        let event = try XCTUnwrap(claudeEvent([
            "hook_event_name": "PermissionRequest",
            "tool_name": "WebFetch",
            "tool_input": ["url": "https://example.com"],
            "agent_id": "sub-1"
        ]))
        let decoded = try JSONDecoder().decode(AgentHookEvent.self, from: JSONEncoder().encode(event))
        XCTAssertEqual(decoded, event)
        XCTAssertEqual(decoded.toolSummary, "https://example.com")
    }

    func testTurnLevelClaudeEventsCarryTheirTranscriptPath() throws {
        let path = "/Users/me/.claude/projects/-tmp-proj/5f0c8a52.jsonl"
        for hookName in ["SessionStart", "UserPromptSubmit", "Stop"] {
            XCTAssertEqual(claudeEvent(["hook_event_name": hookName, "transcript_path": path])?.transcriptPath, path, hookName)
        }
        for hookName in ["PreToolUse", "PostToolUse", "Notification", "SessionEnd", "SubagentStop"] {
            XCTAssertNil(claudeEvent(["hook_event_name": hookName, "transcript_path": path])?.transcriptPath, hookName)
        }
        for invalid in ["relative/session.jsonl", "/tmp/session.json", "/etc/passwd\u{0}.jsonl", ""] {
            XCTAssertNil(claudeEvent(["hook_event_name": "Stop", "transcript_path": invalid])?.transcriptPath, invalid)
        }
        XCTAssertNil(claudeEvent(["hook_event_name": "Stop", "transcript_path": 42])?.transcriptPath)

        let event = try XCTUnwrap(claudeEvent(["hook_event_name": "SessionStart", "transcript_path": path]))
        let decoded = try JSONDecoder().decode(AgentHookEvent.self, from: JSONEncoder().encode(event))
        XCTAssertEqual(decoded.transcriptPath, path)
        // Lines queued by older builds have no transcript path.
        let legacy = try JSONDecoder().decode(
            AgentHookEvent.self,
            from: Data(#"{"kind":"claude","name":"stop","sessionID":"s","timestamp":1}"#.utf8)
        )
        XCTAssertNil(legacy.transcriptPath)
    }

    /// `claude -p` answers PermissionRequest itself (a denial) — no dialog.
    func testHeadlessClaudeDetection() {
        let instance = ProcessInstance(pid: 1, startedAt: 1)
        let headless = ForegroundProcess(instance: instance, name: "claude", arguments: ["claude", "-p", "fix it"])
        let print = ForegroundProcess(instance: instance, name: "claude", arguments: ["claude", "--print"])
        let interactive = ForegroundProcess(instance: instance, name: "claude", arguments: ["claude", "--resume", "x"])
        let codex = ForegroundProcess(instance: instance, name: "codex", arguments: ["codex", "-p", "profile"])
        XCTAssertTrue(AgentHookCenter.isHeadlessClaude(headless))
        XCTAssertTrue(AgentHookCenter.isHeadlessClaude(print))
        XCTAssertFalse(AgentHookCenter.isHeadlessClaude(interactive))
        XCTAssertFalse(AgentHookCenter.isHeadlessClaude(codex))
        XCTAssertFalse(AgentHookCenter.isHeadlessClaude(nil))
    }

    // MARK: - AgentText

    func testCleanStripsControlAndInvisibleFormatting() {
        XCTAssertEqual(AgentText.clean("a\u{1B}]0;title\u{07}b", maxLength: 50), "a]0;titleb")
        XCTAssertEqual(AgentText.clean("safe\u{202E}txt.exe\u{200B}", maxLength: 50), "safetxt.exe")
        XCTAssertEqual(AgentText.clean("  line one\r\n\n line\u{2028}two  ", maxLength: 50), "line one line two")
        XCTAssertEqual(AgentText.clean("👩\u{200D}💻 ok", maxLength: 50), "👩\u{200D}💻 ok", "ZWJ sequences survive")
        XCTAssertNil(AgentText.clean("\u{1B}\u{07} \n", maxLength: 50))
        XCTAssertNil(AgentText.clean("text", maxLength: 0))
    }

    func testCleanTruncatesWithEllipsis() {
        XCTAssertEqual(AgentText.clean("abcdef", maxLength: 6), "abcdef")
        XCTAssertEqual(AgentText.clean("abcdefg", maxLength: 6), "abcde…")
        XCTAssertEqual(AgentText.clean(String(repeating: "x", count: 100_000), maxLength: 10)?.count, 10)
    }

    func testCodexTurnComplete() {
        let emitter = ProcessInstance(pid: 321, startedAt: 4)
        let payload: [String: Any] = [
            "type": "agent-turn-complete",
            "thread-id": "thread-9",
            "cwd": "/tmp/proj",
            "last-assistant-message": "Done."
        ]
        let event = AgentHookEvent(
            kind: .codex,
            payload: payload,
            env: env,
            now: 5,
            emitterProcess: emitter
        )
        XCTAssertEqual(event?.name, .turnComplete)
        XCTAssertEqual(event?.sessionID, "thread-9")
        XCTAssertEqual(event?.detail, "Done.")
        XCTAssertEqual(event?.emitterProcess, emitter)
    }

    func testCodexLongMessageTruncated() {
        let payload: [String: Any] = [
            "type": "agent-turn-complete",
            "last-assistant-message": String(repeating: "x", count: 1000)
        ]
        let event = AgentHookEvent(kind: .codex, payload: payload, env: env, now: 5)
        XCTAssertEqual(event?.detail?.count, 500)
    }

    func testCodexUnknownTypeIgnored() {
        let payload: [String: Any] = ["type": "something-else"]
        XCTAssertNil(AgentHookEvent(kind: .codex, payload: payload, env: env, now: 1))
    }

    func testEventRoundTripsThroughJSONLine() throws {
        let payload: [String: Any] = [
            "hook_event_name": "Stop", "session_id": "s1", "cwd": "/p"
        ]
        let event = try XCTUnwrap(AgentHookEvent(kind: .claude, payload: payload, env: env, now: 42))
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(AgentHookEvent.self, from: data)
        XCTAssertEqual(event, decoded)
    }

    func testCodexEmitterRoundTripsThroughJSONLine() throws {
        let payload: [String: Any] = [
            "type": "agent-turn-complete", "thread-id": "thread-9"
        ]
        let event = try XCTUnwrap(AgentHookEvent(
            kind: .codex,
            payload: payload,
            env: env,
            now: 42,
            emitterProcess: ProcessInstance(pid: 321, startedAt: 40)
        ))

        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(AgentHookEvent.self, from: data)

        XCTAssertEqual(event, decoded)
    }

    func testClaudeSessionStartSourceCaptured() {
        let start: [String: Any] = [
            "hook_event_name": "SessionStart", "session_id": "s", "source": "compact"
        ]
        let stop: [String: Any] = [
            "hook_event_name": "Stop", "session_id": "s", "source": "compact"
        ]
        XCTAssertEqual(AgentHookEvent(kind: .claude, payload: start, env: env, now: 1)?.source, "compact")
        XCTAssertNil(AgentHookEvent(kind: .claude, payload: stop, env: env, now: 1)?.source)
    }

    func testClaudeEmitterAndSourceRoundTripThroughJSONLine() throws {
        let payload: [String: Any] = [
            "hook_event_name": "SessionStart", "session_id": "s1", "source": "resume"
        ]
        let event = try XCTUnwrap(AgentHookEvent(
            kind: .claude,
            payload: payload,
            env: env,
            now: 42,
            // Admission compares this exactly after the JSON round trip.
            emitterProcess: ProcessInstance(pid: 7302, startedAt: 1_790_454_481.825692)
        ))

        let decoded = try JSONDecoder().decode(AgentHookEvent.self, from: JSONEncoder().encode(event))

        XCTAssertEqual(event, decoded)
    }

    func testLegacyClaudeEventDecodesWithoutSourceOrEmitter() throws {
        let data = Data(#"{"kind":"claude","name":"sessionStart","sessionID":"s","timestamp":42}"#.utf8)

        let decoded = try JSONDecoder().decode(AgentHookEvent.self, from: data)

        XCTAssertEqual(decoded.sessionID, "s")
        XCTAssertNil(decoded.source)
        XCTAssertNil(decoded.emitterProcess)
    }

    func testLegacyCodexEventDecodesWithoutEmitter() throws {
        let data = Data(#"{"kind":"codex","name":"turnComplete","timestamp":42}"#.utf8)

        let decoded = try JSONDecoder().decode(AgentHookEvent.self, from: data)

        XCTAssertNil(decoded.emitterProcess)
    }

    func testReceiverOnlyAcceptsNiruxTerminals() {
        XCTAssertTrue(AgentHookCLI.isFromNiruxTerminal(env: env))
        XCTAssertFalse(AgentHookCLI.isFromNiruxTerminal(env: [:]), "agent outside Nirux")
        XCTAssertFalse(AgentHookCLI.isFromNiruxTerminal(env: ["NIRUX_AGENT_UUID": ""]))
        XCTAssertFalse(
            AgentHookCLI.isFromNiruxTerminal(env: ["NIRUX_WORKSPACE_ID": "ws-1"]),
            "the column UUID is what routes an event"
        )
    }
}
