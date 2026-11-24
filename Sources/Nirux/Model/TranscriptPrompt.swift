import Foundation

/// A prompt a Claude transcript records: typed at the box (or queued there
/// while Claude worked), or taken in by Claude from elsewhere (a peer, a
/// task notification). With the `prompt_id` its UserPromptSubmit carried,
/// which a prompt queued mid-turn doesn't record: its line is stamped when
/// it was submitted. One queued during the turn's last answer is a user line
/// after it (`promptSource` "queued"), with a `prompt_id` no hook carries:
/// its enqueue line says when it was submitted (Claude Code 2.1.331).
struct TranscriptPrompt: Equatable, Sendable {
    let promptID: String?
    let at: TimeInterval
    let typed: Bool
    let sessionID: String?
    /// When a prompt queued while Claude worked was submitted.
    var submittedAt: TimeInterval?
    /// A queued user line's text, to find its enqueue line (`TranscriptPromptParser`).
    fileprivate var queuedText: Int?

    init(promptID: String?, at: TimeInterval, typed: Bool, sessionID: String? = nil, submittedAt: TimeInterval? = nil) {
        self.promptID = promptID
        self.at = at
        self.typed = typed
        self.sessionID = sessionID
        self.submittedAt = submittedAt ?? (promptID == nil ? at : nil)
    }

    /// Nil for any other line. Older lines, which name no origin, aren't
    /// read.
    init?(line: Data) {
        guard line.withUnsafeBytes({ TranscriptSearch.contains($0, Self.originMarker) }),
              let object = line.withUnsafeBytes(TranscriptSearch.object), object["isSidechain"] as? Bool != true,
              let at = (object["timestamp"] as? String).flatMap(TranscriptSearch.date)?.timeIntervalSince1970
        else { return nil }
        let origin: [String: Any]?
        switch object["type"] as? String {
        case "user":
            origin = object["origin"] as? [String: Any]
            promptID = object["promptId"] as? String
            if object["promptSource"] as? String == "queued" {
                queuedText = ((object["message"] as? [String: Any])?["content"] as? String)?.hashValue
            }
        case "attachment":
            let attachment = object["attachment"] as? [String: Any]
            guard attachment?["type"] as? String == "queued_command" else { return nil }
            origin = attachment?["origin"] as? [String: Any]
            promptID = nil
            submittedAt = at
        default:
            return nil
        }
        guard let kind = origin?["kind"] as? String else { return nil }
        self.at = at
        typed = kind == "human"
        sessionID = object["sessionId"] as? String
    }

    private static let originMarker = Array(#""origin":{"#.utf8)
}

/// The prompts a transcript records as it grows (`TranscriptLineReader`).
struct TranscriptPromptParser: TranscriptLineParser {
    private(set) var prompts: [TranscriptPrompt] = []
    /// The last prompts queued while Claude worked (`queue-operation`
    /// enqueue lines): their text and when they were submitted.
    private var enqueued: [(text: Int, at: TimeInterval)] = []

    mutating func consume(line: Data) {
        if let enqueue = Self.enqueue(line) {
            enqueued = Array((enqueued + [enqueue]).suffix(16))
            return
        }
        guard var prompt = TranscriptPrompt(line: line) else { return }
        if let text = prompt.queuedText, let index = enqueued.lastIndex(where: { $0.text == text && $0.at <= prompt.at }) {
            prompt.submittedAt = enqueued.remove(at: index).at
        }
        prompts.append(prompt)
    }

    private static func enqueue(_ line: Data) -> (text: Int, at: TimeInterval)? {
        guard line.withUnsafeBytes({ TranscriptSearch.contains($0, enqueueMarker) }),
              let object = line.withUnsafeBytes(TranscriptSearch.object),
              object["type"] as? String == "queue-operation", object["operation"] as? String == "enqueue",
              let text = object["content"] as? String,
              let at = (object["timestamp"] as? String).flatMap(TranscriptSearch.date)?.timeIntervalSince1970
        else { return nil }
        return (text.hashValue, at)
    }

    private static let enqueueMarker = Array(#""operation":"enqueue""#.utf8)
}

typealias TranscriptPromptReader = TranscriptLineReader<TranscriptPromptParser>
