import Foundation

// MARK: - What agents know

/// The Project Memory panel's one list: what agents know about a
/// repository, whatever file holds it.
/// - **Always**: the rules of the Nirux project brief (SpaceBrief), which
///   every Claude and Codex session Nirux starts in the project gets.
/// - **Team**: the rules of the repository's `CLAUDE.md` and `AGENTS.md`,
///   committed: read here, changed there.
/// - **When relevant**: Claude Code's memory of the repository, which a
///   session reads when it needs it.
///
/// A file's rules are its top-level bullets and paragraphs; what isn't one
/// (a table, a code block on its own) stays one rule, as written.
extension ProjectMemory {
    enum Scope: String, CaseIterable, Sendable {
        case always, team, whenRelevant

        var title: String {
            switch self {
            case .always: return "Always"
            case .team: return "Team"
            case .whenRelevant: return "When relevant"
            }
        }
    }

    /// A rule of a Markdown file: a top-level bullet, its marker gone, or a
    /// paragraph, with the lines it spans.
    struct Rule: Equatable, Sendable {
        let text: String
        /// 1-based, as an editor numbers lines.
        let lines: ClosedRange<Int>
    }

    /// A file of rules: the brief, or one of the repository's.
    struct RuleFile: Equatable, Sendable {
        let url: URL
        /// "Space brief", "CLAUDE.md"…, as the panel names it.
        let label: String
        let rules: [Rule]
    }

    /// One item of the list.
    struct Entry: Equatable, Sendable {
        enum Source: Equatable, Sendable {
            /// The `index`th rule of `files[file]`.
            case rule(file: Int, index: Int)
            /// An index into `Contents.memories`.
            case memory(Int)
            /// A line of `MEMORY.md` whose file is gone.
            case missingFile(IndexLine)
            /// A brick of the space, by id.
            case brick(String)
            /// A brick proposed to the user, by id.
            case proposal(String)
            /// What an agent flagged without naming a brick (a gap), by id.
            case flag(String)
        }

        let scope: Scope
        let title: String
        let detail: String
        let source: Source
        /// Folded once (see `folded`): the filter runs on every keystroke.
        let searchText: String
        /// What the row's chip says instead of its scope.
        var badge: String?
        /// The bricks its text cites: it rests on them.
        var cites: [String] = []
    }

    /// The space's bricks, as the list shows them.
    struct Bricks: Equatable, Sendable {
        let loaded: KnowledgeStore.Loaded
        /// Per brick: the tasks it reached, those a correction followed.
        let reach: [String: Reach]
        /// The space's switch.
        let serves: Bool
        let now: TimeInterval
        let macOS: Int
        /// What agents flagged, the user's dismissals left out.
        var flags: [KnowledgeFlag] = []

        struct Reach: Equatable, Sendable {
            var tasks = 0
            var corrections = 0
        }

        func status(of id: String) -> BrickStatus? { loaded.status(of: id, now: now, macOS: macOS) }

        /// Reads the space's bricks and their uses.
        static func read(_ store: KnowledgeStore, serves: Bool, now: TimeInterval = Date().timeIntervalSince1970) -> Bricks? {
            let loaded = store.load()
            let dismissed = Set(loaded.state.dismissedFlags ?? [])
            let flags = KnowledgeFlag.load(in: store).filter { !dismissed.contains($0.id) }
            guard !loaded.bricks.isEmpty || !loaded.state.proposals.isEmpty || !flags.isEmpty else { return nil }
            let reach = KnowledgeUse.reach(KnowledgeUse.load(in: store)).mapValues { Reach(tasks: $0.tasks, corrections: $0.corrections) }
            return Bricks(loaded: loaded, reach: reach, serves: serves, now: now, macOS: SpaceKnowledge.macOS, flags: flags)
        }

        /// The first brick `cites` names that agents don't get now, and why.
        func flaggedBase(in cites: [String]) -> (id: String, why: String)? {
            for id in cites {
                guard let status = status(of: id) else { return (id, "this space holds no such brick") }
                if status != .open { return (id, status.title + (status.reason.map { ": \($0)" } ?? "")) }
            }
            return nil
        }

