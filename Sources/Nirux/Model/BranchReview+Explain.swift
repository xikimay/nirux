import Foundation

// MARK: - Explain, from click to cache (section 4.3)

extension BranchReview {
    /// One Explain of a branch: what to read, how, and where to keep it.
    struct ExplainJob: Sendable {
        let snapshot: Snapshot
        let handover: Handover?
        let cli: ClaudeCLI
        var includeUntracked = false
        /// Explains every file again, without the cached explanation as
        /// context: a fresh look. The runs' usage and the notes' counts stay.
        var fresh = false
        var settings = ExplainSettings()
        /// False once the user accepted an account billed per call.
        var requiresSubscription = true
        var options = Options()
        var stateDirectory = Persistence.stateDirectory
        var copyParent = FileManager.default.temporaryDirectory
        /// Past this, the cache isn't written: the review file holds the
        /// comments and marks too, and stops being writable at 8 MB.
        var maxCacheBytes = 2_000_000

        init(snapshot: Snapshot, handover: Handover?, cli: ClaudeCLI) {
            self.snapshot = snapshot
            self.handover = handover
            self.cli = cli
        }
    }

    struct ExplainJobProgress: Equatable, Sendable {
        var part = 1
        var parts = 1
        var run = ExplainProgress()
    }

    struct ExplainResult: Equatable, Sendable {
        enum Ending: Equatable, Sendable {
            case explained
            /// Every file Explain sends is explained at its current patch.
            case upToDate
            /// No diff is left to send (only folded or untracked files).
            case nothingToSend
            /// The explanation couldn't be kept: read-only or unreadable
            /// review, deleted or moved on meanwhile, too large. Before a
            /// run when it can tell, so nothing is paid for in vain.
            case cantKeep(String)
            case couldNotCopy
            /// A run didn't explain its part: the parts before it stay
            /// cached, and the next Explain sends the rest.
            case stopped(ExplainRun.Outcome)
        }

        var ending: Ending
        /// What the page shows: the cache as it is now, files no longer in
        /// the branch left out.
        var explanation: Explanation?
        var runs: [ExplainRun] = []
    }

