import Foundation

/// Formats an editor selection into the snippet pasted into an agent
/// terminal: a `path:Lx-Ly` header plus a fenced code excerpt.
enum AgentExcerpt {
    /// Excerpts longer than this are cut off with a note — a huge paste
    /// drowns the agent's input box.
    static let maxLines = 200
    /// Character backstop for pathological single-line selections
    /// (minified bundles) that sail past the line cap.
    static let maxCharacters = 64_000

    static func format(path: String, startLine: Int, endLine: Int, text: String) -> String {
        // ESC could smuggle an end-of-paste sequence (ESC[201~) into the
        // stream, turning the rest of the excerpt into live keystrokes at
        // the receiving terminal — strip it like real terminals do on
        // paste. CRLF normalizes so the strip/count logic and the PTY see
        // plain \n.
        var body = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\u{1B}", with: "")
        // A full-line selection ends with the cursor past the last line's
        // newline; drop that single trailing newline so it doesn't render
        // as an empty line inside the fence.
        if body.hasSuffix("\n") { body.removeLast() }

        var note: String?
        var lines = body.components(separatedBy: "\n")
        if lines.count > maxLines {
            note = "[excerpt truncated: first \(maxLines) of \(lines.count) lines]"
            lines = Array(lines.prefix(maxLines))
            body = lines.joined(separator: "\n")
        }
        if body.count > maxCharacters {
            note = "[excerpt truncated at \(maxCharacters) characters]"
            body = String(body.prefix(maxCharacters))
        }

        let fence = fence(for: body)
        let range = startLine == endLine ? "L\(startLine)" : "L\(startLine)-L\(endLine)"
        var out = "\(path):\(range)\n\(fence)\n\(body)\n\(fence)"
        // No trailing newline: on a receiver without bracketed paste a
        // final \n would submit the excerpt as a command line.
        if let note { out += "\n" + note }
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
