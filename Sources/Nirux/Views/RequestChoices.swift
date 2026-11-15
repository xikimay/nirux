import AppKit

/// What a click on an agent's request answers, wherever the request shows:
/// a row's block in the sidebar, the glass interface's inbox and the rail's
/// callout (docs/design/glass-interface.md). `RequestChoices` gives each
/// request its buttons, their words and their order, and the words that
/// stand in for them, so the three never disagree; every answer reaches the
/// receiver the rows use.
enum RequestChoice: Hashable {
    case permission(PermissionApproval.Behavior)
    case turn(SidebarTurnAnswer)
    /// A task agent's question (Missions): the reply panel.
    case missionReply

    /// Names the answer in arming keys.
    var key: String {
        switch self {
        case .permission(let behavior): return "permission.\(behavior.rawValue)"
        case .turn(let answer): return "turn.\(answer.rawValue)"
        case .missionReply: return "missionReply"
        }
    }
}

/// One answer's button.
struct RequestButton: Equatable {
    enum Role: Equatable {
        case primary, secondary, quiet
    }

    let choice: RequestChoice
    let title: String
    /// What VoiceOver says: the answer and what it answers.
    let accessibilityLabel: String
    let role: Role
    var toolTip: String?
}

enum RequestChoices {
    /// "wants to run" for a command, "wants WebFetch" for another tool:
    /// short, so that the tool's name survives a long agent name.
    static func permissionVerb(toolName: String) -> String {
        toolName == "Bash" ? "wants to run" : "wants \(toolName)"
    }

    /// Deny, then Allow: macOS order, the approving action last.
    static func permission(_ approval: SidebarPermissionApproval) -> [RequestButton] {
        let description = "\(approval.toolName): \(approval.text)"
        return [
            RequestButton(choice: .permission(.deny), title: "Deny", accessibilityLabel: "Deny \(description)", role: .secondary),
            RequestButton(choice: .permission(.allow), title: "Allow", accessibilityLabel: "Allow once \(description)", role: .primary),
        ]
    }

    /// What stands in for the buttons while a decision travels or after it
    /// failed; nil while the request is open.
    static func permissionStatus(_ display: PermissionApprovalTicket.Display) -> String? {
        switch display {
        case .open: return nil
        case .sending(let behavior): return behavior == .allow ? "Allowing…" : "Denying…"
        case .undelivered: return "Not delivered — answer in the terminal"
        }
    }

    /// Reply…, then No and Yes for a yes-or-no question, Yes last.
    static func turn(_ question: SidebarTurnQuestion) -> [RequestButton] {
        var buttons = [
            RequestButton(choice: .turn(.reply), title: "Reply…", accessibilityLabel: "Reply to: \(question.text)", role: .secondary),
        ]
        if question.isYesNo {
            buttons.append(RequestButton(
                choice: .turn(.no), title: "No", accessibilityLabel: "Answer no to: \(question.text)", role: .secondary
            ))
            buttons.append(RequestButton(
                choice: .turn(.yes), title: "Yes", accessibilityLabel: "Answer yes to: \(question.text)", role: .primary
            ))
        }
        return buttons
    }

    /// Answers nothing: the question leaves the row; the agent still waits
    /// at its prompt.
    static func dismiss(_ question: SidebarTurnQuestion) -> RequestButton {
        RequestButton(
            choice: .turn(.dismiss), title: "Dismiss", accessibilityLabel: "Dismiss this question without answering it",
            role: .quiet, toolTip: "Take this question off the row without answering it. Claude still waits at its prompt."
        )
    }

    static func missionReply(_ question: SidebarMissionQuestion) -> RequestButton {
        RequestButton(choice: .missionReply, title: "Reply…", accessibilityLabel: "Reply to: \(question.text)", role: .secondary)
    }
}

/// The rows' arming (`SidebarApprovalButtonArming`) for the glass
/// interface's requests: an answer's button takes a click only once it has
/// sat at the same place for `SidebarView.approvalArmingDelay`, so that a
/// request that arrives, moves up or takes another's place never takes a
/// click aimed at what was there.
@MainActor
final class RequestArming {
    private var arming: [String: SidebarApprovalButtonArming] = [:]
    private let now: () -> TimeInterval

    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
    }

    /// After a layout: every answer's button by key, in its container's
    /// coordinates.
    func refresh(_ frames: [String: NSRect]) {
        arming = SidebarApprovalButtonArming.rearmed(arming, frames: frames, now: now())
    }

    /// The list scrolled under a still pointer.
    func restartAll() {
        arming = SidebarApprovalButtonArming.restarted(arming, now: now())
    }

    func isArmed(_ key: String) -> Bool {
        arming[key].map { now() >= $0.armedAt } ?? false
    }
}
