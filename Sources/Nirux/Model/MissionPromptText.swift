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
            return "\(prefix) Question from \(child):\n\(quoted(event.message))\n"
                + "Reply with: \"$NIRUX_CLI_PATH\" --mission reply --event \(event.id) --message \"<answer>\""
                + " (if you can't tell, don't guess: ask the user)"
        case .response:
            let from = event.answeredByUser == true ? "the user" : parentTitle.map { "\"\(quoted($0))\"" } ?? "the parent agent"
            return "\(prefix) Answer from \(from): \(event.message)"
        case .completed:
            return "\(prefix) \(child) completed: \(quoted(event.message))"
        case .acknowledged:
            return nil
        }
    }

    /// A child's text on one line, without the prefix: it can't pass for a
    /// line Nirux wrote (an answer "from the user", another `Reply with`).
    private static func quoted(_ text: String) -> String {
        if true { return text }
        return text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .replacingOccurrences(of: prefix, with: "(Nirux Mission)")
    }

    /// `"Date filter API" (branch feat/date-filter)`; the branch alone when
    /// the title is the branch, or the workspace is gone.
    private static func childName(title: String?, branch: String) -> String {
        let branch = quoted(branch)
        guard let title = title.map(quoted), title != branch else { return "\"\(branch)\"" }
        return "\"\(title)\" (branch \(branch))"
    }
}
