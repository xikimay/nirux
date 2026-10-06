import Foundation

// MARK: - Writing what agents know

/// The Project Memory panel's writes: a memory added, edited, moved to the
/// brief or deleted; a brief rule added, edited, moved to the memory or
/// deleted. Sessions write the same files at any time, with no lock shared
/// with Nirux, so every write:
/// - goes to a hidden temporary file beside the target (a link's target),
///   synced to disk with the target's permissions, then a rename; a new file
///   never replaces one that appeared meanwhile;
/// - re-reads the file right before the rename and starts over from what is
///   there when it changed: `MEMORY.md` gets its line added or removed,
///   never a copy of an older index;
/// - first checks that the item still reads as the panel showed it: an
///   agent's newer text is never overwritten, nor moved away unseen;
/// - keeps the file's line breaks, and touches only the file the user acted
///   on and, for a memory, its index line.
/// A move writes its destination first, then removes its source: a failure
/// in between leaves the item twice, never nowhere.
extension ProjectMemory {
    enum WriteError: LocalizedError, Equatable {
        /// A memory file already has that name.
        case exists(String)
        case emptyTitle
        /// The item changed on disk since the panel read it.
        case changed(String)
        /// The brief would pass what sessions get of it.
        case tooLong(Int)
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .exists(let name): return "A memory named \(name) already exists"
            case .emptyTitle: return "Give it a title"
            case .changed(let file): return "\(file) changed since the panel read it: look again and retry"
            case .tooLong(let limit):
                return "The project brief would pass \(limit.formatted()) characters, past what sessions get: shorten it first"
            case .failed(let reason): return reason
            }
        }
    }

    /// Moves a file to the Trash.
    typealias Trash = @Sendable (URL) throws -> Void
    static let systemTrash: Trash = { url in try FileManager.default.trashItem(at: url, resultingItemURL: nil) }

    /// The most a write reads back: a file past it is never written.
    static let maxWrittenBytes = 4 * 1024 * 1024

    // MARK: - Files

    /// `data` in a new hidden file beside `target` (Claude Code's scan skips
    /// it), synced to disk, with `permissions` when given.
    private static func temporaryFile(with data: Data, beside target: URL, permissions: Int?) throws -> URL {
        let temporary = target.deletingLastPathComponent().appendingPathComponent(".nirux-\(UUID().uuidString).tmp")
        do {
            let attributes: [FileAttributeKey: Any]? = permissions.map { [.posixPermissions: $0] }
            guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: attributes) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let handle = try FileHandle(forWritingTo: temporary)
            defer { try? handle.close() }
            try handle.write(contentsOf: data)
            try handle.synchronize()
            return temporary
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw WriteError.failed("Couldn’t write in \(target.deletingLastPathComponent().path): \(error.localizedDescription)")
        }
    }

    /// Renames `temporary` onto `target`: only where nothing is, without
    /// `replacing`. Returns errno, 0 once done; the temporary file goes on
    /// failure.
    private static func rename(_ temporary: URL, onto target: URL, replacing: Bool) -> Int32 {
        let renamed = replacing
            ? Darwin.rename(temporary.path, target.path)
            : renamex_np(temporary.path, target.path, UInt32(RENAME_EXCL))
        guard renamed != 0 else { return 0 }
        let code = errno
        try? FileManager.default.removeItem(at: temporary)
        return code
    }

    /// Writes a new file at `url`; a file already there (one an agent just
    /// wrote) makes it throw `.exists`.
    static func createFile(_ data: Data, at url: URL) throws {
        let temporary = try temporaryFile(with: data, beside: url, permissions: nil)
        switch rename(temporary, onto: url, replacing: false) {
        case 0: return
        case EEXIST: throw WriteError.exists(url.lastPathComponent)
        case let code: throw WriteError.failed("Couldn’t write \(url.lastPathComponent): \(String(cString: strerror(code)))")
        }
    }

    /// Re-reads `url` (empty when it is missing and `creating`), hands its
    /// text to `change`, and writes the result only while the file still
    /// holds what `change` saw; changed meanwhile, it starts over from the
    /// new text. `change` returns nil to write nothing. A link is followed:
    /// its target is written. A file that isn't UTF-8 text, read-only, or
    /// past `maxWrittenBytes` is left alone.
    static func update(_ url: URL, creating: Bool = false, attempts: Int = 3, _ change: (String) throws -> String?) throws {
        let target = url.resolvingSymlinksInPath()
        let name = url.lastPathComponent
        let manager = FileManager.default
        for _ in 0..<attempts {
            let before = readData(target.path, limit: maxWrittenBytes)
            if before == nil, manager.fileExists(atPath: target.path) || !creating { throw WriteError.changed(name) }
            guard (before?.count ?? 0) < maxWrittenBytes else {
                throw WriteError.failed("\(name) is too large to change here: open it in the editor")
            }
            guard let text = before.map({ String(data: $0, encoding: .utf8) }) ?? "" else {
                throw WriteError.failed("\(name) isn’t UTF-8 text: open it in the editor")
            }
            if before != nil, !manager.isWritableFile(atPath: target.path) {
                throw WriteError.failed("\(name) is read-only")
            }
            guard let changed = try change(text) else { return }
            let permissions = (try? manager.attributesOfItem(atPath: target.path))?[.posixPermissions] as? Int
            let temporary = try temporaryFile(with: Data(changed.utf8), beside: target, permissions: permissions)
            // The narrowest window: compared right before the rename.
            guard readData(target.path, limit: maxWrittenBytes) == before else {
                try? manager.removeItem(at: temporary)
                continue
            }
            let code = rename(temporary, onto: target, replacing: before != nil)
            if code == 0 { return }
            if before == nil, code == EEXIST { continue }
            throw WriteError.failed("Couldn’t write \(name): \(String(cString: strerror(code)))")
        }
        throw WriteError.changed(name)
    }

    // MARK: - Lines

    /// A file's lines, each with its own `\r` when it ends `\r\n`, and
    /// whether new lines should: every line kept keeps its break.
    static func splitLines(_ text: String) -> (lines: [String], crlf: Bool) {
        (text.components(separatedBy: "\n"), text.contains("\r\n"))
    }

    static func joinLines(_ lines: [String]) -> String {
        lines.joined(separator: "\n")
    }

    /// New lines, ended as the file's.
    static func ended(_ lines: [String], crlf: Bool) -> [String] {
        crlf ? lines.map { $0 + "\r" } : lines
    }

    /// Typed text as lines, without the `\r` a paste may bring.
    static func typedLines(_ text: String) -> [String] {
        text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
            .map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
    }

    /// `lines` without their trailing blank ones: ready for lines after
    /// the last, which keeps its own break, or gets the file's when it had
    /// none (the file didn't end with one).
    static func trimmedEnd(_ lines: [String], crlf: Bool) -> [String] {
        var lines = lines
        var ended = false
        while lines.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            lines.removeLast()
            ended = true
        }
        if crlf, !ended, let last = lines.last, !last.hasSuffix("\r") { lines[lines.count - 1] = last + "\r" }
        return lines
    }

    /// `lines` with `range` replaced by `new`: when the range ran to the
    /// file's end (no break after it), so does what replaces it, and what
    /// is left before it keeps its break.
    private static func replacing(_ range: Range<Int>, in lines: [String], with new: [String], crlf: Bool) -> [String] {
        var lines = lines
        let atEnd = range.upperBound == lines.count
        let lastEnded = lines[range.upperBound - 1].hasSuffix("\r")
        var replacement = ended(new, crlf: crlf)
        if !replacement.isEmpty, !lastEnded, let last = replacement.last, last.hasSuffix("\r") {
            replacement[replacement.count - 1] = String(last.dropLast())
        }
        lines.replaceSubrange(range, with: replacement)
        if atEnd, replacement.isEmpty, !lines.isEmpty { lines.append("") }
        return lines
    }

    /// Text as written, strictly UTF-8; nil when it isn't.
    static func strictText(_ url: URL) -> String? {
        readData(url.resolvingSymlinksInPath().path, limit: maxWrittenBytes).flatMap { String(data: $0, encoding: .utf8) }
    }

    // MARK: - Memories

    /// A title as a memory's file name: ASCII letters and digits in lower
    /// case, `-` between words, 60 characters at most.
    static func slug(for title: String) -> String {
        let folded = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        var slug = ""
        for scalar in folded.unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                slug.unicodeScalars.append(scalar)
            } else if !slug.isEmpty, !slug.hasSuffix("-") {
                slug += "-"
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        if slug.count > 60 {
            slug = String(slug.prefix(60))
            while slug.hasSuffix("-") { slug.removeLast() }
        }
        return slug
    }

    /// Names a memory whose title has no letter or digit a file name can use.
    static let fallbackSlug = "note"

    /// The file name a new memory titled `title` gets among `taken` (file
    /// names, any case): its slug, numbered when taken; `MEMORY.md` is
    /// always taken.
    static func newFileName(for title: String, taken: Set<String>) throws -> String {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw WriteError.emptyTitle }
        let slug = slug(for: title).isEmpty ? fallbackSlug : slug(for: title)
        let taken = Set(taken.map(fileKey)).union([fileKey(indexFileName)])
        for number in 1...999 {
            let name = number == 1 ? slug + ".md" : "\(slug)-\(number).md"
            if !taken.contains(fileKey(name)) { return name }
        }
        throw WriteError.exists(slug + ".md")
    }

    /// The names in a memory folder.
    static func fileNames(in directory: URL) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
    }

    static func modifiedText(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// A memory file as Claude Code writes them: the frontmatter, then the
    /// text.
    static func memoryText(name: String, description: String, type: String, body: String, modified: Date) -> String {
        """
        ---
        name: \(name)
        description: \(quoted(oneLine(description)))
        metadata:
          type: \(type)
          modified: \(modifiedText(modified))
        ---

        \(body.trimmingCharacters(in: .whitespacesAndNewlines))

        """
    }

    /// A YAML double-quoted scalar.
    private static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func oneLine(_ text: String) -> String {
        text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// `- [Title](file.md) — hook`, on one line, the title's brackets
    /// turned to parentheses so the link holds.
    static func indexLine(title: String, fileName: String, hook: String) -> String {
        let title = oneLine(title).replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")")
        let target = fileName.contains(where: { " ()<>".contains($0) }) ? "<\(fileName)>" : fileName
        let hook = oneLine(hook)
        return "- [\(title)](\(target))" + (hook.isEmpty ? "" : " — \(hook)")
    }

    /// Writes a new memory and its line at the end of `MEMORY.md`, which is
    /// created when there's none, and returns its file name. "+ Add", a
    /// move from the brief and the History tab's "Remember" all write
    /// memories this way. When the index can't take its line, the file
    /// goes too: no memory is left that the index doesn't list.
    @discardableResult
    static func addMemory(
        title: String, description: String, text: String, type: Kind, in directory: URL, now: Date = Date()
    ) throws -> String {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw WriteError.failed("Couldn’t create \(directory.path): \(error.localizedDescription)")
        }
        let fileName = try newFileName(for: title, taken: fileNames(in: directory))
        let name = String(fileName.dropLast(3))
        let description = oneLine(description).isEmpty ? oneLine(title) : description
        let file = directory.appendingPathComponent(fileName)
        try createFile(Data(memoryText(name: name, description: description, type: type.rawValue, body: text, modified: now).utf8), at: file)
        let line = indexLine(title: title, fileName: fileName, hook: description)
        do {
            try update(directory.appendingPathComponent(indexFileName), creating: true) { index in
                let (lines, crlf) = splitLines(index)
                return joinLines(trimmedEnd(lines, crlf: crlf) + ended([line], crlf: crlf) + [""])
            }
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
        return fileName
    }

    /// Replaces a memory's text, its frontmatter kept as written but for
    /// `modified`; refused when the text on disk isn't `expected` (an agent
    /// wrote it since, or the panel read only its start).
    static func replaceMemoryText(
        fileName: String, in directory: URL, expected: String, with body: String, now: Date = Date()
    ) throws {
        try update(directory.appendingPathComponent(fileName)) { text in
            guard frontmatter(of: text).body == expected else { throw WriteError.changed(fileName) }
            let (lines, crlf) = splitLines(text)
            var header = Array(lines[..<frontmatterEnd(lines)])
            if let modified = modifiedLine(in: header) {
                let line = header[modified]
                header[modified] = line.prefix { $0 == " " } + "modified: " + modifiedText(now) + (line.hasSuffix("\r") ? "\r" : "")
            }
            return joinLines((header.isEmpty ? [] : header + ended([""], crlf: crlf)) + ended(typedLines(body), crlf: crlf) + [""])
        }
    }

    /// The frontmatter's `modified:` line: `metadata`'s, else a top-level
    /// one; never a line of another field's text.
    static func modifiedLine(in header: [String]) -> Int? {
        func indent(_ line: String) -> Int { line.prefix { $0 == " " }.count }
        func key(_ line: String) -> String { line.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let metadata = header.firstIndex(where: { indent($0) == 0 && key($0) == "metadata:" }) {
            for index in (metadata + 1)..<header.count where !key(header[index]).isEmpty {
                guard indent(header[index]) > 0 else { break }
                if key(header[index]).hasPrefix("modified:"), indent(header[index]) <= 2 { return index }
            }
        }
        return header.firstIndex { indent($0) == 0 && key($0).hasPrefix("modified:") }
    }

    /// Sends a memory's file to the Trash and takes its lines out of
    /// `MEMORY.md`, every other line kept as written.
    static func deleteMemory(fileName: String, in directory: URL, trash: Trash = systemTrash) throws {
        let url = directory.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                try trash(url)
            } catch {
                throw WriteError.failed("Couldn’t move \(fileName) to the Trash: \(error.localizedDescription)")
            }
        }
        try removeIndexLines(of: fileName, in: directory)
    }

    /// Takes the lines naming `fileName` out of `MEMORY.md`.
    static func removeIndexLines(of fileName: String, in directory: URL) throws {
        let index = directory.appendingPathComponent(indexFileName)
        guard FileManager.default.fileExists(atPath: index.path) else { return }
        try update(index) { text in
            let numbers = Set(indexLines(in: text).filter { fileKey($0.fileName) == fileKey(fileName) }.map(\.number))
            guard !numbers.isEmpty else { return nil }
            let (lines, crlf) = splitLines(text)
            // From the end, so each removal keeps the others' numbers.
            return joinLines(numbers.sorted(by: >).reduce(lines) { lines, number in
                replacing((number - 1)..<number, in: lines, with: [], crlf: crlf)
            })
        }
    }

    // MARK: - Rules

    /// `text` as a bullet with `marker` (`- `, `1. `…; a bare `-` gets its
    /// space): the lines after the first indented under it.
    static func bullet(_ text: String, marker: String = "- ") -> [String] {
        let marker = marker.hasSuffix(" ") ? marker : marker + " "
        let lines = typedLines(text)
        let indent = String(repeating: " ", count: marker.count)
        return [marker + lines[0]] + lines.dropFirst().map { $0.isEmpty ? "" : indent + $0 }
    }

    /// Refused when the brief, once written, would pass what sessions get of
    /// it (see SpaceBrief), and grow: a brief already past it can shrink.
    private static func checkLength(_ text: String, was before: String, max: Int?) throws {
        guard let max else { return }
        let count = SpaceBrief.body(of: text)?.count ?? 0
        guard count > max, count > SpaceBrief.body(of: before)?.count ?? 0 else { return }
        throw WriteError.tooLong(max)
    }

    /// Adds `text` as a bullet at the end of the rules file at `url`.
    static func appendRule(_ text: String, to url: URL, maxCharacters: Int? = nil) throws {
        try update(url, creating: true) { current in
            let (lines, crlf) = splitLines(current)
            let written = joinLines(trimmedEnd(lines, crlf: crlf) + ended(bullet(text), crlf: crlf) + [""])
            try checkLength(written, was: current, max: maxCharacters)
            return written
        }
    }

    /// Why `rule` can't be written in `text` as the panel read it: gone or
    /// moved, or sharing its lines with a comment (it would go, or come out
    /// of hiding).
    private static func refusal(of rule: Rule, in text: String, name: String) -> WriteError? {
        guard rules(in: text).contains(rule) else { return .changed(name) }
        let lines = splitLines(text).lines
        let range = (rule.lines.lowerBound - 1)..<rule.lines.upperBound
        guard !lines[range].contains(where: { $0.contains("<!--") || $0.contains("-->") }),
              withoutComments(lines)[range] == lines[range]
        else { return .failed("This rule shares its lines with a comment: change it in the editor") }
        return nil
    }

    /// Replaces `rule` in the file at `url` with `text` (with the same
    /// marker when it was a bullet), or takes it out with nil. Refused when
    /// the file no longer holds that rule at those lines, or when a comment
    /// shares them (it would go, or come out of hiding).
    static func replaceRule(_ rule: Rule, in url: URL, with text: String?, maxCharacters: Int? = nil) throws {
        try update(url) { current in
            if let refusal = refusal(of: rule, in: current, name: url.lastPathComponent) { throw refusal }
            let (lines, crlf) = splitLines(current)
            let range = (rule.lines.lowerBound - 1)..<rule.lines.upperBound
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return joinLines(replacing(range, in: lines, with: [], crlf: crlf))
            }
            let first = lines[range.lowerBound]
            let indent = String(first.prefix { $0 == " " })
            let trimmed = first.trimmingCharacters(in: .whitespacesAndNewlines)
            let replacement = bulletMarker(trimmed).map { length in
                bullet(text, marker: String(trimmed.prefix(length))).map { indent + $0 }
            } ?? typedLines(text)
            let written = joinLines(replacing(range, in: lines, with: replacement, crlf: crlf))
            try checkLength(written, was: current, max: maxCharacters)
            return written
        }
    }

    /// Refused for what `replaceRule` would refuse, checked before a move
    /// writes anything: a file that isn't UTF-8 text or is read-only, a rule
    /// gone, moved or sharing lines with a comment.
    private static func checkRule(_ rule: Rule, in url: URL) throws {
        let name = url.lastPathComponent
        guard let text = strictText(url) else { throw WriteError.changed(name) }
        let target = url.resolvingSymlinksInPath()
        // The rename needs the folder too.
        if !FileManager.default.isWritableFile(atPath: target.path)
            || !FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) {
            throw WriteError.failed("\(name) is read-only")
        }
        if let refusal = refusal(of: rule, in: text, name: name) { throw refusal }
    }

    // MARK: - Moves

    /// A brief rule becomes a memory titled after its headline: checked
    /// first, then the memory written, then the rule taken out. Returns the
    /// memory's file name.
    @discardableResult
    static func moveRuleToMemory(_ rule: Rule, from brief: URL, to directory: URL, now: Date = Date()) throws -> String {
        try checkRule(rule, in: brief)
        let (title, detail) = headline(of: rule.text)
        let fileName = try addMemory(
            title: title.isEmpty ? fallbackSlug : title, description: detail.isEmpty ? title : String(detail.prefix(150)),
            text: rule.text, type: .feedback, in: directory, now: now
        )
        try replaceRule(rule, in: brief, with: nil)
        return fileName
    }

    /// A memory becomes a brief rule, its title in bold ahead of its text
    /// unless the text starts with it: checked first (the whole file, as an
    /// agent may have changed it), then the rule written, then the memory
    /// sent to the Trash with its index line. Returns the rule's text.
    @discardableResult
    static func moveMemoryToRule(
        _ memory: Memory, in directory: URL, to brief: URL, maxCharacters: Int? = nil, trash: Trash = systemTrash
    ) throws -> String {
        let file = directory.appendingPathComponent(memory.fileName)
        guard let current = strictText(file) else {
            throw FileManager.default.fileExists(atPath: file.path)
                ? WriteError.failed("\(memory.fileName) isn’t UTF-8 text: open it in the editor")
                : WriteError.changed(memory.fileName)
        }
        guard frontmatter(of: current).body == memory.body else { throw WriteError.changed(memory.fileName) }
        let body = memory.body.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = memory.title.trimmingCharacters(in: CharacterSet(charactersIn: " .:"))
        let lead = "**\(title)**"
        let leads = folded(headline(of: body).title) == folded(title)
        let text = body.isEmpty ? lead : leads ? body : lead + " " + body
        try appendRule(text, to: brief, maxCharacters: maxCharacters)
        try deleteMemory(fileName: memory.fileName, in: directory, trash: trash)
        return text
    }
}
