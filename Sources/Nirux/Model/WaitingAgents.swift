import Foundation

/// An agent blocked on the user: it won't go on until they answer its
/// dialog (permission, question, plan approval), get it past an API error,
/// start it again after it exited mid-turn, stop a turn gone silent, or
/// answer the question its last turn ended on. Unlike `AgentStuckState`, a dialog counts as soon as
/// it opens, whatever the long-wait threshold. A finished turn that asks
/// nothing doesn't count: the agent merely waits for its next prompt.
struct AgentWait: Equatable, Sendable {
    let reason: AgentAttentionReason
    /// Epoch seconds the agent got blocked: the dialog opened, the turn
    /// failed, the exit was noticed.
    let since: TimeInterval
    /// A turn's question the user saw on screen, or was asked under their
    /// eyes (`AgentStatusMachine.AskedQuestion.isSeen`): it stands until
    /// answered. Next Waiting Agent goes to it after what they have not
    /// seen. (A dialog, a failure or an exit never stands this way.)
    var isRead = false
}

extension AgentWait {
    /// Whether it still blocks the agent on the user while its status is
    /// `status`: a wait for the user's answer doesn't once the agent works
    /// again (an answered dialog lingers until its tool ends). ⌘J and the
    /// spaces' marks read waits through it.
    func blocks(whileStatus status: AgentStatus) -> Bool {
        reason.signal != .waiting || status != .working
    }
}

extension AgentStatusMachine {
    /// What blocks the agent on the user now, if anything (see
    /// `AgentWait`). `foreground` is the column's foreground process.
    func blockedWait(now: TimeInterval, silence: AgentSilence? = nil, foreground: ForegroundProcess?) -> AgentWait? {
        switch stuckState(now: now, waitThreshold: nil, silence: silence, foreground: foreground) {
        case .exitedMidTurn(let exit)?:
            return AgentWait(reason: .exitedMidTurn, since: exit.exitedAt)
        case .silent(let silence)?:
            return AgentWait(reason: .silent(now - silence.startedAt), since: silence.startedAt)
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
            if let reported = reportedWait(foreground: foreground, now: now) { return reported }
            return visibleQuestion(foreground: foreground).map {
                AgentWait(reason: .askedInReply($0.text), since: $0.since, isRead: $0.isSeen)
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
/// (⌘J) walks through (the shell's `waitingQueue` gathers them).
enum WaitingAgentQueue {
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
    /// screen (`current`), and the walk once there: to the first agent the
    /// walk hasn't visited (`walk`: the column the user last moved to,
    /// then where each press since landed), never the one on screen. Each
    /// wait once, in the queue's order as it is at each press (a question
    /// seen once visited stands further down), then a new round: a visited
    /// agent stays blocked until answered, so "the first" alone would
    /// never move on.
    static func next(from current: UUID?, walk: [UUID], in queue: [WaitingAgent]) -> (agent: WaitingAgent, walk: [UUID])? {
        func unvisited(_ walk: [UUID]) -> WaitingAgent? {
            let visited = Set(walk)
            return queue.first { $0.columnID != current && !visited.contains($0.columnID) }
        }
        if let agent = unvisited(walk) { return (agent, walk + [agent.columnID]) }
        // Every wait visited: a new round, the one on screen at its end.
        return (unvisited([]) ?? queue.first).map { ($0, [$0.columnID]) }
    }
}
