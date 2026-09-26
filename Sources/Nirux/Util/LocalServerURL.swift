import Foundation

/// A local dev-server URL printed in a terminal, e.g. Vite's
/// `http://localhost:5173/` or Jupyter's `http://127.0.0.1:8888/tree?token=…`.
struct LocalServerURL: Equatable, Hashable, Sendable {
    let isSecure: Bool
    /// Unspecified bind addresses (`0.0.0.0`, `[::]`) are normalized to
    /// `localhost`: they aren't valid destinations and WebKit refuses them.
    let host: String
    let port: Int
    /// Path, query and fragment as printed ("/", "/tree?token=…"), or empty.
    let path: String

    var urlString: String { "\(isSecure ? "https" : "http")://\(host):\(port)\(path)" }

    /// Short label for the title-bar chip.
    var displayName: String { "\(host):\(port)" }

    /// Hosts accepted after the scheme, as printed (lowercased).
    static let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "0.0.0.0", "[::1]", "[::]"]

    /// Port of `urlString` when it points at a loopback host (what a browser
    /// column displays), else nil. Scheme default ports apply when omitted.
    static func loopbackPort(of urlString: String) -> Int? {
        guard let components = URLComponents(string: urlString),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host?.lowercased()
        else { return nil }
        // IPv6 brackets are kept or stripped depending on the Foundation version.
        let bare = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        let bracketed = bare.contains(":") ? "[\(bare)]" : bare
        guard loopbackHosts.contains(bracketed) else { return nil }
        return components.port ?? (scheme == "https" ? 443 : 80)
    }
}

/// Streaming detector for local dev-server URLs in raw PTY output.
///
/// Runs on the PTY read queue for every chunk, so the common case stays a
/// `memchr` sweep over ':' bytes: only a "://" preceded by "http"/"https"
/// starts a real parse. SGR sequences inside a URL are skipped (Vite prints
/// the port in bold); any other escape ends it. A URL cut by the read
/// boundary is carried over and completed by the next chunk.
struct LocalServerURLScanner {
    /// Longest candidate carried across chunks; longer ones are dropped.
    static let maxCandidateLength = 512

    private var carry: [UInt8] = []

    mutating func scan(_ chunk: UnsafeRawBufferPointer) -> [LocalServerURL] {
        guard !chunk.isEmpty else { return [] }
        guard !carry.isEmpty else {
            let result = Self.scanBuffer(chunk)
            carry = result.carryFrom.map { Array(chunk[$0...]) } ?? []
            return result.urls
        }
        var joined = carry
        joined.append(contentsOf: chunk)
        let result = joined.withUnsafeBytes { Self.scanBuffer($0) }
        carry = result.carryFrom.map { Array(joined[$0...]) } ?? []
        return result.urls
    }

    mutating func scan(_ bytes: [UInt8]) -> [LocalServerURL] {
        bytes.withUnsafeBytes { scan($0) }
    }

    // MARK: - Buffer scan

    private enum ParseOutcome {
        case match(LocalServerURL, end: Int)
        case noMatch
        /// The buffer ended mid-URL. `partial` is set once host and port
        /// are complete (a path was being read).
        case incomplete(partial: LocalServerURL?)
    }

    private static let colon = UInt8(ascii: ":")
    private static let slash = UInt8(ascii: "/")
    private static let escape: UInt8 = 0x1B

