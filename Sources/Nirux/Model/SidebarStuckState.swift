import Foundation

/// What a column row shows of a stuck agent (see `AgentStuckState`), at
/// display granularity.
enum SidebarStuckState: Hashable {
    /// A dialog waiting past the threshold, and for how long ("2h05m").
    case waiting(AgentAttentionReason, duration: String)
    /// The turn failed on an API error. `failedAt` tells the failure a
    /// Resume click was aimed at from any later one.
    case stoppedOnError(kind: String?, detail: String?, failedAt: TimeInterval, resume: Resume)
    case exitedMidTurn(agent: CodingAgent)
    /// A turn waits on the model with no sign of life, for how long, since
    /// when (`AgentSilence.since`: what Interrupt aims at), and whether
    /// Interrupt may press Esc there.
    case silent(duration: String, since: TimeInterval, interruptible: Bool)

    enum Resume: Hashable {
        /// The button: `continue` can go out.
        case offered
        /// `continue` went out; the next turn has not started yet.
        case sending
        /// The user typed at its prompt since the turn began: their draft,
        /// their Enter.
        case userTyped
        /// The error needs the user first (log in, billing, a limit…).
        case needsFix
        /// Claude is not at its prompt (or not in front).
        case unavailable

        init(_ refusal: AgentResumeRefusal?) {
            switch refusal {
            case nil: self = .offered
            case .alreadySent?: self = .sending
            case .userTyped?: self = .userTyped
            case .needsFix?: self = .needsFix
            case .notStopped?, .notClaude?, .notAtPrompt?: self = .unavailable
            }
        }

        /// Where Resume stands, when it isn't the button.
        var status: String? {
            switch self {
            case .offered: return nil
            case .sending: return "Resuming…"
            case .userTyped: return "Typed in its prompt: go on from the terminal"
            case .needsFix: return "Needs a fix in the terminal first"
            case .unavailable: return "Resume once claude is back at its prompt"
            }
        }
    }

    /// The name the row shows: the agent that died, not the shell that
    /// took its place in front.
    var agentName: String? {
        if case .exitedMidTurn(let agent) = self { return agent.rawValue }
        return nil
    }

    var tooltip: String {
        switch self {
        case .waiting(let reason, let duration):
            let detail = reason.detailLine.flatMap { AgentText.clean($0, maxLength: 300) }
            return (["\(reason.headline) — waiting \(duration)", detail].compactMap { $0 }).joined(separator: " — ")
        case .stoppedOnError(let kind, let detail, _, _):
            let error = AgentAttentionReason.apiError(kind: kind, detail: detail).detailLine
            return ["Stopped on an API error", error].compactMap { $0 }.joined(separator: " — ")
        case .exitedMidTurn(let agent):
            return "\(agent.rawValue) exited in the middle of a turn, without ending its session"
        case .silent(let duration, _, _):
            return "Claude has been silent for \(duration). \(AgentAttentionReason.silentAdvice)"
        }
    }

    /// Red when something broke, amber while a dialog waits.
    var isFailure: Bool {
        if case .waiting = self { return false }
        return true
    }
}
