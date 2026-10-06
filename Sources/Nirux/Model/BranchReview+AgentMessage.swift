import Foundation

// MARK: - The message the agent gets (section 6.2)

extension BranchReview {
    /// What goes to the agent: the message, the comments it holds, and how
    /// many it leaves out to stay within `maxMessageBytes`: `ids` is empty
    /// when none fits (the text still has its header and footer).
    struct AgentMessage: Equatable, Sendable {
        let text: String
        /// The ids of the comments in it, in its order.
        let ids: [String]
        let leftOut: Int
    }

    /// Past these, a comment quotes no more rows, a quoted row is cut (by
    /// Unicode scalars: a character can hold any number), and the message
    /// takes no more comments (by UTF-8 bytes, what the terminal gets).
    static let maxQuotedRows = 20
    static let maxQuotedScalars = 300
    static let maxMessageBytes = 128_000

    /// The message that sends `comments` of the review of `snapshot` to its
    /// agent: a header naming the branch and its head, each comment
    /// numbered with where it is in `files` (the snapshot's, rows read
    /// since included), its rows quoted and its text, then what to do. A
    /// removed row is named by its line in the base; a comment not under
    /// its rows any more is sent as such, with its rows as they were and
    /// no line number. A comment that doesn't fit within `maxMessageBytes`
    /// is left out; the next ones may fit.
    /// Sanitized as a whole: nothing in it reads as a key
    /// (`RemotePromptSanitizer.filtered`), so it can't end the paste.
    static func agentMessage(for comments: [Comment], snapshot: Snapshot, files: [FileChange]) -> AgentMessage {
        // The branch's names and paths are a branch's text: what would
        // break a line or hide shows as its code point.
        let base = visible(snapshot.base.name)
        // Line numbers are the working tree's, as read.
        let head = "head \(snapshot.head.prefix(7))" + (snapshot.hasUncommittedChanges ? " and uncommitted changes" : "")
        let header = ["Review comments on \(visible(snapshot.branch)) (\(head)), from Nirux:", ""]
        let footer = [
            "Address each comment, run the tests, commit and push. If a comment is wrong,",
            "say why and change nothing for it. Then say what you did for each number."
        ]
        var length = (header + footer).reduce(0) { $0 + $1.utf8.count + 1 }
        var body: [String] = []
        var ids: [String] = []
        // Each file's rows once, whatever the number of its comments.
        var rows: [String: [[DiffRow]]] = [:]
        for comment in comments {
            let file = BranchReview.file(for: comment.anchor, moved: comment.moved, in: files)
            var fileRows: [[DiffRow]]?
            if let file, file.omission == nil {
                fileRows = rows[file.path] ?? diffRows(of: file.hunks)
                rows[file.path] = fileRows
            }
            let placement = place(comment.anchor, moved: comment.moved, in: file, rows: fileRows)
            let lines = entry(comment, number: ids.count + 1, file: file, placement: placement, base: base)
            let added = lines.reduce(0) { $0 + $1.utf8.count + 1 }
            guard length + added <= maxMessageBytes else { continue }
            length += added
            body += lines
            ids.append(comment.id)
        }
        let text = RemotePromptSanitizer.filtered((header + body + footer).joined(separator: "\n"))
        return AgentMessage(text: text, ids: ids, leftOut: comments.count - ids.count)
    }

