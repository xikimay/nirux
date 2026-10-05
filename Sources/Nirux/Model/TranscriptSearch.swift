import Foundation

/// Search Everywhere in Claude transcripts (`transcript_path` in the session
/// history): a conversation in Claude's no-flicker mode runs on the
/// terminal's alternate screen, which keeps no scrollback, and a past one
/// has no terminal at all. Read-only and read in place: nothing is kept but
/// the matches shown.
///
/// The transcript format is Claude Code's own and may change. Only what the
/// user typed and what Claude answered is searched: the text of a `user`
/// line the user wrote (its `origin` is the human's, when it says), of a
/// prompt queued while Claude worked (a `queued_command` attachment), and of
/// an `assistant` line's `text` parts. Not tool calls, tool output,
/// thinking, task notifications, command output, summaries, meta or
/// subagent lines. Lines that don't parse, or don't look like that, are
/// skipped.
///
/// Bounded: at most `maxBytesPerTranscript` of each file (its end, the most
/// recent part), lines up to `maxLineBytes`, and one `Budget` of bytes and
/// time across the transcripts of a search. A line is parsed only when its
/// bytes hold the needle, as JSON writes it. Run it off the main thread.
enum TranscriptSearch {
    enum Role: Equatable, Sendable {
        case user, claude
    }

    struct Match: Equatable, Sendable {
        let role: Role
        /// The matching line of the message, cut around the match.
        let excerpt: String
        /// The match in `excerpt`, in UTF-16 units.
        let highlight: NSRange
        /// When the message was written, if the transcript says.
        let timestamp: Date?
    }

    struct Result: Equatable, Sendable {
        /// The newest matches first, at most the limit asked for.
        let matches: [Match]
        /// Every match read, beyond the limit too.
        let total: Int
        /// The name the session was given (`claude --name`, `/rename`).
        let customTitle: String?
        /// The title Claude gave the session itself.
        let aiTitle: String?
        /// Only the end of the file was read: it is longer than
        /// `maxBytesPerTranscript`.
        let isPartial: Bool
        /// The budget ran out before the end of the file.
        let isCut: Bool
    }

    /// What one search may still read, shared by its transcripts. The time
    /// is the real bound; the bytes, a guard against a runaway file.
    struct Budget {
        var bytes: Int
        let deadline: TimeInterval

        static func standard(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Budget {
            Budget(bytes: 8 * 1024 * 1024 * 1024, deadline: now + 5)
        }

        var isSpent: Bool { bytes <= 0 || ProcessInfo.processInfo.systemUptime >= deadline }
    }

    static let maxBytesPerTranscript = 64 * 1024 * 1024
    /// A prompt can carry a pasted file; a line past this is a tool's.
    static let maxLineBytes = 2 * 1024 * 1024
    static let chunkSize = 1024 * 1024

    /// Nil when the file can't be read (gone, not a regular file, a
    /// symbolic link). `maxBytes` and `chunkSize`: tests.
    static func search(
        _ needle: String, transcriptAt path: String, limit: Int, budget: inout Budget,
        isCancelled: () -> Bool = { false }, maxBytes: Int = maxBytesPerTranscript, chunkSize: Int = chunkSize
    ) -> Result? {
        guard !needle.isEmpty, limit > 0 else { return nil }
        var scanner = Scanner(needle: needle, limit: limit)
        guard let reading = readLines(
            transcriptAt: path, budget: &budget, isCancelled: isCancelled, maxBytes: maxBytes, chunkSize: chunkSize,
            line: { scanner.line($0) }
        ) else { return nil }
        return Result(
            matches: scanner.matches.reversed(), total: scanner.total, customTitle: scanner.titles.custom,
            aiTitle: scanner.titles.ai, isPartial: reading.isPartial, isCut: reading.isCut
        )
    }

    /// How much of a transcript `readLines` read.
    struct Reading: Equatable, Sendable {
        /// Only the end of the file: it is longer than the `maxBytes` asked.
        let isPartial: Bool
        /// The budget ran out, or the read was cancelled, before the end.
        let isCut: Bool
    }

