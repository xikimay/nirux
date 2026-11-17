import Foundation

/// Where the user is still in the loop: a space's prompts by tool and
/// target over a period, each with the one line that would spare most of
/// them, if any (Space Settings › Safety). Nothing is added until the user
/// adds it.
enum LoopRecap {
    static let minimumPrompts = 3
    static let questionTool = "AskUserQuestion"

    struct Group: Equatable, Sendable {
        var tool: String
        var target: String?
        var count: Int
        /// Every prompt of the group came in auto mode.
        var autoOnly: Bool

        var isQuestion: Bool { tool == LoopRecap.questionTool }
        var proposal: ClaudeSpaceSettings.Line? { LoopRecap.proposal(for: self) }
    }

    /// Since `since`, the most frequent first.
    static func groups(_ entries: [LoopLog.Entry], since: TimeInterval) -> [Group] {
        var groups: [Group] = []
        for entry in entries where entry.time >= since {
            // A question is a question, whatever it asks.
            let target = entry.tool == questionTool ? nil : entry.target
            if let index = groups.firstIndex(where: { $0.tool == entry.tool && $0.target == target }) {
                groups[index].count += 1
                groups[index].autoOnly = groups[index].autoOnly && entry.mode == "auto"
            } else {
                groups.append(Group(tool: entry.tool, target: target, count: 1, autoOnly: entry.mode == "auto"))
            }
        }
        return groups.sorted { ($0.count, $1.tool, $1.target ?? "") > ($1.count, $0.tool, $0.target ?? "") }
    }

    /// Programs that run whatever they are given: proposed only with a
    /// subcommand (`swift build`, never `swift`), and never as one
    /// (`uv run python`).
    static let runners: Set<String> = [
        "bash", "sh", "zsh", "fish", "dash", "python", "python3", "node", "deno", "bun", "ruby", "perl", "php",
        "swift", "osascript", "npx", "pnpx", "bunx", "uvx", "tsx", "ts-node"
    ]
    /// Subcommands that run whatever follows (`docker exec`, `npm x`).
    static let runningSubcommands: Set<String> = ["exec", "x", "dlx"]
    /// Never proposed, whatever follows: they run other commands or
    /// scripts, remove, change rights, or reach out.
    static let refused: Set<String> = [
        "sudo", "su", "doas", "env", "xargs", "eval", "exec", "source", ".", "find", "open", "rm", "rmdir", "dd", "mv",
        "chmod", "chown", "kill", "pkill", "killall", "curl", "wget", "ssh", "scp", "rsync"
    ]
    /// git commands that can lose work or run hooks and aliases, as
    /// `AgentShellCommand` names them.
    static let refusedGit: Set<String> = [
        "push", "reset", "clean", "checkout", "restore", "worktree", "branch", "rebase", "stash", "gc", "prune",
        "filter-branch", "update-ref", "reflog", "config", "switch", "rm"
    ]
    /// Commands, and what starts with them, that run any code, publish, or
    /// touch credentials.
    static let refusedCommands: Set<String> = [
        "gh api", "gh auth", "gh secret", "gh repo delete", "gh release delete", "npm publish", "npm exec", "pnpm exec",
        "pnpm dlx", "yarn dlx", "bun x", "uv run", "uv tool", "go run", "docker run", "cargo publish"
    ]

    /// An allow line for a program and its subcommand, an MCP tool or a
    /// domain asked about outside auto mode; an `autoMode.environment` line
    /// for a domain auto mode asked about. Nothing for a program alone
    /// (`aws` stands for `aws s3 rm` too), a target Nirux couldn't name, a
    /// file tool, or a question.
    static func proposal(for group: Group) -> ClaudeSpaceSettings.Line? {
        guard group.count >= minimumPrompts else { return nil }
        if AgentToolInput.shellTools.contains(group.tool) {
            let words = group.target?.split(separator: " ").map(String.init) ?? []
            guard let program = group.target, let first = words.first, words.count > 1, !refused.contains(first),
                  !words.dropFirst().contains(where: { runners.contains($0) || runningSubcommands.contains($0) }),
                  AgentShellCommand.namesWholeCommand(program),
                  first != "git" || words.count > 1 && !refusedGit.contains(words[1]),
                  !refusedCommands.contains(where: { program == $0 || program.hasPrefix($0 + " ") })
            else { return nil }
            return .allow("\(group.tool)(\(program):*)")
        }
        if group.tool == "WebFetch", let domain = group.target {
            return group.autoOnly ? .environment("**Trusted domain**: \(domain)") : .allow("WebFetch(domain:\(domain))")
        }
        if group.tool.hasPrefix("mcp__") { return .allow(group.tool) }
        return nil
    }
}
