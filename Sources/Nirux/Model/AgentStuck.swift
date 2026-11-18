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
    /// When the failed turn's prompt went in (epoch seconds), if seen: text
    /// typed at the prompt since is a draft.
    let promptAt: TimeInterval?
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

/// How long a Claude agent has shown no sign of life, on the awake clock
/// (`ProcessInfo.systemUptime`, stopped while the Mac sleeps): a night's
/// sleep is no silence.
struct AgentSilence: Equatable, Sendable {
    /// Awake seconds of the last sign of life (`AgentLifeSigns`).
    let since: TimeInterval
    let now: TimeInterval
    /// Past it, a turn that waits on the model reads as silent.
    let threshold: TimeInterval

    var duration: TimeInterval { now - since }

    /// Over 800 transcripts, the longest wait on a reply that came was 14
    /// minutes of thinking: a turn reads as silent past 20 minutes at
    /// least, whatever the stuck-agent setting says.
    static let minimumThreshold: TimeInterval = 20 * 60

    /// For the stuck-agent setting's dialog threshold: nil (off) stays off.
    static func threshold(waitThreshold: TimeInterval?) -> TimeInterval? {
        waitThreshold.map { max($0, minimumThreshold) }
    }
}

/// A Claude agent's last sign of life, on the awake clock: a hook event, or
/// its transcript growing. Not terminal output: its spinner redraws while
/// a request hangs.
struct AgentLifeSigns: Equatable, Sendable {
    private(set) var lastAt: TimeInterval?
    private var transcript: Transcript?

    private struct Transcript: Equatable, Sendable {
        let path: String
        let size: Int64
    }

    mutating func note(at awake: TimeInterval) {
        lastAt = awake
    }

    /// The transcript at `path` measures `size` now: a change since the
    /// last look at it is a sign. The first look only takes its measure.
    mutating func noteTranscript(path: String, size: Int64, at awake: TimeInterval) {
        if let transcript, transcript.path == path, transcript.size != size { lastAt = awake }
        transcript = Transcript(path: path, size: size)
    }
}

/// An agent that won't go on by itself, beyond the ordinary attention
/// states. Unlike `.needsAttention`, it outlasts focusing the column and
/// activating the app: it ends only when the agent moves again.
enum AgentStuckState: Equatable, Sendable {
    /// A dialog has waited on the user longer than the threshold.
    case waiting(AgentAttentionReason, since: TimeInterval)
    case stoppedOnError(AgentTurnFailure)
    case exitedMidTurn(AgentMidTurnExit)
    /// A turn has waited on the model past the silence threshold, with no
    /// sign of life: the request may hang.
    case silent(AgentSilence)
}

/// What Interrupt did in a turn gone silent.
enum SilentInterrupt: Equatable, Sendable {
    /// Esc went before any reply: Claude gives the prompt back to its box.
    case promptGivenBack
    /// Esc went after a tool call: the box stays empty.
    case stopped
    /// Not the silence the button showed: the agent moved on, or another
    /// silence began.
    case notSilent
    case refused(AgentInterruptRefusal)
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
    /// The user typed at the prompt since the failed turn's prompt went
    /// in: `continue` would join their draft, and Enter would send it.
    case userTyped
    /// The error needs the user first (see `AgentTurnFailure.isResumable`).
    case needsFix
    /// `continue` went out moments ago.
    case alreadySent
}
