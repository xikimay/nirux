import Darwin
import Foundation

// MARK: - The review file (docs/branch-review.md, sections 6.3 and 8)

extension BranchReviewController {
    /// The real review file: `<state dir>/reviews/`, for the repository
    /// the snapshot's worktree is in.
    nonisolated static func openReviewFile(_ snapshot: BranchReview.Snapshot) -> (BranchReview.Store, BranchReview.Store.Loaded)? {
        guard let repository = BranchReview.repositoryIdentity(root: snapshot.root),
              let store = BranchReview.Store(repository: repository, branch: snapshot.branch)
        else { return nil }
        return (store, store.open(for: snapshot))
    }

    /// Asked of the repository itself (its common git folder), which
    /// outlives a worktree Clean Up deleted: the branch's ref by its exact
    /// name (APFS would find `Fix/A` for `fix/a`). Nil when git fails.
    nonisolated static func branchExists(_ store: BranchReview.Store) -> Bool? {
        var options = BranchReview.Options()
        options.timeout = 5
        let ref = "refs/heads/" + store.branch
        guard let listed = BranchReview.git(
            ["--git-dir=" + store.repository, "for-each-ref", "--format=%(refname)", ref], in: store.repository, options: options
        ), listed.status == 0 else { return nil }
        return listed.text.split(separator: "\n").contains { $0 == ref }
    }

    /// Whether `ancestor` is `descendant` or in its history, in the
    /// store's repository; nil when git can't say.
    nonisolated static func isAncestor(_ store: BranchReview.Store, _ ancestor: String, _ descendant: String) -> Bool? {
        if ancestor == descendant { return true }
        guard BranchReview.isCommitID(ancestor), BranchReview.isCommitID(descendant) else { return false }
        var options = BranchReview.Options()
        options.timeout = 5
        switch BranchReview.git(
            ["--git-dir=" + store.repository, "merge-base", "--is-ancestor", ancestor, descendant], in: store.repository,
            options: options
        )?.status {
        case 0?: return true
        case 1?: return false
        default: return nil
        }
    }
}

/// The stored review of the branch a column shows, as the column last
/// opened, read or wrote it.
struct BranchReviewState: Equatable, Sendable {
    let branch: String
    /// Empty when it couldn't be read: see `isKnown`.
    let record: BranchReview.Record
    /// The record is what the file holds (or there is no file yet), not a
    /// stand-in for one that couldn't be read.
    let isKnown: Bool
    /// Why the review can't be changed now, or why the last change failed.
    let problem: String?
    let canWrite: Bool
}

/// The review file of the branch a column shows, used only on its review
/// queue: the store, and the access `open` gave, which writes need. Writes
/// for the branch shown asked for while one waits are made with it, in one
/// locked write.
final class BranchReviewFile: @unchecked Sendable {
    typealias Change = @Sendable (inout BranchReview.Record) -> Void

    /// A change and the branch it is for.
    private struct Pending {
        let id: Int
        let branch: String
        let change: Change
    }

    private let opener: BranchReviewController.ReviewOpener
    private let branchCheck: BranchReviewController.BranchCheck
    private let isAncestor: BranchReviewController.HeadOrder
    private var store: BranchReview.Store?
    private var access: BranchReview.Store.Access?
    private var snapshot: BranchReview.Snapshot?
    private var state: BranchReviewState?
    /// What the last open saw: a same-head refresh with the file unchanged
    /// doesn't open it again.
    private struct Opened: Equatable {
        let branch: String
        let head: String
        let pullRequest: Int?
        let root: String
        var file: FileStamp?
    }

    private var opened: Opened?
    /// The branch is gone: no write until it is opened again.
    private var deleted: String?
    /// The later head the review was found opened at: written so, its
    /// head kept, without asking git again each time.
    private var keptHead: String?
    /// Asked for from any thread; taken on the queue.
    private let lock = NSLock()
    private var pending: [Pending] = []

    init(
        opener: @escaping BranchReviewController.ReviewOpener, branchCheck: @escaping BranchReviewController.BranchCheck,
        isAncestor: @escaping BranchReviewController.HeadOrder
    ) {
        self.opener = opener
        self.branchCheck = branchCheck
        self.isAncestor = isAncestor
    }

