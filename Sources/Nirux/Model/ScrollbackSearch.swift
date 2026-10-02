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
        /// further one the match above.
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
        let pattern = Array(needle.utf8).map(lowercasedASCII)
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
            let lineStart = haystack[..<start].lastIndex(of: newline).map { $0 + 1 } ?? 0
            let lineEnd = haystack[start...].firstIndex(of: newline) ?? haystack.count
            let matchEnd = min(start + pattern.count, lineEnd)
            let (excerpt, highlight) = excerpt(
                before: haystack[lineStart..<start],
                match: haystack[start..<matchEnd],
                after: haystack[matchEnd..<lineEnd]
            )
            matches.append(Match(
                line: line,
                excerpt: excerpt,
                highlight: highlight,
                fromBottom: kept.count - 1 - offset
            ))
        }
        return Result(matches: matches.reversed(), total: starts.count)
    }

    private static let newline = UInt8(ascii: "\n")
    private static let space = UInt8(ascii: " ")

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

    /// Offsets of the matches, oldest first. A match resumes the search
    /// after itself, as Ghostty's does.
    private static func matchStarts(of pattern: [UInt8], in haystack: [UInt8]) -> [Int] {
        guard haystack.count >= pattern.count else { return [] }
        var starts: [Int] = []
        var index = 0
        let last = haystack.count - pattern.count
        while index <= last {
            var matched = true
            for (offset, byte) in pattern.enumerated() where lowercasedASCII(haystack[index + offset]) != byte {
                matched = false
                break
            }
            if matched {
                starts.append(index)
                index += pattern.count
            } else {
                index += 1
            }
        }
        return starts
    }

    /// A long line keeps `excerptLead` characters before the match and is
    /// cut to `excerptLength` characters, ellipses included; leading spaces
    /// go.
    private static func excerpt(
        before: ArraySlice<UInt8>, match: ArraySlice<UInt8>, after: ArraySlice<UInt8>
    ) -> (String, NSRange) {
        var lead = String(decoding: before, as: UTF8.self)
        lead = String(lead.drop { $0 == " " })
        if lead.count > excerptLead {
            lead = "…" + lead.suffix(excerptLead)
        }
        let found = String(decoding: match, as: UTF8.self)
        var tail = String(decoding: after, as: UTF8.self)
        let room = max(0, excerptLength - lead.count - found.count)
        if tail.count > room {
            tail = tail.prefix(max(0, room - 1)) + "…"
        }
        let highlight = NSRange(location: (lead as NSString).length, length: (found as NSString).length)
        return (lead + found + tail, highlight)
    }
}
