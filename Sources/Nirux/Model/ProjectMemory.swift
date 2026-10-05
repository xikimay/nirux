import Foundation

/// Claude Code's auto-memory for a repository: the facts its sessions note
/// for themselves, one Markdown file each, in one folder per repository
/// (see `ProjectMemory+Location`). `MEMORY.md` indexes them, one line per
/// memory, and Claude Code reads it at the start of every session.
///
/// A memory file starts with a frontmatter:
///
///     ---
///     name: review-workflow
///     description: one-line summary
///     metadata:
///       type: user | feedback | project | reference
///     ---
///     The fact, with links to other memories as [[their-name]].
///
/// Sessions write the folder at any time; reading it never writes.
enum ProjectMemory {
    static let indexFileName = "MEMORY.md"
    /// A memory larger than this is cut to it: these are notes, not files to
    /// hold in memory whole.
    static let maxFileBytes = 256 * 1024

    /// What a memory is about, as Claude Code's instructions name it.
    enum Kind: String, CaseIterable, Sendable {
        case user, feedback, project, reference

        var title: String { rawValue.capitalized }
    }

    /// One `- [Title](file.md) — hook` line of `MEMORY.md`.
    struct IndexLine: Equatable, Sendable {
        /// 1-based, as an editor numbers lines.
        let number: Int
        let title: String
        /// The link as written.
        let target: String
        let hook: String

        /// The file the link names, in the memory folder: no `<…>`, `./`,
        /// `#anchor` or percent escapes.
        var fileName: String {
            var name = target
            if name.hasPrefix("<"), name.hasSuffix(">") { name = String(name.dropFirst().dropLast()) }
            if let anchor = name.firstIndex(of: "#") { name = String(name[..<anchor]) }
            name = name.removingPercentEncoding ?? name
            return name.hasPrefix("./") ? String(name.dropFirst(2)) : name
        }
    }

    struct Memory: Equatable, Sendable {
        let fileName: String
        /// The frontmatter's `name`, else the file's name without `.md`.
        let name: String
        let description: String
        /// The frontmatter's `type` as written; `kind` when it's one Claude
        /// Code knows.
        let type: String?
        let body: String
        /// Its line in `MEMORY.md`, nil when the index doesn't list it.
        let indexLine: IndexLine?
        /// The frontmatter's `modified`, else the file's date.
        let modified: Date?
        /// Its title, name, file, description and text, folded once (see
        /// `folded`): the filter runs on every keystroke.
        let searchText: String

        var kind: Kind? { type.flatMap { Kind(rawValue: $0.lowercased()) } }
        /// The index's title, else the name.
        var title: String { ProjectMemory.title(indexLine: indexLine, name: name) }
    }

    /// The memory folder as read.
    struct Contents: Equatable, Sendable {
        let directory: URL
        /// In the index's order, then the ones it doesn't list by file.
        let memories: [Memory]
        /// Lines of the index whose file isn't in the folder.
        let missingFiles: [IndexLine]
        /// The lines of `MEMORY.md` Claude Code reads (see `linesRead`); nil
        /// without one.
        let linesRead: Set<Int>?

        var hasIndex: Bool { linesRead != nil }
        /// Whether Claude Code reads `line` at the start of a session.
        func isRead(_ line: IndexLine) -> Bool { linesRead?.contains(line.number) == true }
        var unindexed: [Memory] { memories.filter { $0.indexLine == nil } }

        /// The memory a `[[name]]` link points to: by name, else by file.
        func index(ofMemoryNamed name: String) -> Int? {
            let wanted = name.trimmingCharacters(in: .whitespaces)
            let file = ProjectMemory.fileKey(wanted.hasSuffix(".md") ? wanted : wanted + ".md")
            return memories.firstIndex { $0.name == wanted }
                ?? memories.firstIndex { ProjectMemory.fileKey($0.fileName) == file }
        }
    }

    // MARK: - Reading

    /// Claude Code reads `MEMORY.md` up to its 200th line, and up to 25,000
    /// characters.
    static let indexLineLimit = 200
    static let indexCharacterLimit = 25_000
    /// Folders of the memory folder that hold no memory of this repository.
    static let skippedFolders: Set<String> = ["team", "logs", "sessions", "proposals"]
    static let maxFiles = 1_000
    /// A folder that isn't a memory folder (a setting pointing at the home
    /// folder) isn't read whole.
    static let maxEntries = 5_000
    static let maxDepth = 8

