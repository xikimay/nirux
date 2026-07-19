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
        let payload: [String: Any] = ["hook_event_name": "PostToolUse", "session_id": "s"]
        XCTAssertNil(AgentHookEvent(kind: .claude, payload: payload, env: env, now: 1))
        XCTAssertNil(AgentHookEvent(kind: .claude, payload: ["nope": 1], env: env, now: 1))
    }

    func testCodexTurnComplete() {
        let payload: [String: Any] = [
            "type": "agent-turn-complete",
            "thread-id": "thread-9",
            "cwd": "/tmp/proj",
            "last-assistant-message": "Done."
        ]
        let event = AgentHookEvent(kind: .codex, payload: payload, env: env, now: 5)
        XCTAssertEqual(event?.name, .turnComplete)
        XCTAssertEqual(event?.sessionID, "thread-9")
        XCTAssertEqual(event?.detail, "Done.")
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
}