    private static func scanBuffer(_ buf: UnsafeRawBufferPointer) -> (urls: [LocalServerURL], carryFrom: Int?) {
        guard let base = buf.baseAddress else { return ([], nil) }
        let count = buf.count
        var urls: [LocalServerURL] = []
        var index = 0
        while index < count, let hit = memchr(base + index, Int32(colon), count - index) {
            let colonIndex = base.distance(to: UnsafeRawPointer(hit))
            index = colonIndex + 1
            // "http:" or "http:/" at the very end: the tail carry below keeps it.
            guard colonIndex + 2 < count else { break }
            guard buf[colonIndex + 1] == slash, buf[colonIndex + 2] == slash,
                  let scheme = schemeStart(in: buf, colon: colonIndex)
            else { continue }
            switch parseAfterScheme(buf, from: colonIndex + 3, isSecure: scheme.isSecure) {
            case .match(let url, let end):
                urls.append(url)
                index = end
            case .noMatch:
                index = colonIndex + 3
            case .incomplete(let partial):
                if count - scheme.start <= maxCandidateLength {
                    return (urls, scheme.start)
                }
                // Too long to carry (a huge query string): host and port are
                // known, so offer the server root rather than nothing.
                if let partial {
                    urls.append(LocalServerURL(isSecure: partial.isSecure, host: partial.host, port: partial.port, path: ""))
                }
                return (urls, nil)
            }
        }
        return (urls, partialSchemeStart(in: buf))
    }

    /// "http" or "https" (any case) immediately before the "://" at `colon`.
    private static func schemeStart(in buf: UnsafeRawBufferPointer, colon: Int) -> (start: Int, isSecure: Bool)? {
        if colon >= 5, matchesLowercased(buf, at: colon - 5, httpsPrefix[..<5]) { return (colon - 5, true) }
        if colon >= 4, matchesLowercased(buf, at: colon - 4, httpPrefix[..<4]) { return (colon - 4, false) }
        return nil
    }

    /// Start of a trailing proper prefix of "http://" / "https://" (e.g. a
    /// chunk ending in "…Local: htt"), so the next chunk can complete it.
    private static func partialSchemeStart(in buf: UnsafeRawBufferPointer) -> Int? {
        let count = buf.count
        // Cheap exit for the usual chunk end ("\n", "m" of an SGR, …).
        guard let last = buf.last, "htps:/".utf8.contains(lowercased(last)) else { return nil }
        // "https:/" is the longest proper prefix of either scheme.
        for length in stride(from: min(httpsPrefix.count - 1, count), through: 1, by: -1) {
            let start = count - length
            if matchesLowercased(buf, at: start, httpsPrefix[..<length])
                || (length < httpPrefix.count && matchesLowercased(buf, at: start, httpPrefix[..<length])) {
                return start
            }
        }
        return nil
    }

    private static let httpsPrefix = Array("https://".utf8)
    private static let httpPrefix = Array("http://".utf8)

    private static func matchesLowercased(_ buf: UnsafeRawBufferPointer, at start: Int, _ literal: some Collection<UInt8>) -> Bool {
        var offset = start
        for expected in literal {
            guard offset < buf.count, lowercased(buf[offset]) == expected else { return false }
            offset += 1
        }
        return true
    }

    private static func lowercased(_ byte: UInt8) -> UInt8 {
        (0x41...0x5A).contains(byte) ? byte | 0x20 : byte
    }

    // MARK: - URL parse

    private enum Phase { case host, port, path }

