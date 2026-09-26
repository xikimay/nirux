import Foundation

/// One setting read from a Ghostty config file. The trimmed source line is
/// kept verbatim so Nirux can hand it back to libghostty unchanged and get
/// Ghostty's own parsing semantics (bare boolean keys, quoting, …).
struct GhosttyConfigEntry: Equatable, Sendable {
    /// Setting name: the text before the first `=`, or the whole line.
    let key: String
    /// Value as Ghostty interprets it: trimmed, one pair of surrounding
    /// double quotes removed. Empty for a bare key.
    let value: String
    /// Trimmed source line.
    let line: String
    /// File the entry was read from, for logs.
    let source: String
    let lineNumber: Int
}

/// Reads the user's Ghostty configuration the way Ghostty 1.3 does, without
/// going through libghostty (which would look under Nirux's bundle id and
/// ignore `config-file` includes).
enum GhosttyConfigFile {
    /// Upper bound on files read, including `config-file` includes.
    static let maxFiles = 32
    /// Longest line Ghostty reads: its LineIterator buffer is 4096 bytes,
    /// two of which hold a `--` prefix. A longer line ends the file.
    static let maxLineBytes = 4094

    /// Default config files in Ghostty's load order (see `loadDefaultFiles`
    /// in ghostty/src/config/Config.zig): the legacy `config` then
    /// `config.ghostty`, first under `$XDG_CONFIG_HOME/ghostty`, then under
    /// Ghostty's Application Support directory.
    static func defaultPaths(environment: [String: String], home: String) -> [String] {
        let appSupport = (home as NSString).appendingPathComponent("Library/Application Support/com.mitchellh.ghostty")
        let xdg = (xdgConfigHome(environment: environment, home: home) as NSString).appendingPathComponent("ghostty")
        return [xdg, appSupport].flatMap { dir in
            ["config", "config.ghostty"].map { (dir as NSString).appendingPathComponent($0) }
        }
    }

    /// `$XDG_CONFIG_HOME`, or `~/.config` when unset or not absolute.
    static func xdgConfigHome(environment: [String: String], home: String) -> String {
        if let value = environment["XDG_CONFIG_HOME"], value.hasPrefix("/") {
            return value
        }
        return (home as NSString).appendingPathComponent(".config")
    }

    /// Parses Ghostty's `key = value` format (LineIterator in
    /// ghostty/src/cli/args.zig): lines are split on `\n` and trimmed of
    /// spaces, tabs and `\r`; blank lines and lines starting with `#` are
    /// skipped. (Its line length limit applies to raw bytes, so
    /// `readRegularFile` enforces it.)
    static func parse(_ contents: String, source: String) -> [GhosttyConfigEntry] {
        let whitespace = CharacterSet(charactersIn: " \t\r")
        // Swift treats "\r\n" as a single Character, so split on the
        // scalar instead of the Character.
        let rawLines = contents.unicodeScalars
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String(String.UnicodeScalarView($0)) }

        var entries: [GhosttyConfigEntry] = []
        for (index, rawLine) in rawLines.enumerated() {
            let line = rawLine.trimmingCharacters(in: whitespace)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }

            let key: String
            var value = ""
            if let equals = line.firstIndex(of: "=") {
                key = line[..<equals].trimmingCharacters(in: whitespace)
                value = line[line.index(after: equals)...].trimmingCharacters(in: whitespace)
                if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                    value = String(value.dropFirst().dropLast())
                }
            } else {
                key = line
            }
            entries.append(GhosttyConfigEntry(
                key: key, value: value, line: line, source: source, lineNumber: index + 1
            ))
        }
        return entries
    }

    /// Loads `paths` in order, then follows `config-file` includes the way
    /// Ghostty's `loadRecursiveFiles` does: includes are queued and read
    /// after every default file, relative paths resolve against the
    /// including file's directory, a `?` prefix marks the include optional,
    /// each include is read at most once, and an empty value clears the
    /// queue. Missing or unreadable files are skipped.
    ///
    /// `readFile` is injected so tests don't touch the real filesystem.
    static func load(
        paths: [String],
        home: String,
        readFile: (String) -> String? = readRegularFile
    ) -> [GhosttyConfigEntry] {
        var entries: [GhosttyConfigEntry] = []
        var includes: [String] = []
        var filesRead = 0

        func ingest(_ path: String) {
            guard filesRead < maxFiles, let contents = readFile(path) else { return }
            filesRead += 1
            let directory = (path as NSString).deletingLastPathComponent
            for entry in parse(contents, source: path) {
                guard entry.key == "config-file" else {
                    entries.append(entry)
                    continue
                }
                if let include = includePath(entry.value, relativeTo: directory, home: home) {
                    includes.append(include)
                } else if entry.value.isEmpty, entry.line.contains("=") {
                    includes.removeAll()
                }
            }
        }

        paths.forEach(ingest)
        // Index loop, not for-in: included files can queue more includes
        // (and an empty `config-file` can clear the queue). Like Ghostty's
        // cycle check, only includes are tracked: an include may re-read a
        // default file.
        var included = Set<String>()
        var index = 0
        while index < includes.count {
            if included.insert(includes[index]).inserted {
                ingest(includes[index])
            }
            index += 1
        }
        return entries
    }

    /// Absolute path for a `config-file` value (Ghostty's Path.parse and
    /// expand), or nil when empty. Optional (`?`) and required includes are
    /// treated alike: a missing file is skipped either way.
    static func includePath(_ value: String, relativeTo directory: String, home: String) -> String? {
        var path = value.hasPrefix("?") ? String(value.dropFirst()) : value
        if path.count >= 2, path.hasPrefix("\""), path.hasSuffix("\"") {
            path = String(path.dropFirst().dropLast())
        }
        guard !path.isEmpty else { return nil }
        if path.hasPrefix("~/") {
            path = (home as NSString).appendingPathComponent(String(path.dropFirst(2)))
        } else if !path.hasPrefix("/") {
            path = (directory as NSString).appendingPathComponent(path)
        }
        return (path as NSString).standardizingPath
    }

    /// Contents of a regular file, nil otherwise, cut before the first
    /// line longer than `maxLineBytes` as Ghostty stops reading there.
    /// Decoded leniently, as Ghostty reads bytes: an invalid UTF-8 sequence
    /// only garbles its own line instead of discarding the file.
    static func readRegularFile(_ path: String) -> String? {
        guard isRegularFile(path) else { return nil }
        guard let data = FileManager.default.contents(atPath: path) else {
            NSLog("[GhosttyConfig] cannot read %@", path)
            return nil
        }
        // Lossy on purpose: invalid bytes become U+FFFD.
        let contents = String(decoding: truncatedAtOverlongLine(data), as: UTF8.self) // swiftlint:disable:this optional_data_string_conversion
        return contents.hasPrefix("\u{FEFF}") ? String(contents.dropFirst()) : contents
    }

    /// `data` up to the first line longer than `maxLineBytes`.
    static func truncatedAtOverlongLine(_ data: Data) -> Data {
        var lineStart = data.startIndex
        for index in data.indices where data[index] == UInt8(ascii: "\n") {
            if index - lineStart > maxLineBytes { return data[..<lineStart] }
            lineStart = index + 1
        }
        return data.endIndex - lineStart > maxLineBytes ? data[..<lineStart] : data
    }

    /// True for a regular file, following symlinks. Rejects FIFOs and
    /// devices, which could block or never end.
    static func isRegularFile(_ path: String) -> Bool {
        var info = stat()
        return stat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
    }
}
