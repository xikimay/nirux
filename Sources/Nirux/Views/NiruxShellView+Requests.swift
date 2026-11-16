import AppKit

/// The requests of agents waiting for the user, as the glass interface's
/// inbox and the rail's callout show them (docs/design/glass-interface.md,
/// step 3.3), and where they are open.
@MainActor
final class RequestsState {
    /// A Mission child's question handed to the user, by its column: ⌘J and
    /// the inbox count it as a wait.
    struct HandedOff: Equatable {
        let workspaceID: String
        let question: SidebarMissionQuestion
    }

    /// The requests at the last refresh, in ⌘J's order, the column on
    /// screen left out: the inbox's list and the command bar's count.
    var requests: [WaitingRequest] = []
    var handedOff: [UUID: HandedOff] = [:]
    var inbox: RequestInboxView?
    var inboxPanel: RequestPanel?
    var callout: RequestCalloutView?
    var calloutPanel: RequestPanel?
    /// The task whose request the callout shows, and the icon it sits by.
    var calloutTaskID: String?
    weak var calloutAnchor: NSView?
    var calloutScrollObserver: NSObjectProtocol?

    var isInboxOpen: Bool { inboxPanel?.isOpen == true }
    var isCalloutOpen: Bool { calloutPanel?.isOpen == true }
}

// MARK: - The requests

extension NiruxShellView {
    /// ⌘J's queue (`WaitingAgentQueue`): the agents blocked on the user in
    /// every space, and the Mission questions handed to the user (amber on
    /// the rail, "Needs you" on the row), in its order.
    func waitingQueue(snapshot: ProcessSnapshot, now: TimeInterval) -> [WaitingAgent] {
        let open = workspaces.filter { !$0.isClosing }
        var agents = open.flatMap { workspace in
            workspace.columns.compactMap { column in
                quickSwitch.agentWait(column, snapshot, now).map { WaitingAgent(workspaceID: workspace.id, columnID: column.id, wait: $0) }
            }
        }
        // An agent waiting on the user's answer already (a permission, a
        // dialog) asks that first; one stopped on an error still has its
        // question for the user.
        let asking = Set(agents.filter { $0.wait.reason.signal == .waiting }.map(\.columnID))
        let columns = Set(open.flatMap { $0.columns.filter { !$0.isClosing }.map(\.id) })
        agents += requestsState.handedOff
            .filter { !asking.contains($0.key) && columns.contains($0.key) }
            .sorted { ($0.value.question.askedAt, $0.key.uuidString) < ($1.value.question.askedAt, $1.key.uuidString) }
            .map { columnID, handed in
                WaitingAgent(
                    workspaceID: handed.workspaceID, columnID: columnID,
                    wait: Self.handedOffWait(handed.question)
                )
            }
        return WaitingAgentQueue.ordered(agents)
    }

    /// The wait a Mission question handed to the user stands for in ⌘J's
    /// queue.
    static func handedOffWait(_ question: SidebarMissionQuestion) -> AgentWait {
        AgentWait(reason: .question(question.text), since: question.askedAt)
    }

    /// Of ⌘J's queue, what waits for the user's answer (amber: not an
    /// agent stopped on an error or exited, which ⌘J also visits), leaving
    /// out the column on screen, where ⌘J never goes: the inbox's requests
    /// and the command bar's count.
    static func requestedAgents(in queue: [WaitingAgent], onScreen: UUID?) -> [WaitingAgent] {
        queue.filter { $0.columnID != onScreen && $0.wait.reason.signal == .waiting }
    }

    /// The Mission questions handed to the user, by column (see
    /// `missionQuestions`).
    func handedOffQuestions(_ questions: [ObjectIdentifier: SidebarMissionQuestion]) -> [UUID: RequestsState.HandedOff] {
        var handed: [UUID: RequestsState.HandedOff] = [:]
        for workspace in workspaces {
            for column in workspace.columns {
                guard let question = questions[ObjectIdentifier(column)], question.handOff != nil, !question.isAnswered else { continue }
                handed[column.id] = RequestsState.HandedOff(workspaceID: workspace.id, question: question)
            }
        }
        return handed
    }

    /// The request each agent of `agents` makes, from what the rows read
    /// for it: its permission, the question its turn ended on, its dialog,
    /// its Mission question.
    func waitingRequests(
        _ agents: [WaitingAgent], approvalHolds: [ObjectIdentifier: PermissionApprovalHold],
        foregroundProcesses: [ObjectIdentifier: ForegroundProcess]
    ) -> [WaitingRequest] {
        agents.compactMap { agent in
            guard let workspace = workspaces.first(where: { $0.id == agent.workspaceID && !$0.isClosing }),
                  let column = workspace.columns.first(where: { $0.id == agent.columnID && !$0.isClosing }) else { return nil }
            let foreground = foregroundProcesses[ObjectIdentifier(column)]
            let approval = sidebarApproval(for: column, hold: approvalHolds[ObjectIdentifier(column)])
            // The question's own entry, not a wait of the agent's.
            let handed = requestsState.handedOff[column.id].map(\.question).flatMap { agent.wait == Self.handedOffWait($0) ? $0 : nil }
            let kind = Self.requestKind(
                mission: handed, approval: approval,
                turnQuestion: Self.sidebarTurnQuestion(of: column, status: column.pty?.cachedAgentState ?? .idle, foreground: foreground),
                dialog: column.pty?.agentVisibleDialog(foreground: foreground)?.dialog, reason: agent.wait.reason
            )
            return WaitingRequest(
                taskID: workspace.id, columnID: column.id, taskTitle: workspace.title,
                icon: StateIcon(.needsYou(approval != nil ? .command : StateIcon.Reason(agent.wait.reason) ?? .question)),
                waited: SidebarView.cardAge(since: agent.wait.since), kind: kind
            )
        }
    }

    /// What a waiting column asks, the first that holds: a Mission question
    /// handed to the user, a permission the rows can answer, the question
    /// its turn ended on, a question dialog; else a prompt only the terminal
    /// answers (a folder's trust, a permission with approvals off).
    static func requestKind(
        mission: SidebarMissionQuestion?, approval: SidebarPermissionApproval?, turnQuestion: SidebarTurnQuestion?,
        dialog: AgentDialog?, reason: AgentAttentionReason
    ) -> WaitingRequest.Kind {
        if let mission { return .mission(mission) }
        if let approval { return .permission(approval) }
        if let turnQuestion { return .question(turnQuestion) }
        if let dialog, let first = dialog.questions.first { return .dialog(question: first.text, more: dialog.questions.count - 1) }
        switch reason {
        case .permission(let tool, let summary):
            let text = [tool, summary].compactMap { $0 }.joined(separator: ": ")
            return .terminal(text.isEmpty ? "A permission" : text)
        case .question(let text), .askedInReply(let text), .message(let text):
            return .terminal(text ?? "A question")
        default:
            return .terminal("Answer in the terminal")
        }
    }
}
