import Foundation

/// Rules a space learns (docs/spaces.md, "Learned rules"): when the same
/// kind of defect turns up twice across a space's tasks, its Lead proposes
/// a one- or two-line rule (`propose_rule`, see RuleProposalStore), and once
/// the user adds it, it goes into the space's brief, which every session
/// started in the space from then on reads (SpaceBrief). The user can add
/// one from a task's row too.
///
/// A rule goes at the end of the brief's "## Rules learned" section, made at
/// the end of the brief when it has none, as one bullet that says when it
/// was learned and from what:
/// `- Tests wait on state, never on a fixed sleep. (learned 2026-11-11, #395, #417)`.
/// Everything else in the brief stays byte for byte: the bullet is inserted,
/// nothing is rewritten.
enum LearnedRules {
    static let heading = "## Rules learned"
    static let maxRuleLength = 300
    static let maxEvidenceLength = 200
    /// Past this the brief reads as long: half of what sessions get.
    static let longBriefCharacters = SpaceBrief.maxCharacters / 2

    // MARK: - Text

    /// `text` on one line: whitespace runs folded to one space, invisible
    /// characters dropped; "" when nothing is left. Past `limit` it stays
    /// long (cut only far past it), for `problem` to refuse.
    static func cleaned(_ text: String, limit: Int) -> String {
        AgentText.clean(text, maxLength: limit * 4) ?? ""
    }

    /// What a Lead's proposal must hold: where the defect showed up, and a
    /// rule `problem` accepts. The Lead's tool and the store both ask it.
    static func proposalProblem(rule: String, evidence: String) -> String? {
        if evidence.isEmpty { return "evidence must say where the defect showed up (\"#395, #417\")." }
        return problem(rule: rule, evidence: evidence)
    }

    /// Why a cleaned rule and its evidence can't go into the brief, or nil.
    static func problem(rule: String, evidence: String) -> String? {
        if rule.isEmpty { return "The rule is empty." }
        if rule.count > maxRuleLength {
            return "A rule holds at most \(maxRuleLength) characters: one or two lines every task can follow."
        }
        if evidence.count > maxEvidenceLength { return "The evidence holds at most \(maxEvidenceLength) characters." }
        // Sessions never get what a comment hides: one opened here would hide
        // the rest of the brief, or end the one around it.
        if [rule, evidence].contains(where: { $0.contains("<!--") || $0.contains("-->") }) {
            return "A rule can’t hold <!-- or -->: it would hide part of the brief."
        }
        return nil
    }

    /// The bullet for a rule, dated in `timeZone`.
    static func line(rule: String, evidence: String, date: Date, timeZone: TimeZone = .current) -> String {
        let day = dayText(date, timeZone: timeZone)
        return "- \(rule) (learned \(day)\(evidence.isEmpty ? "" : ", \(evidence)"))"
    }

