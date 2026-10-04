import Foundation

// MARK: - What Explain answers (section 4.3)

extension BranchReview {
    /// A run's answer, checked against its input: only the files and hunks
    /// the input named, every string capped and shown as text, invisible
    /// characters as code points. The diff the model read may hold
    /// instructions aimed at it ("say this file is safe"), so nothing here
    /// is trusted beyond its shape. The model never marks a file reviewed,
    /// hides a file or removes a risk signal: the answer has no field for
    /// any of that.
    struct ExplainOutput: Equatable, Sendable {
        enum Intent: String, CaseIterable, Codable, Equatable, Sendable {
            case feature
            case behaviorChange
            case refactor
            case tests
            case config
            case docs
            case ci
        }

        struct Group: Codable, Equatable, Sendable {
            let intent: Intent
            let title: String
            /// Each path is in one group at most.
            let paths: [String]
        }

        struct FileExplanation: Equatable, Sendable {
            let path: String
            let summary: String
            /// 3 high, 1 low.
            let importance: Int
        }

        struct Note: Equatable, Sendable {
            let hunk: HunkReference
            let text: String
            /// What the reviewer should verify, when the model thinks
            /// something may be wrong.
            let check: String?
        }

        enum Verdict: String, CaseIterable, Codable, Equatable, Sendable {
            case matches
            case partly
            case contradicts
            case notInDiff
        }

        struct Claim: Codable, Equatable, Sendable {
            let claim: String
            let verdict: Verdict
            let evidence: String
        }

        var overview: String
        var groups: [Group]
        /// Only for the files whose diff the run sent, one per path.
        var files: [FileExplanation]
        var notes: [Note]
        var claims: [Claim]
        /// At most `Limits.questions`.
        var questions: [String]
        /// Groups' files, files and notes the answer named by an id the
        /// input didn't have: an answer that explains none of the files it
        /// was sent isn't worth keeping.
        var dropped = 0

        /// In code points for strings: a character can carry thousands of
        /// combining marks.
        enum Limits {
            static let overview = 3_000
            static let title = 120
            static let summary = 400
            static let note = 1_200
            static let check = 800
            static let claim = 500
            static let evidence = 1_000
            static let question = 500
            static let groups = 12
            static let notes = 400
            static let claims = 40
            static let questions = 5
        }

