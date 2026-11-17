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
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        // One byte more: it says whether the window starts a line.
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) - 1 : 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return nil }
        return last(in: data, startsMidLine: start > 0)
    }

    /// The main thread's last assistant message with text: the text of
    /// every line of it (Claude writes one line per part), in order. Tool
    /// output isn't parsed; Claude Code's own placeholders ("No response
    /// requested.") aren't the agent's words.
    static func last(in data: Data, startsMidLine: Bool = false) -> TranscriptSearch.Message? {
        var whole: Data.SubSequence = data[...]
        if startsMidLine {
            guard let newline = data.firstIndex(of: UInt8(ascii: "\n")) else { return nil }
            whole = data[data.index(after: newline)...]
        }
        var found: (id: String?, message: TranscriptSearch.Message)?
        var parts: [String] = []
        for line in whole.split(separator: UInt8(ascii: "\n")).reversed() {
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
}