    /// Hands `line` each line of the transcript at `path`, oldest first,
    /// without its newline: at most the last `maxBytes` of the file (the
    /// first, `fromStart`), lines up to `maxLineBytes` (longer ones are
    /// skipped), while `budget` lasts. Nil when the file can't be read
    /// (gone, not a regular file, a symbolic link).
    static func readLines(
        transcriptAt path: String, budget: inout Budget, isCancelled: () -> Bool = { false },
        maxBytes: Int = maxBytesPerTranscript, chunkSize: Int = chunkSize, fromStart: Bool = false,
        line: (UnsafeRawBufferPointer) -> Void
    ) -> Reading? {
        let descriptor = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }

        var splitter = LineSplitter()
        let size = Int(info.st_size)
        var offset = fromStart ? 0 : max(0, size - maxBytes)
        let end = fromStart ? min(size, maxBytes) : size
        if offset > 0 {
            // Started mid-file: skip to the next line, unless one starts here.
            var previous: UInt8 = 0
            if pread(descriptor, &previous, 1, off_t(offset - 1)) == 1 { splitter.isSkippingLine = previous != 0x0A }
        }
        var chunk = Data(count: max(1, chunkSize))
        var isCut = false
        while offset < end {
            if budget.isSpent || isCancelled() {
                isCut = true
                break
            }
            let wanted = min(chunk.count, end - offset)
            let count = chunk.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, wanted, off_t(offset)) }
            guard count > 0 else { break }
            offset += count
            budget.bytes -= count
            chunk.prefix(count).withUnsafeBytes { splitter.consume($0, line: line) }
        }
        // A line cut by `end` isn't whole.
        if !isCut, end == size { splitter.finish(line: line) }
        return Reading(isPartial: size > maxBytes, isCut: isCut)
    }

    /// Splits bytes read in chunks into lines: lines are found with
    /// `memchr`, and a line cut by a chunk's end is carried over. A line
    /// longer than `maxLineBytes` is skipped.
    private struct LineSplitter {
        var isSkippingLine = false
        private var partial = Data()

        mutating func consume(_ buffer: UnsafeRawBufferPointer, line: (UnsafeRawBufferPointer) -> Void) {
            guard let base = buffer.baseAddress else { return }
            var start = 0
            while start < buffer.count, let found = memchr(base + start, 0x0A, buffer.count - start) {
                let newline = base.distance(to: UnsafeRawPointer(found))
                let piece = UnsafeRawBufferPointer(rebasing: buffer[start..<newline])
                if isSkippingLine {
                    isSkippingLine = false
                } else if partial.isEmpty {
                    if piece.count <= maxLineBytes { line(piece) }
                } else {
                    var whole = partial
                    whole.append(contentsOf: piece)
                    if whole.count <= maxLineBytes { whole.withUnsafeBytes { line($0) } }
                }
                partial = Data()
                start = newline + 1
            }
            let rest = UnsafeRawBufferPointer(rebasing: buffer[start...])
            guard !isSkippingLine, !rest.isEmpty else { return }
            if partial.count + rest.count > maxLineBytes {
                partial = Data()
                isSkippingLine = true
            } else {
                partial.append(contentsOf: rest)
            }
        }

        /// The last line, when the file doesn't end with a newline.
        mutating func finish(line: (UnsafeRawBufferPointer) -> Void) {
            let last = partial
            partial = Data()
            if !isSkippingLine, !last.isEmpty { last.withUnsafeBytes { line($0) } }
        }
    }

    /// Keeps the lines that may match, and searches their messages.
    private struct Scanner {
        let needle: String
        let limit: Int
        /// The needle as JSON writes it, ASCII letters lowercased.
        let pattern: [UInt8]
        /// Oldest first; the newest `limit` kept.
        var matches: [Match] = []
        var total = 0
        var titles = Titles()

        init(needle: String, limit: Int) {
            self.needle = needle
            self.limit = limit
            pattern = Array(TranscriptSearch.jsonEscaped(needle).utf8).map(lowercasedASCII)
        }

        mutating func line(_ bytes: UnsafeRawBufferPointer) {
            if titles.read(bytes) { return }
            // Most lines can't match, and tool output is most of the bytes:
            // skip their JSON.
            guard TranscriptSearch.containsIgnoringASCIICase(bytes, pattern), !TranscriptSearch.isToolResult(bytes),
                  let object = TranscriptSearch.object(bytes), let message = TranscriptSearch.message(in: object)
            else { return }
            let found = ScrollbackSearch.search(needle, in: message.text, limit: limit)
            guard found.total > 0 else { return }
            total += found.total
            for match in found.matches.reversed() {
                matches.append(Match(
                    role: message.role, excerpt: match.excerpt, highlight: match.highlight, timestamp: message.timestamp
                ))
            }
            if matches.count > limit { matches.removeFirst(matches.count - limit) }
        }
    }

    /// The names a session was given, as its title lines say: the last of
    /// each kind wins.
    struct Titles: Equatable, Sendable {
        /// `claude --name`, `/rename`.
        var custom: String?
        /// The title Claude gave the session itself.
        var ai: String?

        /// True when `bytes` is a title line, now read.
        mutating func read(_ bytes: UnsafeRawBufferPointer) -> Bool {
            guard TranscriptSearch.contains(bytes, Self.marker), let object = TranscriptSearch.object(bytes) else {
                return false
            }
            switch object["type"] as? String {
            case "custom-title": custom = Self.title(object["customTitle"]) ?? custom
            case "ai-title": ai = Self.title(object["aiTitle"]) ?? ai
            default: return false
            }
            return true
        }

        private static func title(_ value: Any?) -> String? {
            (value as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(200)) }
        }

        /// `"type":"custom-title"` and `"type":"ai-title"` lines.
        private static let marker = Array("-title\"".utf8)
    }

    /// A message of the conversation: what the user typed, or Claude's
    /// answer.
    struct Message: Equatable, Sendable {
        let role: Role
        let text: String
        /// When it was written, if the line says.
        let timestamp: Date?
    }

    private static let toolResultMarker = Array("\"type\":\"tool_result\"".utf8)
    /// Claude writes milliseconds; a date without them still reads.
    private static let dateStyles = [
        Date.ISO8601FormatStyle(includingFractionalSeconds: true), Date.ISO8601FormatStyle()
    ]
    /// What a harness writes into a `user` line, or a part of one, not
    /// the user. A pasted block (`<pasted_content>`) is the user's.
    private static let harnessPrefixes = [
        "<command-name>", "<command-message>", "<command-args>", "<local-command-stdout>",
        "<local-command-stderr>", "<bash-stdout>", "<bash-stderr>", "<task-notification>",
        "<system-reminder>", "[Request interrupted"
    ]

    /// A line holding tool output (`tool_result`), most of a transcript's
    /// bytes: never a message, so never worth parsing.
    static func isToolResult(_ bytes: UnsafeRawBufferPointer) -> Bool {
        contains(bytes, toolResultMarker)
    }

    static func contains(_ bytes: UnsafeRawBufferPointer, _ marker: [UInt8]) -> Bool {
        guard let base = bytes.baseAddress else { return false }
        return marker.withUnsafeBytes { memmem(base, bytes.count, $0.baseAddress, marker.count) != nil }
    }

    /// The line's JSON object, if it is one.
    static func object(_ bytes: UnsafeRawBufferPointer) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(bytes))) as? [String: Any]
    }

    /// The text a conversation shows of this line: a prompt the user
    /// typed, or Claude's answer. Nil for anything else.
    static func message(in object: [String: Any]) -> Message? {
        for flag in ["isSidechain", "isMeta", "isCompactSummary", "isVisibleInTranscriptOnly", "isApiErrorMessage"]
        where object[flag] as? Bool == true {
            return nil
        }
        let role: Role
        let content: Any?
        var timestamp = object["timestamp"]
        switch object["type"] as? String {
        case "user":
            guard isHuman(object) else { return nil }
            role = .user
            content = (object["message"] as? [String: Any])?["content"]
        case "assistant":
            role = .claude
            content = (object["message"] as? [String: Any])?["content"]
        case "attachment":
            // A prompt typed while Claude worked, queued for its next turn.
            guard let attachment = object["attachment"] as? [String: Any],
                  attachment["type"] as? String == "queued_command",
                  attachment["commandMode"] as? String == "prompt",
                  attachment["isMeta"] as? Bool != true, isHuman(attachment) else { return nil }
            role = .user
            content = attachment["prompt"]
            timestamp = attachment["timestamp"] ?? timestamp
        default:
            return nil
        }
        let texts: [String]
        if let content = content as? String {
            texts = [content]
        } else if let parts = content as? [[String: Any]] {
            texts = parts.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
        } else {
            return nil
        }
        let text = (role == .user ? texts.compactMap(typed) : texts).joined(separator: "\n")
        guard !text.isEmpty else { return nil }
        let date = (timestamp as? String).flatMap { text in
            dateStyles.lazy.compactMap { try? $0.parse(text) }.first
        }
        return Message(role: role, text: text, timestamp: date)
    }

    /// What the user typed of a prompt's text: nil for what a harness
    /// wrote; of a slash command, its arguments (`/review the parser`).
    private static func typed(_ text: String) -> String? {
        let trimmed = text.drop { $0.isWhitespace }
        guard harnessPrefixes.contains(where: trimmed.hasPrefix) else { return text }
        guard trimmed.hasPrefix("<command-"), let start = text.range(of: "<command-args>"),
              let end = text.range(of: "</command-args>", range: start.upperBound..<text.endIndex)
        else { return nil }
        let arguments = text[start.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return arguments.isEmpty ? nil : arguments
    }

    /// The human typed it, as far as the line says: task notifications
    /// and peer messages carry another `origin`; older lines carry none.
    private static func isHuman(_ object: [String: Any]) -> Bool {
        guard let origin = object["origin"] as? [String: Any], let kind = origin["kind"] as? String else { return true }
        return kind == "human"
    }

    /// `pattern` in `bytes`, ASCII letters in either case: `memchr`
    /// finds each place its first byte, in either case, starts.
    private static func containsIgnoringASCIICase(_ buffer: UnsafeRawBufferPointer, _ pattern: [UInt8]) -> Bool {
        guard let first = pattern.first, let base = buffer.baseAddress, buffer.count >= pattern.count else {
            return false
        }
        let lastStart = buffer.count - pattern.count
        for candidate in Set([first, uppercasedASCII(first)]) {
            var from = 0
            while from <= lastStart, let found = memchr(base + from, Int32(candidate), lastStart + 1 - from) {
                let index = base.distance(to: UnsafeRawPointer(found))
                if (1..<pattern.count).allSatisfy({ lowercasedASCII(buffer[index + $0]) == pattern[$0] }) {
                    return true
                }
                from = index + 1
            }
        }
        return false
    }

    /// How JSON.stringify writes `text` inside a string: quotes, backslashes
    /// and control characters escaped, the rest as it is.
    static func jsonEscaped(_ text: String) -> String {
        var escaped = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": escaped += "\\\""
            case "\\": escaped += "\\\\"
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            case "\u{8}": escaped += "\\b"
            case "\u{C}": escaped += "\\f"
            case _ where scalar.value < 0x20: escaped += String(format: "\\u%04x", scalar.value)
            default: escaped.unicodeScalars.append(scalar)
            }
        }
        return escaped
    }

    /// ASCII letters match in either case, as in `ScrollbackSearch`.
    private static func lowercasedASCII(_ byte: UInt8) -> UInt8 {
        (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte) ? byte + 32 : byte
    }

    private static func uppercasedASCII(_ byte: UInt8) -> UInt8 {
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) ? byte - 32 : byte
    }
}
