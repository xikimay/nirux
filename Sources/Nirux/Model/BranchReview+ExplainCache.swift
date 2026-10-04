import Foundation

// MARK: - Explain's cache (sections 4.3 and 8)

extension BranchReview {
    /// What Explain found for a branch, kept in its review file under one
    /// top-level key, `explain`: the overview, groups, claims and questions
    /// of the last explanation, with the head and model it read; per file,
    /// its summary and notes, keyed by the patch hash they explain, with the
    /// head and model that explained it; each run's usage; and how many
    /// notes were kept and marked wrong. Notes are stored by their hunk's
    /// index in the file's patch and the hunk's anchor (`hunkAnchor`), not by
    /// a run's hunk ids (`f3h1`), which live for one run only.
    ///
    /// Decoding is lenient: a missing field takes its default, and a group,
    /// claim, note or run this build can't read is skipped, so a later
    /// build's fields don't cost a full paid run. A newer `version` reads as
    /// unreadable, and is never written over.
    struct Explanation: Codable, Equatable, Sendable {
        static let currentVersion = 1

        struct FileEntry: Codable, Equatable, Sendable {
            /// The patch the summary and notes explain: a file whose patch
            /// changed is explained again.
            var patchHash: String
            var summary: String?
            var importance: Int?
            var notes: [NoteEntry] = []
            /// The head and model that explained it, and when.
            var head: String?
            var model: String?
            var date: Date?
            /// Why its diff at this patch wasn't sent, when it can't be (too
            /// large for one run): seen, so it isn't pending.
            var notSent: String?

            init(
                patchHash: String, summary: String?, importance: Int?, notes: [NoteEntry] = [], head: String? = nil,
                model: String? = nil, date: Date? = nil, notSent: String? = nil
            ) {
                self.patchHash = patchHash
                self.summary = summary
                self.importance = importance
                self.notes = notes
                self.head = head
                self.model = model
                self.date = date
                self.notSent = notSent
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                patchHash = try container.decode(String.self, forKey: .patchHash)
                summary = try? container.decodeIfPresent(String.self, forKey: .summary)
                importance = try? container.decodeIfPresent(Int.self, forKey: .importance)
                notes = Lossy.array(container, .notes)
                head = try? container.decodeIfPresent(String.self, forKey: .head)
                model = try? container.decodeIfPresent(String.self, forKey: .model)
                date = try? container.decodeIfPresent(Date.self, forKey: .date)
                notSent = try? container.decodeIfPresent(String.self, forKey: .notSent)
            }
        }

        struct NoteEntry: Codable, Equatable, Sendable {
            /// Stays with the note: R3c marks it wrong by it, R4 turns it into
            /// a comment by it.
            var id: String
            /// The hunk's index in the file's patch, and its anchor: the page
            /// places the note under the hunk whose anchor matches, and hides
            /// it when none does.
            var hunk: Int
            var anchor: String?
            var text: String
            var check: String?
            /// The user marked it wrong (R3c).
            var isWrong = false

            init(id: String = UUID().uuidString, hunk: Int, anchor: String?, text: String, check: String?, isWrong: Bool = false) {
                self.id = id
                self.hunk = hunk
                self.anchor = anchor
                self.text = text
                self.check = check
                self.isWrong = isWrong
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
                hunk = try container.decode(Int.self, forKey: .hunk)
                anchor = try? container.decodeIfPresent(String.self, forKey: .anchor)
                text = try container.decode(String.self, forKey: .text)
                check = try? container.decodeIfPresent(String.self, forKey: .check)
                isWrong = (try? container.decodeIfPresent(Bool.self, forKey: .isWrong)) ?? false
            }
        }

        struct RunEntry: Codable, Equatable, Sendable {
            var id = UUID().uuidString
            var date: Date
            var head: String
            var model: String
            var effort: String
            /// "explained", "usageLimit", "cancelled", "timedOut", "failed".
            var outcome: String
            var inputTokens: Int
            var cacheReadTokens: Int
            var cacheCreationTokens: Int
            var outputTokens: Int
            var costUSD: Double?
            /// The run ended: its cost is the whole run's.
            var isComplete: Bool
            var duration: TimeInterval
            /// The files whose diff it sent.
            var files: Int
        }

        /// Runs past this many, the oldest are dropped.
        static let maxRuns = 200

