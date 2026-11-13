import XCTest
@testable import Nirux

/// Agents blocked on the user, and the order Next Waiting Agent (⌘J) walks
/// them in. Fed with fake hook events and injected time.
final class WaitingAgentTests: XCTestCase {
    private var machine = AgentStatusMachine()
    private let t0: TimeInterval = 1_000
    private let claudeProcess = ProcessInstance(pid: 4242, startedAt: 900)

    private func event(
        _ name: AgentHookEvent.Name,
        at offset: TimeInterval = 0,
        tool: String? = nil,
        key: String? = nil,
        errorKind: String? = nil,
        type: String? = nil
    ) -> AgentHookEvent {
        AgentHookEvent(
            kind: .claude, name: name, sessionID: "lead", emitterProcess: nil,
            detail: tool, toolName: tool, toolSummary: nil, toolKey: key,
            agentID: nil, notificationType: type, errorKind: errorKind, timestamp: t0 + offset
        )
    }

    private func apply(_ event: AgentHookEvent) {
        _ = machine.apply(event, isUserFocused: false)
    }

    private func startTurn() {
        _ = machine.tick(fgName: "claude", isUserFocused: false, now: Date(timeIntervalSince1970: t0))
        apply(event(.sessionStart))
        apply(event(.userPromptSubmit))
        apply(event(.preToolUse, tool: "Bash"))
    }

    private func front(_ name: String = "claude") -> ForegroundProcess {
        ForegroundProcess(instance: claudeProcess, name: name, arguments: [name])
    }

    private func wait(at offset: TimeInterval, foreground: ForegroundProcess? = nil) -> AgentWait? {
        machine.blockedWait(now: t0 + offset, foreground: foreground ?? front())
    }

    // MARK: - What blocks an agent

    /// The long-wait threshold only decides when a dialog alerts: ⌘J goes
    /// to one the moment it opens.
    func testDialogBlocksAsSoonAsItOpens() {
        startTurn()
        apply(event(.permissionRequest, at: 5, tool: "Bash", key: "k"))

        XCTAssertEqual(wait(at: 6), AgentWait(reason: .permission(tool: "Bash", summary: nil), since: t0 + 5))
        XCTAssertNil(machine.stuckState(now: t0 + 6, waitThreshold: 600, foreground: front()), "not stuck yet")
        // Seen on screen, it blocks as before: only a turn's question stands.
        _ = machine.tick(fgName: "claude", claudeFiredHooks: true, isUserFocused: true, now: Date(timeIntervalSince1970: t0 + 7))
        XCTAssertEqual(wait(at: 8), AgentWait(reason: .permission(tool: "Bash", summary: nil), since: t0 + 5))
    }

    /// A keystroke reached the dialog: answered (or denied with Esc, which
    /// fires no hook).
    func testAnsweredDialogNoLongerBlocks() {
        startTurn()
        apply(event(.permissionRequest, at: 5, tool: "Bash", key: "k"))
        machine.noteKeystroke(now: Date(timeIntervalSince1970: t0 + 7))

        XCTAssertNil(wait(at: 8))
    }