    /// The review of a snapshot the column shows. Its worktree was just
    /// read on that branch: the branch exists. Nothing is read again when
    /// the branch, head, pull request and file are as last opened.
    func open(_ snapshot: BranchReview.Snapshot) -> BranchReviewState {
        let number = snapshot.pullRequest.pullRequest?.number
        if let store, state != nil, opened == Opened(
            branch: snapshot.branch, head: snapshot.head, pullRequest: number, root: snapshot.root, file: FileStamp(store.fileURL)
        ), let state {
            self.snapshot = snapshot
            return state
        }
        deleted = nil
        keptHead = nil
        self.snapshot = snapshot
        let before = store.flatMap { FileStamp($0.fileURL) }
        guard let (store, loaded) = opener(snapshot) else {
            store = nil
            access = nil
            opened = nil
            return remember(BranchReviewState(
                branch: snapshot.branch, record: BranchReview.Record(), isKnown: false,
                problem: "Nirux couldn’t open this branch’s review file: git couldn’t tell its repository.", canWrite: false
            ))
        }
        self.store = store
        access = loaded.access
        // Kept only when opening again would find the same: not after a
        // failure that may pass (git, the lock), nor when the file changed
        // while it was opened (by this open's stamp, or another writer).
        let after = FileStamp(store.fileURL)
        opened = Self.isLasting(loaded) && before == after
            ? Opened(branch: snapshot.branch, head: snapshot.head, pullRequest: number, root: snapshot.root, file: after)
            : nil
        var problem = Self.problem(of: loaded)
        if problem == nil, loaded.setAside != nil {
            problem = "A review stored for an earlier branch named \(snapshot.branch) was set aside (in reviews/archive): this one starts fresh."
        }
        return remember(state(loaded.record, isKnown: Self.isKnown(loaded), problem: problem))
    }

    /// The file as it is now, without opening it again: after a writer
    /// that isn't this column (Explain) saved it.
    func reload() -> BranchReviewState? {
        guard let store, let snapshot, store.branch == snapshot.branch else { return state }
        let loaded = store.load()
        opened = nil
        var problem = deleted
        if case .readOnly(let reason) = loaded.status {
            access = nil
            problem = problem ?? reason.message
        } else if access == nil {
            problem = problem ?? state?.problem ?? "This review can’t be changed."
        }
        return remember(state(loaded.record, isKnown: Self.isKnown(loaded), problem: problem))
    }

    /// Asks for `change` to the review of `branch`, made at the next
    /// `write`. From any thread.
    func enqueue(id: Int, branch: String, _ change: @escaping Change) {
        lock.lock()
        pending.append(Pending(id: id, branch: branch, change: change))
        lock.unlock()
    }

    /// Makes the changes asked for up to `last` (the id the call was
    /// scheduled for), and the later ones for the branch shown, together;
    /// those up to `last` for another branch are dropped, and later ones
    /// for another branch wait for their own call, after the open of the
    /// branch they are for. Returns their ids, and the review after them;
    /// nil when there was nothing to do.
    func write(through last: Int) -> (ids: [Int], state: BranchReviewState)? {
        let shown = snapshot?.branch
        lock.lock()
        let takes: (Pending) -> Bool = { $0.id <= last || $0.branch == shown }
        let taken = pending.filter(takes)
        pending.removeAll(where: takes)
        lock.unlock()
        guard !taken.isEmpty else { return nil }
        let ids = taken.map(\.id)
        guard let snapshot else {
            return (ids, remember(BranchReviewState(
                branch: "", record: BranchReview.Record(), isKnown: false, problem: nil, canWrite: false
            )))
        }
        let changes = taken.filter { $0.branch == snapshot.branch }.map(\.change)
        guard !changes.isEmpty, let store else { return (ids, state ?? self.state(BranchReview.Record(), isKnown: false, problem: nil)) }
        let apply: (inout BranchReview.Record) -> Void = { record in changes.forEach { $0(&record) } }
        let written = write(apply, to: store, at: snapshot)
        // A Refresh opens it again, and says what it says now.
        if written.problem != nil { opened = nil }
        return (ids, remember(written))
    }

