import CryptoKit
import Foundation

// MARK: - Patch parsing

extension BranchReview {
    /// One entry of `git diff --name-status -z`: the authoritative list of
    /// paths, which the patch's sections are matched against.
    struct NameStatusEntry: Equatable, Sendable {
        /// The status letter: A, M, D, R, T, U…
        let letter: Character
        /// The rename score, in percent.
        let score: Int?
        let path: String
        /// The source of a rename or a copy.
        let oldPath: String?
    }

    /// One `diff --git` section of a patch, before it is matched with its
    /// name-status entry.
    struct PatchSection: Equatable, Sendable {
        /// Nil for /dev/null: an added file has no old path.
        var oldPath: String?
        var newPath: String?
        var oldMode: String?
        var newMode: String?
        var oldObjectID: String?
        var newObjectID: String?
        var isBinary = false
        var hunks: [Hunk] = []
        /// Its size in the patch, header included.
        var byteCount = 0

        /// The path its name-status entry lists last: the new path, or the
        /// old one for a deletion.
        var key: String? { newPath ?? oldPath }
    }

    enum Patch {
        /// Splits a patch into its `diff --git` sections and parses each.
        /// Each section is decoded on its own, lossily: one file that isn't
        /// UTF-8 gets replacement characters instead of emptying the page.
        /// Nil when a section can't be parsed.
        static func sections(of data: Data) -> [PatchSection]? {
            let marker = Data("\ndiff --git ".utf8)
            var starts: [Int] = []
            if data.starts(with: marker.dropFirst()) { starts.append(data.startIndex) }
            var searchStart = data.startIndex
            while let found = data.range(of: marker, in: searchStart..<data.endIndex) {
                starts.append(found.lowerBound + 1)
                searchStart = found.lowerBound + 1
            }
            // Anything before the first section is noise git never prints.
            var sections: [PatchSection] = []
            for (index, start) in starts.enumerated() {
                let end = index + 1 < starts.count ? starts[index + 1] : data.endIndex
                let bytes = data[start..<end]
                guard var section = section(bytes) else { return nil }
                section.byteCount = bytes.count
                sections.append(section)
            }
            return sections
        }

        /// The lines of `bytes`, each decoded lossily. Split on the bytes:
        /// Swift reads "\r\n" as one Character, which a split on "\n"
        /// would leave whole.
        static func lines(_ bytes: Data) -> [Substring] {
            bytes.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
                .map { Substring(String(decoding: $0, as: UTF8.self)) }
        }

        /// Parses one section, from its `diff --git` line on.
        static func section(_ bytes: Data) -> PatchSection? {
            var lines = lines(bytes)
            if lines.last?.isEmpty == true { lines.removeLast() }
            guard let first = lines.first, first.hasPrefix("diff --git ") else { return nil }
            var section = PatchSection()
            var oldName: String??
            var newName: String??
            var renamedFrom: String?
            var renamedTo: String?
            var index = 1
            while index < lines.count, !lines[index].hasPrefix("@@ ") {
                let line = lines[index]
                if let value = line.dropPrefix("old mode ") {
                    section.oldMode = String(value)
                } else if let value = line.dropPrefix("new mode ") {
                    section.newMode = String(value)
                } else if let value = line.dropPrefix("deleted file mode ") {
                    section.oldMode = String(value)
                    newName = .some(nil)
                } else if let value = line.dropPrefix("new file mode ") {
                    section.newMode = String(value)
                    oldName = .some(nil)
                } else if let value = line.dropPrefix("rename from ") {
                    renamedFrom = unquoted(value)
                } else if let value = line.dropPrefix("rename to ") {
                    renamedTo = unquoted(value)
                } else if let value = line.dropPrefix("index ") {
                    let ids = value.split(separator: " ").first?.components(separatedBy: "..") ?? []
                    if ids.count == 2 {
                        section.oldObjectID = ids[0]
                        section.newObjectID = ids[1]
                    }
                } else if let value = line.dropPrefix("--- ") {
                    oldName = headerPath(value, prefix: "a/")
                } else if let value = line.dropPrefix("+++ ") {
                    newName = headerPath(value, prefix: "b/")
                } else if line.hasPrefix("Binary files ") {
                    section.isBinary = true
                }
                index += 1
            }
            // The most reliable source first: rename lines and the ---/+++
            // lines are quoted when needed; the `diff --git` line is
            // ambiguous when a path holds " b/".
            let gitLine = gitLinePaths(first.dropFirst("diff --git ".count))
            let oldFromHeaders: String? = oldName ?? gitLine?.old
            let newFromHeaders: String? = newName ?? gitLine?.new
            section.oldPath = renamedFrom ?? oldFromHeaders
            section.newPath = renamedTo ?? newFromHeaders
            guard section.key != nil else { return nil }

            while index < lines.count {
                guard let hunk = hunk(from: lines, at: &index) else { return nil }
                section.hunks.append(hunk)
            }
            return section
        }

