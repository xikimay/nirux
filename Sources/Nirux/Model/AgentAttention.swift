import CryptoKit
import Foundation

/// Why an agent waits on the user — the "why" behind `.needsAttention`.
enum AgentAttentionReason: Hashable, Sendable {
    /// A tool call waits for the user's approval: the tool and a short,
    /// cleaned excerpt of what it would do. Both nil when only the delayed
    /// `permission_prompt` notification reported it (its message then
    /// stands in as the summary).
    case permission(tool: String?, summary: String?)
    /// A dialog asks the user something (AskUserQuestion, an MCP
    /// elicitation form).
    case question(String?)
    /// The turn is over: the agent waits for the next prompt.
    case turnFinished
    /// Any other notification, with its message.
    case message(String?)

    /// A dialog is open in the terminal: typed input answers it rather
    /// than reaching the prompt.
    var isBlockingDialog: Bool {
        switch self {
        case .permission, .question: return true
        case .turnFinished, .message: return false
        }
    }

    /// Plan approval goes through the permission flow as a tool call.
    private var isPlanApproval: Bool {
        if case .permission(let tool, _) = self { return tool == "ExitPlanMode" }
        return false
    }

    /// Compact label for sidebar rows: "permission · Bash", "question".
    var shortLabel: String {
        switch self {
        case .permission(let tool, _):
            if isPlanApproval { return "plan approval" }
            return tool.map { "permission · \($0)" } ?? "permission"
        case .question: return "question"
        case .turnFinished: return "done"
        case .message: return "needs you"
        }
    }

    /// Completes "<agent> …" in a notification title.
    var headline: String {
        switch self {
        case .permission: return isPlanApproval ? "needs plan approval" : "needs permission"
        case .question: return "has a question"
        case .turnFinished: return "finished its turn"
        case .message: return "needs you"
        }
    }

    /// One line of specifics (notification body, tooltips): the tool and
    /// its excerpt, the question, the message.
    var detailLine: String? {
        switch self {
        case .permission(let tool, let summary):
            if isPlanApproval { return summary }
            switch (tool, summary) {
            case let (tool?, summary?): return "\(tool): \(summary)"
            case let (tool?, nil): return tool
            case let (nil, summary): return summary
            }
        case .question(let text), .message(let text): return text
        case .turnFinished: return nil
        }
    }

    /// Activity feed summary.
    var activitySummary: String {
        switch self {
        case .permission(let tool, let summary):
            if isPlanApproval { return "plan approval" }
            let head = tool.map { "permission: \($0)" } ?? "permission"
            return [head, summary].compactMap { $0 }.joined(separator: " · ")
        case .question(let text): return "question: \(text ?? "needs input")"
        case .turnFinished: return "turn finished"
        case .message(let text): return text ?? "needs input"
        }
    }
}

/// A permission (or question) dialog Claude may be showing. Recorded from
/// PermissionRequest (or, when that hook never fired, from the delayed
/// `permission_prompt` notification) and dropped once hooks prove the
/// dialog closed. The follow-up "approve from the sidebar" work builds on
/// these details.
struct AgentPermissionRequest: Hashable, Sendable {
    let toolName: String?
    let summary: String?
    /// Identifies the tool call across PermissionRequest (which carries no
    /// tool_use_id) and its PostToolUse / PostToolUseFailure. Nil for a
    /// request only a notification reported: nothing can match it then.
    let key: String?
    /// Subagent that asked; nil on the main thread.
    let agentID: String?
    /// Claude session that asked: a teammate's turn ending closes nothing
    /// of the lead's.
    let sessionID: String?
    /// Epoch seconds.
    let requestedAt: TimeInterval
    /// A question (AskUserQuestion, an MCP elicitation form) rather than an
    /// approval.
    let isQuestion: Bool
    /// A later tool event from the same agent suggests the dialog was
    /// answered (a denial fires no hook). Only the column's status trusts
    /// that; the Telegram gate waits for proof.
    var mayBeAnswered = false
    /// The hook receiver waits for a sidebar decision on this request.
    var approval: PermissionApprovalTicket?

    init(
        toolName: String?,
        summary: String?,
        key: String?,
        agentID: String?,
        sessionID: String?,
        requestedAt: TimeInterval,
        isQuestion: Bool? = nil
    ) {
        self.toolName = toolName
        self.summary = summary
        self.key = key
        self.agentID = agentID
        self.sessionID = sessionID
        self.requestedAt = requestedAt
        self.isQuestion = isQuestion ?? (toolName == "AskUserQuestion")
    }

    var reason: AgentAttentionReason {
        isQuestion ? .question(summary) : .permission(tool: toolName, summary: summary)
    }

    /// Whether `event` (PostToolUse, a re-sent PermissionRequest) is about
    /// the call this dialog asked about.
    func isSameCall(key: String, as event: AgentHookEvent) -> Bool {
        self.key == key && agentID == event.agentID && sessionID == event.sessionID
    }
}

/// What applying one hook event meant, for the surfaces that report it.
struct AgentHookOutcome: Equatable {
    /// The column flipped into needsAttention: alert (dock, notification).
    var firedAttention = false
    /// What the event asks of the user, when it asks something.
    var attention: AgentAttentionReason?
    /// The event reports a request already reported: the delayed
    /// `permission_prompt` notification after its PermissionRequest.
    var isRepeat = false
    /// Requests whose receiver still waits for a sidebar decision that
    /// the event closed by other means (answered at the terminal, turn or
    /// session over): release them, nothing will be decided.
    var abandonedApprovals: [AgentPermissionRequest] = []
}

