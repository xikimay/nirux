import Foundation

// MARK: - Sending a Branch Review's comments (docs/branch-review.md, section 6.2)

/// Why a Branch Review's comments can't go into a column's prompt now.
enum ReviewSendRefusal: Equatable, Sendable {
    /// Nothing that takes a prompt runs there.
    case noAgent
    /// An agent that doesn't say when it waits at its prompt (Codex's
    /// notify hook reports turn ends only; Gemini CLI and OpenCode report
    /// nothing): an open question would take the comments as its answer.
    case notClaude(String)
    /// A Claude that took no prompt since it started, or hasn't reported
    /// since it came back from Ctrl-Z: a dialog it shows before any hook
    /// (trust, an MCP server) would take the comments.
    case notHeardFrom
    /// `claude -p`: it takes no prompt.
    case headless
    /// An agent run by another program in front (a launcher): its prompt
    /// isn't the terminal's, as far as Nirux can tell.
    case underLauncher(String)
    /// The agent is stopped (Ctrl-Z) or in the background: the shell is in
    /// front.
    case notInFront
    /// A dialog may be on screen: typed text would answer it.
    case dialog
    /// The last turn ended on an error that needs the user first (a usage
    /// limit, a login, a model): some show a menu of Claude's own that
    /// fires no hook. Until a prompt goes in.
    case errorMenu
    /// A turn is under way.
    case working

    var message: String {
        switch self {
        case .noAgent:
            return "No agent waits at its prompt in this worktree."
        case .notClaude(let name):
            return "Only Claude Code tells Nirux when it waits at its prompt; \(name) doesn’t, "
                + "so a question it asks would take the comments as its answer."
        case .notHeardFrom:
            return "Nirux hasn’t heard from this Claude at its prompt yet: send it a prompt first, "
                + "or restart it if it started before Nirux’s hooks were installed."
        case .headless:
            return "This Claude runs headless (claude -p): it takes no prompt."
        case .notInFront:
            return "The agent here is stopped or in the background: bring it back (fg) first."
        case .underLauncher(let name):
            return "The agent here runs under \(name): Nirux can’t tell when it waits at its prompt. "
                + "Copy Message, and paste it there yourself."
        case .dialog:
            return "Claude may be asking something: answer it first."
        case .errorMenu:
            return "Claude’s last turn ended on an error that needs you first (a usage limit, a login, a model), "
                + "and a menu it shows would take the comments: deal with it in its terminal and send Claude a prompt, "
                + "then send the comments."
        case .working:
            return "Claude is working: send the comments once its turn is over."
        }
    }
}

extension AgentStatusMachine {
    /// Names, by process, of the agents Nirux knows that aren't Claude Code.
    static let otherAgents = ["codex": "Codex", "gemini": "Gemini CLI", "opencode": "OpenCode"]

    /// Why a review's comments may not be typed into `foreground`'s prompt
    /// now; nil when they may: an interactive `claude` driven by Nirux's
    /// hooks (`hookKind`), that took a prompt since it started (as Mission's
    /// `tell` asks), with no dialog listed, no work going on, no turn
    /// started, and no error whose menu fires no hook. Closing a column
    /// trusts "idle" on part of this (`WorkspaceClosePolicy.LiveAgent`).
    /// Unlike Resume, it asks for no failed turn. A subagent
    /// still at work after the main turn, or a turn interrupted with Esc
    /// (no hook until Claude's idle notice), reads as working.
    func reviewSendRefusal(foreground: ForegroundProcess?) -> ReviewSendRefusal? {
        guard let foreground else { return .noAgent }
        guard foreground.name == "claude" else {
            return Self.otherAgents[foreground.name].map(ReviewSendRefusal.notClaude) ?? .noAgent
        }
        guard !AgentHookCenter.isHeadlessClaude(foreground) else { return .headless }
        // `hookKind` is the column's, cleared when Claude ends or another
        // process comes to the front (Ctrl-Z): a Claude restarted in it, or
        // back in front, must report again. A prompt since it started: SessionStart can come before
        // Claude's own dialogs.
        guard hookKind == "claude", let lastPromptAt, lastPromptAt >= foreground.instance.startedAt else {
            return .notHeardFrom
        }
        // Any dialog still listed may be on screen.
        guard pendingDialogs.isEmpty else { return .dialog }
        // As for Resume: the menus of these errors fire no hook, nor does
        // what the user does there; a prompt that goes in clears it.
        if let turnFailure, !turnFailure.isResumable { return .errorMenu }
        guard !hookWorking, turnStartedAt == nil else { return .working }
        return nil
    }

    /// Keys reached the column since its last prompt went in: a draft at
    /// the prompt, typed during the turn or after, or a menu or picker no
    /// hook tells of (`/resume`, `/model`, a search). The comments would
    /// join them: the sheet says so.
    var hasDraft: Bool {
        lastDraftInputAt > (lastPromptAt ?? 0)
    }
}