        /// Reads one hunk starting at its `@@` line; leaves `index` after it.
        private static func hunk(from lines: [Substring], at index: inout Int) -> Hunk? {
            guard let header = hunkHeader(lines[index]) else { return nil }
            var oldRemaining = header.oldCount
            var newRemaining = header.newCount
            var body: [Line] = []
            index += 1
            // The counts say where the hunk ends: an added line may well
            // read "+++ b/x" or "@@ -1 +1 @@". The marker is the first
            // scalar, not the first Character: a line starting with a
            // combining accent makes one Character of "+" and the accent.
            while index < lines.count {
                let line = lines[index]
                let marker = line.unicodeScalars.first
                if marker == "\\" {
                    body.append(Line(kind: .noNewlineMarker, text: ""))
                } else if oldRemaining > 0 || newRemaining > 0 {
                    let text = String(Substring(line.unicodeScalars.dropFirst()))
                    switch marker {
                    case "+":
                        guard newRemaining > 0 else { return nil }
                        newRemaining -= 1
                        body.append(Line(kind: .added, text: text))
                    case "-":
                        guard oldRemaining > 0 else { return nil }
                        oldRemaining -= 1
                        body.append(Line(kind: .removed, text: text))
                    case " ", nil:
                        guard oldRemaining > 0, newRemaining > 0 else { return nil }
                        oldRemaining -= 1
                        newRemaining -= 1
                        body.append(Line(kind: .context, text: text))
                    default:
                        return nil
                    }
                } else {
                    break
                }
                index += 1
            }
            guard oldRemaining == 0, newRemaining == 0 else { return nil }
            return Hunk(
                oldStart: header.oldStart, oldCount: header.oldCount,
                newStart: header.newStart, newCount: header.newCount,
                section: header.section, lines: body
            )
        }

        /// "@@ -12,3 +12,4 @@ func name()": a count left out is 1.
        static func hunkHeader(
            _ line: Substring
        ) -> (oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, section: String)? {
            guard let rest = line.dropPrefix("@@ -"), let close = rest.range(of: " @@") else { return nil }
            let ranges = rest[..<close.lowerBound].split(separator: " ")
            guard ranges.count == 2, ranges[1].hasPrefix("+"),
                  let old = range(ranges[0]), let new = range(ranges[1].dropFirst())
            else { return nil }
            var section = rest[close.upperBound...]
            if section.hasPrefix(" ") { section = section.dropFirst() }
            return (old.start, old.count, new.start, new.count, String(section))
        }

        private static func range(_ text: Substring) -> (start: Int, count: Int)? {
            let parts = text.split(separator: ",", omittingEmptySubsequences: false)
            guard (1...2).contains(parts.count), let start = Int(parts[0]) else { return nil }
            guard parts.count == 2 else { return (start, 1) }
            guard let count = Int(parts[1]) else { return nil }
            return (start, count)
        }

        /// A ---/+++ path: nil for /dev/null. git ends the name with a tab
        /// when it holds a space, for patch(1).
        private static func headerPath(_ value: Substring, prefix: String) -> String?? {
            guard value != "/dev/null" else { return .some(nil) }
            var name = value
            if !name.hasPrefix("\""), name.hasSuffix("\t") { name = name.dropLast() }
            guard let path = Substring(unquoted(name)).dropPrefix(prefix) else { return nil }
            return .some(String(path))
        }