        /// Proposals first, then standing bricks, then closed ones.
        var listed: [(id: String, brick: KnowledgeBrick, status: BrickStatus?)] {
            let proposals = loaded.pending.map { ($0.id, $0.brick, BrickStatus?.none) }
            let bricks = loaded.ordered.map { ($0.id, $0.brick, status(of: $0.id)) }
            func rank(_ status: BrickStatus?) -> Int {
                switch status {
                case .open?: return 0
                case .expired?, .suspect?, .failing?, .flagged?: return 1
                case .closed?: return 2
                case nil: return 0
                }
            }
            return proposals + bricks.enumerated().sorted { (rank($0.element.2), $0.offset) < (rank($1.element.2), $1.offset) }.map(\.element)
        }
    }

    /// What agents know about a repository, as read.
    struct Knowledge: Equatable, Sendable {
        /// The brief first, then the repository's files.
        let files: [RuleFile]
        /// Nil when the repository has no memory folder yet.
        let memory: Contents?
        /// Nil when the space has no brick and no proposal.
        let bricks: Bricks?
        /// Always, then team, then when relevant: the memory in its index's
        /// order, then the index's lines without a file.
        let entries: [Entry]

        init(brief: RuleFile?, teamFiles: [RuleFile], memory: Contents?, bricks: Bricks? = nil) {
            files = (brief.map { [$0] } ?? []) + teamFiles
            self.memory = memory
            self.bricks = bricks
            var entries: [Entry] = []
            for (fileIndex, file) in files.enumerated() {
                let scope: Scope = fileIndex == 0 && brief != nil ? .always : .team
                for (index, rule) in file.rules.enumerated() {
                    let (title, detail) = ProjectMemory.headline(of: rule.text)
                    entries.append(Entry(
                        scope: scope, title: title, detail: detail, source: .rule(file: fileIndex, index: index),
                        searchText: ProjectMemory.folded(rule.text)
                    ))
                }
            }
            let listed = bricks?.listed ?? []
            let flagEntries = (bricks?.flags ?? []).filter { $0.brick == nil }.map { flag in
                Entry(
                    scope: .whenRelevant, title: flag.about, detail: "\(flag.kind.rawValue) flagged by an agent · \(flag.text)", source: .flag(flag.id),
                    searchText: ProjectMemory.folded([flag.about, flag.text].joined(separator: "\n")), badge: flag.kind.rawValue
                )
            }
            let proposals = listed.prefix { $0.status == nil }.count
            for (index, (id, brick, status)) in listed.enumerated() {
                if index == proposals { entries += flagEntries }
                let reach = bricks?.reach[id]
                let detail = [
                    status == nil ? "proposed by \(brick.proposedBy ?? "an agent")" : nil,
                    brick.scope.paths.joined(separator: ", "),
                    brick.proofs.map(\.label).joined(separator: " · "),
                    reach.map { "\($0.tasks) task\($0.tasks == 1 ? "" : "s")" }
                ].compactMap { $0 }.joined(separator: " · ")
                entries.append(Entry(
                    scope: .whenRelevant, title: brick.sentence, detail: detail, source: status == nil ? .proposal(id) : .brick(id),
                    searchText: ProjectMemory.folded([brick.sentence, brick.subject, brick.scope.paths.joined(separator: " "), id].joined(separator: "\n")),
                    badge: status?.title ?? "proposed"
                ))
            }
            if proposals == listed.count { entries += flagEntries }
            for (index, memory) in (memory?.memories ?? []).enumerated() {
                entries.append(Entry(
                    scope: .whenRelevant, title: memory.title, detail: memory.description, source: .memory(index),
                    searchText: memory.searchText
                ))
            }
            for line in memory?.missingFiles ?? [] {
                entries.append(Entry(
                    scope: .whenRelevant, title: line.title.isEmpty ? line.target : line.title,
                    detail: "Its file is gone", source: .missingFile(line),
                    searchText: ProjectMemory.folded([line.title, line.target, line.hook].joined(separator: "\n"))
                ))
            }
            // A rule or a memory that cites a brick rests on it: flagged
            // while agents don't get that brick.
            let ruleFiles = files
            self.entries = entries.map { entry in
                var entry = entry
                switch entry.source {
                case .rule(let file, let index):
                    entry.cites = ruleFiles[safe: file]?.rules[safe: index].map { KnowledgeLinks.cited(in: $0.text) } ?? []
                case .memory(let index):
                    entry.cites = memory?.memories[safe: index].map { KnowledgeLinks.cited(in: $0.body + "\n" + $0.description) } ?? []
                default:
                    break
                }
                if bricks?.flaggedBase(in: entry.cites) != nil { entry.badge = "flagged" }
                return entry
            }
        }

