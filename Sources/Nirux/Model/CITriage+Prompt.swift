import Foundation

// MARK: - What the model reads, and what it answers

extension CITriage {
    /// One changed file of the pull request, with its patch when GitHub
    /// gives one (none for a binary or a very large file).
    struct ChangedFile: Equatable, Sendable {
        let path: String
        let patch: String?
    }

    /// `gh api --paginate repos/…/pulls/N/files --jq '.[] | {filename, patch}'`:
    /// one JSON object per line, an empty patch for a file without one.
    /// Nil when a line isn't such an object (an error body).
    static func changedFiles(fromFileList data: Data) -> [ChangedFile]? {
        var files: [ChangedFile] = []
        for line in data.split(separator: 0x0A) where !line.allSatisfy({ $0 == 0x20 || $0 == 0x0D }) {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  let path = object["filename"] as? String
            else { return nil }
            files.append(ChangedFile(path: path, patch: (object["patch"] as? String).flatMap { $0.isEmpty ? nil : $0 }))
        }
        return files
    }

    /// The source of one failing test.
    struct TestSource: Equatable, Sendable {
        let name: String
        let path: String
        let lines: [String]
    }

    /// A file the pull request changes, with the declarations it edits
    /// there (none when the commit isn't in the local repository, or for a
    /// file that isn't Swift).
    struct Change: Equatable, Sendable {
        let path: String
        var declarations: [String] = []
    }

    /// Everything the model is given about one open failure.
    struct Evidence: Equatable, Sendable {
        var jobs: [Job]
        var attempt: Int
        var findings: LogFindings
        var sources: [TestSource] = []
        var changes: [Change] = []
    }

    /// The prompt measured, word for word. One sentence before the verdict
    /// is what makes the model commit: asked for the word alone, it answers
    /// UNSURE on almost every flake. That sentence is the reason shown.
    static let systemPrompt = """
        You triage one failed CI run of a pull request for its author. The failing tests are tests the pull request \
        does not edit. You are given the failing tests with their messages, their source, and what the pull request \
        changes (its files, and the declarations edited in each).

        Decide whether the pull request's changes made these tests fail.

        Look at the code: what do the failing tests call, set up and assert on? Do the changed declarations sit on \
        that path: the same type, the same feature, or code the tested behaviour runs through?

        Answer REAL when they do, or when a failure message names something the pull request changes.
        Answer FLAKY when they do not: the tests exercise a feature the pull request leaves alone, and a rerun of \
        the same commit would probably pass.
        Answer UNSURE when what you are given does not tell whether the changed code is on the tests' path.
        A timeout or a failed wait says nothing by itself: changes break tests that way too.

        Reply with two lines. First line: one short sentence saying what the failing tests exercise and whether \
        the changes touch it. Second line: exactly one word, FLAKY, REAL or UNSURE.
        """

    /// Bounds of the input, as measured: about 3,000 tokens at the median.
    static let promptTests = 8
    static let promptFailuresPerTest = 2
    static let promptMessageLength = 300
    static let promptSources = 3
    static let promptSourceLines = 60
    static let promptSourceLength = 3_000
    static let promptDeclarationsPerFile = 8
    static let promptFiles = 120
    static let promptJobs = 6
    /// The whole input, whatever its parts add up to.
    static let promptLength = 60_000

