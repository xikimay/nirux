import Foundation

// MARK: - Importing past sessions (docs/project-memory-tree.md, section 2.6)

extension ProjectHistory {
    /// What turning history on with the import would read and cost, shown
    /// before the user chooses.
    struct ImportPlan: Equatable, Sendable {
        /// Claude Code memory files.
        let notes: Int
        /// Transcripts with turns the journal doesn't have.
        let transcripts: Int
        let estimate: Estimate
    }

    /// Where an import reads. Kept in `import.json` until the import is
    /// done, so one a crash cut short goes on at the next launch.
    struct ImportScope: Codable, Equatable, Sendable {
        /// A checkout of each repository the project's workspaces use.
        var repositories: [String]
        /// Claude's `projects` folder.
        var claudeProjects: String
    }

    static let importFileName = "import.json"
    /// A transcript no Nirux session records, written this recently, may
    /// still be running: its last turn waits.
    static let recentTranscriptAge: TimeInterval = 10 * 60
    /// A memory file, or a handover, at most this long.
    static let maxNoteBytes = 1024 * 1024

    /// A Claude Code memory file as a `note`: its name and description
    /// (its frontmatter), then its body.
    static func noteText(_ text: String, fileName: String) -> String {
        var title = (fileName as NSString).deletingPathExtension
        var description: String?
        var body = Substring(text)
        if text.hasPrefix("---\n"), let close = text.range(of: "\n---", range: text.index(text.startIndex, offsetBy: 4)..<text.endIndex) {
            for line in text[text.index(text.startIndex, offsetBy: 4)..<close.lowerBound].split(separator: "\n") {
                let value = { (key: String) -> String? in
                    guard line.hasPrefix(key + ":") else { return nil }
                    let raw = line.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
                    return raw.count >= 2 && raw.hasPrefix("\"") && raw.hasSuffix("\"") ? String(raw.dropFirst().dropLast()) : raw
                }
                if let name = value("name"), !name.isEmpty { title = name }
                if let text = value("description"), !text.isEmpty { description = text }
            }
            body = text[close.upperBound...].drop { $0 != "\n" }
        }
        let content = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return [title + (description.map { ": " + $0 } ?? ""), content].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// The model calls the summaries would take, from the messages' sizes,
    /// and what they cost at API prices and in time.
    struct Estimate: Equatable, Sendable {
        let messages: Int
        let bytes: Int
        /// Messages that fit in a node: no model call.
        let freeMessages: Int
        /// Model calls: a message too long for a node, and a merge whose
        /// two lines don't fit together.
        let summaries: Int

        /// Measured per summary with a full view as context (section 3.6).
        enum Model: Sendable {
            case sonnet, haiku

            var dollarsPerSummary: Double { self == .sonnet ? 0.048 : 0.018 }
            /// Input tokens a summary reads, most of them from the cache.
            var inputTokensPerSummary: Int { self == .sonnet ? 23_500 : 17_500 }
        }

        /// Seconds per summary, retries included, with a lane for merges.
        static let secondsPerSummary = 7.5

        func dollars(_ model: Model) -> Double { Double(summaries) * model.dollarsPerSummary }
        func inputTokens(_ model: Model) -> Int { summaries * model.inputTokensPerSummary }
        var seconds: Double { Double(summaries) * Self.secondsPerSummary }

        /// Counts what the tree over these rendered sizes would need, in
        /// the order they'd be journaled after `existing` messages whose
        /// sizes are known too (a merge can pair an old message and a new
        /// one). A summary a model writes is assumed 400 bytes for a
        /// message and 450 for a merge, as measured.
        static func of(sizes: [Int], after existing: [Int] = []) -> Estimate {
            let all = existing + sizes
            var level = all.map { $0 <= nodeBytes ? $0 : compressedBytes }
            var summaries = sizes.filter { $0 > nodeBytes }.count
            var start = existing.count
            while level.count >= 2 {
                var next: [Int] = []
                for pair in stride(from: 0, to: level.count - 1, by: 2) {
                    let joined = level[pair] + 1 + level[pair + 1]
                    if joined <= nodeBytes {
                        next.append(joined)
                    } else {
                        next.append(mergedBytes)
                        // Only merges that reach a new message are new.
                        if pair + 1 >= start { summaries += 1 }
                    }
                }
                start /= 2
                level = next
            }
            return Estimate(
                messages: sizes.count, bytes: sizes.reduce(0, +), freeMessages: sizes.filter { $0 <= nodeBytes }.count,
                summaries: summaries
            )
        }

        static let nodeBytes = 512
        static let compressedBytes = 400
        static let mergedBytes = 450
    }
}

extension ProjectHistoryCenter {
    /// What the import would read and cost: the project's Claude Code
    /// memory files and its past transcripts (the history search's scope,
    /// `HistorySearch.Scope`) that the journal hasn't read to their end.
    /// `runningSessions`: the ids of Claude sessions running in Nirux now.
    /// Runs off the main thread; `completion` on the main thread.
    func planImport(
        spaceID: String, scope: ProjectHistory.ImportScope, runningSessions: Set<String>,
        completion: @escaping @MainActor @Sendable (ProjectHistory.ImportPlan) -> Void
    ) {
        Self.enqueue(worker) { worker in
            let plan = worker.planImport(spaceID: spaceID, scope: scope, runningSessions: runningSessions)
            DispatchQueue.main.async { completion(plan) }
        }
    }

