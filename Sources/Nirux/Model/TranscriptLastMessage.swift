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
        tail(of: path, bytes: tailBytes).flatMap { last(in: $0.data, startsMidLine: $0.startsMidLine) }
    }

    /// The last `bytes` of the file at `path` past `offset`, and one more,
    /// which says whether they start a line.
    static func tail(of path: String, bytes: Int, from offset: UInt64 = 0) -> (data: Data, startsMidLine: Bool)? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let first = max(offset, size > UInt64(bytes) ? size - UInt64(bytes) : 0)
        let start = first > 0 ? first - 1 : 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return nil }
        return (data, start > 0)
    }

    /// The size of the file at `path`, 0 when it can't be read.
    static func size(of path: String) -> UInt64 {
        (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.uint64Value ?? 0
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
        var found: (id: String?, message: TranscriptSearch.Message)?
        var parts: [String] = []
        for line in lines(of: data, startsMidLine: startsMidLine).reversed() {
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

    /// Whether the main thread's conversation at the end of the transcript
    /// at `path` waits on Claude: its last word is a prompt or a tool
    /// result, not a line of Claude's reply (its first thought counts) nor
    /// an interrupt. Nil when its last `tailBytes` hold none of these.
    static func awaitsReply(path: String, tailBytes: Int = tailBytes) -> Bool? {
        tail(of: path, bytes: tailBytes).flatMap { awaitsReply(in: $0.data, startsMidLine: $0.startsMidLine) }
    }

    static func awaitsReply(in data: Data, startsMidLine: Bool = false) -> Bool? {
        for line in lines(of: data, startsMidLine: startsMidLine).reversed() {
            if line.withUnsafeBytes({ TranscriptSearch.contains($0, interruptMarker) }) { return false }
            // Tool output, never parsed: a result went in.
            if line.withUnsafeBytes(TranscriptSearch.isToolResult) { return true }
            guard let object = line.withUnsafeBytes({ $0.isEmpty ? nil : TranscriptSearch.object($0) }),
                  !TranscriptSearch.isAside(object) else { continue }
            switch object["type"] as? String {
            case "assistant": return false
            case "user" where TranscriptSearch.message(in: object) != nil: return true
            default: continue
            }
        }
        return nil
    }

    /// Whether the transcript at `path` shows Claude stopping a turn at an
    /// Esc sent at `date`: its "[Request interrupted by user" line, which
    /// Claude stamps once it read the key (milliseconds, this Mac's clock).
    /// Only what was written past `offset` (the file's size at the Esc) is
    /// read, its last 256 KB at most.
    static func showsInterrupt(path: String, since date: Date, after offset: UInt64) -> Bool {
        guard let tail = tail(of: path, bytes: 256 * 1024, from: offset) else { return false }
        // Claude stamps milliseconds, cut.
        let sentAt = Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1_000).rounded(.down) / 1_000)
        return lines(of: tail.data, startsMidLine: tail.startsMidLine).reversed().contains { line in
            guard line.withUnsafeBytes({ TranscriptSearch.contains($0, interruptMarker) }),
                  let object = line.withUnsafeBytes(TranscriptSearch.object), object["type"] as? String == "user",
                  let time = (object["timestamp"] as? String).flatMap(TranscriptSearch.date), time >= sentAt
            else { return false }
            let content = (object["message"] as? [String: Any])?["content"]
            let texts = (content as? String).map { [$0] }
                ?? (content as? [[String: Any]] ?? []).compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            return texts.contains { $0.hasPrefix("[Request interrupted by user") }
        }
    }

    private static let interruptMarker = Array("[Request interrupted by user".utf8)

    /// `data`'s lines, the first left out when the window cut it.
    private static func lines(of data: Data, startsMidLine: Bool) -> [Data.SubSequence] {
        var whole: Data.SubSequence = data[...]
        if startsMidLine {
            guard let newline = data.firstIndex(of: UInt8(ascii: "\n")) else { return [] }
            whole = data[data.index(after: newline)...]
        }
        return whole.split(separator: UInt8(ascii: "\n"))
    }
}