    /// The evidence between tags it can't close itself.
    static func modelInput(_ evidence: Evidence) -> Data {
        var lines: [String] = []
        for job in evidence.jobs.filter(\.isRed).prefix(promptJobs) {
            let failed = job.failedSteps.prefix(4).map { clipped($0, maxNameLength) }.joined(separator: ", ")
            let steps = failed.isEmpty ? "" : " Failed step: \(failed)."
            lines.append("Job: \(clipped(job.name, maxNameLength)) (attempt \(evidence.attempt)).\(steps)")
        }
        let tests = evidence.findings.tests
        if !tests.isEmpty {
            lines.append("Failing tests: \(tests.count)")
            for test in tests.prefix(promptTests) {
                lines.append("- \(test.name)")
                for failure in test.failures.prefix(promptFailuresPerTest) {
                    let file = (failure.file as NSString).lastPathComponent
                    lines.append("    \(file):\(failure.line): \(clipped(failure.message, promptMessageLength))")
                }
                if test.failures.count > promptFailuresPerTest {
                    lines.append("    (and \(test.failures.count - promptFailuresPerTest) more failures in this test)")
                }
            }
            if tests.count > promptTests {
                let more = tests.dropFirst(promptTests).prefix(12).map(\.name).joined(separator: ", ")
                lines.append("(and \(tests.count - promptTests) more failing tests: \(more))")
            }
        }
        let failed = Set(tests.map(\.name))
        let unfinished = evidence.findings.unfinished.filter { !failed.contains($0) }
        if !unfinished.isEmpty {
            let signal = evidence.findings.signals.first.map { " (signal \($0))" } ?? ""
            lines.append("Tests that started and never finished (crash or hang): "
                + unfinished.prefix(promptTests).joined(separator: ", ") + signal)
        }
        for crash in evidence.findings.crashes.prefix(promptFailuresPerTest) {
            lines.append("Crash: \(clipped(crash.file, maxNameLength)):\(crash.line): Fatal error: \(clipped(crash.message, promptMessageLength))")
        }
        if !evidence.sources.isEmpty {
            lines.append("Source of the failing tests:")
            for source in evidence.sources.prefix(promptSources) {
                var text = source.lines.prefix(promptSourceLines).joined(separator: "\n")
                if source.lines.count > promptSourceLines { text += "\n    // … (cut)" }
                lines.append("// \(source.path)\n" + clipped(text, promptSourceLength))
            }
        }
        lines.append("The pull request changes \(evidence.changes.count) files:")
        for change in evidence.changes.prefix(promptFiles) {
            let declarations = change.declarations
            var line = clipped(change.path, 2 * maxNameLength)
            if !declarations.isEmpty {
                line += ": " + declarations.prefix(promptDeclarationsPerFile).joined(separator: "; ")
                if declarations.count > promptDeclarationsPerFile { line += "; (+\(declarations.count - promptDeclarationsPerFile))" }
            }
            lines.append(line)
        }
        if evidence.changes.count > promptFiles { lines.append("(and \(evidence.changes.count - promptFiles) more files)") }
        let text = clipped(lines.joined(separator: "\n"), promptLength)
            .replacingOccurrences(of: "</failure>", with: "</ failure>", options: .caseInsensitive)
        return Data("<failure>\n\(text)\n</failure>".utf8)
    }

    private static func clipped(_ text: String, _ length: Int) -> String {
        text.count <= length ? text : String(text.prefix(length)) + "…"
    }

    static let fallbackFlakyReason = "The failing tests exercise code this pull request doesn’t change."
    static let reasonLength = 300

    /// The model's two lines. The verdict is its last line, which must be
    /// one of the three words and nothing else (but punctuation and
    /// Markdown around it): "REAL, not flaky" is no verdict, and no verdict
    /// is no answer. The reason is its first line, cleaned for display (it
    /// is the model's text about a log).
    @Sendable static func verdict(fromAnswer answer: String) -> Verdict? {
        let lines = answer.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let last = lines.last else { return nil }
        switch last.trimmingCharacters(in: CharacterSet.letters.inverted).uppercased() {
        case "REAL":
            return .real
        case "UNSURE":
            return .unsure
        case "FLAKY":
            let reason = lines.count > 1 ? AgentText.clean(lines[0], maxLength: reasonLength) : nil
            return .flaky(reason: reason ?? fallbackFlakyReason)
        default:
            return nil
        }
    }

    // MARK: - Sources and declarations, from the local repository

    /// The lines of `func <method>(` in a Swift source, to its closing
    /// brace (braces counted as they come: enough for a test method), 200
    /// lines at most.
    static func testBody(method: String, in source: String) -> [String]? {
        let lines = source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard let start = lines.firstIndex(where: { declaresFunction($0, named: method) }) else { return nil }
        var body: [String] = []
        var depth = 0
        var opened = false
        for line in lines[start...].prefix(200) {
            body.append(String(line))
            for character in line {
                if character == "{" {
                    depth += 1
                    opened = true
                } else if character == "}" {
                    depth -= 1
                }
            }
            if opened, depth <= 0 { break }
        }
        return body
    }

    private static func declaresFunction(_ line: Substring, named method: String) -> Bool {
        guard let found = line.range(of: "func \(method)") else { return false }
        let after = line[found.upperBound...].drop { $0 == " " }
        return after.first == "(" || after.first == "<"
    }