        func rule(of entry: Entry) -> (file: RuleFile, rule: Rule)? {
            guard case .rule(let fileIndex, let index) = entry.source, let file = files[safe: fileIndex],
                  let rule = file.rules[safe: index]
            else { return nil }
            return (file, rule)
        }

        /// The brick an entry shows, proposed or validated.
        func brick(of entry: Entry) -> (id: String, brick: KnowledgeBrick, status: BrickStatus?)? {
            switch entry.source {
            case .brick(let id): return bricks?.loaded.bricks[id].map { (id, $0, bricks?.status(of: id)) }
            case .proposal(let id): return bricks?.loaded.pending.first { $0.id == id }.map { (id, $0.brick, nil) }
            default: return nil
            }
        }

        func flag(of entry: Entry) -> KnowledgeFlag? {
            guard case .flag(let id) = entry.source else { return nil }
            return bricks?.flags.first { $0.id == id }
        }

        func memory(of entry: Entry) -> Memory? {
            guard case .memory(let index) = entry.source else { return nil }
            return memory?.memories[safe: index]
        }

        /// The file to open for `entry`, at the line where it starts.
        func location(of entry: Entry) -> (url: URL, line: Int?)? {
            switch entry.source {
            case .rule:
                return rule(of: entry).map { ($0.file.url, $0.rule.lines.lowerBound) }
            case .memory:
                guard let memory = memory(of: entry), let directory = self.memory?.directory else { return nil }
                return (directory.appendingPathComponent(memory.fileName), nil)
            case .missingFile(let line):
                return self.memory.map { ($0.directory.appendingPathComponent(ProjectMemory.indexFileName), line.number) }
            case .flag:
                return nil
            case .brick, .proposal:
                // The first file its proofs name, in the repository's main checkout.
                guard let brick = brick(of: entry)?.brick, let root = SpaceKnowledge.anchor(key: brick.scope.anchor)?.folder,
                      let path = brick.proofs.lazy.compactMap({ proof -> String? in
                          switch proof {
                          case .file(let path), .text(let path, _), .test(let path, _): return path
                          default: return nil
                          }
                      }).first
                else { return nil }
                return (URL(fileURLWithPath: root).appendingPathComponent(path), nil)
            }
        }

        func count(_ scope: Scope) -> Int { entries.filter { $0.scope == scope }.count }

        /// What a write acts on for `entry`, resolved now; nil for the
        /// team's rules, which change in the editor.
        func target(of entry: Entry) -> Target? {
            switch entry.source {
            case .rule:
                guard entry.scope == .always, let (file, rule) = rule(of: entry) else { return nil }
                return .briefRule(rule, file: file.url)
            case .memory:
                guard let memory = memory(of: entry), let directory = self.memory?.directory else { return nil }
                return .memory(memory, directory: directory)
            case .missingFile(let line):
                return self.memory.map { .missingFile(line, directory: $0.directory) }
            case .brick, .proposal, .flag:
                // Never edited: the panel's own buttons decide them.
                return nil
            }
        }
    }

    /// An item as the user acted on it, resolved from the panel's list right
    /// then: a write never looks it up again by its place in a list that may
    /// have changed meanwhile.
    enum Target: Equatable, Sendable {
        case memory(Memory, directory: URL)
        case briefRule(Rule, file: URL)
        case missingFile(IndexLine, directory: URL)
    }