    /// Explains `job.snapshot`: only the files whose patch changed since
    /// the cached explanation, with what it found as context, or every
    /// file. A large branch goes in parts, one run each, in order; a later
    /// part gets what the earlier ones found. Each part's answer is merged
    /// into the review file as it is then, and every run's usage is kept.
    /// Leftover copies are swept first, and the copy is removed after.
    /// Runs git and claude: call it off the main thread, through
    /// `ExplainQueue`.
    static func explain(
        _ job: ExplainJob,
        cancellation: BoundedProcess.Cancellation? = nil,
        progress: (@Sendable (ExplainJobProgress) -> Void)? = nil
    ) -> ExplainResult {
        let snapshot = job.snapshot
        let branchFiles = Set(snapshot.files.map(\.path))
        var cache = ExplainCacheWriter(job: job)
        let cached = job.fresh ? nil : cache.explanation
        let only = cached?.pathsToExplain(in: snapshot, includeUntracked: job.includeUntracked)
        if let only, only.isEmpty { return ExplainResult(ending: .upToDate, explanation: cached?.pruned(to: branchFiles)) }
        // Found out before any run: nothing is paid for that can't be kept.
        if let problem = cache.problem {
            return ExplainResult(ending: .cantKeep(problem), explanation: cache.explanation?.pruned(to: branchFiles))
        }

        ExplainCopy.sweep(in: job.copyParent)
        guard let copy = ExplainCopy.make(
            for: snapshot, includeUntracked: job.includeUntracked, options: job.options, in: job.copyParent,
            cancellation: cancellation
        ) else {
            let cancelled = cancellation?.isCancelled == true
            return ExplainResult(
                ending: cancelled ? .stopped(.cancelled) : .couldNotCopy, explanation: cache.explanation?.pruned(to: branchFiles)
            )
        }
        defer { ExplainCopy.remove(copy) }

        var request = ExplainRequest()
        request.includeUntracked = job.includeUntracked
        request.only = only
        request.previous = only != nil && cached?.hasOverview == true ? cached?.context : nil
        var delta = ExplainDelta()
        let inputs = explainInputs(
            for: snapshot, handover: job.handover, request: request, notInCopy: copy.leftOut,
            onNotSent: { file, reason in
                if reason == .overRunSize { delta.skip(file, because: reason, head: snapshot.head, date: Date()) }
            }
        ) { file in
            // Reading thousands of diffs takes minutes: Cancel stops it.
            cancellation?.isCancelled == true ? nil : filePatch(file, in: snapshot, options: job.options)
        }
        if cancellation?.isCancelled == true {
            return ExplainResult(ending: .stopped(.cancelled), explanation: cache.explanation?.pruned(to: branchFiles))
        }
        guard !inputs.isEmpty else {
            if !delta.files.isEmpty, !cache.save(&delta, branchFiles: branchFiles) {
                return ExplainResult(ending: .cantKeep(cache.problem ?? ""), explanation: cache.explanation?.pruned(to: branchFiles))
            }
            return ExplainResult(ending: only == nil ? .nothingToSend : .upToDate, explanation: cache.explanation?.pruned(to: branchFiles))
        }

        var context: ExplainContext?
        var runs: [ExplainRun] = []
        func ending(_ ending: ExplainResult.Ending) -> ExplainResult {
            ExplainResult(ending: ending, explanation: cache.explanation?.pruned(to: branchFiles), runs: runs)
        }
        for (index, part) in inputs.enumerated() {
            let input = context.map(part.addingEarlierParts) ?? part
            let run = runExplain(
                input, in: copy.folder, cli: job.cli, settings: job.settings, requiresSubscription: job.requiresSubscription,
                cancellation: cancellation
            ) { runProgress in
                progress?(ExplainJobProgress(part: index + 1, parts: inputs.count, run: runProgress))
            }
            runs.append(run)
            delta.record(run, input: input, head: snapshot.head, settings: job.settings, date: Date())
            guard case .explained(let output) = run.outcome else {
                cache.save(&delta, branchFiles: branchFiles)
                return ending(.stopped(run.outcome))
            }
            // Answered with ids the input didn't have, and nothing else: not
            // worth keeping as "Claude flagged nothing".
            guard !(output.files.isEmpty && output.notes.isEmpty && output.dropped > 0) else {
                cache.save(&delta, branchFiles: branchFiles)
                return ending(.stopped(.failed(.unreadableAnswer)))
            }
            delta.add(output, input: input, head: snapshot.head, model: run.models.first ?? job.settings.model, date: Date())
            context = ExplainContext(overview: output.overview, claims: output.claims, questions: output.questions)
            // A part that can't be kept stops the rest: they would be paid
            // for in vain.
            guard cache.save(&delta, branchFiles: branchFiles) else { return ending(.cantKeep(cache.problem ?? "")) }
        }
        return ending(.explained)
    }
}

/// The review file the cache goes to. Each save applies the job's
/// findings onto the cache as the file holds it then (marks made meanwhile,
/// another Nirux's runs), under the file's lock, without recording a head or
/// a pull request: opening records the job's, only while its head is the
/// review's newest, and a review the job creates records them once. After
/// that, the page may open the review at a later head of the branch (the
/// agent committed meanwhile, or the job waited in line), or at the job's
/// again: the cache is written at whichever, since its entries are keyed by
/// patch hash and hold there too. A review deleted meanwhile (Clean Up),
/// archived, or on another history, isn't written, nor created again.
private struct ExplainCacheWriter {
    private enum Mode {
        /// No review yet: the first write creates it, at the job's head.
        case creating(BranchReview.Store.Access)
        /// The review is at the job's head or a later one: writes keep it.
        case keepingHead(String)
        case closed
    }

    private let store: BranchReview.Store?
    private let snapshot: BranchReview.Snapshot
    private let options: BranchReview.Options
    private let maxBytes: Int
    private var mode = Mode.closed
    private(set) var explanation: BranchReview.Explanation?
    private(set) var problem: String?

    init(job: BranchReview.ExplainJob) {
        snapshot = job.snapshot
        options = job.options
        maxBytes = job.maxCacheBytes
        store = BranchReview.repositoryIdentity(root: job.snapshot.root, options: job.options).flatMap {
            BranchReview.Store(repository: $0, branch: job.snapshot.branch, stateDirectory: job.stateDirectory)
        }
        guard let store else {
            problem = "Nirux couldn’t find this branch’s review file."
            return
        }
        // Opening stamps the job's head: not over a later one.
        let found = store.load()
        if case .loaded = found.status, let head = writableHead(in: found.record), head != snapshot.head {
            mode = .keepingHead(head)
            read(found.record)
            return
        }
        let loaded = store.open(for: job.snapshot, options: job.options)
        if let access = loaded.access {
            if case .loaded = loaded.status, let head = loaded.record.lastHead {
                mode = .keepingHead(head)
            } else {
                mode = .creating(access)
            }
        }
        read(loaded.record)
        if problem == nil, case .readOnly(let reason) = loaded.status { problem = reason.message }
        if problem == nil, loaded.access == nil { problem = "Nirux can’t write this branch’s review file." }
    }

