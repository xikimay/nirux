import Foundation

/// Parses a terminal `file:` link (a cmd+clicked path or a `file://` OSC 8
/// hyperlink as emitted by Claude Code) into an absolute path plus an
/// optional 1-based line number. Line numbers come from a GitHub-style
/// `#L12` fragment or a trailing `:12` suffix.
enum FileLink {
    struct Target: Equatable {
        let path: String
        let line: Int?
    }

    /// `fileExists` is injected so the `:12`-suffix disambiguation is
    /// testable without touching the real filesystem.
    static func parse(
        _ url: URL,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Target? {
        guard url.scheme?.lowercased() == "file" else { return nil }
        let path = url.path
        guard !path.isEmpty else { return nil }

        if let fragment = url.fragment, let line = lineNumber(fromFragment: fragment) {
            return Target(path: path, line: line)
        }

        // Trailing `:12` is only a line number when stripping it yields a
        // file that exists — paths may legally contain colons, and a real
        // file always wins over the line interpretation.
        if !fileExists(path),
           let (stripped, line) = splitLineSuffix(path),
           fileExists(stripped) {
            return Target(path: stripped, line: line)
        }
        return Target(path: path, line: nil)
    }

    /// `L12` → 12. Anything else (including bare digits) is not a line.
    private static func lineNumber(fromFragment fragment: String) -> Int? {
        guard fragment.hasPrefix("L"),
              let line = Int(fragment.dropFirst()),
              line >= 1
        else { return nil }
        return line
    }

    /// `/a/b.swift:12` → (`/a/b.swift`, 12); nil when there is no all-digit
    /// suffix after the last colon.
    private static func splitLineSuffix(_ path: String) -> (path: String, line: Int)? {
        guard let colon = path.lastIndex(of: ":"),
              colon != path.startIndex,
              let line = Int(path[path.index(after: colon)...]),
              line >= 1
        else { return nil }
        return (String(path[..<colon]), line)
    }
}
