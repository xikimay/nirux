import Foundation

/// One line of a Claude Code transcript as the project history journal
/// reads it (docs/project-memory-tree.md): what the user typed and what
/// Claude answered, as transcript search reads them
/// (`TranscriptSearch.message(in:)`), plus what another session sent and
/// where a turn of Claude's tool loop went.
///
/// The format is Claude Code's own and may change. Lines that don't parse,
/// or don't look like this, are skipped.
enum TranscriptLine {
    /// What the journal keeps of a line.
    enum Entry: Equatable, Sendable {
        /// What the user typed: a prompt, a prompt queued while Claude
        /// worked, the arguments of a slash command.
        case user(text: String, date: Date?)
        /// A message another session sent this one (`origin.kind` "peer",
        /// not a subagent's hand-back), and who sent it.
        case peer(text: String, from: String?, date: Date?)
        /// The text parts of an assistant line without a tool call.
        case assistantText(text: String, date: Date?)
        /// An assistant line calling a tool: text before it isn't a reply.
        case toolUse
        /// A line that starts a turn without being a message: a subagent's
        /// report, a background task's notification, a scheduled prompt.
        case turnStart
        /// Claude Code's mark that a turn is over (`turn_duration`,
        /// `stop_hook_summary`).
        case turnEnd
        /// An API error ended the turn: it has no reply.
        case apiError
    }

    /// Lines a fork copied from its parent (`/branch`, `--fork-session`):
    /// the parent's transcript already holds them.
    static func isForkedCopy(_ object: [String: Any]) -> Bool {
        object["forkedFrom"] != nil
    }

    /// The journal's view of a line, or nil for anything it skips.
    static func entry(_ object: [String: Any]) -> Entry? {
        guard object["isSidechain"] as? Bool != true, !isForkedCopy(object) else { return nil }
        let date = self.date(object["timestamp"])
        switch object["type"] as? String {
        case "user":
            if let origin = object["origin"] as? [String: Any], let entry = fromOrigin(origin, date: date) {
                return entry
            }
            if let message = message(object), message.role == .user {
                return .user(text: message.text, date: message.timestamp)
            }
            // A turn started by something else: /loop, a scheduled task, an
            // origin this build doesn't know.
            let content = (object["message"] as? [String: Any])?["content"]
            let isToolResult = (content as? [[String: Any]])?.contains { $0["type"] as? String == "tool_result" } ?? false
            return !isToolResult && (object["turnOrigin"] != nil || object["origin"] != nil) ? .turnStart : nil
        case "assistant":
            if object["isApiErrorMessage"] as? Bool == true { return .apiError }
            let message = object["message"] as? [String: Any]
            // Claude Code's own stand-in ("No response requested."), not Claude's.
            guard !isSkipped(object), message?["model"] as? String != "<synthetic>" else { return nil }
            if let parts = message?["content"] as? [[String: Any]], parts.contains(where: { $0["type"] as? String == "tool_use" }) {
                return .toolUse
            }
            guard let text = self.message(object) else { return nil }
            return .assistantText(text: text.text, date: text.timestamp)
        case "attachment":
            // A prompt queued while Claude worked: the user's, another
            // session's, or a report.
            if let attachment = object["attachment"] as? [String: Any], attachment["type"] as? String == "queued_command",
               let origin = attachment["origin"] as? [String: Any],
               let entry = fromOrigin(origin, date: self.date(attachment["timestamp"] ?? object["timestamp"])) {
                return entry
            }
            guard let message = message(object) else { return nil }
            return .user(text: message.text, date: message.timestamp)
        case "system":
            let subtype = object["subtype"] as? String
            return subtype == "turn_duration" || subtype == "stop_hook_summary" ? .turnEnd : nil
        default:
            return nil
        }
    }

    /// Claude Code's own stand-in reply ("No response requested."): it ends
    /// a turn as a final answer would, but isn't Claude's.
    static func isStandIn(_ object: [String: Any]) -> Bool {
        object["type"] as? String == "assistant"
            && (object["message"] as? [String: Any])?["model"] as? String == "<synthetic>"
    }

    /// A line whose `origin` isn't the human's: another session's message,
    /// a subagent's report (it carries the task it answers), a task's
    /// notification. Nil for the human's, which the message decides.
    private static func fromOrigin(_ origin: [String: Any], date: Date?) -> Entry? {
        switch origin["kind"] as? String {
        case "peer":
            if origin["senderTaskId"] != nil || origin["handback"] != nil { return .turnStart }
            guard let body = (origin["body"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !body.isEmpty else { return .turnStart }
            return .peer(text: body, from: (origin["name"] as? String) ?? (origin["from"] as? String), date: date)
        case "human", nil:
            return nil
        default:
            return .turnStart
        }
    }

    /// The text a conversation shows of this line, as transcript search
    /// reads it: a prompt the user typed, or Claude's answer.
    static func message(_ object: [String: Any]) -> (role: TranscriptSearch.Role, text: String, timestamp: Date?)? {
        TranscriptSearch.message(in: object).map { ($0.role, $0.text, $0.timestamp) }
    }

    /// Lines no reader shows: subagents, harness-only lines, summaries.
    private static func isSkipped(_ object: [String: Any]) -> Bool {
        ["isSidechain", "isMeta", "isCompactSummary", "isVisibleInTranscriptOnly", "isApiErrorMessage"]
            .contains { object[$0] as? Bool == true }
    }

    /// Claude writes milliseconds; a date without them still reads.
    private static let dateStyles = [
        Date.ISO8601FormatStyle(includingFractionalSeconds: true), Date.ISO8601FormatStyle()
    ]

    private static func date(_ value: Any?) -> Date? {
        (value as? String).flatMap { text in dateStyles.lazy.compactMap { try? $0.parse(text) }.first }
    }
}