        /// The two paths of a `diff --git a/x b/x` line. Unquoted, they can
        /// only be told apart because they are the same path: git prints
        /// sections without ---/+++ lines (mode change, binary, empty file)
        /// only for those.
        private static func gitLinePaths(_ rest: Substring) -> (old: String, new: String)? {
            if rest.hasPrefix("\"") {
                guard let (quotedOld, remainder) = quotedPrefix(rest), remainder.hasPrefix(" ") else { return nil }
                guard let old = Substring(unquotedBytes(quotedOld)).dropPrefix("a/"),
                      let new = Substring(unquoted(remainder.dropFirst())).dropPrefix("b/")
                else { return nil }
                return (String(old), String(new))
            }
            let bytes = Array(rest.utf8)
            guard bytes.count >= 5, (bytes.count - 5) % 2 == 0 else { return nil }
            let length = (bytes.count - 5) / 2
            let old = bytes[2..<(2 + length)]
            let middle = bytes[(2 + length)..<(5 + length)]
            let new = bytes[(5 + length)...]
            guard bytes.starts(with: Array("a/".utf8)), Array(middle) == Array(" b/".utf8),
                  Array(old) == Array(new)
            else { return nil }
            let path = String(decoding: old, as: UTF8.self)
            return (path, path)
        }

        /// A C-quoted name with its quotes, and what follows it.
        private static func quotedPrefix(_ text: Substring) -> (String, Substring)? {
            var escaped = false
            for index in text.indices.dropFirst() {
                if escaped {
                    escaped = false
                } else if text[index] == "\\" {
                    escaped = true
                } else if text[index] == "\"" {
                    return (String(text[...index]), text[text.index(after: index)...])
                }
            }
            return nil
        }

        /// A path as git prints it: as is, or C-quoted ("we\tird",
        /// "\303\251.txt") when it holds a control character, a quote or a
        /// backslash.
        static func unquoted(_ text: Substring) -> String {
            guard text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") else { return String(text) }
            return unquotedBytes(String(text))
        }

        private static func unquotedBytes(_ quoted: String) -> String {
            var bytes: [UInt8] = []
            var input = Array(quoted.utf8.dropFirst().dropLast())[...]
            while let byte = input.popFirst() {
                guard byte == UInt8(ascii: "\\"), let next = input.popFirst() else {
                    bytes.append(byte)
                    continue
                }
                switch next {
                case UInt8(ascii: "a"): bytes.append(0x07)
                case UInt8(ascii: "b"): bytes.append(0x08)
                case UInt8(ascii: "t"): bytes.append(0x09)
                case UInt8(ascii: "n"): bytes.append(0x0A)
                case UInt8(ascii: "v"): bytes.append(0x0B)
                case UInt8(ascii: "f"): bytes.append(0x0C)
                case UInt8(ascii: "r"): bytes.append(0x0D)
                case UInt8(ascii: "0")...UInt8(ascii: "3"):
                    var value = next - UInt8(ascii: "0")
                    for _ in 0..<2 {
                        guard let digit = input.first, (UInt8(ascii: "0")...UInt8(ascii: "7")).contains(digit) else { break }
                        input.removeFirst()
                        value = value &* 8 &+ (digit - UInt8(ascii: "0"))
                    }
                    bytes.append(value)
                default: bytes.append(next)
                }
            }
            return String(decoding: bytes, as: UTF8.self)
        }

        /// Parses `git diff --name-status -z`. Nil when it is malformed.
        static func nameStatus(_ data: Data) -> [NameStatusEntry]? {
            var fields = data.split(separator: 0, omittingEmptySubsequences: false)[...]
            if fields.last?.isEmpty == true { fields.removeLast() }
            var entries: [NameStatusEntry] = []
            while let statusField = fields.popFirst() {
                let status = String(decoding: statusField, as: UTF8.self)
                guard let letter = status.first else { return nil }
                let score = Int(status.dropFirst())
                let pathCount = letter == "R" || letter == "C" ? 2 : 1
                guard fields.count >= pathCount else { return nil }
                let paths = (0..<pathCount).map { _ in String(decoding: fields.removeFirst(), as: UTF8.self) }
                entries.append(NameStatusEntry(
                    letter: letter, score: score,
                    path: paths[pathCount - 1], oldPath: pathCount == 2 ? paths[0] : nil
                ))
            }
            return entries
        }

