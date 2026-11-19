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
    let agent: CodingAgent
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

/// A turn that waits on the model past the silence threshold with no sign
/// of life, while its transcript ends waiting on Claude's reply: the
/// request may hang.
struct AgentSilence: Equatable, Sendable {
    /// When the silence began: on the awake clock (`ProcessInfo.systemUptime`,
    /// stopped while the Mac sleeps), what tells one silence from the next;
    /// and in epoch seconds, what the row and ⌘J say.
    let since: TimeInterval
    let startedAt: TimeInterval

    /// Over 800 transcripts, the longest wait on a reply that came was 14
    /// minutes of thinking: a turn reads as silent past 20 minutes at least.
    static let minimumThreshold: TimeInterval = 20 * 60

    /// The stuck-agent setting's dialog threshold, 20 minutes at least; the
    /// setting off leaves the floor.
    static func threshold(waitThreshold: TimeInterval?) -> TimeInterval {
        max(waitThreshold ?? 0, minimumThreshold)
    }
}

/// A Claude agent's last sign of life: a hook event, or its transcript
/// growing. Not terminal output: its spinner redraws while a request hangs.
struct AgentLifeSigns: Equatable, Sendable {
    /// On the awake clock (the threshold's) and in epoch seconds.
    private(set) var lastAt: TimeInterval?
    private(set) var lastWallAt: TimeInterval?
    private(set) var transcript: Transcript?

    struct Transcript: Equatable, Sendable {
        let path: String
        let size: Int64
        /// What its end waits on Claude for, once read at this size.
        var awaited: TranscriptLastMessage.AwaitedReply?
    }

    mutating func note(awake: TimeInterval, wall: TimeInterval) {
        lastAt = awake
        lastWallAt = wall
    }

    /// The transcript at `path` measures `size` now: a change since the
    /// last look at it is a sign. The first look only takes its measure.
    mutating func noteTranscript(path: String, size: Int64, awake: TimeInterval, wall: TimeInterval) {
        guard transcript?.path != path || transcript?.size != size else { return }
        if transcript?.path == path { note(awake: awake, wall: wall) }
        transcript = Transcript(path: path, size: size)
    }

    mutating func noteAwaited(_ awaited: TranscriptLastMessage.AwaitedReply) {
        transcript?.awaited = awaited
    }

    mutating func forgetTranscript() {
        transcript = nil
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

/// What Interrupt would do in a turn gone silent.
enum SilentInterruptPlan: Equatable, Sendable {
    case refused(AgentInterruptRefusal)
    /// The transcript ends on a prompt typed at its box that Claude hasn't
    /// begun answering: the Esc gives it back, and Claude writes nothing.
    case givesBackPrompt
    /// The turn went past a tool result: Claude writes its interrupt.
    case stops

    var offersEsc: Bool {
        if case .refused = self { return false }
        return true
    }
}

/// What Interrupt did in a turn gone silent.
enum SilentInterrupt: Equatable, Sendable {
    /// Esc went: the prompt is back in the box, and the turn over.
    case promptGivenBack
    /// Esc went: the turn of `promptAt` is over once the transcript shows
    /// Claude's interrupt.
    case stopping(promptAt: TimeInterval)
    /// Not the silence the button showed: the agent moved on, or another
    /// silence began.
    case notSilent
    /// The process table couldn't be read.
    case noProcesses
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
