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
                fromBottom: kept.count - 1 - offset
            ))
        }
        return Result(matches: matches.reversed(), total: starts.count)
    }

    /// How many matches the text holds, as `search` counts them.
    static func count(_ needle: String, in text: String) -> Int {
        let pattern = Self.pattern(needle)
        return pattern.isEmpty ? 0 : matchStarts(of: pattern, in: normalized(text)).count
    }

    private static let newline = UInt8(ascii: "\n")
    private static let space = UInt8(ascii: " ")

    private static func pattern(_ needle: String) -> [UInt8] {
        Array(needle.utf8).map(lowercasedASCII)
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
        let end = lineEnd ?? tailWindow
        let matchEnd = min(start + length, end)

        var lead = String(decoding: haystack[(lineStart ?? leadWindow)..<start], as: UTF8.self)
        let leadIsCut = lineStart == nil && leadWindow > 0
        if !leadIsCut {
            lead = String(lead.drop { $0 == " " })
        }
        if leadIsCut || lead.count > excerptLead {
            lead = "…" + lead.suffix(excerptLead)
        }
        let found = String(decoding: haystack[start..<matchEnd], as: UTF8.self)
        var tail = String(decoding: haystack[matchEnd..<end], as: UTF8.self)
        let room = max(0, excerptLength - lead.count - found.count)
        if (lineEnd == nil && tailWindow < haystack.count) || tail.count > room {
            tail = tail.prefix(max(0, room - 1)) + "…"
        }
        let highlight = NSRange(location: (lead as NSString).length, length: (found as NSString).length)
        return (lead + found + tail, highlight)
    }
}