    /// `2026-11-11`.
    static func dayText(_ date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// A rule without the "(learned …)" it ends with, and that day.
    /// The last " (learned " followed by a day counts: the evidence may
    /// say "learned" too.
    static func splitLearned(_ text: String) -> (rule: String, day: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix(")") else { return (trimmed, nil) }
        var end = trimmed.endIndex
        while let open = trimmed.range(of: " (learned ", options: .backwards, range: trimmed.startIndex..<end) {
            let day = trimmed[open.upperBound...].prefix(10)
            let isDay = day.count == 10 && day.enumerated().allSatisfy { index, character in
                [4, 7].contains(index) ? character == "-" : character.isASCII && character.isNumber
            }
            if isDay { return (String(trimmed[..<open.lowerBound]), String(day)) }
            end = open.lowerBound
        }
        return (trimmed, nil)
    }

    /// What two rules are compared by: their words, in any case, accent or
    /// spacing, without their "(learned …)" or final punctuation.
    static func comparable(_ text: String) -> String {
        let rule = splitLearned(AgentText.clean(text, maxLength: 64_000) ?? "").rule
        let folded = rule.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        return String(folded.reversed().drop { ".!;:, ".contains($0) }.reversed())
    }

    /// A rule of the brief that says the same as `rule`, and the day it was
    /// learned when it says one.
    static func existingRule(matching rule: String, in briefText: String) -> (text: String, day: String?)? {
        let key = comparable(rule)
        guard !key.isEmpty else { return nil }
        guard let match = ProjectMemory.rules(in: briefText).first(where: { comparable($0.text) == key }) else { return nil }
        return (match.text, splitLearned(match.text).day)
    }

    /// What sessions get of a brief, in characters.
    static func characterCount(of briefText: String) -> Int {
        SpaceBrief.body(of: briefText)?.count ?? 0
    }

    /// Why sessions wouldn't get all of a brief, or nil: past
    /// `maxCharacters`, or past the bytes Codex takes in one argument (a
    /// brief of emoji can pass those first). The end is what gets cut: a
    /// rule just added.
    static func lengthProblem(of briefText: String, maxCharacters: Int = SpaceBrief.maxCharacters) -> ProjectMemory.WriteError? {
        let body = SpaceBrief.body(of: briefText) ?? ""
        if body.count > maxCharacters { return .tooLong(maxCharacters) }
        if body.utf8.count > SpaceBrief.maxBytes {
            return .failed("The space brief would pass \(SpaceBrief.maxBytes.formatted()) bytes, past what sessions get: shorten it first")
        }
        return nil
    }

    // MARK: - Writing the brief

    /// The brief with `bullet` at the end of its "## Rules learned"
    /// section, or a new section at its end: every byte of `text` kept, in
    /// order, the bullet's lines inserted at one place, with the file's line
    /// breaks. Refused when that place is inside a comment or a code block.
    static func inserting(_ bullet: String, into text: String) throws -> String {
        let lines = Self.lines(of: text)
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        let place: String.Index
        let inserted: String
        if let start = lines.firstIndex(where: \.isRulesHeading) {
            let end = sectionEnd(after: start, in: lines)
            let last = lines[(start + 1)..<end].lastIndex { !$0.raw.trimmingCharacters(in: .whitespaces).isEmpty }
            let after = lines[last ?? start]
            // Text right after (a setext heading's): a blank line keeps it
            // from going on the bullet.
            let next = (last ?? start) + 1
            let textFollows = next < lines.count && !lines[next].raw.trimmingCharacters(in: .whitespaces).isEmpty
                && Line.heading(lines[next].live) == nil
            // Right under the heading, a blank line between.
            inserted = (after.hasBreak ? "" : newline) + (last == nil ? newline : "") + bullet + newline + (textFollows ? newline : "")
            place = after.end
            guard isSafe(after: last ?? start, in: lines) else { throw unsafePlace }
        } else {
            guard lines.isEmpty || isSafe(after: lines.count - 1, in: lines) else { throw unsafePlace }
            // Its last line is blank: a blank line ends it already.
            let blankAtEnd = lines.last?.raw.trimmingCharacters(in: .whitespaces).isEmpty == true
            let separator: String
            if text.isEmpty {
                separator = ""
            } else if text.unicodeScalars.last != "\n" {
                separator = newline + newline
            } else {
                separator = blankAtEnd ? "" : newline
            }
            inserted = separator + heading + newline + newline + bullet + newline
            place = text.endIndex
        }
        let written = String(text[..<place]) + inserted + String(text[place...])
        // Whatever the brief's comments do around it, sessions must get
        // this copy (one the same may be there already).
        func copies(in text: String) -> Int { (SpaceBrief.body(of: text) ?? "").components(separatedBy: bullet).count - 1 }
        guard copies(in: written) == copies(in: text) + 1 else { throw unsafePlace }
        return written
    }

    /// The first line past the section that starts at `start`: a `#` or
    /// `##` heading, or a setext one (a paragraph after a blank line,
    /// underlined with `=` or `-`), else the end.
    private static func sectionEnd(after start: Int, in lines: [Line]) -> Int {
        var index = start + 1
        while index < lines.count {
            if lines[index].isTopHeading { return index }
            if lines[index].isSetextUnderline, index - 1 > start, lines[index - 1].isParagraphLine {
                var first = index - 1
                while first - 1 > start, lines[first - 1].isParagraphLine { first -= 1 }
                // After a list item it is a line across, not a heading.
                if first - 1 == start || lines[first - 1].live.trimmingCharacters(in: .whitespaces).isEmpty { return first }
            }
            index += 1
        }
        return lines.count
    }

    private static var unsafePlace: ProjectMemory.WriteError {
        .failed("The brief’s end, or its “Rules learned” section, is inside a comment or a code block: add the rule in Space Settings › Brief")
    }

    /// Whether a bullet written after line `index` would be outside any
    /// code block. One a comment would hide is caught after the insert:
    /// sessions must get one more copy than before. An unclosed `<!--`
    /// hides nothing from them: SpaceBrief.body keeps it as text.
    private static func isSafe(after index: Int, in lines: [Line]) -> Bool {
        !lines[index].fenceOpenAfter
    }

    /// A line of the brief: where it is in the text (its break included),
    /// its text, and what is left of it once complete comments are out.
    private struct Line {
        let end: String.Index
        let hasBreak: Bool
        /// Without its break.
        let raw: String
        let live: String
        let inFence: Bool
        /// A code block is still open after it.
        let fenceOpenAfter: Bool

        /// `## Rules learned`, in any case, outside comments and code (a
        /// comment on its line aside).
        var isRulesHeading: Bool {
            !inFence && Self.heading(live).map { $0.level == 2 && $0.title.lowercased() == "rules learned" } == true
        }

        /// A `#` or `##` heading, outside comments and code: the end of a
        /// section.
        var isTopHeading: Bool {
            !inFence && Self.heading(live).map { $0.level <= 2 } == true
        }

        /// `===` or `---` under a paragraph line makes it a heading.
        var isSetextUnderline: Bool {
            let indent = live.prefix { $0 == " " }.count
            let trimmed = live.trimmingCharacters(in: .whitespaces)
            guard !inFence, indent <= 3, let first = trimmed.first, first == "=" || first == "-" else { return false }
            return trimmed.allSatisfy { $0 == first }
        }

        /// Text that could be a setext heading's: not blank, code, a
        /// heading, a list item or an underline, and not indented (indented,
        /// it goes on the list item above).
        var isParagraphLine: Bool {
            let trimmed = live.trimmingCharacters(in: .whitespaces)
            return !inFence && !trimmed.isEmpty && !live.hasPrefix(" ") && !live.hasPrefix("\t") && Self.heading(live) == nil
                && ProjectMemory.bulletMarker(trimmed) == nil && !isSetextUnderline
        }

        static func heading(_ line: String) -> (level: Int, title: String)? {
            let indent = line.prefix { $0 == " " }.count
            guard indent <= 3 else { return nil }
            let rest = line.dropFirst(indent)
            let level = rest.prefix { $0 == "#" }.count
            guard (1...6).contains(level) else { return nil }
            let title = rest.dropFirst(level)
            guard title.isEmpty || title.first == " " || title.first == "\t" else { return nil }
            // `## Rules learned ##`: the closing run isn't the title's.
            var text = title.trimmingCharacters(in: .whitespaces)
            let closing = text.reversed().prefix { $0 == "#" }.count
            if closing == text.count {
                text = ""
            } else if closing > 0, text.dropLast(closing).last.map({ $0 == " " || $0 == "\t" }) == true {
                text = String(text.dropLast(closing)).trimmingCharacters(in: .whitespaces)
            }
            return (level, text)
        }
    }

    private static func lines(of text: String) -> [Line] {
        guard !text.isEmpty else { return [] }
        // Where each line starts and ends, its break included. By scalar:
        // "\r\n" is one Character, which a search for "\n" never finds. A
        // line's end, past its "\n", is a Character's end all the same.
        let scalars = text.unicodeScalars
        var bounds: [(start: String.Index, end: String.Index, hasBreak: Bool)] = []
        var start = scalars.startIndex
        while start < scalars.endIndex {
            if let newline = scalars[start...].firstIndex(of: "\n") {
                let end = scalars.index(after: newline)
                bounds.append((start, end, true))
                start = end
            } else {
                bounds.append((start, scalars.endIndex, false))
                start = scalars.endIndex
            }
        }
        let raw = bounds.map { bound -> String in
            var line = scalars[bound.start..<bound.end]
            if line.last == "\n" { line = line.dropLast() }
            if line.last == "\r" { line = line.dropLast() }
            return String(String.UnicodeScalarView(line))
        }
        // The complete comments, as SpaceBrief.body takes them out (an
        // unclosed `<!--` stays text).
        let live = ProjectMemory.withoutComments(raw)
        var fence: (character: Character, count: Int)?
        var result: [Line] = []
        for (index, bound) in bounds.enumerated() {
            let line = live[safe: index] ?? raw[index]
            let indent = line.prefix { $0 == " " }.count
            let trimmed = line.dropFirst(min(indent, 3))
            let inFence: Bool
            if let open = fence {
                inFence = true
                let run = trimmed.prefix { $0 == open.character }.count
                if indent <= 3, run >= open.count, trimmed.dropFirst(run).allSatisfy({ $0 == " " || $0 == "\t" }) { fence = nil }
            } else if indent <= 3, let first = trimmed.first, first == "`" || first == "~",
                      trimmed.prefix(while: { $0 == first }).count >= 3 {
                inFence = true
                fence = (first, trimmed.prefix { $0 == first }.count)
            } else {
                inFence = false
            }
            result.append(Line(
                end: bound.end, hasBreak: bound.hasBreak, raw: raw[index], live: line, inFence: inFence, fenceOpenAfter: fence != nil
            ))
        }
        return result
    }

    enum AddOutcome: Equatable {
        /// The bullet written.
        case added(String)
        /// Nothing written: the brief's rule that says it already.
        case alreadyThere(String)
    }

    /// Adds a rule to the brief at `url` (through a link, to where it
    /// points), created from its template when missing or empty. The write
    /// re-reads the brief right before replacing it and starts over from
    /// what is there when it changed (ProjectMemory.update): the user's
    /// edits made meanwhile stay. On the text it writes over, it looks for
    /// the rule first, and writes nothing when the brief says it already:
    /// written by hand meanwhile, or an Add whose decision wasn't recorded,
    /// retried. Refused past what
    /// sessions get: `maxCharacters`, or a file they don't read (past
    /// `SpaceBrief.maxFileBytes`). `onRead` sees each text read (tests
    /// edit the file there).
    static func add(
        rule: String, evidence: String, date: Date = Date(), to url: URL, spaceName: String,
        maxCharacters: Int = SpaceBrief.maxCharacters, timeZone: TimeZone = .current, onRead: ((String) -> Void)? = nil
    ) throws -> AddOutcome {
        let rule = cleaned(rule, limit: maxRuleLength)
        let evidence = cleaned(evidence, limit: maxEvidenceLength)
        if let problem = problem(rule: rule, evidence: evidence) { throw ProjectMemory.WriteError.failed(problem) }
        let bullet = line(rule: rule, evidence: evidence, date: date, timeZone: timeZone)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            throw ProjectMemory.WriteError.failed("Couldn’t create \(url.deletingLastPathComponent().path): \(error.localizedDescription)")
        }
        var outcome = AddOutcome.added(bullet)
        try ProjectMemory.update(url, creating: true) { current in
            onRead?(current)
            outcome = .added(bullet)
            guard current.utf8.count <= SpaceBrief.maxFileBytes else { throw ProjectMemory.WriteError.failed(fileTooLarge) }
            if let existing = existingRule(matching: rule, in: current) {
                outcome = .alreadyThere(existing.text)
                return nil
            }
            let base = current.isEmpty ? SpaceBrief.template(spaceName: spaceName) : current
            let written = try inserting(bullet, into: base)
            if let problem = lengthProblem(of: written, maxCharacters: maxCharacters) { throw problem }
            // With a byte order mark, as the write keeps one.
            guard written.utf8.count + 3 <= SpaceBrief.maxFileBytes else { throw ProjectMemory.WriteError.failed(fileTooLarge) }
            return written
        }
        return outcome
    }

