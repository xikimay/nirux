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
    }

    /// A keystroke reached the dialog: answered (or denied with Esc, which
    /// fires no hook).
    func testAnsweredDialogNoLongerBlocks() {
        startTurn()
        apply(event(.permissionRequest, at: 5, tool: "Bash", key: "k"))
        machine.noteKeystroke(now: Date(timeIntervalSince1970: t0 + 7))

        XCTAssertNil(wait(at: 8))
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

    /// A dialog belongs to the `claude` in front: none behind a shell.
    func testDialogOfAClaudeNotInFrontDoesNotBlock() {
        startTurn()
        apply(event(.permissionRequest, at: 5, tool: "Bash", key: "k"))

        XCTAssertNil(wait(at: 6, foreground: front("zsh")))
    }

    // MARK: - The queue

    private let columns = (0..<4).map { _ in UUID() }

    private func agent(_ column: Int, since: TimeInterval, workspace: String = "ws") -> WaitingAgent {
        WaitingAgent(workspaceID: workspace, columnID: columns[column], wait: AgentWait(reason: .question(nil), since: since))
    }

    func testQueueStartsWithTheLongestWait() {
        let queue = WaitingAgentQueue.ordered([agent(0, since: 30), agent(1, since: 10), agent(2, since: 30), agent(3, since: 20)])

        XCTAssertEqual(queue.map(\.columnID), [columns[1], columns[3], columns[0], columns[2]], "equal waits keep their order")
    }

    func testFirstPressGoesToTheLongestWait() {
        let queue = [agent(0, since: 10), agent(1, since: 20), agent(2, since: 30)]

        XCTAssertEqual(WaitingAgentQueue.next(from: nil, lastJump: nil, in: queue), queue[0])
        XCTAssertEqual(WaitingAgentQueue.next(from: UUID(), lastJump: nil, in: queue), queue[0], "from a column that doesn't wait")
        XCTAssertEqual(
            WaitingAgentQueue.next(from: columns[2], lastJump: nil, in: queue), queue[0],
            "from a waiting column the user went to by hand"
        )
        XCTAssertEqual(WaitingAgentQueue.next(from: columns[0], lastJump: nil, in: queue), queue[1], "already on it: the next one")
        XCTAssertNil(WaitingAgentQueue.next(from: columns[0], lastJump: columns[0], in: []))
    }

    /// A visited agent stays blocked until answered: each press goes on to
    /// the next one, then wraps around.
    func testEachPressGoesOnToTheNextAgent() {
        let queue = [agent(0, since: 10), agent(1, since: 20), agent(2, since: 30)]
        var current: UUID?
        var visited: [UUID] = []
        for _ in 0..<4 {
            let next = WaitingAgentQueue.next(from: current, lastJump: current, in: queue)
            current = next?.columnID
            visited.append(next?.columnID ?? UUID())
        }

        XCTAssertEqual(visited, [columns[0], columns[1], columns[2], columns[0]])
    }

    /// The agent the last press landed on was answered: it left the queue,
    /// and the next press starts over at the longest wait.
    func testAnsweredAgentStartsTheQueueOver() {
        let queue = [agent(1, since: 20), agent(2, since: 30)]

        XCTAssertEqual(WaitingAgentQueue.next(from: columns[0], lastJump: columns[0], in: queue), queue[0])
    }

    func testOnlyAgentWaitingIsTheOneOnScreen() {
        let queue = [agent(0, since: 10)]

        XCTAssertEqual(WaitingAgentQueue.next(from: columns[0], lastJump: nil, in: queue), queue[0])
        XCTAssertEqual(WaitingAgentQueue.next(from: columns[0], lastJump: columns[0], in: queue), queue[0])
    }
}
