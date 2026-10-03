import Foundation

/// Finds a needle in a terminal's text (see `TerminalScreenText`) the way
/// Ghostty's own search does, so that the find bar opened on a result
/// highlights the same match: ASCII letters match in either case, any other
/// character only itself; each row is trimmed of trailing spaces and rows
/// are joined by "\n", so a needle may span a hard line break.
enum ScrollbackSearch {
    struct Match: Equatable, Sendable {
        /// 1-based, counted from the top of the scrollback.
        let line: Int
        /// The line, cut around the match when long (see `excerpt`).
        let excerpt: String
        /// The match in `excerpt`, in UTF-16 units (NSString ranges).
        let highlight: NSRange
        /// Position among the terminal's matches, the newest being 0:
        /// Ghostty's first "next match" selects the newest one, and each
        /// further one the match above. Ghostty 1.3.1 orders the matches on
        /// screen by page when the screen spans two of its pages, so a pick
        /// among those may select another match on screen; matches above
        /// the screen keep their order.
        let fromBottom: Int
        /// The match and what surrounds it in its line, hashed: a pick
        /// finds it again in text that changed since (`relocate`).
        let context: Int
    }

    struct Result: Equatable, Sendable {
        /// The newest matches first, at most the limit asked for.
        let matches: [Match]
        /// Every match in the text, beyond the limit too.
        let total: Int
    }

    /// Characters kept before the match in a long line's excerpt.
    static let excerptLead = 40
    static let excerptLength = 200

    static func search(_ needle: String, in text: String, limit: Int) -> Result {
        let pattern = Self.pattern(needle)
        guard !pattern.isEmpty, limit > 0 else { return Result(matches: [], total: 0) }
        let haystack = normalized(text)
        let starts = matchStarts(of: pattern, in: haystack)
        let kept = starts.suffix(limit)
        guard let first = kept.first else { return Result(matches: [], total: starts.count) }

        // Lines up to the first kept match, then match to match.
        var line = 1 + haystack[..<first].reduce(0) { $1 == newline ? $0 + 1 : $0 }
        var position = first
        var matches: [Match] = []
        matches.reserveCapacity(kept.count)
        for (offset, start) in kept.enumerated() {
            line += haystack[position..<start].reduce(0) { $1 == newline ? $0 + 1 : $0 }
            position = start
            let (excerpt, highlight) = excerpt(at: start, length: pattern.count, in: haystack)
            matches.append(Match(
                line: line,
                excerpt: excerpt,
                highlight: highlight,
                fromBottom: kept.count - 1 - offset,
                context: context(at: start, length: pattern.count, in: haystack)
            ))
        }
        return Result(matches: matches.reversed(), total: starts.count)
    }

    /// Where a match found earlier stands in `text`, which changed since:
    /// output printed after it adds matches below it, and the scrollback
    /// limit drops lines, matches with them, above it. Matches only move
    /// up, so of the ones with its `context`, the first at or above its old
    /// `fromBottom`, else the nearest below; when none is left, its old
    /// place. With the text's match count.
    static func relocate(
        context: Int, fromBottom: Int, of needle: String, in text: String
    ) -> (fromBottom: Int, total: Int) {
        let pattern = Self.pattern(needle)
        guard !pattern.isEmpty else { return (0, 0) }
        let haystack = normalized(text)
        let starts = matchStarts(of: pattern, in: haystack)
        let total = starts.count
        let old = min(max(fromBottom, 0), max(total - 1, 0))
        let isIt = { (rank: Int) in Self.context(at: starts[total - 1 - rank], length: pattern.count, in: haystack) == context }
        let found = (old..<total).first(where: isIt) ?? (0..<old).reversed().first(where: isIt)
        return (found ?? old, total)
    }

    private static let newline = UInt8(ascii: "\n")
    private static let space = UInt8(ascii: " ")
    /// Bytes of a match's line hashed on each side of it (`Match.context`).
    private static let contextBytes = 128