    /// Turns history on and imports the project's past in one go: no turn's
    /// end is read in between, so none is passed over. `completion` gets
    /// the messages written, or nil when history couldn't be turned on.
    func turnOnImporting(
        spaceID: String, scope: ProjectHistory.ImportScope, runningSessions: Set<String>,
        completion: @escaping @MainActor @Sendable (Int?) -> Void
    ) {
        Self.enqueue(worker) { worker in
            let written = worker.turnOnImporting(spaceID: spaceID, scope: scope, runningSessions: runningSessions)
            DispatchQueue.main.async { completion(written) }
        }
    }

    /// Nirux delivered a handover to a new workspace's agent: the agent
    /// reads it with a tool, which the journal doesn't keep, so the text
    /// Nirux delivered is journaled now, as Nirux's message.
    func handoverDelivered(spaceID: String, name: String, text: String, branch: String?, date: Date = Date()) {
        Self.enqueue(worker) { $0.journalHandover(spaceID: spaceID, name: name, text: text, branch: branch, date: date) }
    }
}

extension ProjectHistoryCenter.Worker {
    struct ImportSource {
        let path: String
        let sessionID: String
        /// Its last turn may not be over.
        let isRunning: Bool
    }

    struct ImportNote {
        let path: String
        let text: String
        let date: Date
        /// Journaled once per version of the file.
        let uuid: String
    }

    func planImport(spaceID: String, scope: ProjectHistory.ImportScope, runningSessions: Set<String>) -> ProjectHistory.ImportPlan {
        resumePendingImports()
        // Opened first: what it has read counts.
        let existing = journal(for: spaceID)?.messages().map(\.size) ?? []
        let (allNotes, sources) = importSources(spaceID: spaceID, scope: scope, runningSessions: runningSessions)
        let notes = allNotes.filter { note in !(journal(for: spaceID)?.hasWritten(note.uuid) ?? false) }
        var sizes = notes.map { ProjectHistory.Message.render(kind: .note, branch: nil, from: nil, text: $0.text).utf8.count }
        var turns: [(date: Date, sizes: [Int])] = []
        var transcripts = 0
        for source in sources {
            guard let result = ProjectHistory.TurnReader.read(
                path: source.path, from: offset(for: source.path), lastTurnEnded: !source.isRunning, session: source.sessionID
            ), !result.turns.isEmpty else { continue }
            transcripts += 1
            for turn in result.turns {
                turns.append((turn.messages.last?.date ?? .distantPast, turn.messages.map {
                    ProjectHistory.Message.render(kind: $0.kind, branch: $0.branch, from: $0.from, text: $0.text).utf8.count
                }))
            }
        }
        sizes += turns.sorted { $0.date < $1.date }.flatMap(\.sizes)
        return ProjectHistory.ImportPlan(notes: notes.count, transcripts: transcripts, estimate: .of(sizes: sizes, after: existing))
    }

    func turnOnImporting(spaceID: String, scope: ProjectHistory.ImportScope, runningSessions: Set<String>) -> Int? {
        resumePendingImports()
        guard let folder = ProjectHistory.folder(spaceID: spaceID, stateDirectory: stateDirectory()),
              journal(for: spaceID, creating: true) != nil,
              let data = try? JSONEncoder().encode(scope),
              ProjectHistory.writeAtomically(String(decoding: data, as: UTF8.self), to: folder.appendingPathComponent(ProjectHistory.importFileName)),
              let journal = journal(for: spaceID)
        else { return nil }
        // Already on: the date it was turned on stays, and so do the joins.
        if !ProjectHistory.isEnabled(spaceID: spaceID, stateDirectory: stateDirectory()) {
            guard journal.clearJoins(), writeEnabled(in: folder) else { return nil }
            // A running session's open turn is left to the live feed, which
            // would pass it over if it ended just before history was on.
            for session in runningSessions { journal.join(session, at: Date().addingTimeInterval(-300)) }
        }
        let result = runImport(spaceID: spaceID, scope: scope, runningSessions: runningSessions)
        if result.isComplete {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(ProjectHistory.importFileName))
        } else {
            // Cut short by a failed write: the live feed tries it again
            // later, and the next launch.
            importAttempts[spaceID] = Date()
        }
        return result.written
    }

