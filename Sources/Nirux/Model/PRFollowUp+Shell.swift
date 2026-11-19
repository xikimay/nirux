import Foundation

// What the shell reads from the follow-up: its agent's gate, its row's words.

extension PRFollowUp {
    /// What a task's Claude says, for the round's gate.
    struct AgentState: Equatable, Sendable {
        /// Why its prompt takes no Mission message now
        /// (`AgentStatusMachine.promptRefusal`).
        var refusal: AgentPromptRefusal?
        /// Its turn ended on a question to the user, or a dialog waits.
        var waitsOnUser = false
        var lastTurnEndedAt: TimeInterval = 0
        /// A Mission question of the task waits for its answer, or a
        /// Mission message waits to be typed into it: those go first.
        var missionWaits = false
        /// The user looks at its terminal: its column in front, Nirux
        /// active.
        var isWatched = false
    }

    /// What its turn just said may still be read.
    static let turnEndQuiet: TimeInterval = 30

    /// `Facts.agentRefusal` and `Facts.agentIsBusy`. Busy: its turn, or
    /// the user's, may still move the pull request; a turn that failed
    /// (a usage limit) too.
    static func gate(_ agent: AgentState, now: TimeInterval) -> (refusal: String?, isBusy: Bool) {
        let busyRefusals: Set<AgentPromptRefusal> = [.dialog, .working, .draft, .verdict, .failedTurn]
        let isBusy = agent.waitsOnUser || agent.missionWaits || agent.refusal.map(busyRefusals.contains) == true
        let refusal = agent.refusal.map(\.rawValue)
            ?? (agent.waitsOnUser ? "it waits on the user" : nil)
            ?? (agent.missionWaits ? "a Mission message waits" : nil)
            ?? (now - agent.lastTurnEndedAt < turnEndQuiet ? "its turn just ended" : nil)
            ?? (agent.isWatched ? "the user is on its terminal" : nil)
        return (refusal, isBusy)
    }

    /// The working row's line while a round's turn runs.
    static func roundText(_ kind: Kind, number: Int) -> String {
        let what = switch kind {
        case .conflict: "conflict"
        case .ci: "failed checks"
        case .feedback: "review feedback"
        }
        return "Auto follow-up \(number)/\(maxRounds) · \(what)"
    }

    /// What follows "Needs you · " on the row of a pull request handed over.
    static func stopText(_ stop: Stop, pullRequest: PRInfo) -> String {
        let number = "#\(pullRequest.number)"
        let base = pullRequest.baseRefName ?? "its base"
        switch stop.cause {
        case .checkoutDiffers:
            return "\(number): the checkout isn’t at the pull request’s head after the automatic round"
        case .rounds:
            let trouble = switch stop.kind {
            case .conflict: "conflicts with \(base)"
            case .ci: "has failed checks"
            case .feedback: "has new review feedback"
            }
            return "\(number) \(trouble) after \(maxRounds) automatic rounds"
        case .nothingPushed:
            let trouble = switch stop.kind {
            case .conflict: "still conflicts with \(base)"
            case .ci: "still fails its checks"
            case .feedback: "still has review feedback open"
            }
            return "\(number) \(trouble): the automatic round pushed nothing"
        }
    }
}
