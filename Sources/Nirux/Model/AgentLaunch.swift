import Foundation

/// The session a launch resumes.
enum AgentResumeTarget: Equatable {
    /// No usable stored ID (state written by an older Nirux, a session
    /// never bound, or one another column already claimed). Let the user
    /// choose; `codex resume --last` / `claude --continue` would attach
    /// several columns to the most recent conversation.
    case picker
    case session(String)
}

/// One start of a launchable agent: the session it resumes (nil: a fresh
/// one) and its flags.
enum AgentLaunch: Equatable {
    case claude(resume: AgentResumeTarget?, mode: ClaudeLaunchMode)
    case codex(resume: AgentResumeTarget?, mode: CodexLaunchMode?)
    case agy(resume: AgentResumeTarget?)

    /// `agent`'s, with the mode of its kind; nil for an agent Nirux doesn't
    /// start.
    init?(
        _ agent: CodingAgent, resume: AgentResumeTarget?,
        claudeMode: @autoclosure () -> ClaudeLaunchMode, codexMode: @autoclosure () -> CodexLaunchMode
    ) {
        switch agent {
        case .claude: self = .claude(resume: resume, mode: claudeMode())
        case .codex: self = .codex(resume: resume, mode: codexMode())
        case .agy: self = .agy(resume: resume)
        case .gemini, .opencode: return nil
        }
    }

    var agent: CodingAgent {
        switch self {
        case .claude: .claude
        case .codex: .codex
        case .agy: .agy
        }
    }

    /// The session it will resume; nil for a fresh agent or the picker.
    var sessionID: String? {
        switch self {
        case .claude(.session(let sessionID)?, _), .codex(.session(let sessionID)?, _), .agy(.session(let sessionID)?):
            return sessionID
        default:
            return nil
        }
    }

    /// The launch, through the picker when another column already runs
    /// its session: `liveText` holds what they run (launch lines, the
    /// sessions their hooks confirmed). Two agents appending to one
    /// transcript corrupt it.
    func openingElsewhere(_ liveText: [String]) -> AgentLaunch {
        guard let sessionID, AgentSessionHolder.mentions(sessionID, in: liveText) else { return self }
        switch self {
        case .claude(_, let mode): return .claude(resume: .picker, mode: mode)
        case .codex(_, let mode): return .codex(resume: .picker, mode: mode)
        case .agy: return .agy(resume: .picker)
        }
    }
}

/// Claude Code's `--permission-mode` values. `.default` passes no flag, so
/// the user's `permissions.defaultMode` applies, else auto mode; `.manual`
/// is the mode Claude Code names `default`. `.skipPermissions` is
/// `--dangerously-skip-permissions`, an alias of `bypassPermissions` kept
/// so a saved choice still launches with it.
enum ClaudeLaunchMode: String, Codable, CaseIterable {
    case `default`
    case manual
    case acceptEdits
    case auto
    case plan
    case dontAsk
    case bypassPermissions
    case skipPermissions

    var displayName: String {
        switch self {
        case .default: return "Claude Code default (your defaultMode, else Auto if available)"
        case .manual: return "Manual (asks before edits and commands)"
        case .acceptEdits: return "Accept edits (edits and file commands run; others ask)"
        case .auto: return "Auto (a safety check allows or blocks risky actions)"
        case .plan: return "Plan (read-only)"
        case .dontAsk: return "Don't ask (denies unless pre-approved)"
        case .bypassPermissions: return "Bypass permissions (skips permission checks)"
        case .skipPermissions: return "Bypass permissions (saved as Skip all)"
        }
    }

    /// A menu's choices: `.skipPermissions` repeats `.bypassPermissions`, so
    /// it shows only as the saved choice.
    static func choices(keeping saved: ClaudeLaunchMode?) -> [ClaudeLaunchMode] {
        allCases.filter { $0 != .skipPermissions || $0 == saved }
    }

    /// argv tail to append after `claude`. Empty for `.default`.
    var cliArgs: [String] {
        switch self {
        case .default: return []
        case .manual: return ["--permission-mode", "default"]
        case .acceptEdits: return ["--permission-mode", "acceptEdits"]
        case .auto: return ["--permission-mode", "auto"]
        case .plan: return ["--permission-mode", "plan"]
        case .dontAsk: return ["--permission-mode", "dontAsk"]
        case .bypassPermissions: return ["--permission-mode", "bypassPermissions"]
        case .skipPermissions: return ["--dangerously-skip-permissions"]
        }
    }

    /// The mode a `claude` argv was launched in; nil when it names none.
    static func detect(arguments: [String]) -> ClaudeLaunchMode? {
        if arguments.contains("--dangerously-skip-permissions") {
            return .skipPermissions
        }
        guard let index = arguments.firstIndex(of: "--permission-mode"),
              arguments.indices.contains(index + 1) else { return nil }
        let mode = arguments[index + 1]
        return mode == "default" ? .manual : ClaudeLaunchMode(rawValue: mode)
    }
}

/// Curated presets over Codex's two CLI axes (`--ask-for-approval` and
/// `--sandbox`). Default passes no flags, so Codex's own config applies; it is
/// also what launches use when nothing is saved. Full Auto removes Codex's
/// sandbox, enables web search, and runs without approval prompts. Workspace
/// Write keeps the sandbox and lets Codex ask before escalating.
enum CodexLaunchMode: String, Codable, CaseIterable {
    case `default`
    case fullAccess
    case workspaceWrite
    case readOnly
    case fullAuto
    case bypass

    var displayName: String {
        switch self {
        case .default: return "Default (codex defaults)"
        case .fullAccess: return "Full Access (no sandbox)"
        case .workspaceWrite: return "Workspace Write (sandboxed, asks to escalate)"
        case .readOnly: return "Read-only"
        case .fullAuto: return "Full Auto (no sandbox, non-blocking)"
        case .bypass: return "Yolo (bypass approvals & sandbox)"
        }
    }

    /// argv tail to append after `codex` or either `codex resume` form.
    var cliArgs: [String] {
        switch self {
        case .default: return []
        case .fullAccess: return ["--sandbox", "danger-full-access"]
        // codex >= 0.143.0 removed the `on-failure` approval policy; `never`
        // returns sandbox failures to the model, `on-request` lets it ask.
        case .workspaceWrite: return ["--sandbox", "workspace-write", "--ask-for-approval", "on-request"]
        case .readOnly: return ["--sandbox", "read-only"]
        case .fullAuto: return ["--sandbox", "danger-full-access", "--ask-for-approval", "never", "--search"]
        case .bypass: return ["--dangerously-bypass-approvals-and-sandbox"]
        }
    }

    /// Recover a preset only when argv identifies its sandbox and approval
    /// semantics; nil leaves restore on the backward-compatible default path.
    static func detect(arguments: [String]) -> CodexLaunchMode? {
        if arguments.contains("--dangerously-bypass-approvals-and-sandbox") {
            return .bypass
        }
        guard let sandboxIndex = arguments.firstIndex(of: "--sandbox"),
              arguments.indices.contains(sandboxIndex + 1) else { return nil }
        switch arguments[sandboxIndex + 1] {
        case "workspace-write":
            return .workspaceWrite
        case "read-only":
            return .readOnly
        case "danger-full-access":
            guard let approvalIndex = arguments.firstIndex(of: "--ask-for-approval"),
                  arguments.indices.contains(approvalIndex + 1),
                  arguments[approvalIndex + 1] == "never",
                  arguments.contains("--search") else { return .fullAccess }
            return .fullAuto
        default:
            return nil
        }
    }
}