    /// A question dialog's keys move among its options and answer its
    /// questions one by one: it waits until its answers are sent (its
    /// tool's PostToolUse), or an Esc or Ctrl-C closes it, which fire no
    /// hook. The forms Claude Code reads them in: plain, kitty keyboard
    /// protocol (Caps Lock and Num Lock don't change the key), xterm's
    /// modifyOtherKeys. None of them is a draft at the prompt.
    func testQuestionDialogWaitsThroughItsKeys() {
        let question = AgentWait(reason: .question(nil), since: t0 + 5)
        func at(_ offset: TimeInterval) -> Date { Date(timeIntervalSince1970: t0 + offset) }
        func asks() {
            machine = AgentStatusMachine()
            startTurn()
            apply(event(.permissionRequest, at: 5, tool: "AskUserQuestion", key: "q"))
        }
        let esc = "\u{1B}"
        let cancels = [
            esc, esc + "[27u", esc + "[27;1u", esc + "[27;65u", esc + "[27;129u", esc + "[27;1:1u",
            "\u{03}", esc + "[99;5u", esc + "[99;69u", esc + "[99;133u", esc + "[27;5;99~",
        ]
        // Moving, answering one of its questions, keys like a cancel key's.
        let moves = [esc + "[B", "2", "\r", "\t", "a", esc + "[99;6u", esc + "[27;3u", esc + "[27;1:3u", esc + "[27;5;98~"]
        for cancel in cancels {
            asks()
            for keys in moves { machine.noteKeystroke(now: at(6), keys: Data(keys.utf8)) }
            XCTAssertEqual(wait(at: 8), question, "still asks before \(cancel.debugDescription)")
            // Claude redraws the dialog at each key: no work for that.
            machine.noteRead(now: at(8))
            XCTAssertEqual(machine.tick(fgName: "claude", isUserFocused: false, now: at(8.5)), .needsAttention)
            machine.noteKeystroke(now: at(9), keys: Data(cancel.utf8))
            XCTAssertNil(wait(at: 10), "closed by \(cancel.debugDescription)")
            XCTAssertFalse(machine.hasDraft, "keys into the dialog, not the prompt")
            // Closed: Claude prints the refusal, then sits at its prompt,
            // where a key is a draft.
            machine.noteRead(now: at(9.2))
            XCTAssertEqual(machine.tick(fgName: "claude", isUserFocused: false, now: at(9.5)), .working)
            XCTAssertEqual(machine.tick(fgName: "claude", isUserFocused: false, now: at(30)), .idle)
            machine.noteKeystroke(now: at(31), keys: Data("x".utf8))
            XCTAssertTrue(machine.hasDraft)
        }
        // Its answers sent: its tool's end.
        asks()
        machine.noteKeystroke(now: at(6), keys: Data("\r".utf8))
        apply(event(.postToolUse, at: 7, tool: "AskUserQuestion", key: "q"))
        XCTAssertNil(wait(at: 8))
        // An Esc that a field of it took (its "Type something"): Claude's
        // reminder brings it back. One that crossed the reminder (the hook
        // is async) still closed it.
        asks()
        machine.noteKeystroke(now: at(6), keys: Data([0x1B]))
        XCTAssertNil(wait(at: 7))
        apply(event(.notification, at: 12, type: "permission_prompt"))
        XCTAssertEqual(wait(at: 13), question)
        machine.noteKeystroke(now: at(13.1), keys: Data([0x1B]))
        apply(event(.notification, at: 13, type: "permission_prompt"))
        XCTAssertNil(wait(at: 14), "a reminder sent before the Esc")
        // An approval's first key is its answer, as before.
        machine = AgentStatusMachine()
        startTurn()
        apply(event(.permissionRequest, at: 5, tool: "Bash", key: "k"))
        machine.noteKeystroke(now: at(6), keys: Data((esc + "[B").utf8))
        XCTAssertNil(wait(at: 7))
    }

    /// The question dialog in front takes the keys: they don't answer a
    /// subagent's approval queued behind it, which shows once the
    /// questions are sent.
    func testKeysOfAQuestionDialogLeaveTheApprovalBehindIt() {
        func at(_ offset: TimeInterval) -> Date { Date(timeIntervalSince1970: t0 + offset) }
        startTurn()
        apply(event(.permissionRequest, at: 4, tool: "AskUserQuestion", key: "q"))
        apply(AgentHookEvent(
            kind: .claude, name: .permissionRequest, sessionID: "lead", detail: "Bash", toolName: "Bash", toolKey: "b",
            agentID: "sub", timestamp: t0 + 5
        ))
        for offset in stride(from: 6.0, through: 20, by: 2) { machine.noteKeystroke(now: at(offset), keys: Data("\r".utf8)) }
        apply(event(.postToolUse, at: 21, tool: "AskUserQuestion", key: "q"))
        XCTAssertEqual(wait(at: 22), AgentWait(reason: .permission(tool: "Bash", summary: nil), since: t0 + 5))
        machine.noteKeystroke(now: at(23), keys: Data("1".utf8))
        XCTAssertNil(wait(at: 24), "its own first key answers it")
    }

