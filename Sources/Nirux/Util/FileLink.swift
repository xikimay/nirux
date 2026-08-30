import Foundation

/// Validated destination for a link coming from Ghostty. Keeping parsing
/// pure makes malformed OSC 8 links harmless before they reach AppKit or
/// WebKit.
enum TerminalLinkTarget: Equatable, Sendable {
    case web(URL)
    case file(URL)
    case external(URL)

    static func parse(_ rawValue: String) -> TerminalLinkTarget? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              let url = components.url
        else { return nil }

        switch scheme {
        case "http", "https":
            guard components.host?.isEmpty == false else { return nil }
            return .web(url)
        case "file":
            guard url.isFileURL, !url.path.isEmpty else { return nil }
            return .file(url)
        case "javascript", "data":
            return nil
        default:
            return .external(url)
        }
    }
}

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

        // Trailing `:12` (or compiler-style `:12:5`) is only a line number
        // when stripping it yields a file that exists — paths may legally
        // contain colons, and a real file always wins over the line
        // interpretation.
        if !fileExists(path), let (stripped, line) = splitLineSuffix(path) {
            if fileExists(stripped) {
                return Target(path: stripped, line: line)
            }
            // `:line:col` — the first number is the line, the column is
            // dropped (the editor jump is line-based).
            if let (stripped2, line2) = splitLineSuffix(stripped), fileExists(stripped2) {
                return Target(path: stripped2, line: line2)
            }
        }
        return Target(path: path, line: nil)
    }

    /// True when the editor should open this path: missing (the editor
    /// surfaces a readable alert) or a regular text file. Directories,
    /// FIFOs, and binary content go to the system handler instead —
    /// Finder / Preview do those jobs; Monaco can't.
    static func opensInEditor(path: String) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else {
            return true
        }
        guard attrs[.type] as? FileAttributeType == .typeRegular else { return false }
        guard let handle = FileHandle(forReadingAtPath: path) else { return true }
        defer { try? handle.close() }
        guard let prefix = try? handle.read(upToCount: 4096) else { return true }
        // UTF-16 BOM files are text despite being full of NUL bytes.
        if prefix.starts(with: [0xFF, 0xFE]) || prefix.starts(with: [0xFE, 0xFF]) { return true }
        return !prefix.contains(0)
    }

    /// `L12` → 12; GitHub range fragments (`L12-L20`) yield the first
    /// line. Anything else (including bare digits) is not a line.
    private static func lineNumber(fromFragment fragment: String) -> Int? {
        guard fragment.hasPrefix("L"),
              let line = Int(fragment.dropFirst().prefix(while: \.isNumber)),
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