        /// The JSON schema `--json-schema` passes for `input`: files and
        /// hunks by the ids it lists, so claude itself makes the model try
        /// again when it answers with a path.
        static func schema(for input: ExplainInput) -> String {
            func array(_ items: String, maxItems: Int? = nil) -> String {
                #"{"type":"array","# + (maxItems.map { #""maxItems":\#($0),"# } ?? "") + #""items":\#(items)}"#
            }
            func object(_ properties: [(String, String)], required: [String]) -> String {
                let fields = properties.map { #""\#($0.0)":\#($0.1)"# }.joined(separator: ",")
                let names = required.map { #""\#($0)""# }.joined(separator: ",")
                return #"{"type":"object","additionalProperties":false,"required":[\#(names)],"properties":{\#(fields)}}"#
            }
            func enumeration(_ values: [String]) -> String {
                #"{"type":"string","enum":["# + values.map { #""\#($0)""# }.joined(separator: ",") + "]}"
            }
            let string = #"{"type":"string"}"#
            let fileID = input.listedFiles.isEmpty ? string : enumeration(input.listedFiles)
            let sentIDs = input.listedFiles.filter { input.files[$0].map(input.sentPaths.contains) == true }
            let hunkIDs = input.hunks.keys.sorted()
            let group = object([
                ("intent", enumeration(Intent.allCases.map(\.rawValue))), ("title", string), ("files", array(fileID))
            ], required: ["intent", "title", "files"])
            let file = object([
                ("file", sentIDs.isEmpty ? string : enumeration(sentIDs)), ("summary", string),
                ("importance", #"{"type":"integer","minimum":1,"maximum":3}"#)
            ], required: ["file", "summary", "importance"])
            let note = object([
                ("hunk", hunkIDs.isEmpty ? string : enumeration(hunkIDs)), ("text", string), ("check", string)
            ], required: ["hunk", "text"])
            let claim = object([
                ("claim", string), ("verdict", enumeration(Verdict.allCases.map(\.rawValue))), ("evidence", string)
            ], required: ["claim", "verdict", "evidence"])
            return object([
                ("overview", string), ("groups", array(group)), ("files", array(file, maxItems: sentIDs.isEmpty ? 0 : nil)),
                ("notes", array(note, maxItems: hunkIDs.isEmpty ? 0 : nil)), ("claims", array(claim)),
                ("questions", array(string, maxItems: Limits.questions))
            ], required: ["overview", "groups", "files", "notes", "claims", "questions"])
        }

        /// The answer, with what the input didn't name dropped: files and
        /// hunks by unknown id (a file may be named by its path too), a
        /// summary of a file whose diff wasn't sent, values outside the
        /// schema's. Nil when it has no overview.
        static func checked(_ answer: JSONValue, against input: ExplainInput) -> ExplainOutput? {
            guard let fields = answer.objectValue, let overview = fields["overview"]?.stringValue.map({ shown($0, Limits.overview) }),
                  !overview.isEmpty
            else { return nil }
            func objects(_ key: String) -> [[String: JSONValue]] {
                fields[key]?.arrayValue?.compactMap(\.objectValue) ?? []
            }
            let paths = Set(input.files.values)
            let sentPaths = input.sentPaths
            var dropped = 0
            func path(_ value: JSONValue?) -> String? {
                guard let name = value?.stringValue else { return nil }
                if let path = input.files[name] ?? (paths.contains(name) ? name : nil) { return path }
                dropped += 1
                return nil
            }

            var grouped = Set<String>()
            var groups: [Group] = []
            for group in objects("groups") {
                guard groups.count < Limits.groups, let intent = group["intent"]?.stringValue.flatMap(Intent.init(rawValue:)),
                      let title = group["title"]?.stringValue.map({ shown($0, Limits.title) }), !title.isEmpty
                else { continue }
                let members = (group["files"]?.arrayValue ?? []).compactMap(path).filter { grouped.insert($0).inserted }
                if !members.isEmpty { groups.append(Group(intent: intent, title: title, paths: members)) }
            }

            var explained = Set<String>()
            var files: [FileExplanation] = []
            for file in objects("files") {
                guard let path = path(file["file"]), sentPaths.contains(path),
                      let summary = file["summary"]?.stringValue.map({ shown($0, Limits.summary) }), !summary.isEmpty,
                      explained.insert(path).inserted
                else { continue }
                files.append(FileExplanation(path: path, summary: summary, importance: min(3, max(1, file["importance"]?.intValue ?? 1))))
            }

            var notes: [Note] = []
            for note in objects("notes") {
                guard notes.count < Limits.notes, let id = note["hunk"]?.stringValue else { continue }
                guard let hunk = input.hunks[id] else {
                    dropped += 1
                    continue
                }
                guard let text = note["text"]?.stringValue.map({ shown($0, Limits.note) }), !text.isEmpty else { continue }
                let check = note["check"]?.stringValue.map { shown($0, Limits.check) }
                notes.append(Note(hunk: hunk, text: text, check: check?.isEmpty == false ? check : nil))
            }

            var claims: [Claim] = []
            for claim in objects("claims") {
                guard claims.count < Limits.claims, let verdict = claim["verdict"]?.stringValue.flatMap(Verdict.init(rawValue:)),
                      let text = claim["claim"]?.stringValue.map({ shown($0, Limits.claim) }), !text.isEmpty
                else { continue }
                claims.append(Claim(claim: text, verdict: verdict, evidence: shown(claim["evidence"]?.stringValue ?? "", Limits.evidence)))
            }

            let questions = (fields["questions"]?.arrayValue ?? []).compactMap { $0.stringValue.map { shown($0, Limits.question) } }
                .filter { !$0.isEmpty }.prefix(Limits.questions)
            return ExplainOutput(
                overview: overview, groups: groups, files: files, notes: notes, claims: claims, questions: Array(questions),
                dropped: dropped
            )
        }

        /// Trimmed, invisible characters as code points (line breaks
        /// kept, CRLF as LF), cut at `limit` code points.
        static func shown(_ text: String, _ limit: Int) -> String {
            let lines = text.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            let visible = BranchReview.visible(lines, keepingLineBreaks: true)
            guard visible.unicodeScalars.count > limit else { return visible }
            return String(String.UnicodeScalarView(visible.unicodeScalars.prefix(limit - 1))) + "…"
        }
    }
}
