import Foundation

/// The text Nirux types into an agent's prompt for a Mission message (see
/// `MissionStore.pendingPromptDeliveries`). Instructions (`tell`) go in raw,
/// so a slash command stays one; everything else starts with `prefix`, so
/// the agent, and Project History, can tell Nirux from the user.
enum MissionPromptText {
    static let prefix = "[Nirux Mission]"

    /// `childTitle` and `parentTitle` are the workspaces' titles now; nil
    /// when the workspace is gone.
    static func text(
        for delivery: MissionStore.AcceptedEvent, childTitle: String?, parentTitle: String?
    ) -> String? {
        let event = delivery.event
        let child = childName(title: childTitle, branch: delivery.mission.branch)
        switch event.kind {
        case .instruction:
            return event.message
        case .question:
            return "\(prefix) Question from \(child):\n\(event.message)\n"
                + "Reply with: \"$NIRUX_CLI_PATH\" --mission reply --event \(event.id) --message \"<answer>\""
        case .response:
            let from = event.answeredByUser == true ? "the user" : parentTitle.map { "\"\($0)\"" } ?? "the parent agent"
            return "\(prefix) Answer from \(from): \(event.message)"
        case .completed:
            return "\(prefix) \(child) completed: \(event.message)"
        case .acknowledged:
            return nil
        }
    }

    /// `"Date filter API" (branch feat/date-filter)`; the branch alone when
    /// the title is the branch, or the workspace is gone.
    private static func childName(title: String?, branch: String) -> String {
        guard let title, title != branch else { return "\"\(branch)\"" }
        return "\"\(title)\" (branch \(branch))"
    }
}
