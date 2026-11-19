import Foundation

/// A terminal coding agent Nirux recognizes. The raw value is its process
/// name (`ProcessSnapshot.execName`: Gemini CLI runs as `node … gemini`),
/// and what saved state, `nirux://` URLs and `Nirux --hook` write.
enum CodingAgent: String, CaseIterable, Codable, Sendable {
    case claude, codex
    /// Antigravity CLI, Google's successor to Gemini CLI.
    case agy
    case gemini, opencode

    /// What tells Nirux the agent's status.
    enum StatusSource: Sendable {
        /// Lifecycle hooks: Claude Code's, Codex's `notify` (turn ends only).
        case hooks
        /// Its terminal output: activity, and Antigravity's OSC 7501.
        case output
    }

    /// When it asks whether to trust the folder it starts in, before any
    /// hook runs (see `AgentTrustPrompt`).
    enum FolderTrust: Sendable {
        case never
        /// In a folder no trusted one contains: a task's new folder.
        case newFolder
        /// In any folder it wasn't trusted in by its exact path: a new worktree.
        case everyFolder
    }

    static let launchable = allCases.filter(\.isLaunchable)

    /// The launchable agent `rawValue` names.
    init?(launchable rawValue: String) {
        guard let agent = CodingAgent(rawValue: rawValue), agent.isLaunchable else { return nil }
        self = agent
    }

    var statusSource: StatusSource {
        switch self {
        case .claude, .codex: .hooks
        case .agy, .gemini, .opencode: .output
        }
    }

    /// It runs `Nirux --hook <raw value>`. Antigravity's hooks only say
    /// which conversation it runs.
    var sendsHooks: Bool {
        switch self {
        case .claude, .codex, .agy: true
        case .gemini, .opencode: false
        }
    }

    /// Nirux starts it: it has an `AgentLaunch`.
    var isLaunchable: Bool {
        AgentLaunch(self, resume: nil, claudeMode: .default, codexMode: .default) != nil
    }

    var folderTrust: FolderTrust {
        switch self {
        case .claude, .codex: .newFolder
        case .agy: .everyFolder
        case .gemini, .opencode: .never
        }
    }

    /// In sentences and filters: "Claude is working".
    var name: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .agy: "Antigravity"
        case .gemini: "Gemini"
        case .opencode: "OpenCode"
        }
    }

    /// In menus and pickers: "New Claude Code".
    var productName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .agy: "Antigravity"
        case .gemini: "Gemini CLI"
        case .opencode: "OpenCode"
        }
    }

    /// With its maker where the product name doesn't say it: "Launch
    /// OpenAI Codex in a new terminal".
    var fullName: String {
        switch self {
        case .codex: "OpenAI Codex"
        case .agy: "Google’s Antigravity CLI"
        case .claude, .gemini, .opencode: productName
        }
    }

    /// Its SF Symbol, where its app's icon isn't shown.
    var symbolName: String {
        switch self {
        case .claude: "sparkles"
        case .codex: "brain.head.profile"
        case .agy: "atom"
        case .gemini: "sparkle"
        case .opencode: "curlybraces"
        }
    }

    /// Its desktop app, whose icon stands for it when installed.
    var appBundleID: String? {
        switch self {
        case .claude: "com.anthropic.claudefordesktop"
        case .codex: "com.openai.codex"
        case .agy, .gemini, .opencode: nil
        }
    }

    /// What precedes a session's id in the launch that resumes it
    /// (`claude --resume <id>`, `codex resume <id>`, `agy --conversation <id>`).
    var resumeArgument: String? {
        switch self {
        case .claude: "--resume"
        case .codex: "resume"
        case .agy: "--conversation"
        case .gemini, .opencode: nil
        }
    }

    /// Titles it gives its terminal that name no session.
    var genericTitles: Set<String> {
        switch self {
        case .claude: ["claude", "claude code"]
        case .codex: ["codex", "openai codex"]
        case .agy, .gemini, .opencode: []
        }
    }

    /// A run of it with `arguments` (argv) that holds no conversation to
    /// come back to: `claude -p`, `codex exec`, `agy -p` or a subcommand
    /// of agy's.
    func isHeadless(_ arguments: [String]) -> Bool {
        switch self {
        case .claude:
            return arguments.contains("-p") || arguments.contains("--print")
        case .codex:
            return Self.isCodexExec(arguments)
        case .agy:
            let arguments = arguments.dropFirst()
            return arguments.contains { ["-p", "--print", "--prompt"].contains($0) }
                || arguments.first.map(Self.agySubcommands.contains) ?? false
        case .gemini, .opencode:
            return false
        }
    }

    /// agy 1.5's subcommands (`agy help`).
    private static let agySubcommands: Set<String> = [
        "acp", "agent", "agents", "changelog", "help", "install", "mcp", "mic-serve", "models",
        "plugin", "plugins", "remote-control", "update"
    ]

    /// `codex exec` (alias `e`). The subcommand follows Codex's global
    /// options, and `codex` itself may be a script its runtime runs
    /// (`node …/bin/codex`, from npm or bun).
    private static func isCodexExec(_ arguments: [String]) -> Bool {
        guard let codex = arguments.firstIndex(where: {
            (($0 as NSString).lastPathComponent as NSString).deletingPathExtension == CodingAgent.codex.rawValue
        }) else { return false }
        var index = codex + 1
        while let argument = arguments[safe: index], argument != "--" {
            guard argument.hasPrefix("-") else { return argument == "exec" || argument == "e" }
            index += codexOptionsWithValue.contains(argument) ? 2 : 1
        }
        return false
    }

    /// Codex's global options whose value is the next argument.
    private static let codexOptionsWithValue: Set<String> = [
        "-c", "--config", "--enable", "--disable", "--remote", "--remote-auth-token-env", "-i", "--image",
        "-m", "--model", "--local-provider", "-p", "--profile", "-s", "--sandbox", "-C", "--cd", "--add-dir",
        "-a", "--ask-for-approval"
    ]
}

extension ForegroundProcess {
    var agent: CodingAgent? { CodingAgent(rawValue: name) }

    /// The agent a person talks to here: not a headless run of it.
    var interactiveAgent: CodingAgent? {
        agent.flatMap { $0.isHeadless(arguments) ? nil : $0 }
    }

    /// The agent here, when it runs headless.
    var headlessAgent: CodingAgent? {
        agent.flatMap { $0.isHeadless(arguments) ? $0 : nil }
    }
}