    /// One comment's lines: its number and place, its rows, its text, a
    /// blank line.
    private static func entry(
        _ comment: Comment, number: Int, file: FileChange?, placement: CommentPlacement, base: String
    ) -> [String] {
        let path = visible(file?.path ?? comment.current.path)
        let marker = "\(number). "
        let indent = String(repeating: " ", count: marker.count)
        var lines: [String] = []
        switch placement {
        case .placed(let anchor) where anchor.isFile:
            lines.append(marker + "\(path) (file)")
        case .placed(let anchor):
            let removedFrom = file?.oldPath.map { "\(visible($0)) in \(base)" } ?? base
            lines.append(marker + location(path: path, rows: anchor.rows, base: removedFrom))
            lines += quoted(anchor.rows, indent: indent)
        case .fileGone:
            lines.append(marker + "\(path) (the file no longer differs from \(base))")
            lines += quoted(comment.current.rows, indent: indent)
        case .outdated:
            lines.append(marker + "\(path) (outdated: Nirux can’t find these lines where they were)")
            lines += quoted(comment.current.rows, indent: indent)
        case .unread:
            lines.append(marker + "\(path) (as these lines were: the file’s diff isn’t read yet)")
            lines += quoted(comment.current.rows, indent: indent)
        case .tooLarge:
            lines.append(marker + "\(path) (as these lines were: the file’s diff is too large to place them)")
            lines += quoted(comment.current.rows, indent: indent)
        }
        // Every line break the text may hold starts a line of its own,
        // indented under its number. What else it holds shows as in the
        // sheet: a bidi control pasted into it reads as one.
        let text = comment.text.replacingOccurrences(of: "\r\n", with: "\n")
        lines += text.split(omittingEmptySubsequences: false) { "\n\r\u{2028}\u{2029}\u{85}".contains($0) }
            .map { indent + visible(String($0), keepingTabs: true) }
        lines.append("")
        return lines
    }

    /// `message` as typed into the agent's prompt: a bracketed paste, with
    /// nothing after it. The user reads it there, and submits it.
    static func agentPaste(_ message: String) -> String {
        "\u{1B}[200~" + message + "\u{1B}[201~"
    }

    /// Where rows are: `path:42` or `path:42–45` by the working tree's
    /// lines; removed rows by the base's (`base`), run by run.
    private static func location(path: String, rows: [DiffRow], base: String) -> String {
        let kept = rows.filter { $0.kind != .removed }.map(\.new)
        let removed = rows.filter { $0.kind == .removed }.map(\.old)
        let named = "\(removed.count == 1 ? "line" : "lines") \(runs(removed)) of \(base)"
        switch (kept.isEmpty, removed.isEmpty) {
        case (false, false): return "\(path):\(runs(kept)), with removed \(named)"
        case (false, true): return "\(path):\(runs(kept))"
        case (true, false): return "\(path) (removed, \(named))"
        case (true, true): return path
        }
    }

    /// Line numbers as runs: "42–43, 45".
    private static func runs(_ lines: [Int]) -> String {
        var spans: [(Int, Int)] = []
        for line in lines.sorted() {
            if let last = spans.last, line == last.1 + 1 { spans[spans.count - 1].1 = line } else { spans.append((line, line)) }
        }
        return spans.map { $0 == $1 ? "\($0)" : "\($0)–\($1)" }.joined(separator: ", ")
    }

    /// Rows quoted under a comment's place, each marked by its kind ("+"
    /// added, "-" removed, " " unchanged), so that a line that starts with
    /// "- " reads as its own, up to `maxQuotedRows` of up to
    /// `maxQuotedScalars`, whole characters (a row cut when it was stored
    /// says so too, however short what is left of it).
    /// Line breaks, controls and characters that change how a line reads
    /// without showing are written as their code point: a quoted line can't
    /// end the quote and read as the user's. The carriage returns of a CRLF
    /// file stay hidden, as in the diff, unless some rows quoted lack one.
    private static func quoted(_ rows: [DiffRow], indent: String) -> [String] {
        let shown = rows.prefix(maxQuotedRows)
        let whole = shown.filter { $0.digest == nil }
        let crlf = !whole.isEmpty && whole.allSatisfy { $0.text.hasSuffix("\r") }
        var lines = shown.map { row in
            let text = crlf && row.text.hasSuffix("\r") ? String(row.text.dropLast()) : row.text
            let mark = switch row.kind {
            case .added: "+"
            case .removed: "-"
            case .context: " "
            }
            var line = visible(text, keepingTabs: true)
            if line.unicodeScalars.count > maxQuotedScalars || row.digest != nil {
                var scalars = 0
                line = String(line.prefix { character in
                    scalars += character.unicodeScalars.count
                    return scalars <= maxQuotedScalars
                }) + "…"
            }
            return indent + "> " + mark + " " + line
        }
        let more = rows.count - shown.count
        if more > 0 { lines.append(indent + "> … \(more) more \(more == 1 ? "line" : "lines")") }
        return lines
    }
}