    /// An MCP server's form takes keys too: its `elicitation_response`
    /// comes whatever its end. A teammate's "needs your input" gets no
    /// hook: its first key is its answer.
    func testAFormWaitsThroughItsKeys() {
        func at(_ offset: TimeInterval) -> Date { Date(timeIntervalSince1970: t0 + offset) }
        startTurn()
        apply(event(.notification, at: 5, type: "elicitation_dialog"))
        for keys in ["a", "\t", "b"] { machine.noteKeystroke(now: at(6), keys: Data(keys.utf8)) }
        XCTAssertEqual(wait(at: 7)?.since, t0 + 5)
        apply(event(.notification, at: 8, type: "elicitation_response"))
        XCTAssertNil(wait(at: 9))
        machine = AgentStatusMachine()
        startTurn()
        apply(event(.notification, at: 5, type: "agent_needs_input"))
        machine.noteKeystroke(now: at(6), keys: Data("\r".utf8))
        XCTAssertNil(wait(at: 7))
    }

    func testFailedTurnBlocksUntilTheAgentMovesAgain() {
        startTurn()
        apply(event(.stopFailure, at: 10, errorKind: "overloaded"))

        XCTAssertEqual(wait(at: 20), AgentWait(reason: .apiError(kind: "overloaded", detail: nil), since: t0 + 10))

        apply(event(.userPromptSubmit, at: 30))
        XCTAssertNil(wait(at: 31))
    }

    func testExitMidTurnBlocksOnceConfirmed() {
        startTurn()
        machine.noteAgentExited(AgentMidTurnExit(
            processName: "claude", exitedAt: t0 + 10, lastSeenAt: t0 + 9,
            sessionID: nil, arguments: ["claude"], firedHooks: true
        ))

        XCTAssertNil(wait(at: 11, foreground: front("zsh")), "its SessionEnd may still be on its way")
        XCTAssertEqual(wait(at: 20, foreground: front("zsh")), AgentWait(reason: .exitedMidTurn, since: t0 + 10))
    }

    /// The agent merely waits for its next prompt.
    func testFinishedTurnDoesNotBlock() {
        startTurn()
        apply(event(.stop, at: 10))

        XCTAssertEqual(machine.state, .needsAttention)
        XCTAssertNil(wait(at: 20))
    }

    // MARK: - The queue

    private let columns = (0..<4).map { _ in UUID() }

    private func agent(_ column: Int, since: TimeInterval, workspace: String = "ws", read: Bool = false) -> WaitingAgent {
        WaitingAgent(
            workspaceID: workspace, columnID: columns[column], wait: AgentWait(reason: .question(nil), since: since, isRead: read)
        )
    }

    func testQueueStartsWithTheLongestWait() {
        let queue = WaitingAgentQueue.ordered([agent(0, since: 30), agent(1, since: 10), agent(2, since: 30), agent(3, since: 20)])

        XCTAssertEqual(queue.map(\.columnID), [columns[1], columns[3], columns[0], columns[2]], "equal waits keep their order")
    }

    /// Those not seen on screen yet come before those that stand, however
    /// long these have waited.
    func testQueueStartsWithThoseNotSeenYet() {
        let queue = WaitingAgentQueue.ordered([
            agent(0, since: 10, read: true), agent(1, since: 30), agent(2, since: 5, read: true), agent(3, since: 20),
        ])

        XCTAssertEqual(queue.map(\.columnID), [columns[3], columns[1], columns[2], columns[0]])
    }

