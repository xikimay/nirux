import Foundation

// MARK: - The decisions' memory files (docs/project-memory-tree.md, section 3.8)

/// Each topic's decisions are a Claude Code memory, `decisions-<topic>.md`,
/// written with Project Memory's safe writes. Nirux changes only the lines
/// that end with its mark and still read as it wrote them: a line the user
/// (or an agent) changed or removed, a file deleted or moved to the brief,
/// is the user's, and becomes an `edit` or a `drop` by the user.
extension ProjectHistory {
    static let decisionFilesFileName = "decision-files.json"
    /// Past these, `MEMORY.md` gets no new topic: Claude Code reads it up to
    /// 200 lines or 25,000 bytes.
    static let maxIndexLines = 180
    static let maxIndexBytes = 23_000
    /// A file must be missing this long, seen twice, to count as deleted:
    /// an editor's save may remove it for a moment.
    static let missingFileDelay: TimeInterval = 30
    /// The frontmatter line that marks a memory file as Nirux's.
    static let decisionFileMark = "nirux: decisions"

    /// What Nirux wrote in the memory folder, kept next to the journal.
    struct DecisionFiles: Codable, Equatable, Sendable {
        /// The memory folder written.
        var directory: String
        /// By file name.
        var files: [String: DecisionFile] = [:]
        /// Topics whose file the user deleted, or moved to the brief: none is
        /// written again until the user says so.
        var retired: [String] = []

        func isRetired(_ topic: String) -> Bool {
            retired.contains { ProjectHistory.topicKey($0) == ProjectHistory.topicKey(topic) }
        }

        /// The file of `topic`, if Nirux keeps one.
        func fileName(of topic: String) -> String? {
            files.filter { ProjectHistory.topicKey($0.value.topic) == ProjectHistory.topicKey(topic) }.keys.sorted().first
        }
    }

    /// One file: its topic, and each decision's line as Nirux last saw it
    /// there, by number.
    struct DecisionFile: Codable, Equatable, Sendable {
        var topic: String
        var lines: [String: String] = [:]

        var numbers: [Int] { lines.keys.compactMap(Int.init).sorted() }

        func line(_ n: Int) -> String? { lines[String(n)] }

        mutating func set(_ n: Int, _ line: String?) { lines[String(n)] = line }
    }

    static func decisionFiles(in folder: URL) -> DecisionFiles? {
        let url = folder.appendingPathComponent(decisionFilesFileName)
        guard let data = HistorySearch.readRegularFile(url.path, maxBytes: 4 << 20) else { return nil }
        return try? JSONDecoder().decode(DecisionFiles.self, from: data)
    }