/// Display-safe text from agent payloads (notification messages, tool
/// inputs): no control or invisible formatting characters (terminal
/// escapes, bidi overrides), whitespace runs folded to one space, bounded.
enum AgentText {
    static func clean(_ text: String, maxLength: Int) -> String? {
        guard maxLength > 0 else { return nil }
        var scalars = String.UnicodeScalarView()
        var kept = 0 // UnicodeScalarView.count is O(n)
        var pendingSpace = false
        var truncated = false
        // Bounds the scan on huge inputs (a Write's content, a heredoc).
        let scalarBudget = maxLength * 4 + 4
        for scalar in text.unicodeScalars {
            if kept >= scalarBudget {
                truncated = true
                break
            }
            if scalar.properties.isWhitespace {
                pendingSpace = true
                continue
            }
            switch scalar.properties.generalCategory {
            case .control, .surrogate:
                continue
            case .format where scalar.value != 0x200D: // keep ZWJ (emoji sequences)
                continue
            default:
                break
            }
            if pendingSpace, kept > 0 {
                scalars.append(" ")
                kept += 1
            }
            pendingSpace = false
            scalars.append(scalar)
            kept += 1
        }
        let result = String(scalars)
        guard !result.isEmpty else { return nil }
        guard truncated || result.count > maxLength else { return result }
        return String(result.prefix(maxLength - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

/// Reads the parts of a Claude tool call that say what it does.
enum AgentToolInput {
    static let maxSummaryLength = 160

    /// The input field that says what a call does, by tool. Nil for tools
    /// without one (MCP tools…).
    static func primaryValue(toolName: String, input: [String: Any]) -> String? {
        switch toolName {
        case "Bash", "PowerShell": return input["command"] as? String
        case "Edit", "MultiEdit", "Write", "Read": return input["file_path"] as? String
        case "NotebookEdit", "NotebookRead": return input["notebook_path"] as? String
        case "WebFetch": return input["url"] as? String
        case "WebSearch": return input["query"] as? String
        case "Glob", "Grep": return input["pattern"] as? String
        case "Task", "Agent": return input["description"] as? String
        case "AskUserQuestion":
            let questions = input["questions"] as? [[String: Any]]
            return questions?.first?["question"] as? String
        // Approving a plan may rewrite its input: the name alone matches.
        case "ExitPlanMode": return ""
        default: return nil
        }
    }

    /// Short excerpt for display. File paths shed the project directory
    /// (or home) prefix: the file name is what tells calls apart.
    static func summary(toolName: String, input: [String: Any], cwd: String?, home: String?) -> String? {
        guard var value = primaryValue(toolName: toolName, input: input), !value.isEmpty else { return nil }
        if ["Edit", "MultiEdit", "Write", "Read", "NotebookEdit", "NotebookRead"].contains(toolName) {
            if let cwd, !cwd.isEmpty, value.hasPrefix(cwd + "/") {
                value = String(value.dropFirst(cwd.count + 1))
            } else if let home, !home.isEmpty, value.hasPrefix(home + "/") {
                value = "~/" + value.dropFirst(home.count + 1)
            }
        }
        return AgentText.clean(value, maxLength: maxSummaryLength)
    }

    /// The exact text a sidebar approval shows, or nil when the sidebar
    /// can't offer one. Only tools whose whole meaning is one short value
    /// qualify: a command, a URL, a search query, a file to read. Edits and
    /// writes (whose change can't be shown), Grep/Glob (whose path the
    /// excerpt omits) and MCP tools answer in the terminal. The value must
    /// also reach the screen unchanged: printable ASCII, no newline or tab,
    /// no folded spaces, no truncation. Approving then means approving
    /// exactly the text on screen.
    static func approvalText(toolName: String, input: [String: Any], cwd: String?, home: String?) -> String? {
        switch toolName {
        case "Bash", "PowerShell":
            // Leaving the sandbox changes what the command may reach; the
            // terminal dialog says so, the sidebar would not.
            if input["dangerouslyDisableSandbox"] as? Bool == true { return nil }
        case "Read", "WebFetch", "WebSearch":
            break
        default:
            return nil
        }
        // Printable ASCII only: every character then takes one cell of the
        // sidebar's monospaced text, with no look-alike, wide or
        // right-to-left glyph to hide what runs.
        guard let raw = primaryValue(toolName: toolName, input: input), !raw.isEmpty,
              raw.count <= maxSummaryLength,
              raw.unicodeScalars.allSatisfy({ (0x20...0x7E).contains($0.value) }),
              AgentText.clean(raw, maxLength: maxSummaryLength) == raw
        else { return nil }
        return summary(toolName: toolName, input: input, cwd: cwd, home: home)
    }

    /// Stable across processes (each hook runs its own receiver, so no
    /// per-process seeded hashing): the tool name plus its whole input
    /// with sorted keys — two Greps with one pattern in different paths
    /// are different calls. Tools whose answer rewrites their input key on
    /// what stays: the question asked, or the name alone for a plan.
    static func key(toolName: String, input: [String: Any]) -> String {
        var material = Data(toolName.utf8)
        material.append(0)
        if ["AskUserQuestion", "ExitPlanMode"].contains(toolName) {
            material.append(Data((primaryValue(toolName: toolName, input: input) ?? "").utf8))
        } else if JSONSerialization.isValidJSONObject(input),
                  let json = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]) {
            material.append(json)
        }
        return SHA256.hash(data: material).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