    /// Reads the folder: its `.md` files, in subfolders too, as Claude Code
    /// finds them (no hidden or linked file, no `MEMORY.md`, nothing in
    /// `skippedFolders`), and the index. Nil when there is no folder. Call
    /// it off the main thread.
    static func read(directory: URL) -> Contents? {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue,
              let files = manager.enumerator(atPath: directory.path)
        else { return nil }
        let indexText = readText(directory.appendingPathComponent(indexFileName).path)
        let lines = indexText.map(indexLines(in:)) ?? []
        var lineByFile: [String: IndexLine] = [:]
        for line in lines where lineByFile[fileKey(line.fileName)] == nil { lineByFile[fileKey(line.fileName)] = line }

        // Relative paths, the folder's own spelling kept even through a
        // linked parent; `fileAttributes` describe the entry, not what a
        // link points to.
        var memories: [Memory] = []
        var visited = 0
        while let relative = files.nextObject() as? String, memories.count < maxFiles {
            visited += 1
            guard visited <= maxEntries else { break }
            let type = files.fileAttributes?[.type] as? FileAttributeType
            let name = (relative as NSString).lastPathComponent
            if type == .typeDirectory {
                if name.hasPrefix(".") || files.level >= maxDepth
                    || (files.level == 1 && skippedFolders.contains(folderKey(name))) {
                    files.skipDescendants()
                }
                continue
            }
            guard type == .typeRegular, !name.hasPrefix("."), name.hasSuffix(".md"), name != indexFileName,
                  let text = readText(directory.appendingPathComponent(relative).path)
            else { continue }
            memories.append(memory(
                fileName: relative, text: text, indexLine: lineByFile[fileKey(relative)],
                fileDate: files.fileAttributes?[.modificationDate] as? Date
            ))
        }
        let present = Set(memories.map { fileKey($0.fileName) })
        let order = Dictionary(lines.enumerated().map { (fileKey($1.fileName), $0) }) { first, _ in first }
        memories.sort { lhs, rhs in
            switch (order[fileKey(lhs.fileName)], order[fileKey(rhs.fileName)]) {
            case let (left?, right?): return left < right
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return lhs.fileName.localizedStandardCompare(rhs.fileName) == .orderedAscending
            }
        }
        // A file skipped above (linked, in a skipped folder) is there all
        // the same.
        let missing = lines.filter { line in
            !present.contains(fileKey(line.fileName))
                && !manager.fileExists(atPath: directory.appendingPathComponent(line.fileName).path)
        }
        return Contents(
            directory: directory, memories: memories, missingFiles: missing, linesRead: indexText.map(linesRead(of:))
        )
    }