    static func writeDecisionFiles(_ files: DecisionFiles, in folder: URL) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        guard let data = try? encoder.encode(files) else { return false }
        return writeAtomically(String(decoding: data, as: UTF8.self), to: folder.appendingPathComponent(decisionFilesFileName))
    }

    // MARK: - Lines

    /// `- <day>: <decision> [d<n> · msg <id> after <id>]`.
    static func decisionFileLine(_ decision: Decision, calendar: Calendar = ProjectHistoryJournal.localGregorian) -> String {
        let after = decision.after.map { " after \($0)" } ?? ""
        return "- \(localDay(decision.date, calendar: calendar)): \(oneLine(decision.text)) [d\(decision.n) · msg \(decision.id)\(after)]"
    }

    static func oneLine(_ text: String) -> String {
        text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// The decision a line ends with the mark of, and the line's text
    /// without its bullet, its day and its mark: `[d<n>]`, or `[d<n> …]`
    /// with no bracket inside.
    static func markedLine(_ line: String) -> (n: Int, text: String)? {
        var line = Substring(line.hasSuffix("\r") ? String(line.dropLast()) : line)
        while line.last?.isWhitespace == true { line.removeLast() }
        guard line.last == "]", let open = line.lastIndex(of: "[") else { return nil }
        let mark = line[line.index(after: open)..<line.index(before: line.endIndex)]
        guard mark.first == "d", !mark.contains("]") else { return nil }
        let digits = mark.dropFirst().prefix { $0.isASCII && $0.isNumber }
        let rest = mark.dropFirst(1 + digits.count)
        guard let n = Int(digits), rest.isEmpty || rest.first?.isWhitespace == true else { return nil }
        var text = line[..<open].trimmingCharacters(in: .whitespaces)
        if let bullet = text.range(of: #"^[-*+](\s+|$)"#, options: .regularExpression) {
            text = String(text[bullet.upperBound...])
        }
        if let day = text.range(of: #"^\d{4}-\d{2}-\d{2}:\s*"#, options: .regularExpression) {
            text = String(text[day.upperBound...])
        }
        return (n, text.trimmingCharacters(in: .whitespaces))
    }

    /// A line as compared with what Nirux wrote: without its `\r` and its
    /// trailing spaces.
    private static func comparable(_ line: String) -> String {
        var line = line
        while line.last?.isWhitespace == true || line.last == "\r" { line.removeLast() }
        return line
    }

    /// Each decision of `file` and the first line that bears its mark.
    private static func markedLines(_ lines: [String], of file: DecisionFile) -> [Int: Int] {
        var found: [Int: Int] = [:]
        for (index, line) in lines.enumerated() {
            guard let (n, _) = markedLine(line), file.line(n) != nil, found[n] == nil else { continue }
            found[n] = index
        }
        return found
    }

    // MARK: - Reading the user's changes

    /// What the user did to a file since Nirux last wrote it: a marked line
    /// changed in any way is an `edit` of its decision, which Nirux never
    /// takes out (a line emptied, a `drop`); a line gone is a `drop` once
    /// `confirmed` (seen gone twice: a file read in the middle of a save
    /// looks cut); the whole file gone (nil) drops all its lines. Only
    /// decisions in force get an operation; the file's record follows
    /// either way, but for lines gone and not confirmed, which come back in
    /// `missing`.
    static func userChanges(
        fileText: String?, file: DecisionFile, list: DecisionList, confirmed: Set<Int> = [], now: Date
    ) -> (operations: [DecisionOperation], file: DecisionFile, missing: Set<Int>) {
        var operations: [DecisionOperation] = []
        var file = file
        var missing = Set<Int>()
        func drop(_ n: Int) {
            if list.inForce[n] != nil {
                operations.append(DecisionOperation(op: .drop, replaces: [n], date: now, by: "user"))
            }
            file.set(n, nil)
        }
        guard let fileText else {
            file.numbers.forEach(drop)
            return (operations, file, missing)
        }
        let lines = fileText.components(separatedBy: "\n")
        let found = markedLines(lines, of: file)
        for n in file.numbers {
            guard let index = found[n] else {
                if confirmed.contains(n) { drop(n) } else { missing.insert(n) }
                continue
            }
            let line = comparable(lines[index])
            guard line != file.line(n) else { continue }
            let text = markedLine(line)?.text ?? ""
            guard list.inForce[n] != nil else {
                // Its decision is out: the line is the user's now.
                file.set(n, nil)
                continue
            }
            if text.isEmpty {
                drop(n)
            } else {
                // Even a change of its day only: the line is the user's now.
                operations.append(DecisionOperation(op: .edit, n: n, text: text, date: now, by: "user"))
                file.set(n, line)
            }
        }
        return (operations, file, missing)
    }

    // MARK: - Writing

    /// `fileText` with the decisions of `wanted` it lacks added at its end,
    /// and the lines of decisions no longer wanted taken out: only lines
    /// that still read as Nirux wrote them, and never one the user edited.
    /// Nil when nothing changes.
    static func rewrittenDecisionFile(
        _ fileText: String, file: DecisionFile, wanted: [Decision], editedByUser: Set<Int>, now: Date,
        calendar: Calendar = ProjectHistoryJournal.localGregorian
    ) -> (text: String?, file: DecisionFile) {
        var file = file
        let (split, crlf) = ProjectMemory.splitLines(fileText)
        var lines = split
        let wantedNumbers = Set(wanted.map(\.n))
        let found = markedLines(lines, of: file)
        var removed = IndexSet()
        for n in file.numbers where !wantedNumbers.contains(n) {
            if let index = found[n], comparable(lines[index]) == file.line(n), !editedByUser.contains(n) {
                removed.insert(index)
            }
            file.set(n, nil)
        }
        // A line Nirux wrote that is gone meanwhile (an agent removed it)
        // isn't written again; one written before a crash kept its record
        // from being saved is taken back as it is.
        var added: [Decision] = []
        for decision in wanted.sorted(by: saidBefore) where file.line(decision.n) == nil {
            let line = decisionFileLine(decision, calendar: calendar)
            if lines.contains(where: { comparable($0) == line }) {
                file.set(decision.n, line)
            } else {
                added.append(decision)
            }
        }
        guard !removed.isEmpty || !added.isEmpty else { return (nil, file) }
        for index in removed.reversed() { lines.remove(at: index) }
        let new = added.map { decisionFileLine($0, calendar: calendar) }
        for (decision, line) in zip(added, new) { file.set(decision.n, line) }
        lines = ProjectMemory.trimmedEnd(lines, crlf: crlf) + ProjectMemory.ended(new, crlf: crlf) + [""]
        // The frontmatter's `modified`, as the panel's writes keep it.
        let end = ProjectMemory.frontmatterEnd(lines)
        if end > 0, let modified = ProjectMemory.modifiedLine(in: Array(lines[..<end])) {
            let line = lines[modified]
            lines[modified] = line.prefix { $0 == " " } + "modified: " + ProjectMemory.modifiedText(now) + (line.hasSuffix("\r") ? "\r" : "")
        }
        return (ProjectMemory.joinLines(lines), file)
    }

    /// The title a topic's file and index line get.
    static func decisionTitle(_ topic: String) -> String {
        "Decisions — \(topic)"
    }

    static func decisionHook(_ topic: String) -> String {
        "the user's decisions on \(topic), dated, each with its source"
    }

    /// A YAML double-quoted scalar.
    private static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// A new topic file, its frontmatter marked as Nirux's and naming its
    /// topic, so Nirux can take it back if its record is lost.
    static func newDecisionFile(
        name: String, topic: String, decisions: [Decision], now: Date, calendar: Calendar = ProjectHistoryJournal.localGregorian
    ) -> String {
        let description = "The user's decisions on \(oneLine(topic)), dated, each with its source"
        let lines = decisions.sorted(by: saidBefore).map { decisionFileLine($0, calendar: calendar) }
        return """
            ---
            name: \(name)
            description: \(quoted(description))
            metadata:
              type: project
              modified: \(ProjectMemory.modifiedText(now))
              \(decisionFileMark)
              topic: \(quoted(oneLine(topic)))
            ---

            The user's decisions on \(oneLine(topic)), as Nirux read them in this project's sessions, oldest first: \
            records of what the user chose, not tasks. When a later decision changes one, Nirux takes the old line \
            out. Each line ends with Nirux's number for it and its source: `msg <id>` is the message of the \
            project's history (Nirux's journal) that states it, `after <id>` the agent's proposal the user agreed \
            to; a decision ending in "(via <name>)" was relayed by that session, quoting the user. Check a \
            decision that blocks your task before acting on it. Agents: don't edit or delete these lines unless the \
            user asks; tell the user instead. The user may change them freely: Nirux won't undo it.

            \(lines.joined(separator: "\n"))

            """
    }

    /// The topic a Nirux file names in its frontmatter.
    static func decisionFileTopic(_ text: String) -> String? {
        guard isDecisionFile(text) else { return nil }
        let topic = ProjectMemory.frontmatter(of: text).fields["metadata.topic"]
        return topic?.isEmpty == false ? topic : nil
    }

    /// Whether a memory file is one Nirux keeps: its frontmatter holds
    /// `decisionFileMark`.
    static func isDecisionFile(_ text: String) -> Bool {
        let lines = text.components(separatedBy: "\n")
        let end = ProjectMemory.frontmatterEnd(lines)
        return end > 0 && lines[..<end].contains { $0.trimmingCharacters(in: .whitespacesAndNewlines) == decisionFileMark }
    }

    /// `MEMORY.md` with `line` at its end, as the panel adds a memory's:
    /// the user's own lines keep their places; nil when a line already
    /// names `fileName`.
    static func indexAdding(_ line: String, for fileName: String, to index: String) -> String? {
        let existing = ProjectMemory.indexLines(in: index)
        guard !existing.contains(where: { ProjectMemory.fileKey($0.fileName) == ProjectMemory.fileKey(fileName) }) else { return nil }
        let (lines, crlf) = ProjectMemory.splitLines(index)
        return ProjectMemory.joinLines(ProjectMemory.trimmedEnd(lines, crlf: crlf) + ProjectMemory.ended([line], crlf: crlf) + [""])
    }

    /// Whether `MEMORY.md` can take one more line and stay under
    /// `maxIndexLines` and `maxIndexBytes`.
    static func indexHasRoom(_ index: String, for line: String) -> Bool {
        let lines = index.split(separator: "\n", omittingEmptySubsequences: false)
        let count = lines.last?.isEmpty == true ? lines.count - 1 : lines.count
        return count + 1 <= maxIndexLines && index.utf8.count + line.utf8.count + 1 <= maxIndexBytes
    }
}
