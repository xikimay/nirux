import Foundation

/// An agent blocked on the user: it won't go on until they answer its
/// dialog (permission, question, plan approval), get it past an API error,
/// or start it again after it exited mid-turn, or answer the question its
/// last turn ended on. Unlike `AgentStuckState`, a dialog counts as soon as
/// it opens, whatever the long-wait threshold. A finished turn that asks
/// nothing doesn't count: the agent merely waits for its next prompt.
struct AgentWait: Equatable, Sendable {
    let reason: AgentAttentionReason
    /// Epoch seconds the agent got blocked: the dialog opened, the turn
    /// failed, the exit was noticed.
    let since: TimeInterval
    /// A turn's question the user saw on screen, or was asked under their
    /// eyes: its alert is over, and it stands until answered. Next Waiting
    /// Agent goes to it after what they have not seen. (A dialog, a
    /// failure or an exit never stands this way.)
    var isRead = false
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
            // screen blocks, however young. Then a question the last turn
            // ended on: the agent goes on only with an answer.
            if let dialog = visibleDialog(foreground: foreground) {
                return AgentWait(reason: dialog.reason, since: dialog.requestedAt)
            }
            // Before any hook: the agent asks whether to trust its folder.
            if let trust = visibleTrustPrompt(foreground: foreground) {
                return AgentWait(reason: AgentTrustPrompt.reason, since: trust.seenAt)
            }
            // Idle with its question: seen, or asked under the user's
            // eyes. Nothing alerts for it any more.
            return visibleQuestion(foreground: foreground).map {
                AgentWait(reason: .askedInReply($0.text), since: $0.since, isRead: state == .idle)
            }
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

/// The agents blocked on the user, those not seen on screen first, then
/// those that stand, longest wait first in each: what Next Waiting Agent
/// (⌘J) walks through.
enum WaitingAgentQueue {
    /// The agents of `workspaces` that `wait` finds blocked (a workspace
    /// closing is left out), as `ordered` sorts them.
    @MainActor
    static func collect(from workspaces: [WorkspaceState], wait: (ColumnState) -> AgentWait?) -> [WaitingAgent] {
        ordered(workspaces.filter { !$0.isClosing }.flatMap { workspace in
            workspace.columns.compactMap { column in
                wait(column).map { WaitingAgent(workspaceID: workspace.id, columnID: column.id, wait: $0) }
            }
        })
    }

    /// Those the user has not seen on screen first, then those that
    /// stand; in each, longest wait first, and equal waits keep the order
    /// given.
    static func ordered(_ agents: [WaitingAgent]) -> [WaitingAgent] {
        agents.enumerated()
            .sorted { lhs, rhs in
                let (left, right) = (lhs.element.wait, rhs.element.wait)
                if left.isRead != right.isRead { return right.isRead }
                return left.since != right.since ? left.since < right.since : lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    /// Where ⌘J goes in `queue` (as `ordered` sorts it) from the column on
    /// screen (`current`). A first press goes to the queue's first — the
    /// next one when the user is on it already. While the user stays where
    /// the last press landed (`lastJump`), each press goes on to the agent
    /// after it, then wraps around: a visited agent stays blocked until
    /// answered, so "the first" alone would never move on. Seen by then,
    /// it stands further down the queue: one not seen yet still comes
    /// before the agent after it.
    static func next(from current: UUID?, lastJump: UUID?, in queue: [WaitingAgent]) -> WaitingAgent? {
        guard let first = queue.first else { return nil }
        let position = current.flatMap { current in queue.firstIndex { $0.columnID == current } }
        guard let position else { return first }
        if current == lastJump || position == 0 {
            if queue[position].wait.isRead, !first.wait.isRead { return first }
            return queue[(position + 1) % queue.count]
        }
        return first
    }
}
