import Foundation

/// The last message an agent wrote in a Claude Code transcript (one JSON
/// object per line, read as TranscriptSearch reads it): what the Lead's
/// `read_task` returns.
enum TranscriptLastMessage {
    /// Read from the end of the file, where the last message is: a few
    /// tool outputs after it fit, a huge one may cut it.
    static let tailBytes = 4 * 1024 * 1024

    /// The last message in the transcript at `path`; nil when it holds
    /// none or can't be read.
    static func read(path: String, tailBytes: Int = tailBytes) -> TranscriptSearch.Message? {
        tail(of: path, bytes: tailBytes).flatMap { last(in: $0.data, startsMidLine: $0.startsMidLine) }
    }

    /// The last `bytes` of the file at `path`, and one more, which says
    /// whether they start a line.
    static func tail(of path: String, bytes: Int) -> (data: Data, startsMidLine: Bool)? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(bytes) ? size - UInt64(bytes) - 1 : 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return nil }
        return (data, start > 0)
    }

    /// The main thread's last assistant message with text: the text of
    /// every line of it (Claude writes one line per part), in order. Tool
    /// output isn't parsed; Claude Code's own placeholders ("No response
    /// requested.") aren't the agent's words.
    static func last(in data: Data, startsMidLine: Bool = false) -> TranscriptSearch.Message? {
        var found: (id: String?, message: TranscriptSearch.Message)?
        var parts: [String] = []
        for line in lines(of: data, startsMidLine: startsMidLine).reversed() {
            guard let object = line.withUnsafeBytes({ $0.isEmpty || TranscriptSearch.isToolResult($0) ? nil : TranscriptSearch.object($0) }),
                  object["type"] as? String == "assistant", !TranscriptSearch.isAside(object)
            else { continue }
            let body = object["message"] as? [String: Any]
            guard body?["model"] as? String != "<synthetic>" else { continue }
            let id = body?["id"] as? String
            if let found, found.id == nil || id != found.id { break }
            // A tool call after its last text: that text is further up.
            guard let said = TranscriptSearch.message(in: object) else { continue }
            if found == nil { found = (id, said) }
            parts.insert(said.text, at: 0)
        }
        guard let found else { return nil }
        return TranscriptSearch.Message(role: .claude, text: parts.joined(separator: "\n\n"), timestamp: found.message.timestamp)
    }

    /// Whether the transcript at `path` shows Claude stopping a turn at an
    /// Esc sent at `date`: its "[Request interrupted by user" line, which
    /// Claude stamps once it read the key (milliseconds, this Mac's clock).
    static func showsInterrupt(path: String, since date: Date) -> Bool {
        guard let tail = tail(of: path, bytes: 256 * 1024) else { return false }
        return lines(of: tail.data, startsMidLine: tail.startsMidLine).reversed().contains { line in
            guard line.withUnsafeBytes({ TranscriptSearch.contains($0, interruptMarker) }),
                  let object = line.withUnsafeBytes(TranscriptSearch.object), object["type"] as? String == "user",
                  let time = (object["timestamp"] as? String).flatMap(TranscriptSearch.date), time >= date
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
