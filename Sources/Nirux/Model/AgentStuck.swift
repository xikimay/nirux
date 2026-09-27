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
    /// When Resume last typed `continue` (epoch seconds), and the
    /// keystroke time that left: a later keystroke is the user's.
    var resumeSentAt: TimeInterval?
    var resumeKeystrokeAt: TimeInterval?

    /// Errors a `continue` can get past once the service answers again.
    /// The others need the user first (log in, billing, a model, a prompt
    /// too long), and some come with a menu of Claude's own — rate limits,
    /// login — that fires no hook and that Enter would answer.
    static let resumableKinds: Set<String> = ["overloaded", "server_error", "unknown", "max_output_tokens"]

    var isResumable: Bool { kind.map(Self.resumableKinds.contains) ?? true }

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
    /// Epoch seconds the agent was last seen in front, alive: keystrokes
    /// since may have reached the shell.
    let lastSeenAt: TimeInterval
    /// The conversation it ran, when its own hooks confirmed one: what
    /// Resume Session reopens (else Claude's picker).
    let sessionID: String?
    /// Its argv, for the launch flags a resume keeps.
    let arguments: [String]
    /// This very process fired hooks: it would have sent SessionEnd on a
    /// clean exit.
    let firedHooks: Bool
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
    /// The foreground process is not the interactive `claude` whose turn
    /// failed.
    case notClaude
    /// Claude is not back at its prompt: a dialog may be open, or work
    /// goes on.
    case notAtPrompt
    /// The user typed since the failure: `continue` would join their
    /// draft, and Enter would send it.
    case userTyped
    /// The error needs the user first (see `AgentTurnFailure.isResumable`).
    case needsFix
    /// `continue` went out moments ago.
    case alreadySent
}
