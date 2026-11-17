import Foundation

/// The last message an agent wrote in a Claude Code transcript (one JSON
/// object per line): what the Lead's `read_task` returns.
enum TranscriptLastMessage {
    struct Message: Equatable, Sendable {
        let text: String
        let timestamp: Date?
    }

    /// Read from the end of the file, where the last message is: a few
    /// tool outputs after it fit, a huge one may cut it.
    static let tailBytes = 4 * 1024 * 1024

    /// The last message in the transcript at `path`; nil when it holds
    /// none or can't be read.
    static func read(path: String, tailBytes: Int = tailBytes) -> Message? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return nil }
        return last(in: data, startsMidLine: start > 0)
    }

    /// The main thread's last assistant message with text: the text parts
    /// of every line of it (Claude writes one line per part), in order.
    /// Subagents' lines and API errors aren't the agent's words.
    static func last(in data: Data, startsMidLine: Bool = false) -> Message? {
        var lines = data.split(separator: UInt8(ascii: "\n"))
        if startsMidLine, !lines.isEmpty { lines.removeFirst() }
        var found: (id: String?, timestamp: Date?)?
        var parts: [String] = []
        for line in lines.reversed() {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  object["type"] as? String == "assistant", object["isSidechain"] as? Bool != true,
                  object["isApiErrorMessage"] as? Bool != true,
                  let message = object["message"] as? [String: Any]
            else { continue }
            let id = message["id"] as? String
            if let found, found.id == nil || id != found.id { break }
            let texts = texts(of: message["content"])
            // A tool call after its last text: that text is further up.
            guard found != nil || !texts.isEmpty else { continue }
            if found == nil { found = (id, (object["timestamp"] as? String).flatMap(timestamp)) }
            parts.insert(contentsOf: texts, at: 0)
        }
        guard let found else { return nil }
        let text = parts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : Message(text: text, timestamp: found.timestamp)
    }

    private static func texts(of content: Any?) -> [String] {
        if let text = content as? String { return [text] }
        return (content as? [[String: Any]] ?? []).compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
    }

    private static func timestamp(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}
