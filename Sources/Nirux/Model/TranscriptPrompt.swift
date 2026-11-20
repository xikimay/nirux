import Foundation

/// A prompt a Claude transcript records: typed at the box (or queued there
/// while Claude worked), or taken in by Claude from elsewhere (a peer, a
/// task notification). With the `prompt_id` its UserPromptSubmit carried,
/// which a prompt queued mid-turn doesn't record.
struct TranscriptPrompt: Equatable, Sendable {
    let promptID: String?
    let at: TimeInterval
    let typed: Bool

    init(promptID: String?, at: TimeInterval, typed: Bool) {
        self.promptID = promptID
        self.at = at
        self.typed = typed
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
        case "attachment":
            let attachment = object["attachment"] as? [String: Any]
            guard attachment?["type"] as? String == "queued_command" else { return nil }
            origin = attachment?["origin"] as? [String: Any]
            promptID = nil
        default:
            return nil
        }
        guard let kind = origin?["kind"] as? String else { return nil }
        self.at = at
        typed = kind == "human"
    }

    private static let originMarker = Array(#""origin":{"#.utf8)
}

/// The prompts a transcript records as it grows (`TranscriptLineReader`).
struct TranscriptPromptParser: TranscriptLineParser {
    private(set) var prompts: [TranscriptPrompt] = []

    mutating func consume(line: Data) {
        if let prompt = TranscriptPrompt(line: line) { prompts.append(prompt) }
    }
}

typealias TranscriptPromptReader = TranscriptLineReader<TranscriptPromptParser>
