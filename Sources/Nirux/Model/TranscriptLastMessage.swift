import Foundation

/// The agent's latest words in a Claude Code transcript (one JSON object per
/// line, read as TranscriptSearch reads it): what the Lead's `read_task`
/// returns.
enum TranscriptLastMessage {
    /// Read from the end of the file, where the last message is: a few
    /// tool outputs after it fit, a huge one may cut it.
    static let tailBytes = 4 * 1024 * 1024

    /// What the end of a transcript says since its newest prompt.
    enum Reading: Equatable, Sendable {
        /// The agent's last message since the newest prompt.
        case message(TranscriptSearch.Message)
        /// The newest prompt, which the agent hasn't answered with text yet.
        case unanswered(prompt: TranscriptSearch.Message)
        /// The window read holds neither, past its start: tool output
        /// fills it.
        case noText
    }

    /// The reading of the transcript at `path`; nil when it can't be read,
    /// or holds neither a prompt nor a message (a conversation not started).
    static func read(path: String, tailBytes: Int = tailBytes) -> Reading? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        // One byte more: it says whether the window starts a line.
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) - 1 : 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return nil }
        return last(in: data, startsMidLine: start > 0)
    }

    /// `text` with each line that holds a secret replaced (a private key's
    /// block whole: its lines after the first hold none), and how many were.
    static func withholdingSecrets(_ text: String) -> (text: String, withheld: Int) {
        guard HistorySearch.holdsSecret(text) else { return (text, 0) }
        var withheld = 0
        var inKey = false
        let lines = text.components(separatedBy: "\n").map { line -> String in
            let secret = inKey || HistorySearch.holdsSecret(line)
            if secret, line.contains("-----BEGIN") { inKey = true }
            if inKey, line.contains("-----END") { inKey = false }
            guard secret else { return line }
            withheld += 1
            return "[withheld: it looks like a secret]"
        }
        return (lines.joined(separator: "\n"), withheld)
    }

    /// The main thread's last assistant message with text after the newest
    /// prompt: the text of every line of it (Claude writes one line per
    /// part), in order. Tool output isn't parsed; Claude Code's own
    /// placeholders ("No response requested.") aren't the agent's words.
    static func last(in data: Data, startsMidLine: Bool = false) -> Reading? {
        var whole: Data.SubSequence = data[...]
        if startsMidLine {
            guard let newline = data.firstIndex(of: UInt8(ascii: "\n")) else { return .noText }
            whole = data[data.index(after: newline)...]
        }
        var found: (id: String?, message: TranscriptSearch.Message)?
        var parts: [String] = []
        for line in whole.split(separator: UInt8(ascii: "\n")).reversed() {
            guard let object = line.withUnsafeBytes({ $0.isEmpty || TranscriptSearch.isToolResult($0) ? nil : TranscriptSearch.object($0) })
            else { continue }
            if let prompt = TranscriptSearch.message(in: object), prompt.role == .user {
                guard found != nil else { return .unanswered(prompt: prompt) }
                break
            }
            guard object["type"] as? String == "assistant", !TranscriptSearch.isAside(object) else { continue }
            let body = object["message"] as? [String: Any]
            guard body?["model"] as? String != "<synthetic>" else { continue }
            let id = body?["id"] as? String
            if let found, found.id == nil || id != found.id { break }
            // A tool call after its last text: that text is further up.
            guard let said = TranscriptSearch.message(in: object) else { continue }
            if found == nil { found = (id, said) }
            parts.insert(said.text, at: 0)
        }
        guard let found else { return startsMidLine ? .noText : nil }
        return .message(TranscriptSearch.Message(role: .claude, text: parts.joined(separator: "\n\n"), timestamp: found.message.timestamp))
    }
}