    private static func context(at start: Int, length: Int, in haystack: [UInt8]) -> Int {
        let lower = max(0, start - contextBytes)
        let upper = min(haystack.count, start + length + contextBytes)
        let from = haystack[lower..<start].lastIndex(of: newline).map { $0 + 1 } ?? lower
        let to = haystack[(start + length)..<upper].firstIndex(of: newline) ?? upper
        var hasher = Hasher()
        haystack[from..<to].withUnsafeBytes { hasher.combine(bytes: $0) }
        hasher.combine(start - from)
        return hasher.finalize()
    }

    private static func pattern(_ needle: String) -> [UInt8] {
        Array(needle.utf8).map(lowercasedASCII)
    }

    private static func isContinuation(_ byte: UInt8) -> Bool {
        byte & 0xC0 == 0x80
    }

    private static func lowercasedASCII(_ byte: UInt8) -> UInt8 {
        (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte) ? byte + 32 : byte
    }

    /// The text's bytes, each row trimmed of trailing spaces.
    private static func normalized(_ text: String) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(text.utf8.count)
        var pendingSpaces = 0
        for byte in text.utf8 {
            if byte == space {
                pendingSpaces += 1
                continue
            }
            if byte != newline, pendingSpaces > 0 {
                bytes.append(contentsOf: repeatElement(space, count: pendingSpaces))
            }
            pendingSpaces = 0
            bytes.append(byte)
        }
        return bytes
    }

    /// Offsets of the matches, oldest first. Like Ghostty's, they may
    /// overlap: the search resumes one byte after a match's start, so "aa"
    /// matches "aaa" twice. A needle never starts on a UTF-8 continuation
    /// byte, so no match starts inside a character.
    private static func matchStarts(of pattern: [UInt8], in haystack: [UInt8]) -> [Int] {
        guard haystack.count >= pattern.count else { return [] }
        return (0...(haystack.count - pattern.count)).filter { index in
            pattern.indices.allSatisfy { lowercasedASCII(haystack[index + $0]) == pattern[$0] }
        }
    }

    /// A long line keeps `excerptLead` characters before the match and is
    /// cut to `excerptLength` characters, ellipses included; leading spaces
    /// go. Only the bytes around the match are decoded: a soft-wrapped line
    /// can be megabytes long (a minified file, a JSON log).
    private static func excerpt(at start: Int, length: Int, in haystack: [UInt8]) -> (String, NSRange) {
        // Enough bytes for the characters kept, at four bytes each, plus
        // one character cut by the window's edge.
        let leadBytes = excerptLead * 4 + 4
        let tailBytes = excerptLength * 4 + 4
        let leadWindow = max(0, start - leadBytes)
        let lineStart = haystack[leadWindow..<start].lastIndex(of: newline).map { $0 + 1 }
        let tailWindow = min(haystack.count, start + length + tailBytes)
        let lineEnd = haystack[start..<tailWindow].firstIndex(of: newline)
        let leadIsCut = lineStart == nil && leadWindow > 0
        let tailIsCut = lineEnd == nil && tailWindow < haystack.count
        // A cut window starts and ends on a code point, and the character
        // it may have split (a modifier, a combining mark) goes.
        var leadStart = lineStart ?? leadWindow
        while leadIsCut, leadStart < start, isContinuation(haystack[leadStart]) { leadStart += 1 }
        var end = lineEnd ?? tailWindow
        while tailIsCut, end > start + length, isContinuation(haystack[end]) { end -= 1 }
        let matchEnd = min(start + length, end)

        var lead = String(decoding: haystack[leadStart..<start], as: UTF8.self)
        if leadIsCut {
            lead = String(lead.dropFirst())
        } else {
            lead = String(lead.drop { $0 == " " })
        }
        if leadIsCut || lead.count > excerptLead {
            lead = "…" + lead.suffix(excerptLead)
        }
        let found = String(decoding: haystack[start..<matchEnd], as: UTF8.self)
        var tail = String(decoding: haystack[matchEnd..<end], as: UTF8.self)
        if tailIsCut {
            tail = String(tail.dropLast())
        }
        let room = max(0, excerptLength - lead.count - found.count)
        if tailIsCut || tail.count > room {
            tail = tail.prefix(max(0, room - 1)) + "…"
        }
        let highlight = NSRange(location: (lead as NSString).length, length: (found as NSString).length)
        return (lead + found + tail, highlight)
    }
}