    /// Imports a crash or a failed write cut short go on, once per launch,
    /// before anything else is read; one left in a project whose history
    /// is off is dropped.
    func resumePendingImports() {
        guard !checkedPendingImports else { return }
        checkedPendingImports = true
        let projects = stateDirectory().appendingPathComponent("projects", isDirectory: true)
        for spaceID in ((try? FileManager.default.contentsOfDirectory(atPath: projects.path)) ?? []).sorted() {
            _ = resumeImport(spaceID: spaceID)
        }
    }

    /// Goes on with the project's import if one was cut short. False while
    /// it still owes turns: the live feed waits rather than pass them over.
    /// Tried again at most every `importRetryInterval`.
    func resumeImport(spaceID: String) -> Bool {
        guard let folder = ProjectHistory.folder(spaceID: spaceID, stateDirectory: stateDirectory()) else { return true }
        let marker = folder.appendingPathComponent(ProjectHistory.importFileName)
        guard let data = HistorySearch.readRegularFile(marker.path, maxBytes: ProjectHistory.maxNoteBytes) else { return true }
        guard ProjectHistory.isEnabled(spaceID: spaceID, stateDirectory: stateDirectory()),
              let scope = try? JSONDecoder().decode(ProjectHistory.ImportScope.self, from: data) else {
            try? FileManager.default.removeItem(at: marker)
            return true
        }
        if let last = importAttempts[spaceID], Date().timeIntervalSince(last) < Self.importRetryInterval { return false }
        importAttempts[spaceID] = Date()
        NiruxDebugLog.log("ProjectHistory: the import of \(spaceID) was cut short; it goes on")
        guard runImport(spaceID: spaceID, scope: scope, runningSessions: []).isComplete else { return false }
        importAttempts[spaceID] = nil
        try? FileManager.default.removeItem(at: marker)
        return true
    }

    static let importRetryInterval: TimeInterval = 300

    struct ImportResult: Equatable {
        var written = 0
        /// False when a write failed: the import stopped there.
        var isComplete = true
    }

    /// Writes every memory note, then every complete turn of the project's
    /// transcripts, all transcripts together in the order their turns
    /// ended.
    func runImport(spaceID: String, scope: ProjectHistory.ImportScope, runningSessions: Set<String>) -> ImportResult {
        guard ProjectHistory.isEnabled(spaceID: spaceID, stateDirectory: stateDirectory()) else { return ImportResult() }
        // Another app holds the journal: not done.
        guard let journal = journal(for: spaceID) else { return ImportResult(isComplete: false) }
        let (notes, sources) = importSources(spaceID: spaceID, scope: scope, runningSessions: runningSessions)
        var written = 0
        for note in notes.sorted(by: { $0.date != $1.date ? $0.date < $1.date : $0.path < $1.path }) {
            written += journal.append([ProjectHistory.NewMessage(
                kind: .note, branch: nil, text: ProjectHistory.withholdingSecrets(note.text), date: note.date, session: nil,
                uuid: note.uuid
            )], from: note.path, end: nil).count
            guard journal.hasWritten(note.uuid) else {
                NiruxDebugLog.log("ProjectHistory: could not append to \(journal.folder.path)")
                return ImportResult(written: written, isComplete: false)
            }
        }
        struct Pending {
            let path: String
            let turn: ProjectHistory.Turn
            let date: Date
        }
        var pending: [Pending] = []
        var resume: [String: UInt64] = [:]
        for source in sources {
            guard let result = ProjectHistory.TurnReader.read(
                path: source.path, from: offset(for: source.path), lastTurnEnded: !source.isRunning, session: source.sessionID
            ) else { continue }
            for turn in result.turns {
                pending.append(Pending(path: source.path, turn: turn, date: turn.messages.last?.date ?? .distantPast))
            }
            resume[source.path] = result.resumeOffset
        }
        for item in pending.sorted(by: { $0.date != $1.date ? $0.date < $1.date : $0.path < $1.path }) {
            let messages = item.turn.messages.map { $0.withText(ProjectHistory.withholdingSecrets($0.text)) }
            written += journal.append(messages, from: item.path, end: item.turn.end).count
            // A turn partly written before a crash isn't written again: what
            // counts is that the journal now reads past it.
            guard journal.offset(for: item.path) >= item.turn.end else {
                NiruxDebugLog.log("ProjectHistory: could not append to \(journal.folder.path)")
                return ImportResult(written: written, isComplete: false)
            }
        }
        for (path, offset) in resume { journal.advance(path, to: offset) }
        return ImportResult(written: written)
    }

