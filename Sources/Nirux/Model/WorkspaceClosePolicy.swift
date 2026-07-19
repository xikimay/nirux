import Foundation

/// Pure decision logic for the sidebar "Close Workspace" action. Closing
/// kills live PTY/agent sessions, so anything beyond a plain single-column
/// shell asks for confirmation first.
enum WorkspaceClosePolicy {
    struct Context: Equatable {
        var totalWorkspaceCount: Int
        var columnCount: Int
        /// Any column whose agent is working or needs attention.
        var hasBusyAgent: Bool
        /// Workspace cwd is a linked git worktree checkout.
        var isWorktreeBacked: Bool
    }

    enum Decision: Equatable {
        /// Last remaining workspace — closing is not allowed.
        case blocked
        /// Plain empty-shell workspace — close without ceremony.
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
        if context.hasBusyAgent {
            details.append("An agent is still running — closing the workspace ends its session.")
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
}
