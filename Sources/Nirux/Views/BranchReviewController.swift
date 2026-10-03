import AppKit

/// One Branch Review column (docs/branch-review.md): the branch checked out
/// in a worktree when the column opened, read without writing to the
/// repository, and shown read-only. git and gh run off the main thread: one
/// read of the branch at a time, and one read of a file's diff at a time,
/// for the rows the page opens.
@MainActor
final class BranchReviewController {
    /// Reads the worktree at `path`: the snapshot, and the handover if the
    /// branch has one. `fetchBase` fetches the pull request's base first
    /// (Refresh). Runs off the main thread.
    typealias Reader = @Sendable (
        _ path: String, _ fetchBase: Bool, _ known: BranchReview.KnownPullRequest?
    ) -> (BranchReview.Outcome, BranchReview.Handover?)
    /// A file's diff the snapshot left out (`BranchReview.filePatch`). Runs
    /// off the main thread.
    typealias PatchReader = @Sendable (BranchReview.FileChange, BranchReview.Snapshot) -> BranchReview.FileChange?

    let view: BranchReviewView
    /// The workspace's folder when the column opened.
    let worktree: String
    /// The branch the column reviews: the one checked out at `worktree`
    /// when it first read it.
    private(set) var branch: String?
    private(set) var snapshot: BranchReview.Snapshot?
    /// Read with the snapshot.
    private var handover: BranchReview.Handover?
    /// What the page says instead of a review: reading, paused, why there
    /// is none. Shown again if the page loads again.
    private var status: String?
    /// The page loads and the branch is read: at once for a new column,
    /// once its workspace shows for a restored one.
    private(set) var isStarted = false
    /// A read is under way.
    private(set) var isReading = false
    /// Asked for during a read: one more once it ends, fetching the base
    /// (true) if any of the asks wanted to.
    private var readAfterRead: Bool?
    /// When the snapshot was read.
    private var readAt = Date()
    /// Counts snapshots: the page's generation. A file's diff is read and
    /// sent only for the snapshot the page shows, whose ids it uses.
    private var snapshotCount = 0
    private let reader: Reader
    private let patchReader: PatchReader
    /// One `git diff` at a time, whatever the number of rows opened.
    private let patchQueue = DispatchQueue(label: "nirux.branch-review.file-diffs", qos: .userInitiated)

    init(
        worktree: String, branch: String?, view: BranchReviewView = BranchReviewView(),
        reader: @escaping Reader = BranchReviewController.readWorktree,
        patchReader: @escaping PatchReader = { BranchReview.filePatch($0, in: $1) }
    ) {
        self.worktree = worktree
        self.branch = branch
        self.view = view
        self.reader = reader
        self.patchReader = patchReader
        view.onRefresh = { [weak self] in
            self?.view.forgetCrashes()
            self?.reload(fetchBase: true)
        }
        view.onLoadFile = { [weak self] id, generation in self?.loadFile(id: id, generation: generation) }
        view.onPageReady = { [weak self] in self?.showCurrent() }
        updateHeader()
    }

    /// Loads the page and reads the branch, once.
    func start(fetchBase: Bool = false) {
        guard !isStarted else { return }
        isStarted = true
        view.load()
        reload(fetchBase: fetchBase)
    }

    /// Reads the branch again; with `fetchBase`, the pull request's base
    /// is fetched first, the page's only write to the repository.
    func reload(fetchBase: Bool = false) {
        guard isStarted else { return start(fetchBase: fetchBase) }
        guard !isReading else {
            readAfterRead = fetchBase || readAfterRead == true
            return
        }
        isReading = true
        updateHeader()
        if snapshot == nil { showStatus("Reading \(branch ?? "the branch")…") }
        let known = snapshot?.knownPullRequest
        Self.inBackground(on: .global(qos: .userInitiated), { [reader, worktree] in
            reader(worktree, fetchBase, fetchBase ? nil : known)
        }) { [weak self] result in
            self?.apply(result.0, handover: result.1)
        }
    }

