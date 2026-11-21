import Foundation

/// What a terminal agent says of itself through OSC 7501, the Program Status
/// Protocol: `ESC ] 7501 ; state=…[:kind=…]:app=…[:msg=<base64>]`, ended by
/// BEL or ST. Nirux reads Antigravity's, asked for with `AGY_CLI_OSC7501=on`
/// in its terminals, and Codex's, which it always sends to a terminal.
/// Claude Code speaks it only to a terminal that answers its query, which
/// Nirux doesn't: its hooks say more.
struct AgentProgramStatus: Equatable, Sendable {
    enum State: String, Sendable {
        case working, blocked, done, idle, error
    }

    let state: State
    /// Why it's blocked: `permission` (a command, the folder's trust),
    /// `question`, `auth`.
    let kind: String?
    /// What it shows: the pending command or question, the turn's answer.
    let message: String?
    /// The agent it speaks for, which must be in front to be heard.
    let agent: CodingAgent

    /// Every launch says `blocked:kind=auth` for a moment while it signs in.
    static let signInGrace: TimeInterval = 5
    /// agy's spinner never stops this long while it works: past it, a
    /// reported `working` was ended by a status Nirux missed.
    static let workingSilence: TimeInterval = 60

    static let prefix = "\u{1b}]7501;"

    /// Why it waits on the user, or how its turn ended.
    var attentionReason: AgentAttentionReason? {
        switch state {
        case .blocked:
            switch kind {
            case "permission": return .permission(tool: nil, summary: message)
            case "question": return .question(message)
            default: return .message(message)
            }
        case .done: return .turnFinished
        case .error: return .apiError(kind: nil, detail: message)
        case .working, .idle: return nil
        }
    }

    /// Codex 0.171 reports the dialog kind even when it omits the command or question.
    var codexChoice: AgentAttentionReason? {
        guard process == Self.codex, state == .blocked else { return nil }
        switch kind {
        case "permission": return .permission(tool: nil, summary: message ?? "approval in Codex")
        case "question": return .question(message ?? "choose an option in Codex")
        default: return nil
        }
    }

    /// `payload`, what follows `ESC ] 7501 ;`: nil for an app Nirux doesn't
    /// read, or a query.
    static func parse(_ payload: Substring) -> AgentProgramStatus? {
        var fields: [Substring: Substring] = [:]
        for field in payload.split(separator: ":") {
            let pair = field.split(separator: "=", maxSplits: 1)
            if pair.count == 2 { fields[pair[0]] = pair[1] }
        }
        guard let agent = fields["app"].flatMap({ app in CodingAgent.allCases.first { $0.programStatusApp == String(app) } }),
              let state = fields["state"].flatMap({ State(rawValue: String($0)) })
        else { return nil }
        let message = fields["msg"]
            .flatMap { Data(base64Encoded: String($0)) }
            .flatMap { String(data: $0, encoding: .utf8) }
            .flatMap { AgentText.clean($0, maxLength: AgentToolInput.maxSummaryLength) }
        return AgentProgramStatus(state: state, kind: fields["kind"].map(String.init), message: message, agent: agent)
    }

    /// Reads them out of terminal output, which comes in chunks: a sequence
    /// a chunk cuts waits for the next one. One longer than `maxCarry` is
    /// read without the rest of its `msg`, the last field agy sends.
    struct Scanner: Sendable {
        /// The cut sequence's payload so far, or the start of the prefix a
        /// chunk ended on.
        private var carry = ""
        private var inPayload = false
        static let maxCarry = 4096

        /// Whether a cut sequence waits for the next chunk.
        var isWaiting: Bool { inPayload || !carry.isEmpty }

        mutating func statuses(in chunk: String) -> [AgentProgramStatus] {
            var found: [AgentProgramStatus] = []
            var text = Substring(chunk)
            if inPayload {
                guard let end = text.firstIndex(where: Self.isTerminator) else {
                    keep(text)
                    return found
                }
                keep(text[..<end])
                if let status = AgentProgramStatus.parse(Substring(carry)) { found.append(status) }
                (carry, inPayload) = ("", false)
                text = text[end...]
            } else if !carry.isEmpty {
                text = Substring(carry + text)
                carry = ""
            }
            while let start = text.range(of: AgentProgramStatus.prefix) {
                let payload = text[start.upperBound...]
                guard let end = payload.firstIndex(where: Self.isTerminator) else {
                    inPayload = true
                    keep(payload)
                    return found
                }
                if let status = AgentProgramStatus.parse(payload[..<end]) { found.append(status) }
                text = payload[end...]
            }
            // A chunk that ends on the prefix's start.
            if let escape = text.lastIndex(of: "\u{1b}"), AgentProgramStatus.prefix.hasPrefix(text[escape...]) {
                carry = String(text[escape...])
            }
            return found
        }

        private mutating func keep(_ payload: Substring) {
            carry += payload.prefix(max(0, Self.maxCarry - carry.count))
        }

        private static func isTerminator(_ character: Character) -> Bool {
            character == "\u{07}" || character == "\u{1b}"
        }
    }
}