    private mutating func read(_ record: BranchReview.Record) {
        switch record.explanationState {
        case .readable(let explanation): self.explanation = explanation
        case .none: break
        case .unreadable:
            problem = "This branch’s explanation was saved by a newer Nirux, or is damaged: this version won’t replace it."
        }
    }

    /// The review's head, when the job can write at it: the job's own, or
    /// a later head of this branch (the job's head is in its history).
    private func writableHead(in record: BranchReview.Record) -> String? {
        guard record.branch == snapshot.branch, let lastHead = record.lastHead else { return nil }
        if lastHead == snapshot.head { return lastHead }
        guard BranchReview.isCommitID(lastHead),
              BranchReview.git(["merge-base", "--is-ancestor", snapshot.head, lastHead], in: snapshot.root, options: options)?
                .status == 0
        else { return nil }
        return lastHead
    }

    /// False when nothing could be kept: `problem` says why.
    @discardableResult
    mutating func save(_ delta: inout BranchReview.ExplainDelta, branchFiles: Set<String>) -> Bool {
        guard let store else { return false }
        // Three tries at most: the page may move the review on meanwhile.
        for _ in 0..<3 {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            var refusal: String?
            let applying = delta
            let maxBytes = maxBytes
            let change: (inout BranchReview.Record) -> Void = { record in
                var base: BranchReview.Explanation
                switch record.explanationState {
                case .readable(let current): base = current
                case .none: base = BranchReview.Explanation()
                case .unreadable:
                    refusal = "Another Nirux saved an explanation this version can’t read: it won’t be replaced."
                    return
                }
                var updated = base
                updated.apply(applying, branchFiles: branchFiles)
                if let size = try? encoder.encode(updated).count, size > maxBytes {
                    refusal = "This branch’s explanation would take more than \(maxBytes / 1_000_000) MB of its review file: "
                        + "Nirux keeps what it already had."
                    // The runs' usage is still kept, and the files seen, so
                    // the next Explain doesn't pay for them again.
                    var runsOnly = applying
                    runsOnly.files = applying.files.mapValues {
                        BranchReview.Explanation.FileEntry(
                            patchHash: $0.patchHash, summary: nil, importance: nil, head: $0.head, date: $0.date,
                            notSent: "too much to keep"
                        )
                    }
                    runsOnly.summary = nil
                    runsOnly.notes = runsOnly.savedNotes
                    updated = base
                    updated.apply(runsOnly, branchFiles: branchFiles)
                }
                if !record.setExplanation(updated) { refusal = "Nirux couldn’t encode the explanation." }
            }
            let result: Result<BranchReview.Store.Loaded, BranchReview.Store.WriteError>
            switch mode {
            case .creating(let access): result = store.update(access, change)
            case .keepingHead(let lastHead): result = store.update(keepingHead: lastHead, change)
            case .closed: return false
            }
            switch result {
            case .success(let loaded):
                // Created: from now on, written at whatever head it is.
                if case .creating = mode, let head = loaded.record.lastHead { mode = .keepingHead(head) }
                explanation = loaded.record.explanation ?? explanation
                problem = refusal
                if refusal == nil { delta.savedNotes = delta.notes }
                return refusal == nil
            case .failure(.changedSinceOpened):
                // The page opened the review at a later head, or at the
                // job's again: write at it.
                let found = store.load()
                guard case .loaded = found.status, let later = writableHead(in: found.record) else {
                    mode = .closed
                    problem = "The review changed while Explain ran (deleted by Clean Up, or on another history). "
                        + "Explain again to keep the rest."
                    return false
                }
                mode = .keepingHead(later)
            case .failure(.readOnly(let reason)):
                problem = reason.message
                return false
            case .failure(.tooLarge):
                problem = "The review file would grow past \(BranchReview.Store.maxFileBytes / 1_000_000) MB."
                return false
            case .failure(.couldNotLock(let why)), .failure(.couldNotSetAside(let why)), .failure(.couldNotWrite(let why)):
                problem = "Nirux couldn’t write the review file: \(why)"
                return false
            }
        }
        problem = "The review kept changing while Explain ran. Explain again to keep the rest."
        return false
    }
}