    private func write(
        _ apply: (inout BranchReview.Record) -> Void, to store: BranchReview.Store, at snapshot: BranchReview.Snapshot
    ) -> BranchReviewState {
        if let deleted { return state(nil, problem: deleted) }
        guard let access else { return state(nil, problem: state?.problem ?? Self.problem(of: store.load())) }
        // A write at a kept head never creates the review.
        if keptHead == nil, let refused = checkBranch(before: access, of: store) { return refused }
        // Changes that leave a review not created yet empty (about a draft
        // or comment that isn't there) don't create it.
        var result = keptHead.map { store.update(keepingHead: $0, apply) } ?? store.update(access, createsEmpty: false, apply)
        if case .failure(.changedSinceOpened) = result {
            keptHead = nil
            // Opened by another Nirux (or set aside, or deleted) since.
            let current = store.load()
            guard case .loaded = current.status, current.record.branch == store.branch,
                  current.record.repository == store.repository, let lastHead = current.record.lastHead
            else {
                self.access = nil
                return state(nil, problem: "The review was deleted or set aside since it was opened. Refresh to see it again.")
            }
            let olderOrSame = isAncestor(store, lastHead, snapshot.head)
            if olderOrSame == true {
                // At the head shown or an older one: open it again at the
                // head shown, and try again.
                guard let (reopened, loaded) = opener(snapshot), loaded.setAside == nil, let fresh = loaded.access else {
                    self.access = nil
                    opened = nil
                    return state(nil, problem: "Nirux couldn’t open the review again. Refresh to try again.")
                }
                self.store = reopened
                self.access = fresh
                if let refused = checkBranch(before: fresh, of: reopened) { return refused }
                result = reopened.update(fresh, createsEmpty: false, apply)
            } else if let newer = isAncestor(store, snapshot.head, lastHead), olderOrSame != nil {
                guard newer else {
                    return state(nil, problem: "The review was opened at another head since. Reload or Refresh to change it.")
                }
                // Opened at a later head of the branch than the page
                // shows: written as it is, its head kept. Marks carry
                // their own head.
                keptHead = lastHead
                result = store.update(keepingHead: lastHead, apply)
            } else {
                return state(nil, problem: "Nirux couldn’t tell how the review’s head relates to this one. Try again.")
            }
        }
        switch result {
        case .success(let written):
            // The write changed the file's stamp: the next open reads it.
            if let next = written.access { self.access = next }
            return state(written.record, isKnown: true, problem: nil)
        case .failure(let error):
            if case .readOnly = error {
                self.access = nil
                opened = nil
            }
            return state(nil, problem: Self.message(error))
        }
    }

    /// Before a write that would create the review: the branch must still
    /// exist. Nil when it may go ahead.
    private func checkBranch(before access: BranchReview.Store.Access, of store: BranchReview.Store) -> BranchReviewState? {
        guard access.createsReview else { return nil }
        switch branchCheck(store) {
        case true?:
            return nil
        case false?:
            self.access = nil
            opened = nil
            deleted = "\(store.branch) was deleted: Nirux won’t create its review."
            return state(nil, problem: deleted)
        case nil:
            return state(nil, problem: "Nirux couldn’t check that \(store.branch) still exists. Try again.")
        }
    }

    /// The state for the branch shown: `record`, or the last one known.
    private func state(_ record: BranchReview.Record?, isKnown: Bool? = nil, problem: String?) -> BranchReviewState {
        BranchReviewState(
            branch: snapshot?.branch ?? "", record: record ?? state?.record ?? BranchReview.Record(),
            isKnown: isKnown ?? state?.isKnown ?? false, problem: problem, canWrite: access != nil && deleted == nil
        )
    }

    private func remember(_ state: BranchReviewState) -> BranchReviewState {
        self.state = state
        return state
    }

    /// Whether opening again would find the same: a review that can be
    /// written, or one read-only for good (a newer build's, too large, not
    /// a file). Not a failure that may pass: git, the lock.
    private static func isLasting(_ loaded: BranchReview.Store.Loaded) -> Bool {
        switch loaded.status {
        case .readOnly(.newerVersion), .readOnly(.notARegularFile), .readOnly(.tooLarge): return true
        default: return loaded.access != nil
        }
    }

    /// Whether the record is the file's: not a stand-in for a file that
    /// couldn't be read or checked.
    private static func isKnown(_ loaded: BranchReview.Store.Loaded) -> Bool {
        switch loaded.status {
        case .loaded, .missing, .unreadable, .readOnly(.newerVersion): return true
        case .readOnly: return false
        }
    }

    private static func problem(of loaded: BranchReview.Store.Loaded) -> String? {
        if case .readOnly(let reason) = loaded.status { return reason.message }
        return loaded.access == nil ? "This review can’t be changed." : nil
    }

    private static func message(_ error: BranchReview.Store.WriteError) -> String {
        switch error {
        case .readOnly(let reason):
            return reason.message
        case .changedSinceOpened:
            return "The review changed elsewhere since it was opened. Refresh to try again."
        case .tooLarge:
            return "The review would be larger than \(BranchReview.Store.maxFileBytes / 1_000_000) MB: Nirux won’t save it."
        case .couldNotLock(let reason), .couldNotSetAside(let reason), .couldNotWrite(let reason):
            return "Nirux couldn’t save the review: \(reason)"
        }
    }
}

/// What tells a file changed: which file, its size, and when it was last
/// written. Nil when nothing is there.
struct FileStamp: Equatable, Sendable {
    let device: Int64
    let inode: UInt64
    let size: Int64
    let modified: Int64

    init?(_ url: URL) {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        device = Int64(info.st_dev)
        inode = UInt64(info.st_ino)
        size = Int64(info.st_size)
        modified = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
    }
}