        /// One file per name-status entry that has a section. An entry
        /// without one is dropped: under `diff.autoRefreshIndex=false`, a
        /// file whose timestamp changed but not its content is listed, and
        /// the patch leaves it out. A type change has two sections, the old
        /// file deleted and the new one added. Nil when a section matches
        /// no entry: the worktree changed between the two reads.
        static func files(entries: [NameStatusEntry], sections: [PatchSection]) -> [FileChange]? {
            var sectionsByKey: [String: [PatchSection]] = [:]
            for section in sections {
                guard let key = section.key else { return nil }
                sectionsByKey[key, default: []].append(section)
            }
            var files: [FileChange] = []
            var matched = 0
            for entry in entries {
                guard let found = sectionsByKey.removeValue(forKey: entry.path) else { continue }
                matched += found.count
                files.append(file(entry: entry, sections: found))
            }
            guard matched == sections.count else { return nil }
            return files
        }

        private static func file(entry: NameStatusEntry, sections: [PatchSection]) -> FileChange {
            let status: FileStatus
            switch entry.letter {
            case "A", "C": status = .added
            case "D": status = .deleted
            case "R": status = .renamed
            case "T": status = .typeChanged
            default: status = .modified
            }
            var file = FileChange(path: entry.path, status: status)
            if status == .renamed {
                file.oldPath = entry.oldPath
                file.similarity = entry.score
            }
            for section in sections {
                file.oldMode = file.oldMode ?? section.oldMode
                file.newMode = section.newMode ?? file.newMode
                file.isBinary = file.isBinary || section.isBinary
                if section.isBinary {
                    if section.oldPath != nil { file.oldObjectID = section.oldObjectID }
                    if section.newPath != nil { file.newObjectID = section.newObjectID }
                }
                file.hunks += section.hunks
            }
            if !file.isBinary {
                file.oldObjectID = nil
                file.newObjectID = nil
            }
            countLines(&file)
            return file
        }

        static func countLines(_ file: inout FileChange) {
            file.additions = 0
            file.deletions = 0
            for line in file.hunks.lazy.flatMap(\.lines) {
                if line.kind == .added { file.additions += 1 }
                if line.kind == .removed { file.deletions += 1 }
            }
        }
    }
}

// MARK: - Patch hash (section 6.3)

extension BranchReview {
    /// What a "Reviewed" mark is keyed by: the path (both for a rename), the
    /// status, the mode change, and the `-` and `+` lines of the hunks, in
    /// order. Context lines, the `@@` lines and the `index` line are left
    /// out: they change when the base changes the file elsewhere. A binary
    /// file has no lines, so its object ids stand in for them. A
    /// "No newline" marker counts only after a changed line; after a
    /// context line it comes and goes with the context.
    static func patchHash(of file: FileChange) -> String {
        var hasher = SHA256()
        func add(_ text: String) { hasher.update(data: Data(text.utf8)) }
        add("path\0\(file.path)\0")
        add("from\0\(file.status == .renamed ? file.oldPath ?? "" : "")\0")
        add("status\0\(file.status.rawValue)\0")
        add("mode\0\(file.oldMode ?? "")\0\(file.newMode ?? "")\0")
        if file.isBinary {
            add("binary\0\(file.oldObjectID ?? "")\0\(file.newObjectID ?? "")\0")
        }
        for hunk in file.hunks {
            var previous: Line.Kind = .context
            for line in hunk.lines {
                switch line.kind {
                case .added: add("+\(line.text)\n")
                case .removed: add("-\(line.text)\n")
                case .noNewlineMarker where previous != .context: add("\\\n")
                case .noNewlineMarker, .context: break
                }
                previous = line.kind
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private extension Substring {
    /// Compared scalar by scalar: a path starting with a combining accent
    /// would make one Character of "/" and the accent.
    func dropPrefix(_ prefix: String) -> Substring? {
        guard unicodeScalars.starts(with: prefix.unicodeScalars) else { return nil }
        return Substring(unicodeScalars.dropFirst(prefix.unicodeScalars.count))
    }
}
