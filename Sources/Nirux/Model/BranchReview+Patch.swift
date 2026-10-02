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
        /// Empty when parsed without its lines.
        var hunks: [Hunk] = []
        var additions = 0
        var deletions = 0
        /// SHA-256 of its changed lines' bytes (see `ChangedLineHasher`).
        var changedLines = Data()
        /// Its size in the patch, header included.
        var byteCount = 0

        /// The path its name-status entry lists last: the new path, or the
        /// old one for a deletion.
        var key: String? { newPath ?? oldPath }
    }

    enum Patch {
        /// The byte ranges of a patch's `diff --git` sections.
        static func sectionRanges(of data: Data) -> [Range<Data.Index>] {
            let marker = Data("\ndiff --git ".utf8)
            var starts: [Data.Index] = []
            if data.starts(with: marker.dropFirst()) { starts.append(data.startIndex) }
            var searchStart = data.startIndex
            while let found = data.range(of: marker, in: searchStart..<data.endIndex) {
                starts.append(found.lowerBound + 1)
                searchStart = found.lowerBound + 1
            }
            return starts.indices.map { index in
                starts[index]..<(index + 1 < starts.count ? starts[index + 1] : data.endIndex)
            }
        }

        /// Parses every section; `keepsLines` says, from its size, which
        /// ones keep their hunks (the others only count and hash them, so a
        /// huge file never becomes a million Strings). Nil when a section
        /// can't be parsed.
        static func sections(of data: Data, keepsLines: (Int) -> Bool = { _ in true }) -> [PatchSection]? {
            var sections: [PatchSection] = []
            for range in sectionRanges(of: data) {
                guard let section = section(data[range], keepsLines: keepsLines(range.count)) else { return nil }
                sections.append(section)
            }
            return sections
        }

        /// Parses one section, from its `diff --git` line on. Lines are cut
        /// on the newline byte and told apart by their first byte: Swift
        /// makes one Character of "\r\n", and of "+" and a combining accent
        /// after it. Text is decoded lossily, one line at a time, so one
        /// file that isn't UTF-8 doesn't empty the page; the hash reads the
        /// bytes.
        static func section(_ bytes: Data, keepsLines: Bool = true) -> PatchSection? {
            var reader = LineReader(bytes)
            guard let first = reader.next(), first.starts(with: Data("diff --git ".utf8)) else { return nil }
            var section = PatchSection(byteCount: bytes.count)
            var oldName: String??
            var newName: String??
            var renamedFrom: String?
            var renamedTo: String?
            var pendingHunk: Data?
            while let raw = reader.next() {
                if raw.starts(with: Data("@@ ".utf8)) {
                    pendingHunk = raw
                    break
                }
                let line = Substring(decoded(raw))
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
            }
            // The most reliable source first: rename lines and the ---/+++
            // lines are quoted when needed; the `diff --git` line is
            // ambiguous when a path holds " b/".
            let gitLine = gitLinePaths(Substring(decoded(first.dropFirst("diff --git ".count))))
            let oldFromHeaders: String? = oldName ?? gitLine?.old
            let newFromHeaders: String? = newName ?? gitLine?.new
            section.oldPath = renamedFrom ?? oldFromHeaders
            section.newPath = renamedTo ?? newFromHeaders
            guard section.key != nil else { return nil }

            var hasher = ChangedLineHasher()
            while let header = pendingHunk {
                guard let read = hunk(header, from: &reader, into: &section, hasher: &hasher, keepsLines: keepsLines)
                else { return nil }
                if keepsLines { section.hunks.append(read.hunk) }
                pendingHunk = read.next
            }
            section.changedLines = hasher.finalize()
            return section
        }

        /// Reads one hunk after its `@@` line. Returns it, and the next
        /// hunk's `@@` line if one follows.
        private static func hunk(
            _ headerLine: Data,
            from reader: inout LineReader,
            into section: inout PatchSection,
            hasher: inout ChangedLineHasher,
            keepsLines: Bool
        ) -> (hunk: Hunk, next: Data?)? {
            guard let header = hunkHeader(Substring(decoded(headerLine))) else { return nil }
            var oldRemaining = header.oldCount
            var newRemaining = header.newCount
            var body: [Line] = []
            // The counts say where the hunk ends: an added line may well
            // read "+++ b/x" or "@@ -1 +1 @@".
            while let raw = reader.next() {
                let kind: Line.Kind
                if raw.first == UInt8(ascii: "\\") {
                    kind = .noNewlineMarker
                } else if oldRemaining == 0, newRemaining == 0 {
                    guard raw.starts(with: Data("@@ ".utf8)) else { return nil }
                    return (Hunk(header: header, lines: body), raw)
                } else {
                    switch raw.first {
                    case UInt8(ascii: "+"):
                        guard newRemaining > 0 else { return nil }
                        newRemaining -= 1
                        section.additions += 1
                        kind = .added
                    case UInt8(ascii: "-"):
                        guard oldRemaining > 0 else { return nil }
                        oldRemaining -= 1
                        section.deletions += 1
                        kind = .removed
                    case UInt8(ascii: " "), nil:
                        guard oldRemaining > 0, newRemaining > 0 else { return nil }
                        oldRemaining -= 1
                        newRemaining -= 1
                        kind = .context
                    default:
                        return nil
                    }
                }
                let content = raw.dropFirst()
                hasher.add(kind, content)
                if keepsLines {
                    body.append(kind == .noNewlineMarker ? Line(kind: kind, text: "") : Line(kind: kind, bytes: content))
                }
            }
            guard oldRemaining == 0, newRemaining == 0 else { return nil }
            return (Hunk(header: header, lines: body), nil)
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

        static func decoded(_ bytes: Data) -> String {
            String(decoding: bytes, as: UTF8.self)
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
                guard let (quotedOld, remainder) = quotedPrefix(rest), remainder.hasPrefix(" "),
                      let old = Substring(unquotedBytes(quotedOld)).dropPrefix("a/"),
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
                let status = decoded(statusField)
                guard let letter = status.first else { return nil }
                let score = Int(status.dropFirst())
                let pathCount = letter == "R" || letter == "C" ? 2 : 1
                guard fields.count >= pathCount else { return nil }
                let paths = (0..<pathCount).map { _ in decoded(fields.removeFirst()) }
                entries.append(NameStatusEntry(
                    letter: letter, score: score,
                    path: paths[pathCount - 1], oldPath: pathCount == 2 ? paths[0] : nil
                ))
            }
            return entries
        }

        /// One file per name-status entry that has a section, hashed. An
        /// entry without one is dropped: under `diff.autoRefreshIndex=false`,
        /// a file whose timestamp changed but not its content is listed, and
        /// the patch leaves it out. A type change has two sections, the old
        /// file deleted and the new one added. Nil when a section matches no
        /// entry, or not the way its status says: the worktree changed
        /// between the two reads.
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
                guard let file = file(entry: entry, sections: found) else { return nil }
                matched += found.count
                files.append(file)
            }
            guard matched == sections.count else { return nil }
            return files
        }

        private static func file(entry: NameStatusEntry, sections: [PatchSection]) -> FileChange? {
            let status: FileStatus
            switch entry.letter {
            case "A", "C": status = .added
            case "D": status = .deleted
            case "R": status = .renamed
            case "T": status = .typeChanged
            default: status = .modified
            }
            let first = sections[0]
            let matchesStatus: Bool
            switch status {
            case .added: matchesStatus = sections.count == 1 && first.oldPath == nil
            case .deleted: matchesStatus = sections.count == 1 && first.newPath == nil
            case .renamed: matchesStatus = sections.count == 1 && first.oldPath == entry.oldPath
            case .modified: matchesStatus = sections.count == 1 && first.oldPath == first.newPath
            case .typeChanged: matchesStatus = sections.count <= 2
            }
            guard matchesStatus else { return nil }
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
                file.additions += section.additions
                file.deletions += section.deletions
                file.patchBytes += section.byteCount
            }
            if !file.isBinary {
                file.oldObjectID = nil
                file.newObjectID = nil
            }
            file.patchHash = patchHash(of: file, changedLines: sections.map(\.changedLines))
            return file
        }
    }

    /// Reads a section's lines without copying them: slices up to each
    /// newline byte.
    struct LineReader {
        private let bytes: Data
        private var cursor: Data.Index

        init(_ bytes: Data) {
            self.bytes = bytes
            cursor = bytes.startIndex
        }

        mutating func next() -> Data? {
            guard cursor < bytes.endIndex else { return nil }
            let end = bytes[cursor...].firstIndex(of: UInt8(ascii: "\n")) ?? bytes.endIndex
            let line = bytes[cursor..<end]
            cursor = end < bytes.endIndex ? end + 1 : end
            return line
        }
    }
}