    /// The presses since the user last moved, from `start`: the queue as
    /// `queue` gives it at each press (what ⌘J's visits make seen).
    private func presses(_ count: Int, from start: UUID? = nil, queue: ([UUID]) -> [WaitingAgent]) -> [UUID] {
        var walk = start.map { [$0] } ?? []
        var visited: Set<UUID> = []
        var landed: [UUID] = []
        var current = start
        for _ in 0..<count {
            guard let (next, walked) = WaitingAgentQueue.next(from: current, walk: walk, in: queue(Array(visited))) else { break }
            walk = walked
            visited.insert(next.columnID)
            landed.append(next.columnID)
            current = next.columnID
        }
        return landed
    }

    /// A dialog left open, or a failed turn, is never seen: the presses
    /// still go through every question that stands before coming back.
    func testEachPressReachesEveryWaitOnce() {
        let queue = WaitingAgentQueue.ordered([agent(0, since: 30), agent(1, since: 10, read: true), agent(2, since: 20, read: true)])
        XCTAssertEqual(presses(4) { _ in queue }, [columns[0], columns[1], columns[2], columns[0]])
    }

    /// Seen once ⌘J landed on it, a question stands further down the queue:
    /// the next press goes to one not seen yet, then on through those that
    /// stand, none twice.
    func testAPressGoesToOneNotSeenYetBeforeWalkingOn() {
        let walked = presses(4) { visited in
            WaitingAgentQueue.ordered([
                agent(0, since: 10, read: visited.contains(columns[0])),
                agent(1, since: 20, read: visited.contains(columns[1])),
                agent(2, since: 15, read: true),
            ])
        }
        // Once the first is seen, the one after it in the queue is the
        // standing third: not before the second, never seen yet.
        XCTAssertEqual(walked, [columns[0], columns[1], columns[2], columns[0]])
    }

    func testFirstPressGoesToTheLongestWait() {
        let queue = [agent(0, since: 10), agent(1, since: 20), agent(2, since: 30)]

        XCTAssertEqual(WaitingAgentQueue.next(from: nil, walk: [], in: queue)?.agent, queue[0])
        XCTAssertEqual(WaitingAgentQueue.next(from: UUID(), walk: [], in: queue)?.agent, queue[0], "from a column that doesn't wait")
        XCTAssertEqual(
            WaitingAgentQueue.next(from: columns[2], walk: [columns[2]], in: queue)?.agent, queue[0],
            "from a waiting column the user went to by hand"
        )
        XCTAssertEqual(WaitingAgentQueue.next(from: columns[0], walk: [columns[0]], in: queue)?.agent, queue[1], "already on it: the next one")
        XCTAssertNil(WaitingAgentQueue.next(from: columns[0], walk: [columns[0]], in: []))
        XCTAssertEqual(
            WaitingAgentQueue.next(from: columns[0], walk: [columns[1], columns[0]], in: Array(queue.prefix(2)))?.agent, queue[1],
            "a new round: never the one on screen"
        )
    }

    /// A visited agent stays blocked until answered: each press goes on to
    /// the next one, then wraps around.
    func testEachPressGoesOnToTheNextAgent() {
        let queue = [agent(0, since: 10), agent(1, since: 20), agent(2, since: 30)]
        XCTAssertEqual(presses(7) { _ in queue }, [columns[0], columns[1], columns[2], columns[0], columns[1], columns[2], columns[0]])
        XCTAssertEqual(presses(3, from: columns[0]) { _ in queue }, [columns[1], columns[2], columns[0]], "from the first: back to it last")
        XCTAssertEqual(presses(3, from: columns[1]) { _ in queue }, [columns[0], columns[2], columns[0]], "from the second: on past it")
    }

    func testOnlyAgentWaitingIsTheOneOnScreen() {
        let queue = [agent(0, since: 10)]

        XCTAssertEqual(WaitingAgentQueue.next(from: columns[0], walk: [columns[0]], in: queue)?.agent, queue[0])
    }
}
