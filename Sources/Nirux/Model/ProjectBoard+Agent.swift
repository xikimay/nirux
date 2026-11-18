import Foundation

// MARK: - What an agent does, as the merge queue and the Board's rows read it

extension ProjectBoard {
    /// What one agent column does, or a row's most urgent agent column
    /// (docs/design/project-board.md, section 2).
    enum AgentState: Equatable, Sendable {
        /// No agent in the column (or no workspace in the row).
        case none
        /// At its prompt: a finished turn reads "idle", not "done", since a
        /// workspace is done when its pull request is merged or closed.
        case idle
        /// In a turn, for how long ("12m") when known.
        case working(duration: String?)
        /// A dialog (permission, question) waits on the user.
        case waiting(AgentAttentionReason)
        /// A dialog has waited past the stuck-agent threshold.
        case waitingLong(AgentAttentionReason, duration: String)
        /// A turn waits on the model with no sign of life, for how long.
        case silent(duration: String)
        /// The agent died in the middle of a turn.
        case exitedMidTurn(processName: String)
        /// The turn ended on an API error; `resume` says whether Resume may
        /// type `continue`.
        case stoppedOnError(kind: String?, resume: SidebarStuckState.Resume)

        /// Failures first: nothing moves them but the user. Then the
        /// dialogs, the work, the prompt.
        var urgency: Int {
            switch self {
            case .none: return 0
            case .idle: return 1
            case .working: return 2
            case .waiting: return 3
            case .waitingLong: return 4
            case .silent: return 5
            case .exitedMidTurn: return 6
            case .stoppedOnError: return 7
            }
        }

    }

    /// An agent column's state and where it is: Focus goes to it, Resume
    /// types into it.
    struct Agent: Equatable {
        var state: AgentState = .none
        var workspaceID: String?
        var columnID: UUID?
        /// The failed turn a Resume click answers (`stoppedOnError`).
        var failedAt: TimeInterval?

        /// Where Focus goes, as the table's Focus went: this agent's
        /// workspace and column while an agent is there, else the first of
        /// `workspaces` (by id), at no column in particular.
        func focusTarget(workspaces: [String]) -> (workspaceID: String, columnID: UUID?)? {
            if let workspaceID, state != .none { return (workspaceID, columnID) }
            return workspaces.first.map { ($0, nil) }
        }

        /// The first of the most urgent, or `.none`.
        static func mostUrgent(_ agents: [Agent]) -> Agent {
            agents.reduce(Agent()) { best, agent in agent.state.urgency > best.state.urgency ? agent : best }
        }
    }

    /// One column's state:
    /// - a stuck state (#55) as the sidebar reads it wins;
    /// - "waiting" needs the dialog the agent in front shows
    ///   (`AgentStatusMachine.visibleDialog`: open, its own, not answered
    ///   by a key since) and a status other than `.working`: an approved dialog
    ///   stays pending until its tool ends, while the column reads
    ///   `.working`, and an agent that died without ending its session
    ///   leaves its dialogs behind;
    /// - then `.working`, else idle. The status alone can't tell waiting
    ///   from idle: a focused column reads `.idle` with its dialog open, an
    ///   unfocused one that finished its turn reads `.needsAttention`.
    static func agentState(
        stuck: SidebarStuckState?,
        hasAgent: Bool,
        agentInFront: Bool,
        status: AgentStatus,
        openDialog: AgentAttentionReason?,
        workingFor: String? = nil
    ) -> AgentState {
        switch stuck {
        case .waiting(let reason, let duration)?:
            return .waitingLong(reason, duration: duration)
        case .stoppedOnError(let kind, _, _, let resume)?:
            return .stoppedOnError(kind: kind, resume: resume)
        case .exitedMidTurn(let processName)?:
            return .exitedMidTurn(processName: processName)
        case .silent(let duration, _, _)?:
            return .silent(duration: duration)
        case nil:
            break
        }
        guard hasAgent || agentInFront else { return .none }
        if agentInFront, status != .working, let openDialog { return .waiting(openDialog) }
        if status == .working { return .working(duration: workingFor) }
        return .idle
    }
}
