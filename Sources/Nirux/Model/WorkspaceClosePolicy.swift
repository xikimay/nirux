import Foundation

/// Pure decision logic for the close paths that kill live PTY sessions:
/// ⌘W on a column, ⌘W on a workspace's last column, and the sidebar's
/// Close Column / Close Workspace items. A live agent — working, waiting,
/// or idle at its prompt — is never killed without confirmation; a bare
/// shell closes without ceremony.
enum WorkspaceClosePolicy {
    /// A recognized agent process (`AgentStatusMachine.isRecognizedAgentProcess`)
    /// that closing would kill.
    struct LiveAgent: Equatable {
        /// Process name, e.g. "claude".
        var processName: String
        /// nil when the status can't be trusted — the alert then only says
        /// the agent is running.
        var status: AgentStatus?

        var displayName: String {
            switch processName {
            case "claude": return "Claude"
            case "codex": return "Codex"
            case "gemini": return "Gemini"
            case "opencode": return "OpenCode"
            default: return processName
            }
        }

        var statusDescription: String {
            switch status {
            case .working: return "working"
            case .needsAttention: return "waiting for you"
            case .idle: return "idle"
            case nil: return "running"
            }
        }
    }

    struct Context: Equatable {
        var totalWorkspaceCount: Int
        var columnCount: Int
        /// Agents in the workspace's columns, any status.
        var liveAgents: [LiveAgent]
        /// Workspace cwd is a linked git worktree checkout.
        var isWorktreeBacked: Bool
    }

    enum Decision: Equatable {
        /// Last remaining workspace — closing is not allowed.
        case blocked
        /// No agent session or other column at stake — close without ceremony.
        case close
        /// Ask first; `details` are the informative lines for the alert.
        case confirm(details: [String])
    }

    /// The `closeWorkspace(at:)` guard (fed the remaining count), also used
    /// to disable the sidebar's Close Workspace item.
    static func canClose(totalWorkspaceCount: Int) -> Bool {
        totalWorkspaceCount > 1
    }

    static func decision(for context: Context) -> Decision {
        guard canClose(totalWorkspaceCount: context.totalWorkspaceCount) else { return .blocked }
        var details: [String] = []
        if !context.liveAgents.isEmpty {
            details.append(agentDetail(context.liveAgents, closing: "workspace"))
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

    /// Closing one column of a workspace that keeps other columns: the
    /// alert lines, or nil to close without asking. The last column closes
    /// the workspace instead — see `decision(for:)`.
    static func columnConfirmation(for agent: LiveAgent?) -> [String]? {
        agent.map { [agentDetail([$0], closing: "column")] }
    }

    static func agentDetail(_ agents: [LiveAgent], closing target: String) -> String {
        if agents.count == 1 {
            let agent = agents[0]
            return "\(agent.displayName) is \(agent.statusDescription) — closing the \(target) ends its session."
        }
        let list = agents.map { "\($0.displayName) \($0.statusDescription)" }.joined(separator: ", ")
        return "\(agents.count) agents are running (\(list)) — closing the \(target) ends their sessions."
    }
}

extension WorkspaceClosePolicy.LiveAgent {
    /// Status from the agent's status machine. Idle is only trusted when
    /// Claude's hooks drive it: the output-activity fallback (Codex,
    /// hook-less Claude, Gemini, OpenCode) reads idle until the first
    /// keystroke — an agent launched with a handover prompt works while
    /// showing idle — and through silent tool calls.
    init(processName: String, machineStatus: AgentStatus, hookKind: String?) {
        let hookDriven = processName == "claude" && hookKind == "claude"
        self.init(processName: processName, status: machineStatus == .idle && !hookDriven ? nil : machineStatus)
    }
}
