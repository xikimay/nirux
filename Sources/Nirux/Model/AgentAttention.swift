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
    /// The turn is over and its final message asks the user something
    /// (`TurnEndVerdict.asks`): the message's last line. Typed input
    /// answers it at the prompt, as any prompt; no dialog is open.
    case askedInReply(String?)
    /// Any other notification, with its message.
    case message(String?)
    /// The turn ended on an API error (Claude's StopFailure): what ended it
    /// (`rate_limit`…) and the error as the terminal showed it.
    case apiError(kind: String?, detail: String?)
    /// The agent process exited in the middle of a turn, without ending
    /// its session.
    case exitedMidTurn
    /// A dialog still waits on the user after `waited` seconds: the
    /// dialog's own reason. Only ever an alert, never a column's state.
    indirect case stillWaiting(AgentAttentionReason, waited: TimeInterval)

    /// A dialog is open in the terminal: typed input answers it rather
    /// than reaching the prompt.
    var isBlockingDialog: Bool {
        switch self {
        case .permission, .question: return true
        case .turnFinished, .askedInReply, .message, .apiError, .exitedMidTurn: return false
        case .stillWaiting(let dialog, _): return dialog.isBlockingDialog
        }
    }

    /// The turn ended, whatever its final message says: the agent waits
    /// for its next prompt.
    var isTurnEnd: Bool {
        switch self {
        case .turnFinished, .askedInReply: return true
        default: return false
        }
    }

    /// Something went wrong rather than the agent simply waiting: drawn in
    /// red.
    var isFailure: Bool {
        switch self {
        case .apiError, .exitedMidTurn: return true
        default: return false
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
        case .askedInReply: return "asks you"
        case .message: return "needs you"
        case .apiError: return "API error"
        case .exitedMidTurn: return "exited mid-turn"
        case .stillWaiting(let dialog, let waited):
            return "waiting \(SidebarRenderer.shortDuration(waited)) · \(dialog.shortLabel)"
        }
    }

    /// Completes "<agent> …" in a notification title.
    var headline: String {
        switch self {
        case .permission: return isPlanApproval ? "needs plan approval" : "needs permission"
        case .question: return "has a question"
        case .turnFinished: return "finished its turn"
        case .askedInReply: return "asks you something"
        case .message: return "needs you"
        case .apiError: return "stopped on an API error"
        case .exitedMidTurn: return "exited mid-turn"
        case .stillWaiting(let dialog, let waited):
            return "\(dialog.headline) — waiting \(SidebarRenderer.shortDuration(waited))"
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
        case .question(let text), .message(let text), .askedInReply(let text): return text
        case .turnFinished, .exitedMidTurn: return nil
        case .apiError(let kind, let detail):
            let parts = [kind, detail].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: ": ")
        case .stillWaiting(let dialog, _): return dialog.detailLine
        }
    }
}

/// What a lit attention signal asks of the user, least urgent first: the
/// sidebar's cards and rail and the project switcher's ring draw it. Only
/// `.waiting` is amber (`Theme.Color.waiting`).
enum AttentionSignal: String, Codable, Comparable, Hashable, Sendable {
    /// A turn ended: the agent waits for its next prompt, nobody is blocked.
    case finished
    /// Something broke: an API error, an agent that exited mid-turn, a red
    /// check.
    case error
    /// An agent waits for the user's answer: a permission, a question.
    case waiting

    private var rank: Int {
        switch self {
        case .finished: return 0
        case .error: return 1
        case .waiting: return 2
        }
    }

    static func < (lhs: AttentionSignal, rhs: AttentionSignal) -> Bool { lhs.rank < rhs.rank }

