import Foundation

/// Formats an editor selection into the snippet pasted into an agent
/// terminal: a `path:Lx-Ly` header plus a fenced code excerpt.
enum AgentExcerpt {
    /// Excerpts longer than this are cut off with a note — a huge paste
    /// drowns the agent's input box.
    static let maxLines = 200

    static func format(path: String, startLine: Int, endLine: Int, text: String) -> String {
        // A full-line selection ends with the cursor past the last line's
        // newline; drop that single trailing newline so it doesn't render
        // as an empty line inside the fence.
        var body = text
        if body.hasSuffix("\n") { body.removeLast() }

        var lines = body.components(separatedBy: "\n")
        var note: String?
        if lines.count > maxLines {
            note = "[excerpt truncated: first \(maxLines) of \(lines.count) lines]"
            lines = Array(lines.prefix(maxLines))
            body = lines.joined(separator: "\n")
        }

        let fence = fence(for: body)
        let range = startLine == endLine ? "L\(startLine)" : "L\(startLine)-L\(endLine)"
        var out = "\(path):\(range)\n\(fence)\n\(body)\n\(fence)\n"
        if let note { out += note + "\n" }
        return out
    }

    /// One backtick longer than the longest backtick run in the body, so
    /// excerpts containing fenced blocks stay intact. Minimum three.
    private static func fence(for body: String) -> String {
        var longest = 0
        var current = 0
        for char in body {
            current = char == "`" ? current + 1 : 0
            longest = max(longest, current)
        }
        return String(repeating: "`", count: max(3, longest + 1))
    }
}