        var version = currentVersion
        /// The head and model the overview was written at.
        var head = ""
        var model = ""
        var date = Date(timeIntervalSince1970: 0)
        var overview = ""
        var groups: [ExplainOutput.Group] = []
        var claims: [ExplainOutput.Claim] = []
        var questions: [String] = []
        /// By path.
        var files: [String: FileEntry] = [:]
        var runs: [RunEntry] = []
        /// Notes kept, and notes the user marked wrong, since the first
        /// Explain: how often notes were wrong, whatever entries were
        /// replaced since.
        var noteCount = 0
        var wrongCount = 0

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
            head = (try? container.decodeIfPresent(String.self, forKey: .head)) ?? ""
            model = (try? container.decodeIfPresent(String.self, forKey: .model)) ?? ""
            date = (try? container.decodeIfPresent(Date.self, forKey: .date)) ?? Date(timeIntervalSince1970: 0)
            overview = (try? container.decodeIfPresent(String.self, forKey: .overview)) ?? ""
            groups = Lossy.array(container, .groups)
            claims = Lossy.array(container, .claims)
            questions = (try? container.decodeIfPresent([String].self, forKey: .questions)) ?? []
            files = ((try? container.decodeIfPresent([String: Lossy<FileEntry>].self, forKey: .files)) ?? [:])
                .compactMapValues(\.value)
            runs = Lossy.array(container, .runs)
            noteCount = (try? container.decodeIfPresent(Int.self, forKey: .noteCount)) ?? 0
            wrongCount = (try? container.decodeIfPresent(Int.self, forKey: .wrongCount)) ?? 0
        }

        var hasOverview: Bool { !overview.isEmpty }

        var context: ExplainContext {
            ExplainContext(overview: overview, claims: claims, questions: questions)
        }

        /// The files of `snapshot` Explain would send whose entry isn't at
        /// their current patch: none means up to date. Files Explain never
        /// sends (folded, binary, secret, not read, too large, untracked
        /// unless included) never count. Nil when no file was explained or
        /// seen yet.
        func pathsToExplain(in snapshot: Snapshot, includeUntracked: Bool) -> Set<String>? {
            guard hasOverview || !files.isEmpty else { return nil }
            var request = ExplainRequest()
            request.includeUntracked = includeUntracked
            return Set(snapshot.files.filter { file in
                guard explainSkipReason(file, request: request) == nil, let hash = file.patchHash else { return false }
                return files[file.path]?.patchHash != hash
            }.map(\.path))
        }

        /// Without the files no longer in the branch.
        func pruned(to branchFiles: Set<String>) -> Explanation {
            var pruned = self
            pruned.files = files.filter { branchFiles.contains($0.key) }
            pruned.groups = groups.compactMap { group in
                let paths = group.paths.filter(branchFiles.contains)
                return paths.isEmpty ? nil : ExplainOutput.Group(intent: group.intent, title: group.title, paths: paths)
            }
            return pruned
        }

        /// The runs of the day `date` falls in: tokens and cost, and
        /// whether a stopped run's cost is missing ("at least").
        func usage(on date: Date, calendar: Calendar = .current) -> (tokens: Int, costUSD: Double, isComplete: Bool) {
            let today = runs.filter { calendar.isDate($0.date, inSameDayAs: date) }
            return (
                today.reduce(0) { $0 + $1.inputTokens + $1.cacheReadTokens + $1.cacheCreationTokens + $1.outputTokens },
                today.reduce(0) { $0 + ($1.costUSD ?? 0) },
                today.allSatisfy(\.isComplete)
            )
        }

