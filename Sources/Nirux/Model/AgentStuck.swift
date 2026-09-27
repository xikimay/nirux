import Foundation

/// A Claude turn that ended on an API error (StopFailure): the agent sits
/// at its prompt until someone sends it on.
struct AgentTurnFailure: Equatable, Sendable {
    /// What ended the turn (`rate_limit`, `overloaded`…).
    let kind: String?
    /// The error as the terminal showed it.
    let detail: String?
    /// Epoch seconds.
    let failedAt: TimeInterval
    /// The `claude` that reported it: Resume types into that process only.
    let emitter: ProcessInstance?
    /// When Resume last typed `continue` (epoch seconds).
    var resumeSentAt: TimeInterval?

    var reason: AgentAttentionReason { .apiError(kind: kind, detail: detail) }
}

/// An agent process that exited in the middle of a turn, without ending
/// its session (a crash, a kill): recorded when the column's foreground
/// changes and the process is gone.
struct AgentMidTurnExit: Equatable, Sendable {
    /// `claude`.
    let processName: String
    /// Epoch seconds the exit was noticed.
    let exitedAt: TimeInterval
    /// The conversation it ran, when its own hooks confirmed one: what
    /// Resume Session reopens (else Claude's picker).
    let sessionID: String?
    /// Its argv, for the launch flags a resume keeps.
    let arguments: [String]
    /// The alert went out.
    var alerted = false
}

/// An agent that won't go on by itself, beyond the ordinary attention
/// states. Unlike `.needsAttention`, it outlasts focusing the column and
/// activating the app: it ends only when the agent moves again.
enum AgentStuckState: Equatable, Sendable {
    /// A dialog has waited on the user longer than the threshold.
    case waiting(AgentAttentionReason, since: TimeInterval)
    case stoppedOnError(AgentTurnFailure)
    case exitedMidTurn(AgentMidTurnExit)
}

/// Why Resume won't type `continue` into a column.
enum AgentResumeRefusal: Equatable, Sendable {
    /// No failed turn waits (the agent moved on, or never failed).
    case notStopped
    /// The foreground process is not the `claude` whose turn failed.
    case notClaude
    /// Claude is not back at its prompt: a dialog may be open, or work
    /// goes on.
    case notAtPrompt
    /// `continue` went out moments ago.
    case alreadySent
}
