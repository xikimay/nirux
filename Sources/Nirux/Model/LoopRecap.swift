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
        /// The prompts a line naming the target covers exactly.
        var exactCount = 0

        var isQuestion: Bool { tool == LoopRecap.questionTool }
        var proposal: ClaudeSpaceSettings.Line? { LoopRecap.proposal(for: self) }
    }

    /// Since `since`, the most frequent first.
    static func groups(_ entries: [LoopLog.Entry], since: TimeInterval) -> [Group] {
        var groups: [Group] = []
        for entry in entries where entry.time >= since {
            // A question is a question, whatever it asks.
            let target = entry.tool == questionTool ? nil : entry.target
            let exact = entry.exact == true ? 1 : 0
            if let index = groups.firstIndex(where: { $0.tool == entry.tool && $0.target == target }) {
                groups[index].count += 1
                groups[index].exactCount += exact
                groups[index].autoOnly = groups[index].autoOnly && entry.mode == "auto"
            } else {
                groups.append(Group(tool: entry.tool, target: target, count: 1, autoOnly: entry.mode == "auto", exactCount: exact))
            }
        }
        return groups.sorted { ($0.count, $1.tool, $1.target ?? "") > ($1.count, $0.tool, $0.target ?? "") }
    }

    /// What a line may allow: commands that read, build or test, which
    /// Nirux knows run nothing else. Anything else keeps asking.
    static let proposable: Set<String> = [
        "git status", "git diff", "git log", "git show", "git blame", "git grep", "git ls-files", "git rev-parse",
        "git describe", "git fetch",
        "swift build", "swift test", "cargo build", "cargo test", "cargo check", "go build", "go test", "go vet",
        "npm test", "pnpm test", "yarn test", "make build", "make test", "make lint", "make check",
        "gh pr view", "gh pr list", "gh pr checks", "gh pr diff", "gh pr status", "gh run view", "gh run list",
        "gh run watch", "gh issue view", "gh issue list", "gh repo view",
        "xcrun simctl list"
    ]
    /// A package's own scripts: `npm run build`.
    static let proposableScripts: Set<String> = ["npm run", "pnpm run", "yarn run"]

    static func isProposable(_ family: String) -> Bool {
        if proposable.contains(family) { return true }
        let words = family.split(separator: " ")
        return words.count == 3 && proposableScripts.contains(words.prefix(2).joined(separator: " "))
    }

    /// An allow line for a known-safe command or a domain asked about
    /// outside auto mode; an `autoMode.environment` line for a domain auto
    /// mode asked about. Each needs `minimumPrompts` prompts it covers
    /// exactly (`LoopLog.Entry.exact`). Nothing for anything else: MCP
    /// tools, file tools, questions.
    static func proposal(for group: Group) -> ClaudeSpaceSettings.Line? {
        guard group.exactCount >= minimumPrompts, let target = group.target else { return nil }
        if AgentToolInput.shellTools.contains(group.tool) {
            return isProposable(target) ? .allow("\(group.tool)(\(target):*)") : nil
        }
        if group.tool == "WebFetch" {
            return group.autoOnly ? .environment("**Trusted domain**: \(target)") : .allow("WebFetch(domain:\(target))")
        }
        return nil
    }
}
