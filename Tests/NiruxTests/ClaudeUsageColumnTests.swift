import XCTest
@testable import Nirux

/// Which transcript a column follows, and how its title bar shows it.
@MainActor
final class ClaudeUsageColumnTests: XCTestCase {
    private let claude = ForegroundProcess(
        instance: ProcessInstance(pid: 700, startedAt: 70),
        name: "claude",
        arguments: ["claude"]
    )

    private func hook(
        _ name: AgentHookEvent.Name,
        session: String,
        path: String,
        from emitter: ProcessInstance,
        source: String? = nil,
        agentID: String? = nil
    ) -> AgentHookEvent {
        AgentHookEvent(
            kind: .claude, name: name, agentUUID: "uuid", sessionID: session,
            emitterProcess: emitter, source: source, agentID: agentID, transcriptPath: path
        )
    }

    func testColumnFollowsTheTranscriptOfItsOwnSessionOnly() {
        let column = ColumnState(cwd: "/tmp")
        let snapshot = ProcessSnapshot()
        let admit = { (event: AgentHookEvent) in
            _ = column.admitClaudeHook(event, foregroundProcess: self.claude, snapshot: snapshot)
        }

        admit(hook(.sessionStart, session: "s1", path: "/t/s1.jsonl", from: claude.instance, source: "startup"))
        XCTAssertEqual(column.claudeTranscript?.follower.path, "/t/s1.jsonl")
        XCTAssertEqual(column.claudeTranscript?.sessionID, "s1")
        let first = column.claudeTranscript?.follower

        // A nested `claude -p` (outside the foreground job) and a subagent
        // never redirect it.
        admit(hook(.sessionStart, session: "nested", path: "/t/nested.jsonl", from: ProcessInstance(pid: 900, startedAt: 90)))
        admit(hook(.stop, session: "s1", path: "/t/s1/subagents/agent-1.jsonl", from: claude.instance, agentID: "sub"))
        XCTAssertTrue(column.claudeTranscript?.follower === first)

        // Repeats of the same session keep the follower (and what it read).
        admit(hook(.userPromptSubmit, session: "s1", path: "/t/s1.jsonl", from: claude.instance))
        XCTAssertTrue(column.claudeTranscript?.follower === first)

        // /clear: a new session, a new transcript.
        admit(hook(.sessionStart, session: "s2", path: "/t/s2.jsonl", from: claude.instance, source: "clear"))
        XCTAssertEqual(column.claudeTranscript?.follower.path, "/t/s2.jsonl")
        XCTAssertFalse(column.claudeTranscript?.follower === first)
    }

    func testTranscriptIsReadOnlyWhileItsClaudeIsInTheForeground() {
        let follow = ClaudeTranscriptFollow(
            sessionID: "s1", process: claude.instance,
            follower: ClaudeUsageFollower(path: "/t/s1.jsonl", owner: self)
        )
        let shell = ProcessInstance(pid: 50, startedAt: 5)
        let another = ProcessInstance(pid: 701, startedAt: 71)
        var namesAsked = 0
        func step(_ foreground: ProcessInstance?, running: Bool, name: String?) -> ClaudeTranscriptFollow.Step {
            follow.step(foreground: foreground, isRunning: running) {
                namesAsked += 1
                return name
            }
        }
        XCTAssertEqual(step(claude.instance, running: true, name: "claude"), .read)
        XCTAssertEqual(namesAsked, 0, "the common case reads no arguments")
        // Suspended behind its shell.
        XCTAssertEqual(step(shell, running: true, name: "zsh"), .hide)
        XCTAssertEqual(step(nil, running: true, name: nil), .hide)
        // Exited, or replaced by another `claude`.
        XCTAssertEqual(step(shell, running: false, name: "zsh"), .stop)
        XCTAssertEqual(step(another, running: true, name: "claude"), .stop)
    }

    func testTitleBarShowsTheUsageWhenThereIsRoom() {
        let column = ColumnState(cwd: "/tmp")
        column.view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        column.layoutWithTitleBar(width: 600, height: 400)
        XCTAssertNil(column.usageLabel)

        var parser = ClaudeTranscriptUsageParser()
        parser.consume(line: Data(TranscriptLine.response(id: "msg_1", cacheRead: 850_000).utf8))
        column.setAgentUsage(parser.usage)
        let label = try? XCTUnwrap(column.usageLabel)
        XCTAssertEqual(label?.stringValue, "ctx 85%")
        XCTAssertEqual(label?.isHidden, false)
        XCTAssertEqual(label?.frame.maxX, 588)
        XCTAssertTrue(label?.toolTip?.hasPrefix("Context: 850,002 tokens") == true)

        // Too narrow: the title keeps the room.
        column.layoutWithTitleBar(width: 140, height: 400)
        XCTAssertEqual(label?.isHidden, true)
        column.layoutWithTitleBar(width: 600, height: 400)
        XCTAssertEqual(label?.isHidden, false)

        column.setAgentUsage(nil)
        XCTAssertEqual(label?.isHidden, true)
        column.layoutWithTitleBar(width: 600, height: 400)
        XCTAssertEqual(label?.isHidden, true)
    }
}