    /// How the folder matches names: the Mac's volumes ignore case and
    /// Unicode composition.
    static func fileKey(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// A top folder's name as Claude Code compares it with
    /// `skippedFolders`: no trailing dots or spaces, any case.
    static func folderKey(_ name: String) -> String {
        var key = name.precomposedStringWithCanonicalMapping
        while let last = key.last, last == "." || last == " " { key.removeLast() }
        return key.lowercased()
    }

    /// A regular file's text (a named pipe would block), its first
    /// `limit` bytes at most; nil when it can't be read. Invalid UTF-8 is
    /// replaced, not refused.
    static func readText(_ path: String, limit: Int = maxFileBytes) -> String? {
        readData(path, limit: limit).map { data in
            let text = String(decoding: data, as: UTF8.self)
            return text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        }
    }

    static func readData(_ path: String, limit: Int) -> Data? {
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
              let handle = try? FileHandle(forReadingFrom: url)
        else { return nil }
        defer { try? handle.close() }
        do {
            // Nil at the end of the file: an empty file.
            return try handle.read(upToCount: limit) ?? Data()
        } catch {
            return nil
        }
    }

    // MARK: - Index

    /// `- [Title](file.md) — hook`, `*` bullets too; any other line (a
    /// heading, prose, a blank, a frontmatter, a comment) isn't a memory's.
    static func indexLines(in text: String) -> [IndexLine] {
        let raw = withoutComments((text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text).components(separatedBy: "\n"))
        var lines: [IndexLine] = []
        for (offset, line) in raw.enumerated().dropFirst(frontmatterEnd(raw)) {
            if let line = indexLine(line.trimmingCharacters(in: .whitespacesAndNewlines), number: offset + 1) {
                lines.append(line)
            }
        }
        return lines
    }

    private static func indexLine(_ line: String, number: Int) -> IndexLine? {
        guard line.hasPrefix("- [") || line.hasPrefix("* [") else { return nil }
        var rest = line.dropFirst(3)
        // The title ends at the "](" that opens the link.
        guard let open = rest.range(of: "](") else { return nil }
        let title = String(rest[..<open.lowerBound])
        rest = rest[open.upperBound...]
        // The link ends at its own ")": `notes (v2).md` keeps its pair.
        var depth = 0
        guard let end = rest.firstIndex(where: { character in
            if character == "(" { depth += 1 } else if character == ")" { if depth == 0 { return true } else { depth -= 1 } }
            return false
        }) else { return nil }
        let target = rest[..<end].trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty, !target.contains("://") else { return nil }
        var hook = rest[rest.index(after: end)...].trimmingCharacters(in: .whitespaces)
        for dash in ["—", "–", "-", ":"] where hook.hasPrefix(dash) {
            hook = hook.dropFirst(dash.count).trimmingCharacters(in: .whitespaces)
            break
        }
        return IndexLine(number: number, title: title, target: target, hook: hook)
    }

    /// The lines of `MEMORY.md` Claude Code reads, numbered as in the file.
    /// It drops a frontmatter and `<!-- -->` comments, trims the text, then
    /// keeps 200 lines, then cuts at the last line break before 25,000
    /// characters.
    static func linesRead(of text: String) -> Set<Int> {
        let units = Array(text.utf16)
        var removed = [Bool](repeating: false, count: units.count)
        let whole = NSRange(location: 0, length: units.count)
        if let frontmatter = try? NSRegularExpression(pattern: #"\A---[ \t]*\r?\n[\s\S]*?\n---[ \t]*(?:\r?\n|\z)"#),
           let match = frontmatter.firstMatch(in: text, range: whole) {
            for index in match.range.location..<NSMaxRange(match.range) { removed[index] = true }
        }
        if let comments = try? NSRegularExpression(pattern: #"<!--[\s\S]*?-->"#) {
            for match in comments.matches(in: text, range: whole) {
                for index in match.range.location..<NSMaxRange(match.range) { removed[index] = true }
            }
        }
        // What is left, each unit with the line it came from.
        var kept: [(unit: UInt16, line: Int)] = []
        var line = 1
        for (index, unit) in units.enumerated() {
            if !removed[index] { kept.append((unit, line)) }
            if unit == 0x0A { line += 1 }
        }
        func isSpace(_ unit: UInt16) -> Bool {
            [0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0xA0, 0xFEFF, 0x2028, 0x2029].contains(unit)
        }
        while let first = kept.first, isSpace(first.unit) { kept.removeFirst() }
        while let last = kept.last, isSpace(last.unit) { kept.removeLast() }
        var breaks = 0
        for (index, entry) in kept.enumerated() where entry.unit == 0x0A {
            breaks += 1
            guard breaks == indexLineLimit else { continue }
            kept.removeSubrange(index...)
            break
        }
        if kept.count > indexCharacterLimit {
            // No line break before the limit: cut at it.
            let lastBreak: Int? = kept[...indexCharacterLimit].lastIndex { $0.unit == 0x0A }
            kept.removeSubrange((lastBreak ?? indexCharacterLimit)...)
        }
        return Set(kept.filter { $0.unit != 0x0A }.map(\.line))
    }

    // MARK: - Memory files

    static func memory(fileName: String, text: String, indexLine: IndexLine?, fileDate: Date?) -> Memory {
        let (fields, body) = frontmatter(of: text)
        let stem = fileName.hasSuffix(".md") ? String(fileName.dropLast(3)) : fileName
        let name = fields["name"].flatMap { $0.isEmpty ? nil : $0 } ?? stem
        let description = fields["description"] ?? ""
        return Memory(
            fileName: fileName,
            name: name,
            description: description,
            type: (fields["metadata.type"] ?? fields["type"]).flatMap { $0.isEmpty ? nil : $0 },
            body: body,
            indexLine: indexLine,
            modified: (fields["metadata.modified"] ?? fields["modified"]).flatMap(date(from:)) ?? fileDate,
            searchText: folded([title(indexLine: indexLine, name: name), name, fileName, description, body]
                .joined(separator: "\n"))
        )
    }

    static func title(indexLine: IndexLine?, name: String) -> String {
        guard let title = indexLine?.title.trimmingCharacters(in: .whitespaces), !title.isEmpty else { return name }
        return title
    }

    /// Text as the filter compares it: any case, any accent.
    static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// The frontmatter's fields, keyed `name` or `metadata.type` for one
    /// level of nesting, and the text after it. YAML enough for what Claude
    /// Code writes: plain, quoted and folded (`>`, `|`) scalars.
    static func frontmatter(of text: String) -> (fields: [String: String], body: String) {
        let normalized = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        var lines = normalized.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        else { return ([:], text) }
        let header = Array(lines[1..<end])
        lines.removeSubrange(0...end)
        let body = lines.joined(separator: "\n").trimmingCharacters(in: .newlines)

        var fields: [String: String] = [:]
        var parent: (key: String, indent: Int)?
        var index = 0
        while index < header.count {
            let line = header[index]
            index += 1
            let indent = line.prefix { $0 == " " }.count
            let content = line.dropFirst(indent)
            guard !content.isEmpty, !content.hasPrefix("#"), let colon = content.firstIndex(of: ":") else { continue }
            let key = content[..<colon].trimmingCharacters(in: .whitespaces)
            var value = content[content.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if let current = parent, indent <= current.indent { parent = nil }
            if value.isEmpty, indent == 0 {
                parent = (key, indent)
                continue
            }
            if [">", "|", ">-", "|-"].contains(value) {
                var parts: [String] = []
                while index < header.count {
                    let next = header[index]
                    let nextIndent = next.prefix { $0 == " " }.count
                    guard nextIndent > indent || next.trimmingCharacters(in: .whitespaces).isEmpty else { break }
                    parts.append(next.trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                value = parts.joined(separator: value.hasPrefix(">") ? " " : "\n").trimmingCharacters(in: .whitespaces)
            }
            fields[parent.map { "\($0.key).\(key)" } ?? key] = unquoted(value)
        }
        return (fields, body)
    }

    private static func unquoted(_ value: String) -> String {
        guard value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" else {
            return value
        }
        let inner = String(value.dropFirst().dropLast())
        return first == "'"
            ? inner.replacingOccurrences(of: "''", with: "'")
            : inner.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
    }

    /// `modified` as Claude Code writes it (`2026-10-03T15:57:12.123Z`), or
    /// without fractions, or a plain day.
    private static func date(from text: String) -> Date? {
        let options: [ISO8601DateFormatter.Options] = [
            [.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime], [.withFullDate]
        ]
        let formatter = ISO8601DateFormatter()
        for option in options {
            formatter.formatOptions = option
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    // MARK: - Links

    /// A `[[name]]` in a memory's text, where it sits.
    struct Link: Equatable, Sendable {
        let name: String
        /// Of the whole `[[name]]`, in UTF-16 units, as NSAttributedString
        /// counts.
        let range: NSRange
    }

    /// The `[[name]]` links of `text`, each occurrence.
    static func links(in text: String) -> [Link] {
        var links: [Link] = []
        let utf16 = Array(text.utf16)
        var index = 0
        while index + 1 < utf16.count {
            guard utf16[index] == 0x5B, utf16[index + 1] == 0x5B else { index += 1; continue }
            var end = index + 2
            while end + 1 < utf16.count, utf16[end] != 0x5D, utf16[end] != 0x5B, utf16[end] != 0x0A { end += 1 }
            let closes = end + 1 < utf16.count && utf16[end] == 0x5D && utf16[end + 1] == 0x5D
            let name = closes
                ? String(decoding: utf16[(index + 2)..<end], as: UTF16.self).trimmingCharacters(in: .whitespaces)
                : ""
            if name.isEmpty {
                index += closes ? end + 2 - index : 1
                continue
            }
            links.append(Link(name: name, range: NSRange(location: index, length: end + 2 - index)))
            index = end + 2
        }
        return links
    }
}
