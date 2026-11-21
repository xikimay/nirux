import XCTest
@testable import Nirux

/// Which transcript a column follows, and how its header shows it.
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

    func testPlanningFollowsOnlyTheCurrentForegroundSession() throws {
        let column = ColumnState(cwd: "/tmp")
        let snapshot = ProcessSnapshot()
        func send(_ name: String, _ mode: String?, subagent: Bool = false) throws {
            var payload = ["hook_event_name": name, "session_id": "s"]
            payload["permission_mode"] = mode
            if subagent { payload["agent_id"] = "helper" }
            let event = try XCTUnwrap(AgentHookEvent(kind: .claude, payload: payload, env: [:], now: 1, emitterProcess: claude.instance))
            _ = column.admitClaudeHook(event, foregroundProcess: claude, snapshot: snapshot)
        }
        try send("SessionStart", "plan")
        XCTAssertTrue(column.isPlanning(in: claude))
        XCTAssertFalse(column.isPlanning(in: nil))
        try send("PreToolUse", "default", subagent: true)
        XCTAssertTrue(column.isPlanning(in: claude))
        try send("UserPromptSubmit", "default")
        XCTAssertFalse(column.isPlanning(in: claude))
        try send("UserPromptSubmit", "plan")
        try send("SessionEnd", nil)
        XCTAssertFalse(column.isPlanning(in: claude))
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

    /// The column's shell never starts here, so its foreground is unknown:
    /// what decides is whether the session's `claude` still runs.
    func testRefreshHidesWhileTheSessionRunsElsewhereAndDropsItOnceGone() throws {
        let column = ColumnState(cwd: "/tmp")
        column.view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        column.layoutWithHeader(width: 600, height: 400)
        column.followClaudeTranscript(at: "/t/s1.jsonl", sessionID: "s1", process: claude.instance)
        var parser = ClaudeTranscriptUsageParser()
        parser.consume(line: Data(TranscriptLine.response(id: "msg_1", cacheRead: 50_000).utf8))
        column.setAgentUsage(parser.usage)
        XCTAssertEqual(column.usageLabel?.isHidden, false)
        let follower = try XCTUnwrap(column.claudeTranscript?.follower)

        func entry(_ pid: pid_t, _ name: String) -> ProcessSnapshot.Entry {
            .init(pid: pid, parentPID: 1, processGroupID: pid, terminalForegroundProcessGroupID: -1,
                  name: name, startedAt: TimeInterval(pid / 10), arguments: [name])
        }
        // A failed process-table read changes nothing.
        column.refreshAgentUsage(snapshot: ProcessSnapshot(entries: []))
        XCTAssertEqual(column.usageLabel?.isHidden, false)

        // Still running (suspended): hidden, still followed.
        column.refreshAgentUsage(snapshot: ProcessSnapshot(entries: [entry(700, "claude"), entry(50, "zsh")]))
        XCTAssertEqual(column.usageLabel?.isHidden, true)
        XCTAssertTrue(column.claudeTranscript?.follower === follower)
        XCTAssertEqual(column.claudeTranscript?.isInForeground, false)

        // Exited: no longer followed.
        column.refreshAgentUsage(snapshot: ProcessSnapshot(entries: [entry(50, "zsh")]))
        XCTAssertNil(column.claudeTranscript)
        XCTAssertEqual(column.usageLabel?.isHidden, true)
    }

    /// A nearly full context in a narrow header keeps its number: its words
    /// without "⚠︎ " where the warning doesn't fit, rather than nothing.
    func testANearlyFullContextKeepsItsNumberInANarrowHeader() {
        let label = ColumnHeaderLabel()
        label.stringValue = "ctx 85%"
        let short = label.width(fitting: .greatestFiniteMagnitude)
        label.stringValue = "⚠︎ ctx 85%"
        label.shortText = "ctx 85%"
        let full = label.width(fitting: .greatestFiniteMagnitude)
        XCTAssertEqual(label.stringValue, "⚠︎ ctx 85%")
        XCTAssertGreaterThan(full, short)
        XCTAssertEqual(label.width(fitting: full - 1), short)
        XCTAssertEqual(label.stringValue, "ctx 85%")
        XCTAssertEqual(label.width(fitting: short - 1), 0, "no room for either: hidden")
        XCTAssertEqual(label.width(fitting: full), full)
        XCTAssertEqual(label.stringValue, "⚠︎ ctx 85%", "room again: the warning")
    }

    func testHeaderShowsTheUsageWhenThereIsRoom() throws {
        let column = ColumnState(cwd: "/tmp")
        column.terminalTitle = "claude"
        column.view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        column.layoutWithHeader(width: 600, height: 400)
        XCTAssertNil(column.usageLabel)

        var parser = ClaudeTranscriptUsageParser()
        parser.consume(line: Data(TranscriptLine.response(id: "msg_1", cacheRead: 850_000).utf8))
        column.setAgentUsage(parser.usage)
        let label = try? XCTUnwrap(column.usageLabel)
        XCTAssertEqual(label?.stringValue, "⚠︎ ctx 85%", "nearly full: a warning")
        XCTAssertEqual(label?.textColor, .niruxWarning)
        XCTAssertEqual(label?.isHidden, false)
        let header = try XCTUnwrap(column.header)
        XCTAssertEqual(
            label.map { $0.frame.maxX - ColumnHeaderView.labelInset }, header.menuButton.frame.minX - Theme.Space.sm,
            "its text ends a gap before ⋯"
        )
        XCTAssertTrue(label?.toolTip?.hasPrefix("Context: 850,002 tokens") == true)

        // Too narrow: the title keeps the room.
        column.layoutWithHeader(width: 140, height: 400)
        XCTAssertEqual(label?.isHidden, true)
        column.layoutWithHeader(width: 600, height: 400)
        XCTAssertEqual(label?.isHidden, false)

        column.setAgentUsage(nil)
        XCTAssertEqual(label?.isHidden, true)
        column.layoutWithHeader(width: 600, height: 400)
        XCTAssertEqual(label?.isHidden, true)
    }
}
