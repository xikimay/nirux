import Foundation

/// An agent blocked on the user: it won't go on until they answer its
/// dialog (permission, question, plan approval), get it past an API error,
/// or start it again after it exited mid-turn. Unlike `AgentStuckState`, a
/// dialog counts as soon as it opens, whatever the long-wait threshold. A
/// finished turn doesn't count: the agent merely waits for its next
/// prompt.
struct AgentWait: Equatable, Sendable {
    let reason: AgentAttentionReason
    /// Epoch seconds the agent got blocked: the dialog opened, the turn
    /// failed, the exit was noticed.
    let since: TimeInterval
}

extension AgentStatusMachine {
    /// What blocks the agent on the user now, if anything (see
    /// `AgentWait`). `foreground` is the column's foreground process.
    func blockedWait(now: TimeInterval, foreground: ForegroundProcess?) -> AgentWait? {
        switch stuckState(now: now, waitThreshold: nil, foreground: foreground) {
        case .exitedMidTurn(let exit)?:
            return AgentWait(reason: .exitedMidTurn, since: exit.exitedAt)
        case .stoppedOnError(let failure)?:
            return AgentWait(reason: failure.reason, since: failure.failedAt)
        case .waiting?, nil:
            // Without a threshold no wait is `.waiting`: any dialog on
            // screen blocks, however young.
            return visibleDialog(foreground: foreground).map { AgentWait(reason: $0.reason, since: $0.requestedAt) }
        }
    }
}

/// A column whose agent is blocked on the user.
struct WaitingAgent: Equatable, Sendable {
    let workspaceID: String
    /// `ColumnState.id`.
    let columnID: UUID
    let wait: AgentWait
}

/// The agents blocked on the user, longest wait first: what Next Waiting
/// Agent (⌘J) walks through.
enum WaitingAgentQueue {
    /// The agents of `workspaces` that `wait` finds blocked (a workspace
    /// closing is left out), longest wait first.
    @MainActor
    static func collect(from workspaces: [WorkspaceState], wait: (ColumnState) -> AgentWait?) -> [WaitingAgent] {
        ordered(workspaces.filter { !$0.isClosing }.flatMap { workspace in
            workspace.columns.compactMap { column in
                wait(column).map { WaitingAgent(workspaceID: workspace.id, columnID: column.id, wait: $0) }
            }
        })
    }

    /// Longest wait first; equal waits keep the order given.
    static func ordered(_ agents: [WaitingAgent]) -> [WaitingAgent] {
        agents.enumerated()
            .sorted { lhs, rhs in
                lhs.element.wait.since != rhs.element.wait.since
                    ? lhs.element.wait.since < rhs.element.wait.since
                    : lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    /// Where ⌘J goes in `queue` (as `ordered` sorts it) from the column on
    /// screen (`current`). A first press goes to the longest wait — the
    /// next one when the user is on it already. While the user stays where
    /// the last press landed (`lastJump`), each press goes on to the agent
    /// after it, then wraps around: a visited agent stays blocked until
    /// answered, so "the longest wait" alone would never move on.
    static func next(from current: UUID?, lastJump: UUID?, in queue: [WaitingAgent]) -> WaitingAgent? {
        guard let first = queue.first else { return nil }
        let position = current.flatMap { current in queue.firstIndex { $0.columnID == current } }
        guard let position else { return first }
        if current == lastJump || position == 0 {
            return queue[(position + 1) % queue.count]
        }
        return first
    }
}