    /// A kind a newer build wrote reads as the most urgent: never a missed
    /// wait, and never a history that fails to load.
    init(from decoder: Decoder) throws {
        self = AttentionSignal(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .waiting
    }

    /// A column's attention, its reason known or not. An agent without
    /// hooks that falls silent may sit in its own approval prompt: amber,
    /// so a dialog is never missed.
    static func of(_ reason: AgentAttentionReason?) -> AttentionSignal {
        reason?.signal ?? .waiting
    }
}

extension WorkspaceState {
    /// Keeps the most urgent of what happened while the user was away.
    func raiseNotification(_ signal: AttentionSignal) { notification = max(notification ?? signal, signal) }
}

extension AgentAttentionReason {
    var signal: AttentionSignal {
        switch self {
        case .permission, .question, .askedInReply, .message: return .waiting
        case .apiError, .exitedMidTurn: return .error
        case .turnFinished: return .finished
        case .stillWaiting(let dialog, _): return dialog.signal
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
    /// Claude's question dialog, or an MCP elicitation form: its keys move
    /// among its options or fill its fields, so a key isn't its answer as
    /// it is an approval's (`AgentStatusMachine.waitsForKeys`). A hook
    /// ends it (its tool's PostToolUse, `elicitation_response`), or an
    /// Esc or Ctrl-C. Not ExitPlanMode's plan dialog: "Keep planning"
    /// fires no hook, so its first key stays its answer. Nor a teammate's
    /// `agent_needs_input`: no hook closes it either.
    let waitsPastKeys: Bool
    /// A later tool event from the same agent suggests the dialog was
    /// answered (a denial fires no hook). Only the column's status trusts
    /// that; the gate on prompts Nirux types waits for proof.
    var mayBeAnswered = false
    /// The hook receiver waits for a sidebar decision on this request.
    var approval: PermissionApprovalTicket?
    /// What a question dialog asks and offers, when its hook said.
    var dialog: AgentDialog?

    init(
        toolName: String?,
        summary: String?,
        key: String?,
        agentID: String?,
        sessionID: String?,
        requestedAt: TimeInterval,
        isQuestion: Bool? = nil,
        waitsPastKeys: Bool? = nil
    ) {
        self.toolName = toolName
        self.summary = summary
        self.key = key
        self.agentID = agentID
        self.sessionID = sessionID
        self.requestedAt = requestedAt
        self.isQuestion = isQuestion ?? (toolName == "AskUserQuestion")
        self.waitsPastKeys = waitsPastKeys ?? (toolName == "AskUserQuestion")
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

/// What a question dialog asks (Claude's AskUserQuestion), in the agent's
/// own words: each of its questions and the answers it offers. A task's
/// row shows them all, since no hook says which one is on screen; the
/// answers are given in the terminal.
struct AgentDialog: Codable, Hashable, Sendable {
    struct Question: Codable, Hashable, Sendable {
        let text: String
        /// Every option the question lists, or none: half of them would
        /// mislead.
        let options: [Option]
    }

    struct Option: Codable, Hashable, Sendable {
        let label: String
        /// What the option means, when the agent said.
        let detail: String?
    }

    let questions: [Question]

    /// As many questions as the dialog ever asks, and more options than
    /// it ever lists (four, and its own "Other").
    static let maxQuestions = 4
    static let maxOptions = 6

    init(questions: [Question]) {
        self.questions = questions
    }

    /// From AskUserQuestion's input (`questions`, each a `question` and its
    /// `options`, each a `label` and a `description`), as far as a row may
    /// show it (`bounded`). Nil unless every question can be shown.
    init?(toolInput: [String: Any]) {
        let asked = toolInput["questions"] as? [[String: Any]] ?? []
        let questions = asked.compactMap { question -> Question? in
            guard let text = question["question"] as? String else { return nil }
            let listed = question["options"] as? [[String: Any]] ?? []
            let options = listed.compactMap { option in
                (option["label"] as? String).map { Option(label: $0, detail: option["description"] as? String) }
            }
            return Question(text: text, options: options.count == listed.count ? options : [])
        }
        guard questions.count == asked.count, let dialog = Self.bounded(questions) else { return nil }
        self = dialog
    }

    /// Bounded again: the reader can't count on its writer. An error for a
    /// line with no question this build can show, which its event reads
    /// as no dialog (`ReadOrNil`).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let dialog = Self.bounded(try container.decode([Question].self, forKey: .questions)) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "no question to show"))
        }
        self = dialog
    }

    /// `questions` as a row may show them: every text cleaned and cut to
    /// the few lines it gets, no options for a question that lists more
    /// than `maxOptions` or one without a label. Nil for no question, more
    /// than `maxQuestions`, or one that says nothing.
    static func bounded(_ questions: [Question]) -> AgentDialog? {
        guard (1...maxQuestions).contains(questions.count) else { return nil }
        var kept: [Question] = []
        for question in questions {
            guard let text = AgentText.clean(question.text, maxLength: 300) else { return nil }
            let options = question.options.compactMap { option in
                AgentText.clean(option.label, maxLength: 80).map { label in
                    Option(label: label, detail: option.detail.flatMap { AgentText.clean($0, maxLength: 160) })
                }
            }
            let whole = options.count == question.options.count && options.count <= maxOptions
            kept.append(Question(text: text, options: whole ? options : []))
        }
        return AgentDialog(questions: kept)
    }
}

/// What applying one hook event meant, for the surfaces that report it.
struct AgentHookOutcome: Equatable {
    /// The column flipped into needsAttention: alert (dock, notification).
    /// Also an event that put a turn end behind before its verdict came (a
    /// prompt, the conversation changing or ending): it alerts as that turn
    /// end would have.
    var firedAttention = false
    /// What that alert is about: read only when `firedAttention` is set.
    var attention: AgentAttentionReason?
    /// A Claude turn end whose alert waits for the classifier's verdict
    /// (`AgentStatusMachine.applyTurnEndVerdict`).
    var turnEnd: TurnEndRequest?
    /// Requests whose receiver still waits for a sidebar decision that
    /// the event closed by other means (answered at the terminal, turn or
    /// session over): release them, nothing will be decided.
    var abandonedApprovals: [AgentPermissionRequest] = []
}

/// A field another build may have written in another shape: read as
/// nil then, never an error that would drop the whole line it is on.
/// Left out of the line when nil.
@propertyWrapper
struct ReadOrNil<Value: Codable & Hashable & Sendable>: Codable, Hashable, Sendable {
    var wrappedValue: Value?

    init(wrappedValue: Value?) {
        self.wrappedValue = wrappedValue
    }

    init(from decoder: Decoder) throws {
        wrappedValue = try? decoder.singleValueContainer().decode(Value.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wrappedValue)
    }
}

extension KeyedDecodingContainer {
    /// A line written before the field: nil.
    func decode<Value>(_ type: ReadOrNil<Value>.Type, forKey key: Key) throws -> ReadOrNil<Value> {
        try decodeIfPresent(type, forKey: key) ?? ReadOrNil(wrappedValue: nil)
    }
}

extension KeyedEncodingContainer {
    mutating func encode<Value>(_ value: ReadOrNil<Value>, forKey key: Key) throws {
        try encodeIfPresent(value.wrappedValue, forKey: key)
    }
}

/// Display-safe text from agent payloads (notification messages, tool
/// inputs): no control or invisible formatting characters (terminal
/// escapes, bidi overrides), whitespace runs folded to one space, bounded.
enum AgentText {
    /// The agent's words without the marks around them: "**Rebase** on
    /// `main`" reads "Rebase on main" where no Markdown is drawn. Only
    /// the marks that are never words ("_" and "*" may be).
    static func withoutMarks(_ text: String) -> String {
        text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
    }

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
    /// The tools that run a shell command.
    static let shellTools: Set<String> = ["Bash", "PowerShell"]

    /// The input field that says what a call does, by tool. Nil for tools
    /// without one (MCP tools…).
    static func primaryValue(toolName: String, input: [String: Any]) -> String? {
        switch toolName {
        case _ where shellTools.contains(toolName): return input["command"] as? String
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
    /// qualify: a command, a URL, a search query, a file to read (by its
    /// absolute or `~/` path, never relative to a directory the card
    /// doesn't show). Edits and writes (whose change can't be shown),
    /// Grep/Glob (whose excerpt omits the path) and MCP tools answer in the
    /// terminal. The value must also reach the screen unchanged
    /// (`isExactDisplay`): approving then means approving exactly the text
    /// on screen.
    static func approvalText(toolName: String, input: [String: Any], home: String?) -> String? {
        let value: String?
        switch toolName {
        case "Bash", "PowerShell":
            // Leaving the sandbox changes what the command may reach; the
            // terminal dialog says so, the sidebar would not. Only an
            // explicit "no" counts: any other value may mean yes.
            switch input["dangerouslyDisableSandbox"] {
            case nil: break
            case let flag as Bool where !flag: break
            case let flag as String where flag == "false": break
            default: return nil
            }
            value = input["command"] as? String
        case "Read":
            guard let path = input["file_path"] as? String, path.hasPrefix("/") else { return nil }
            if let home, !home.isEmpty, path.hasPrefix(home + "/") {
                value = "~/" + path.dropFirst(home.count + 1)
            } else {
                value = path
            }
        case "WebFetch":
            value = input["url"] as? String
        case "WebSearch":
            value = input["query"] as? String
        default:
            return nil
        }
        guard let value, isExactDisplay(value) else { return nil }
        return value
    }

    /// Printable ASCII on one line, with no leading, trailing or doubled
    /// space, at most `maxSummaryLength` characters: every character then
    /// takes one visible cell of the sidebar's monospaced text, with no
    /// hidden newline, look-alike, wide or right-to-left glyph.
    static func isExactDisplay(_ text: String) -> Bool {
        !text.isEmpty
            && text.utf8.count <= maxSummaryLength
            && text.utf8.allSatisfy { (0x20...0x7E).contains($0) }
            && !text.hasPrefix(" ") && !text.hasSuffix(" ")
            && !text.contains("  ")
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
        return shortHash(material)
    }

    /// 16 hex digits of a SHA-256: stable across processes and launches.
    static func shortHash(_ data: Data) -> String {
        SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