extension BranchReview.Line {
    /// A line of a patch, decoded lossily; the bytes are kept only when the
    /// text isn't them.
    init(kind: Kind, bytes: Data) {
        let text = BranchReview.Patch.decoded(bytes)
        self.init(kind: kind, text: text, bytes: text.utf8.elementsEqual(bytes) ? nil : bytes)
    }
}

extension BranchReview.Hunk {
    init(
        header: (oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, section: String),
        lines: [BranchReview.Line]
    ) {
        self.init(
            oldStart: header.oldStart, oldCount: header.oldCount,
            newStart: header.newStart, newCount: header.newCount,
            section: header.section, lines: lines
        )
    }
}

// MARK: - Patch hash (section 6.3)

extension BranchReview {
    /// Hashes a section's `-` and `+` lines, in order, as bytes: two lines
    /// that aren't UTF-8 and decode to the same replacement characters
    /// still differ. A "No newline" marker counts only after a changed
    /// line; after a context line it comes and goes with the context.
    struct ChangedLineHasher {
        private var hasher = SHA256()
        private var previous: Line.Kind = .context

        mutating func add(_ kind: Line.Kind, _ content: Data) {
            switch kind {
            case .added, .removed:
                hasher.update(data: Data([kind == .added ? UInt8(ascii: "+") : UInt8(ascii: "-")]))
                hasher.update(data: content)
                hasher.update(data: Data([UInt8(ascii: "\n")]))
            case .noNewlineMarker where previous != .context:
                hasher.update(data: Data("\\\n".utf8))
            case .noNewlineMarker, .context:
                break
            }
            previous = kind
        }

        func finalize() -> Data { Data(hasher.finalize()) }
    }

    /// What a "Reviewed" mark is keyed by: the path (both for a rename),
    /// the status, the mode change, and the `-` and `+` lines of the hunks,
    /// in order (`changedLines`, one digest per section). Context lines,
    /// the `@@` lines and the `index` line are left out: they change when
    /// the base changes the file elsewhere. A binary file has no lines, so
    /// its object ids stand in for them.
    static func patchHash(of file: FileChange, changedLines: [Data]) -> String {
        var hasher = SHA256()
        func add(_ text: String) { hasher.update(data: Data(text.utf8)) }
        add("path\0\(file.path)\0")
        add("from\0\(file.status == .renamed ? file.oldPath ?? "" : "")\0")
        add("status\0\(file.status.rawValue)\0")
        add("mode\0\(file.oldMode ?? "")\0\(file.newMode ?? "")\0")
        if file.isBinary {
            add("binary\0\(file.oldObjectID ?? "")\0\(file.newObjectID ?? "")\0")
        }
        for digest in changedLines { hasher.update(data: digest) }
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