    /// One read runs at a time: its answer is the latest.
    private func apply(_ outcome: BranchReview.Outcome, handover: BranchReview.Handover?) {
        isReading = false
        defer {
            updateHeader()
            if let fetchBase = readAfterRead {
                readAfterRead = nil
                reload(fetchBase: fetchBase)
            }
        }
        switch outcome {
        case .snapshot(let fresh):
            if let branch, fresh.branch != branch {
                setSnapshot(nil)
                showStatus(
                    "The worktree is on \(fresh.branch) now, not \(branch). "
                        + "Close this review, and review \(fresh.branch) from the workspace’s menu."
                )
                return
            }
            branch = fresh.branch
            self.handover = handover
            readAt = Date()
            setSnapshot(fresh)
            showCurrent()
        case .paused(let operation):
            setSnapshot(nil)
            showStatus(Self.pauseMessage(operation))
        case .unavailable(let reason):
            setSnapshot(nil)
            showStatus(reason)
        }
    }

    private func setSnapshot(_ snapshot: BranchReview.Snapshot?) {
        self.snapshot = snapshot
        snapshotCount += 1
    }

    private func showStatus(_ message: String) {
        status = message
        view.showStatus(message)
    }

    /// The page, or what it says instead; for a page that loads again too.
    private func showCurrent() {
        // Without a snapshot, a status always says why: reading, paused.
        guard let snapshot else {
            if let status { view.showStatus(status) }
            return
        }
        // Twice: the page shows why instead of loading again.
        guard view.crashes < 2 else {
            return showStatus("The review page stopped while showing this branch. Refresh to try again.")
        }
        status = nil
        let page = BranchReview.page(for: snapshot, handover: handover, generation: snapshotCount, readAt: readAt)
        guard let json = Self.encode(page) else { return }
        view.show(pageJSON: json)
    }

    private func loadFile(id: Int, generation: Int) {
        // A row of a page another is about to replace, which asks again.
        guard generation == snapshotCount else { return }
        guard let snapshot, snapshot.files.indices.contains(id) else {
            return send(BranchReview.FileDiff(id: id, path: "", generation: generation, message: "Refresh to read this file’s diff."))
        }
        let file = snapshot.files[id]
        if let diff = BranchReview.FileDiff(id: id, generation: generation, file: file) {
            send(diff)
            return
        }
        Self.inBackground(on: patchQueue, { [patchReader] in patchReader(file, snapshot) }) { [weak self] read in
            guard let self, generation == self.snapshotCount else { return }
            self.send(read.map { BranchReview.FileDiff(id: id, generation: generation, read: $0) } ?? BranchReview.FileDiff(
                id: id, path: file.path, generation: generation,
                message: "Nirux couldn’t read this file’s diff: it no longer differs from the base, or git failed. Refresh."
            ))
        }
    }

    private func send(_ diff: BranchReview.FileDiff) {
        guard let json = Self.encode(diff) else { return }
        view.showDiff(json: json)
    }

    private func updateHeader() {
        if let snapshot {
            view.header.context = "\(snapshot.branch) → \(snapshot.base.name)"
        } else {
            view.header.context = branch ?? worktree.abbreviatedPath(maxComponents: 2)
        }
        // A page missing from the build says so instead.
        guard view.pageURL != nil else { return }
        view.header.status = isReading ? ColumnHeaderView.Status("Reading", tone: .neutral) : nil
    }

    static func pauseMessage(_ operation: BranchReview.Operation) -> String {
        switch operation {
        case .conflicts:
            return "This worktree has conflicts to resolve. Refresh once they’re resolved."
        case .rebase, .merge, .cherryPick, .revert:
            return "A \(operation.rawValue) is in progress in this worktree. Refresh once it’s over."
        }
    }

    private static func encode<T: Encodable>(_ value: T) -> String? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// `work` on `queue`, then `completion` on the main actor. Nonisolated,
    /// so that `work` is never a main-actor closure run off the main thread
    /// (#48).
    nonisolated static func inBackground<T: Sendable>(
        on queue: DispatchQueue, _ work: @escaping @Sendable () -> T,
        then completion: @escaping @MainActor @Sendable (T) -> Void
    ) {
        queue.async {
            let result = work()
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// The real read: git and gh, with the handover.
    nonisolated static func readWorktree(
        _ path: String, fetchBase: Bool, known: BranchReview.KnownPullRequest?
    ) -> (BranchReview.Outcome, BranchReview.Handover?) {
        var options = BranchReview.Options()
        options.fetchBase = fetchBase
        options.knownPullRequest = known
        let outcome = BranchReview.snapshot(at: path, options: options)
        guard case .snapshot(let snapshot) = outcome else { return (outcome, nil) }
        return (outcome, BranchReview.Handover.read(in: snapshot.root))
    }
}