    /// The repository's files the team shares, at its checkout's top.
    static let teamFileNames = ["CLAUDE.md", ".claude/CLAUDE.md", "AGENTS.md"]

    /// Reads what agents know about the repository holding `folder`: the
    /// brief at `brief`, the team's files of `folder`'s checkout, and the
    /// memory `location` finds. Call it off the main thread.
    static func knowledge(
        folder: String, brief: URL?, location: Location, bricks: Bricks? = nil, followingSymlinks: Bool = true
    ) -> Knowledge {
        let briefFile = brief.flatMap { url in
            SpaceBrief.readBrief(at: url, followingSymlinks: followingSymlinks).map {
                RuleFile(url: url, label: "Space brief", rules: rules(in: $0))
            }
        }
        let checkout = URL(fileURLWithPath: AgentSessionRecord.checkoutRoot(containing: folder) ?? folder)
        let teamFiles = teamFileNames.compactMap { name -> RuleFile? in
            let url = checkout.appendingPathComponent(name)
            return readText(url.path, followingSymlinks: followingSymlinks).map {
                RuleFile(url: url, label: name, rules: rules(in: $0, blockCommentsOnly: true))
            }
        }
        return Knowledge(
            brief: briefFile, teamFiles: teamFiles, memory: read(directory: location.directory, followingSymlinks: followingSymlinks), bricks: bricks
        )
    }

    // MARK: - The panel's list

    /// The entries the panel lists for `text` and `scope` (nil: all; team
    /// rules apply always, so `.always` lists them too), as indexes into
    /// `entries`. Every word must match, in any case and accent.
    static func entries(in knowledge: Knowledge, text: String, scope: Scope?) -> [Int] {
        let words = text.split(whereSeparator: \.isWhitespace).map { folded(String($0)) }
        return knowledge.entries.indices.filter { index in
            let entry = knowledge.entries[index]
            let inScope = scope == nil || entry.scope == scope || (scope == .always && entry.scope == .team)
            return inScope && words.allSatisfy(entry.searchText.contains)
        }
    }

    /// "11 always · 3 team · 49 when relevant · 1 brick to validate"; with
    /// a filter on, "12 of 63".
    static func summary(of knowledge: Knowledge, shown: Int? = nil) -> String {
        if let shown { return "\(shown) of \(knowledge.entries.count)" }
        let parts: [(Scope, String)] = [(.always, "always"), (.team, "team"), (.whenRelevant, "when relevant")]
        var counted = parts.compactMap { scope, name in knowledge.count(scope) > 0 ? "\(knowledge.count(scope)) \(name)" : nil }
        let waiting = knowledge.bricks?.loaded.pending.count ?? 0
        if waiting > 0 { counted.append("\(waiting) brick\(waiting == 1 ? "" : "s") to validate") }
        let flagged = knowledge.entries.filter { $0.badge == "flagged" }.count
        if flagged > 0 { counted.append("\(flagged) flagged") }
        return counted.isEmpty ? "Nothing yet" : counted.joined(separator: " · ")
    }

    // MARK: - Rules

