import Foundation

/// Pure decision logic for the close paths that kill live PTY sessions:
/// ⌘W on a column, ⌘W on a workspace's last column, and the sidebar's
/// Close Column / Close Workspace items. A live agent — working, waiting,
/// or idle at its prompt — is never killed without confirmation; a bare
/// shell closes without ceremony.
enum WorkspaceClosePolicy {
    /// A recognized agent process (claude/codex) in a column's foreground.
    struct LiveAgent: Equatable {
        /// Foreground process name, e.g. "claude".
        var processName: String
        var status: AgentStatus

        var displayName: String {
            switch processName {
            case "claude": return "Claude"
            case "codex": return "Codex"
            default: return processName
            }
        }

        fileprivate var statusDescription: String {
            switch status {
            case .working: return "working"
            case .needsAttention: return "waiting for you"
            case .idle: return "idle"
            }
        }
    }

    struct Context: Equatable {
        var totalWorkspaceCount: Int
        var columnCount: Int
        /// Agents in the foreground of the workspace's columns, any status.
        var liveAgents: [LiveAgent]
        /// Workspace cwd is a linked git worktree checkout.
        var isWorktreeBacked: Bool
    }

    enum Decision: Equatable {
        /// Last remaining workspace — closing is not allowed.
        case blocked
        /// Nothing live would be lost — close without ceremony.
        case close
        /// Ask first; `details` are the informative lines for the alert.
        case confirm(details: [String])
    }

    /// Mirror of the `closeWorkspace(at:)` guard, used to disable the menu item.
    static func canClose(totalWorkspaceCount: Int) -> Bool {
        totalWorkspaceCount > 1
    }

    static func decision(for context: Context) -> Decision {
        guard canClose(totalWorkspaceCount: context.totalWorkspaceCount) else { return .blocked }
        var details: [String] = []
        if let agentLine = agentDetail(context.liveAgents, closing: "workspace") {
            details.append(agentLine)
        }
        if context.columnCount > 1 {
            details.append("All \(context.columnCount) columns will be closed.")
        }
        guard !details.isEmpty else { return .close }
        if context.isWorktreeBacked {
            details.append("The git worktree stays on disk.")
        }
        return .confirm(details: details)
    }

    /// Closing one column of a workspace that keeps other columns. The
    /// last column closes the workspace instead — see `decision(for:)`.
    static func columnDecision(agent: LiveAgent?) -> Decision {
        guard let agent, let agentLine = agentDetail([agent], closing: "column") else { return .close }
        return .confirm(details: [agentLine])
    }

    private static func agentDetail(_ agents: [LiveAgent], closing target: String) -> String? {
        switch agents.count {
        case 0:
            return nil
        case 1:
            let agent = agents[0]
            return "\(agent.displayName) is \(agent.statusDescription) — closing the \(target) ends its session."
        default:
            let list = agents.map { "\($0.displayName) \($0.statusDescription)" }.joined(separator: ", ")
            return "\(agents.count) agents are running (\(list)) — closing the \(target) ends their sessions."
        }
    }
}