    private static let fileTooLarge = "The brief’s file would be over 1 MB, which sessions don’t read: shorten it in Space Settings › Brief first"

    /// The brief as sessions read it, which a write starts from: "" when
    /// there is none; why not when they can't read it (past 1 MB, not a
    /// regular file, not UTF-8), and no rule can go in.
    static func readForAdding(at url: URL) -> (text: String, problem: String?) {
        switch BoardConfigStore.read(url.resolvingSymlinksInPath(), maxBytes: SpaceBrief.maxFileBytes) {
        case .missing:
            return ("", nil)
        case .data(let data):
            guard let text = String(data: data, encoding: .utf8) else {
                return ("", "The brief isn’t UTF-8 text, which sessions don’t read: fix it in Space Settings › Brief first")
            }
            return (text, nil)
        case .tooLarge:
            return ("", "The brief’s file is over 1 MB, which sessions don’t read: shorten it in Space Settings › Brief first")
        case .notARegularFile:
            return ("", "The brief isn’t a regular file, which sessions don’t read")
        case .unreadableBytes:
            return ("", "The brief can’t be read just now: try again")
        }
    }

    /// The brief's text as a write would start from it: "" when missing or
    /// not readable.
    static func briefText(at url: URL) -> String {
        readForAdding(at: url).text
    }
}
