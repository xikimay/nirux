import Foundation

/// What a terminal agent says of itself through OSC 7501, the Program Status
/// Protocol: `ESC ] 7501 ; state=…[:kind=…]:app=…[:msg=<base64>]`, ended by
/// BEL or ST. Nirux reads Antigravity's, asked for with `AGY_CLI_OSC7501=on`
/// in its terminals. Claude Code speaks it only to a terminal that answers
/// its query, which Nirux doesn't: its hooks say more.
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

    /// The one app Nirux reads, and its process.
    static let app = "antigravity"
    static let process = "agy"
    /// Every launch says `blocked:kind=auth` for a moment while it signs in.
    static let signInGrace: TimeInterval = 5

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

    /// `payload`, what follows `ESC ] 7501 ;`: nil for another app's or a
    /// query.
    static func parse(_ payload: Substring) -> AgentProgramStatus? {
        var fields: [Substring: Substring] = [:]
        for field in payload.split(separator: ":") {
            let pair = field.split(separator: "=", maxSplits: 1)
            if pair.count == 2 { fields[pair[0]] = pair[1] }
        }
        guard fields["app"] == Substring(app), let state = fields["state"].flatMap({ State(rawValue: String($0)) }) else {
            return nil
        }
        let message = fields["msg"]
            .flatMap { Data(base64Encoded: String($0)) }
            .flatMap { String(data: $0, encoding: .utf8) }
            .flatMap { AgentText.clean($0, maxLength: AgentToolInput.maxSummaryLength) }
        return AgentProgramStatus(state: state, kind: fields["kind"].map(String.init), message: message)
    }

    /// Reads them out of terminal output, which comes in chunks: a sequence
    /// a chunk cuts waits for the next one.
    struct Scanner: Sendable {
        private var carry = ""
        /// A cut sequence longer than this is dropped.
        static let maxCarry = 4096

        /// Whether a cut sequence waits for the next chunk.
        var isWaiting: Bool { !carry.isEmpty }

        mutating func statuses(in chunk: String) -> [AgentProgramStatus] {
            var text = carry + chunk
            carry = ""
            var found: [AgentProgramStatus] = []
            while let start = text.range(of: AgentProgramStatus.prefix) {
                let payload = text[start.upperBound...]
                guard let end = payload.firstIndex(where: { $0 == "\u{07}" || $0 == "\u{1b}" }) else {
                    if text.distance(from: start.lowerBound, to: text.endIndex) <= Self.maxCarry {
                        carry = String(text[start.lowerBound...])
                    }
                    break
                }
                if let status = AgentProgramStatus.parse(payload[..<end]) { found.append(status) }
                text = String(payload[end...])
            }
            return found
        }
    }
}