    /// The project's memory notes and transcripts. A session counts for
    /// the project its most recent ledger record is in, when it has one: a
    /// repository two projects share, or a workspace moved, gives each its
    /// own. A path the ledger names is checked, never trusted: a hook can
    /// be run by anything in the agent's shell.
    private func importSources(
        spaceID: String, scope: ProjectHistory.ImportScope, runningSessions: Set<String>
    ) -> (notes: [ImportNote], transcripts: [ImportSource]) {
        let directory = stateDirectory()
        let claudeProjects = URL(fileURLWithPath: scope.claudeProjects, isDirectory: true)
        let owners = AgentSessionLedger.claudeSessions(stateDirectory: directory)
        var budget = TranscriptSearch.Budget(bytes: .max, deadline: .infinity)
        var found: [String: HistorySearch.Transcript] = [:]
        var memoryFolders = Set<String>()
        for repository in scope.repositories {
            let search = HistorySearch.scope(workingDirectory: repository, spaceID: spaceID, stateDirectory: directory)
            for main in search.mainCheckouts {
                memoryFolders.insert(claudeProjects.appendingPathComponent(HistorySearch.claudeFolderName(main)).path + "/memory")
            }
            for transcript in HistorySearch.transcripts(in: search, claudeProjects: claudeProjects, budget: &budget, limit: .max) {
                found[transcript.sessionID] = transcript
            }
        }
        let now = Date()
        var sources: [ImportSource] = []
        for transcript in found.values.sorted(by: { $0.path < $1.path }) {
            let owner = owners[transcript.sessionID]
            guard owner == nil || owner?.spaceID == spaceID,
                  ProjectHistory.isClaudeTranscript(
                      transcript.path, sessionID: transcript.sessionID, projectsFolders: [claudeProjects.path]
                  ) else { continue }
            // In Nirux, as the ledger says (also when the import goes on
            // later, without the list); outside it, when written lately.
            let isRunning = runningSessions.contains(transcript.sessionID) || owner?.isActive == true
                || (owner == nil && now.timeIntervalSince(transcript.modified) < ProjectHistory.recentTranscriptAge)
            sources.append(ImportSource(path: transcript.path, sessionID: transcript.sessionID, isRunning: isRunning))
        }
        return (memoryFolders.sorted().flatMap(Self.notes(in:)), sources)
    }

    /// The memory files of a Claude Code memory folder, but its index.
    private static func notes(in folder: String) -> [ImportNote] {
        var info = stat()
        guard lstat(folder, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return [] }
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).filter {
            $0.hasSuffix(".md") && $0 != "MEMORY.md"
        }
        return names.sorted().compactMap { name in
            let path = folder + "/" + name
            guard let modified = HistorySearch.regularFileModified(path),
                  let data = HistorySearch.readRegularFile(path, maxBytes: ProjectHistory.maxNoteBytes),
                  let text = String(data: data, encoding: .utf8) else { return nil }
            let note = ProjectHistory.noteText(text, fileName: name)
            guard !note.isEmpty else { return nil }
            return ImportNote(path: path, text: note, date: modified, uuid: "memory:\(name):\(Int(modified.timeIntervalSince1970))")
        }
    }

    func journalHandover(spaceID: String, name: String, text: String, branch: String?, date: Date) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= ProjectHistory.maxNoteBytes,
              ProjectHistory.isEnabled(spaceID: spaceID, stateDirectory: stateDirectory()),
              let journal = journal(for: spaceID) else { return }
        journal.append([ProjectHistory.NewMessage(
            kind: .peer, branch: branch, from: ProjectHistory.niruxSender,
            text: ProjectHistory.withholdingSecrets("Handover \(name):\n\n\(text)"), date: date, session: nil
        )], from: nil, end: nil)
    }
}