    // One linear state machine over host → port → path; splitting it would
    // scatter the shared cursor/escape handling.
    // swiftlint:disable:next cyclomatic_complexity
    private static func parseAfterScheme(_ buf: UnsafeRawBufferPointer, from start: Int, isSecure: Bool) -> ParseOutcome {
        var cursor = start
        var phase = Phase.host
        var host: [UInt8] = []
        var port = 0
        var portDigits = 0
        var path: [UInt8] = []
        var pathOverflowed = false

        func url(path: [UInt8]) -> LocalServerURL {
            // Host and path bytes are validated printable ASCII.
            let printed = String(bytes: host, encoding: .ascii) ?? ""
            let normalized = printed == "0.0.0.0" || printed == "[::]" ? "localhost" : printed
            return LocalServerURL(
                isSecure: isSecure,
                host: normalized,
                port: port,
                path: pathOverflowed ? "" : String(bytes: trimTrailingPunctuation(path), encoding: .ascii) ?? ""
            )
        }
        func incomplete() -> ParseOutcome {
            .incomplete(partial: phase == .path ? url(path: []) : nil)
        }

        while true {
            guard cursor < buf.count else { return incomplete() }
            var byte = buf[cursor]
            if byte == escape {
                switch skipSGR(buf, at: cursor) {
                case .skipped(let next):
                    cursor = next
                    continue
                case .truncated:
                    return incomplete()
                case .notSGR:
                    byte = 0 // any other escape ends the URL
                }
            }
            switch phase {
            case .host:
                let insideBrackets = host.first == UInt8(ascii: "[") && host.last != UInt8(ascii: "]")
                if byte == colon, !insideBrackets {
                    guard loopbackHostBytes.contains(host) else { return .noMatch }
                    phase = .port
                    cursor += 1
                    continue
                }
                guard host.count < maxHostLength, isHostByte(byte, insideBrackets: insideBrackets) else { return .noMatch }
                host.append(lowercased(byte))
                cursor += 1
            case .port:
                if (0x30...0x39).contains(byte) {
                    guard portDigits < 5 else { return .noMatch }
                    port = port * 10 + Int(byte - 0x30)
                    portDigits += 1
                    cursor += 1
                    continue
                }
                guard portDigits > 0, (1...65_535).contains(port) else { return .noMatch }
                if byte == slash || byte == UInt8(ascii: "?") || byte == UInt8(ascii: "#") {
                    phase = .path
                    continue
                }
                // "localhost:3000abc" isn't a URL boundary.
                if isAlphanumeric(byte) { return .noMatch }
                return .match(url(path: []), end: cursor)
            case .path:
                guard isPathByte(byte) else { return .match(url(path: path), end: cursor) }
                if path.count < maxPathLength {
                    path.append(byte)
                } else {
                    pathOverflowed = true
                }
                cursor += 1
            }
        }
    }

    private enum EscapeOutcome {
        case skipped(next: Int)
        case truncated
        case notSGR
    }

    /// `ESC [ params m` (colors/bold) is transparent inside a URL. Cursor
    /// moves, erases, OSC terminators and the like end it — past them the
    /// bytes belong to another part of the screen.
    private static func skipSGR(_ buf: UnsafeRawBufferPointer, at start: Int) -> EscapeOutcome {
        guard start + 1 < buf.count else { return .truncated }
        guard buf[start + 1] == UInt8(ascii: "[") else { return .notSGR }
        var cursor = start + 2
        while cursor < buf.count, cursor - start < 32 {
            let byte = buf[cursor]
            if (0x40...0x7E).contains(byte) {
                return byte == UInt8(ascii: "m") ? .skipped(next: cursor + 1) : .notSGR
            }
            guard (0x20...0x3F).contains(byte) else { return .notSGR }
            cursor += 1
        }
        return cursor < buf.count ? .notSGR : .truncated
    }

    private static let loopbackHostBytes: Set<[UInt8]> = Set(LocalServerURL.loopbackHosts.map { Array($0.utf8) })
    private static let maxHostLength = LocalServerURL.loopbackHosts.map(\.utf8.count).max() ?? 9
    private static let maxPathLength = 400

    private static func isAlphanumeric(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
    }

    private static func isHostByte(_ byte: UInt8, insideBrackets: Bool) -> Bool {
        isAlphanumeric(byte)
            || byte == UInt8(ascii: ".")
            || byte == UInt8(ascii: "-")
            || byte == UInt8(ascii: "[")
            || byte == UInt8(ascii: "]")
            || (insideBrackets && byte == colon)
    }

    /// Printable ASCII minus the characters that delimit URLs in prose and
    /// markup (quotes, angle brackets, backticks, backslash).
    private static func isPathByte(_ byte: UInt8) -> Bool {
        guard (0x21...0x7E).contains(byte) else { return false }
        return !"\"'<>`\\".utf8.contains(byte)
    }

    /// "see http://localhost:3000/." / "(http://[::]:8000/)" — sentence
    /// punctuation and closing brackets aren't part of the URL.
    private static func trimTrailingPunctuation(_ path: [UInt8]) -> [UInt8] {
        var end = path.count
        while end > 1, ".,;:!?)]}".utf8.contains(path[end - 1]) { end -= 1 }
        return Array(path[..<end])
    }
}