    /// The rules of a Markdown file: one per top-level bullet (its indented
    /// lines with it) or paragraph. Headings, blank lines, a frontmatter,
    /// lines across and `<!-- -->` comments aren't rules; a fenced block
    /// stays whole. The brief drops every comment before sessions get it;
    /// Claude Code drops only the ones on lines of their own
    /// (`blockCommentsOnly`).
    static func rules(in text: String, blockCommentsOnly: Bool = false) -> [Rule] {
        let raw = text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        let lines = withoutComments(raw, blockOnly: blockCommentsOnly)
        var rules: [Rule] = []
        /// The rule being read; `indent` is a bullet's, nil for a paragraph;
        /// `content`, the column its text starts at, past the marker.
        var current: (start: Int, end: Int, lines: [String], indent: Int?, content: Int)?
        /// Blank lines after a bullet's text: they stay with it if an
        /// indented line goes on with it.
        var blanks = 0
        func close() {
            if let rule = current {
                let text = rule.lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { rules.append(Rule(text: text, lines: rule.start...rule.end)) }
            }
            current = nil
            blanks = 0
        }
        func append(_ line: String, number: Int) {
            if current == nil { current = (number, number, [], nil, 0) }
            current?.lines.append(contentsOf: Array(repeating: "", count: blanks) + [line])
            current?.end = number
            blanks = 0
        }
        /// A line inside the current bullet: indented past its marker, or
        /// lazily right after it.
        func continues(at indent: Int) -> Bool {
            guard let rule = current else { return false }
            if let bullet = rule.indent { return indent > bullet || blanks == 0 }
            return true
        }
        var index = frontmatterEnd(lines)
        while index < lines.count {
            let line = expandingLeadingTabs(lines[index])
            index += 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let indent = line.prefix { $0 == " " }.count
            let bulletIndent = current?.indent ?? -1
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                // The fence and all it holds go with the rule it is in, or
                // make one of their own.
                let inBullet = current?.indent != nil && indent > bulletIndent
                if !inBullet && !(current != nil && current?.indent == nil) { close() }
                let fence = String(trimmed.prefix(3))
                // Inside a bullet, its lines lose the indent up to the bullet's
                // text, as its other lines do: written back under the same
                // marker, they get it again, no more.
                let column = current?.content ?? 0
                func content(_ line: String) -> String {
                    guard inBullet else { return line }
                    let line = expandingLeadingTabs(line)
                    return String(line.dropFirst(min(line.prefix { $0 == " " }.count, column)))
                }
                append(content(line), number: index)
                while index < lines.count {
                    index += 1
                    append(content(lines[index - 1]), number: index)
                    if lines[index - 1].trimmingCharacters(in: .whitespaces).hasPrefix(fence) { break }
                }
                if !inBullet { close() }
            } else if trimmed.isEmpty {
                if current?.indent != nil { blanks += 1 } else { close() }
            } else if indent < 4, isHeading(trimmed) || isThematicBreak(trimmed) {
                close()
            } else if let marker = bulletMarker(trimmed), indent <= 3 || current == nil, !(current?.indent != nil && indent > bulletIndent) {
                close()
                // A bare `-` is written back as `- `.
                current = (index, index, [String(trimmed.dropFirst(marker))], indent, indent + max(marker, 2))
            } else if continues(at: indent) {
                let content = current?.indent == nil ? 0 : min(indent, current?.content ?? 0)
                append(String(line.dropFirst(content)), number: index)
            } else {
                close()
                append(line, number: index)
            }
        }
        close()
        return rules
    }

    /// The index of the first line after a frontmatter, else 0.
    static func frontmatterEnd(_ lines: [String]) -> Int {
        guard lines.first.map(stripBOM)?.trimmingCharacters(in: .whitespacesAndNewlines) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "---" })
        else { return 0 }
        return end + 1
    }

    private static func stripBOM(_ line: String) -> String {
        line.hasPrefix("\u{FEFF}") ? String(line.dropFirst()) : line
    }

    /// A tab indents to the next multiple of 4, as Markdown counts it.
    private static func expandingLeadingTabs(_ line: String) -> String {
        guard line.hasPrefix("\t") || line.hasPrefix(" ") else { return line }
        var indent = 0
        var rest = Substring(line)
        while let first = rest.first, first == " " || first == "\t" {
            indent = first == "\t" ? (indent / 4 + 1) * 4 : indent + 1
            rest = rest.dropFirst()
        }
        return String(repeating: " ", count: indent) + rest
    }

    /// `# Title` to `###### Title`; not `#123`.
    private static func isHeading(_ line: String) -> Bool {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return false }
        let rest = line.dropFirst(hashes)
        return rest.isEmpty || rest.first == " "
    }

    /// `---`, `***`, `___`: a line across, not a rule.
    private static func isThematicBreak(_ line: String) -> Bool {
        guard let first = line.first, "-*_".contains(first) else { return false }
        return line.filter { $0 == first }.count >= 3 && line.allSatisfy { $0 == first || $0 == " " }
    }

    /// The length of a bullet's marker and the space after it (`- `, `* `,
    /// `+ `, `1. `, `1) `; 1 for an empty `-`); nil when the line isn't a
    /// bullet.
    static func bulletMarker(_ line: String) -> Int? {
        if let first = line.first, "-*+".contains(first) {
            if line.count == 1 { return 1 }
            return line.dropFirst().first == " " && !isThematicBreak(line) ? 2 : nil
        }
        let digits = line.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let rest = line.dropFirst(digits.count)
        guard let mark = rest.first, mark == "." || mark == ")", rest.dropFirst().first == " " else { return nil }
        return digits.count + 2
    }

    /// `lines` with `<!-- -->` comments blanked, so lines keep their numbers;
    /// with `blockOnly`, only the comments with nothing else on their
    /// lines. An unclosed comment stays, as Claude Code leaves it.
    static func withoutComments(_ lines: [String], blockOnly: Bool = false) -> [String] {
        let text = lines.joined(separator: "\n")
        guard text.contains("<!--"),
              let regex = try? NSRegularExpression(pattern: blockOnly ? #"(?m)^[ \t]*<!--[\s\S]*?-->[ \t]*$"# : #"<!--[\s\S]*?-->"#)
        else { return lines }
        let result = NSMutableString(string: text)
        for match in regex.matches(in: text, range: NSRange(location: 0, length: result.length)).reversed() {
            // Each line break inside stays: the lines after keep their
            // numbers.
            let breaks = (text as NSString).substring(with: match.range).filter { $0 == "\n" }
            result.replaceCharacters(in: match.range, with: String(breaks))
        }
        return (result as String).components(separatedBy: "\n")
    }

    /// A rule's title and what follows it, both on one line, without
    /// Markdown marks: its bold lead, else its first sentence or clause,
    /// else its first line. A code fence isn't a title.
    static func headline(of text: String) -> (title: String, detail: String) {
        func plain(_ line: String) -> String {
            AgentText.withoutMarks(line).trimmingCharacters(in: .whitespaces)
        }
        var lines = text.components(separatedBy: "\n").filter {
            let trimmed = $0.trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty && !trimmed.hasPrefix("```") && !trimmed.hasPrefix("~~~")
        }
        // A bold lead may run over lines: its title is on one.
        if let first = lines.first, first.hasPrefix("**"), !first.dropFirst(2).contains("**"),
           let close = lines.firstIndex(where: { $0.contains("**") && $0 != first }) {
            lines.replaceSubrange(0...close, with: [lines[0...close].joined(separator: " ")])
        }
        guard let firstLine = lines.first else { return ("", "") }
        let rest = lines.dropFirst().map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return plain(bulletMarker(trimmed).map { String(trimmed.dropFirst($0)) } ?? trimmed)
        }.filter { !$0.isEmpty }.joined(separator: " · ")
        /// What follows a title, without the punctuation that ended it.
        func joined(_ head: Substring, _ tail: String) -> String {
            let head = String(head.drop { " :;—–-.".contains($0) }).trimmingCharacters(in: .whitespaces)
            return [head, tail].filter { !$0.isEmpty }.joined(separator: " ")
        }
        let first = firstLine.trimmingCharacters(in: .whitespaces)
        if first.hasPrefix("**"), let close = first.dropFirst(2).range(of: "**") {
            let title = plain(String(first.dropFirst(2)[..<close.lowerBound])).trimmingCharacters(in: CharacterSet(charactersIn: " .:"))
            return (title, joined(Substring(plain(String(first[close.upperBound...]))), rest))
        }
        let line = plain(first)
        // The first sentence or clause end, past a few words.
        let ends = [". ", ": ", " — ", "; "].compactMap { separator in
            line.ranges(of: separator).first { line.distance(from: line.startIndex, to: $0.lowerBound) >= 8 }
        }
        if let end = ends.min(by: { $0.lowerBound < $1.lowerBound }),
           line.distance(from: line.startIndex, to: end.lowerBound) <= 100 {
            return (String(line[..<end.lowerBound]), joined(line[end.upperBound...], rest))
        }
        return (line.trimmingCharacters(in: CharacterSet(charactersIn: ".:")), rest)
    }
}