    /// The numbers, in the new file, of the first line of each run of
    /// changed lines in a unified diff's hunks (a removal counts at the
    /// line that follows it).
    static func changedLines(inPatch patch: String) -> [Int] {
        var result: [Int] = []
        var newLine = 0
        var inChange = false
        for line in patch.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            if line.hasPrefix("@@") {
                // "@@ -12,7 +14,9 @@ context"
                guard let plus = line.firstIndex(of: "+") else { continue }
                newLine = Int(line[line.index(after: plus)...].prefix { $0.isNumber }) ?? 0
                inChange = false
            } else if line.hasPrefix("+") || line.hasPrefix("-") {
                if !inChange { result.append(max(1, newLine)) }
                inChange = true
                if line.hasPrefix("+") { newLine += 1 }
            } else if !line.hasPrefix("\\") {
                inChange = false
                newLine += 1
            }
        }
        return result
    }

    /// The declarations a patch edits in `source` (the file at the pull
    /// request's head): for each run of changed lines, the function,
    /// property or type it sits in. Each once, in order.
    static func declarations(editedBy patch: String, in source: String) -> [String] {
        let lines = source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        var result: [String] = []
        for number in changedLines(inPatch: patch).prefix(maxChangesPerFile) {
            guard let name = enclosingDeclaration(ofLine: min(number, lines.count) - 1, in: lines), !result.contains(name)
            else { continue }
            result.append(name)
        }
        return result
    }

    /// A file's first changes are read, and a declaration is looked for
    /// this many lines up: a generated table has thousands of both, and
    /// names none.
    static let maxChangesPerFile = 100
    static let maxDeclarationWalk = 400

    /// What the line at `index` belongs to, by indentation: a line that is
    /// itself a function or a type; else the nearest function above it
    /// that is less indented (a local `let` on the way is not what
    /// changed); else, in a type's body, the property the line is or sits
    /// in, or the type.
    static func enclosingDeclaration(ofLine index: Int, in lines: [Substring]) -> String? {
        guard lines.indices.contains(index) else { return nil }
        var property: String?
        if let own = parsedDeclaration(in: lines[index]) {
            guard own.kind == .property else { return own.text }
            property = own.text
        }
        // A closing line's opener is as indented as it is: one more, so
        // that the opener counts as enclosing. A blank line takes the
        // first line above it.
        var limit = indentation(of: lines[index]).map { startsWithCloser(lines[index]) ? $0 + 1 : $0 }
        var cursor = index - 1
        var walked = 0
        while cursor >= 0, walked < maxDeclarationWalk {
            let line = lines[cursor]
            cursor -= 1
            walked += 1
            guard let indent = indentation(of: line), !isDirectiveOrComment(line), indent < limit ?? (indent + 1) else { continue }
            limit = startsWithCloser(line) ? indent + 1 : indent
            if let found = parsedDeclaration(in: line) {
                switch found.kind {
                case .function: return found.text
                case .type: return property ?? found.text
                case .property: property = found.text
                }
            }
        }
        return property
    }

    /// The count of leading spaces and tabs; nil for a blank line.
    private static func indentation(of line: Substring) -> Int? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }.count
        return indent == line.count ? nil : indent
    }

    private static func startsWithCloser(_ line: Substring) -> Bool {
        guard let first = line.first(where: { $0 != " " && $0 != "\t" }) else { return false }
        return first == "}" || first == ")" || first == "]"
    }

    /// `#if` sits at the margin whatever it is in, and a comment is in
    /// nothing.
    private static func isDirectiveOrComment(_ line: Substring) -> Bool {
        let text = line.drop { $0 == " " || $0 == "\t" }
        return text.hasPrefix("#") || text.hasPrefix("//")
    }

    private static let modifiers: Set<String> = [
        "public", "private", "fileprivate", "internal", "open", "package", "static", "final", "override", "mutating",
        "nonmutating", "nonisolated", "convenience", "required", "lazy", "weak", "unowned", "indirect", "dynamic"
    ]
    private static let typeKeywords: Set<String> = ["struct", "class", "enum", "extension", "protocol", "actor"]

    struct Declaration: Equatable {
        enum Kind { case function, property, type }
        let kind: Kind
        /// "func name", "init", "var name", "struct Name"…
        let text: String
    }

    /// The declaration's words when the line declares one, past its
    /// attributes and modifiers.
    static func declaration(in line: Substring) -> String? {
        parsedDeclaration(in: line)?.text
    }

    static func parsedDeclaration(in line: Substring) -> Declaration? {
        var words = line.prefix(2_000).split(whereSeparator: { $0 == " " || $0 == "\t" })[...]
        guard words.count <= 64 else { return nil }
        while let first = words.first {
            // "@MainActor", "@objc(name)", "private(set)".
            let bare = first.prefix { $0 != "(" }
            if first.hasPrefix("@") || modifiers.contains(String(bare)) {
                words = words.dropFirst()
            } else if first == "class", let next = words.dropFirst().first,
                      ["func", "var", "let", "subscript"].contains(next.prefix { $0 != "(" }) {
                words = words.dropFirst()
            } else {
                break
            }
        }
        guard let keyword = words.first else { return nil }
        let head = String(keyword.prefix { $0 != "(" && $0 != "<" && $0 != "{" })
        if ["init", "deinit", "subscript"].contains(head.trimmingCharacters(in: CharacterSet(charactersIn: "?!"))) {
            return Declaration(kind: .function, text: head)
        }
        guard let next = words.dropFirst().first else { return nil }
        let isNameCharacter: (Character) -> Bool = { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "`" || $0 == "." }
        let name = String(next.prefix(while: isNameCharacter).prefix(maxNameLength))
        guard !name.isEmpty else { return nil }
        switch head {
        case "func": return Declaration(kind: .function, text: "func \(name)")
        case "var", "let": return Declaration(kind: .property, text: "\(head) \(name)")
        default: return typeKeywords.contains(head) ? Declaration(kind: .type, text: "\(head) \(name)") : nil
        }
    }

    /// A name in the model's input: a job, a step, a path, a declaration.
    static let maxNameLength = 120
}