        /// `delta` applied onto this explanation as the review file holds
        /// it now: the files the job explained replace theirs (a note marked
        /// wrong meanwhile keeps its mark, by id), files no longer in the
        /// branch go, the job's groups come first and the files they don't
        /// place stay in their groups, the job's overview, claims and
        /// questions replace the last ones (the model saw them and answered
        /// for the whole branch), and the job's runs are added once.
        mutating func apply(_ delta: ExplainDelta, branchFiles: Set<String>) {
            for (path, entry) in delta.files {
                // A file seen too large this time, explained at the same
                // patch before (the diff's text holds more than the hash):
                // its explanation stays.
                if entry.notSent != nil, let current = files[path], current.patchHash == entry.patchHash,
                   current.summary != nil || !current.notes.isEmpty {
                    continue
                }
                var entry = entry
                let marked = Set(files[path]?.notes.filter(\.isWrong).map(\.id) ?? [])
                for index in entry.notes.indices where marked.contains(entry.notes[index].id) { entry.notes[index].isWrong = true }
                files[path] = entry
            }
            if let summary = delta.summary {
                var placed = Set(summary.groups.flatMap(\.paths))
                var merged = summary.groups
                for group in groups {
                    let kept = group.paths.filter { placed.insert($0).inserted }
                    guard !kept.isEmpty else { continue }
                    if let index = merged.firstIndex(where: { $0.intent == group.intent && $0.title == group.title }) {
                        merged[index] = ExplainOutput.Group(intent: group.intent, title: group.title, paths: merged[index].paths + kept)
                    } else {
                        merged.append(ExplainOutput.Group(intent: group.intent, title: group.title, paths: kept))
                    }
                }
                groups = merged
                overview = summary.overview
                claims = summary.claims
                questions = summary.questions
                head = summary.head
                model = summary.model
                date = summary.date
            }
            let known = Set(runs.map(\.id))
            runs += delta.runs.filter { !known.contains($0.id) }
            if runs.count > Self.maxRuns { runs.removeFirst(runs.count - Self.maxRuns) }
            noteCount += delta.notes - delta.savedNotes
            self = pruned(to: branchFiles)
            version = Self.currentVersion
        }
    }

    /// What one Explain job found, to apply onto the review file's cache
    /// as it is at each save.
    struct ExplainDelta: Equatable, Sendable {
        struct Summary: Equatable, Sendable {
            var overview: String
            var groups: [ExplainOutput.Group]
            var claims: [ExplainOutput.Claim]
            var questions: [String]
            var head: String
            var model: String
            var date: Date
        }

        var files: [String: Explanation.FileEntry] = [:]
        var summary: Summary?
        var runs: [Explanation.RunEntry] = []
        /// Notes kept by the job, and those already counted by a save.
        var notes = 0
        var savedNotes = 0

        /// A part's answer: its files' entries at the patches it sent; a
        /// file it sent but neither summarized nor noted stays out, so the
        /// next Explain sends it again rather than keep it blank.
        mutating func add(_ output: ExplainOutput, input: ExplainInput, head: String, model: String, date: Date) {
            for (path, patchHash) in input.sentPatches {
                let explained = output.files.first { $0.path == path }
                let notes = output.notes.filter { $0.hunk.path == path }
                    .map { Explanation.NoteEntry(hunk: $0.hunk.index, anchor: $0.hunk.anchor, text: $0.text, check: $0.check) }
                guard explained != nil || !notes.isEmpty else { continue }
                files[path] = Explanation.FileEntry(
                    patchHash: patchHash, summary: explained?.summary, importance: explained?.importance, notes: notes,
                    head: head, model: model, date: date
                )
                self.notes += notes.count
            }
            summary = Summary(
                overview: output.overview, groups: output.groups, claims: output.claims, questions: output.questions,
                head: head, model: model, date: date
            )
        }

        /// A file whose diff can't be sent at this patch (too large for one
        /// run): seen, so the next Explain doesn't count it as pending.
        mutating func skip(_ file: FileChange, because reason: NotSent, head: String, date: Date) {
            guard let patchHash = file.patchHash else { return }
            files[file.path] = Explanation.FileEntry(
                patchHash: patchHash, summary: nil, importance: nil, head: head, date: date, notSent: reason.label
            )
        }

        mutating func record(_ run: ExplainRun, input: ExplainInput, head: String, settings: ExplainSettings, date: Date) {
            let outcome: String
            switch run.outcome {
            case .explained: outcome = "explained"
            case .usageLimit: outcome = "usageLimit"
            case .cancelled: outcome = "cancelled"
            case .timedOut: outcome = "timedOut"
            case .failed: outcome = "failed"
            }
            runs.append(Explanation.RunEntry(
                date: date, head: head, model: run.models.first ?? settings.model, effort: settings.effort, outcome: outcome,
                inputTokens: run.usage.inputTokens, cacheReadTokens: run.usage.cacheReadTokens,
                cacheCreationTokens: run.usage.cacheCreationTokens, outputTokens: run.usage.outputTokens,
                costUSD: run.usage.costUSD, isComplete: run.usage.isComplete, duration: run.usage.duration,
                files: input.sentPatches.count
            ))
        }
    }
}

/// An element decoded if it can be, skipped if not.
private struct Lossy<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }

    static func array<Key: CodingKey>(_ container: KeyedDecodingContainer<Key>, _ key: Key) -> [Value] {
        ((try? container.decodeIfPresent([Lossy<Value>].self, forKey: key)) ?? []).compactMap(\.value)
    }
}

extension BranchReview.Record {
    enum ExplanationState: Equatable, Sendable {
        case none
        case readable(BranchReview.Explanation)
        /// Not an explanation this build reads: saved by a newer Nirux, or
        /// broken. Never written over.
        case unreadable
    }

    var explanationState: ExplanationState {
        guard let value = fields["explain"] else { return .none }
        guard let data = try? JSONEncoder().encode(value) else { return .unreadable }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let explanation = try? decoder.decode(BranchReview.Explanation.self, from: data),
              explanation.version <= BranchReview.Explanation.currentVersion
        else { return .unreadable }
        return .readable(explanation)
    }

    /// Explain's cache, when there is one this build reads.
    var explanation: BranchReview.Explanation? {
        if case .readable(let explanation) = explanationState { return explanation }
        return nil
    }

    /// False when it couldn't be encoded: the field stays as it was.
    @discardableResult
    mutating func setExplanation(_ explanation: BranchReview.Explanation) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(explanation),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return false }
        fields["explain"] = value
        return true
    }
}
