import AppKit
import os

/// One Branch Review column (docs/branch-review.md): the branch checked out
/// in a worktree when the column opened, read without writing to the
/// repository, and shown read-only. git and gh run off the main thread: one
/// read of the branch at a time, and one read of a file's diff at a time,
/// for the rows the page opens.
///
/// It follows its worktree (section 7): a change reads the branch again,
/// a moment after the last one. The same head updates the page; a new head
/// never re-renders it under the user, but waits behind a Reload banner.
/// Off screen, it only marks itself stale, and reads once it shows.
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
    /// Watches the worktree laid out as `layout`, and `branch`'s refs (any
    /// branch's while it's nil); nil when it can't.
    typealias WatcherFactory = @MainActor (
        _ layout: GitRepositoryLayout, _ branch: String?, _ onChange: @escaping @MainActor (GitRepositoryChange) -> Void
    ) -> GitRepositoryWatcher?
    /// Opens the review file of a shown snapshot's branch (section 8):
    /// the store, and what `open` found. Nil when the repository can't be
    /// told. Runs off the main thread.
    typealias ReviewOpener = @Sendable (BranchReview.Snapshot) -> (BranchReview.Store, BranchReview.Store.Loaded)?
    /// Whether the store's branch still exists in its repository; nil when
    /// git can't say. Runs off the main thread.
    typealias BranchCheck = @Sendable (BranchReview.Store) -> Bool?
    /// Whether the first head is the second or in its history, in the
    /// store's repository; nil when git can't say. Runs off the main
    /// thread.
    typealias HeadOrder = @Sendable (_ store: BranchReview.Store, _ ancestor: String, _ descendant: String) -> Bool?
    /// What Explain kept for the snapshot's branch, read only (no head
    /// recorded, nothing written). Runs off the main thread.
    typealias ExplanationReader = @Sendable (BranchReview.Snapshot) -> BranchReview.Explanation?
    /// Locates claude and reads its account. Runs off the main thread.
    typealias ExplainChecker = @Sendable () -> BranchReview.ExplainAvailability
    /// Explains a branch (`BranchReview.explain`). Runs off the main
    /// thread, through `ExplainQueue`.
    typealias Explainer = @Sendable (
        BranchReview.ExplainJob, BoundedProcess.Cancellation, @escaping @Sendable (BranchReview.ExplainJobProgress) -> Void
    ) -> BranchReview.ExplainResult

    /// One read of the worktree: the branch, its handover, and what
    /// Explain kept for it.
    struct Read {
        let snapshot: BranchReview.Snapshot
        let handover: BranchReview.Handover?
        var explanation: BranchReview.Explanation?
        let readAt: Date
    }

    /// Why a read runs: a watched change applies only what doesn't move the
    /// page under the user.
    private enum ReadReason {
        case user
        case watcher
    }

    let view: BranchReviewView
    /// The workspace's folder when the column opened.
    let worktree: String
    /// The branch the column reviews: the one checked out at `worktree`
    /// when it first read it.
    private(set) var branch: String?
    private(set) var snapshot: BranchReview.Snapshot?
    /// Read with the snapshot.
    private var handover: BranchReview.Handover?
    /// What Explain kept for the branch: read with the snapshot, or what
    /// the last Explain left.
    private(set) var explanation: BranchReview.Explanation?
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
    /// The last read's pull request, for the next read of that branch:
    /// watched reads ask gh only when the worktree's branch changed or its
    /// remote branch moved (a push), never on a timer (section 7).
    private var knownPullRequest: BranchReview.KnownPullRequest?
    /// Pushes the watcher saw (the remote branch moved), those a read
    /// found the branch after, and the count when the read under way
    /// began: while a push isn't answered, reads ask gh again.
    private var pushes = 0
    private var pushesAnswered = 0
    private var readPushes = 0
    /// Counts snapshots: the page's generation. A file's diff is read and
    /// sent only for the snapshot the page shows, whose ids it uses.
    private var snapshotCount = 0
    private let reader: Reader
    private let patchReader: PatchReader
    private let makeWatcher: WatcherFactory
    private var watcher: GitRepositoryWatcher?
    /// The root the watcher follows, as asked for (the snapshot's, or the
    /// top level found before it).
    private var watchedRoot: String?
    /// Counts watch requests: a layout resolved for an older one is dropped.
    private var watchRequest = 0
    /// Why the read under way runs.
    private var readReason = ReadReason.user
    /// The worktree changed while the column was off screen: it reads the
    /// branch again once it shows.
    private(set) var isStale = false
    /// A read at a new head, waiting behind the Reload banner.
    private(set) var pending: Read?
    /// What the status's button does, when it has one.
    private var statusAction: (title: String, perform: @MainActor () -> Void)?
    /// Counts watched changes: only the last one of a burst reads.
    private var changeCount = 0
    /// When the burst of changes being waited out began.
    private var burstStartedAt: Date?
    /// When the read under way began, and the last watched read's length
    /// and end: watched reads are spaced by at least that length.
    private var readStartedAt = Date()
    private var lastWatchedReadDuration: TimeInterval = 0
    private var lastWatchedReadEnded = Date.distantPast
    /// The banner over the page while something waits (a new head, a
    /// failed read, a pause, another branch), and what its button does:
    /// nil shows `pending`, or reads again.
    private var banner: (message: String, action: (title: String, perform: @MainActor () -> Void)?)?
    /// A watched read came due during another read: it runs once that one
    /// ends, spaced like any watched read.
    private var watchedReadWanted = false
    /// Watched reads in a row that found nothing new: a build writing in
    /// an ignored folder. Each doubles the max wait.
    private var quietReads = 0
    /// The page has a text selection, which a new page would drop: a read
    /// at the same head waits in `held` until it goes.
    private var pageHasSelection = false
    private var held: Read?
    /// The next read reviews whatever branch the worktree is on: the user
    /// asked to review the other branch.
    private var followsWorktree = false
    /// The page's generation, readable off the main thread: a file's diff
    /// queued for an older page isn't read.
    private let currentGeneration = OSAllocatedUnfairLock(initialState: 0)
    /// Whether the column shows: its workspace in front, its window
    /// visible. Set by the shell.
    var isOnScreen: @MainActor () -> Bool = { true }
    /// One `git diff` at a time, whatever the number of rows opened.
    private let patchQueue = DispatchQueue(label: "nirux.branch-review.file-diffs", qos: .userInitiated)
    /// The review file: opened, then written, in order, off the main
    /// thread.
    private let reviewQueue = DispatchQueue(label: "nirux.branch-review.review-file", qos: .userInitiated)
    private let reviewFile: BranchReviewFile
    /// The stored review of the branch shown, as last opened, read or
    /// written: for the page, and for what reads it (Explain's cache).
    /// Nil until the branch shown has been opened.
    private(set) var review: BranchReviewState?
    /// The review's record, when it is the file's.
    var reviewRecord: BranchReview.Record? { review?.isKnown == true ? review?.record : nil }
    /// Writes asked for, by id, with what to tell once written.
    private var reviewWrites = 0
    private var writeCompletions: [Int: @MainActor (BranchReviewState) -> Void] = [:]
    /// The latest of the page's checkbox clicks Swift has answered: the
    /// page keeps its own state for the later ones.
    private(set) var reviewAcknowledged = 0
    /// Rows' patches read since the page showed (`loadFile`), by id: a
    /// file not read with the snapshot gets its hash, and can be marked.
    private var readFiles: [Int: BranchReview.FileChange] = [:]
    /// The stored review changed (opened, read or written).
    var onReviewChange: (() -> Void)?

    // MARK: Explain

    /// The bar the page shows by Explain's button.
    private var explainBar = BranchReview.Page.ExplainBar()
    /// The last check of claude and its account.
    private var availability: BranchReview.ExplainAvailability?
    /// A check under way, and whether an Explain waits on it (`fresh`).
    private var isCheckingExplain = false
    private var explainAfterCheck: Bool?
    /// The notice is up, or about to be.
    private var isAskingToExplain = false
    /// The Explain waiting or under way, and its number: a completion for
    /// another is dropped.
    private var explainTicket: ExplainQueue.Ticket?
    private var activeExplain: Int?
    private var explainCount = 0
    /// The user cancelled the Explain under way.
    private var explainCancelled = false
    /// When the last Explain ended, and its branch: a read of that branch
    /// that began before keeps the explanation it left, newer than what the
    /// read found.
    private var explanationSetAt = Date.distantPast
    private var explanationBranch: String?
    /// An explanation came while the page had a selection: the page shows
    /// it once the selection goes.
    private var explanationWaits = false
    private let explainQueue: ExplainQueue
    private let explanationReader: ExplanationReader
    private let explainChecker: ExplainChecker
    private let explainer: Explainer
    /// Asks the user before Explain sends the branch to Claude under
    /// `account`, with the number of files whose diff it sends: false
    /// doesn't run. The shell asks once per project and account, and every
    /// time for an account billed per call; this default asks every time.
    var confirmExplain: @MainActor (_ account: BranchReview.ExplainAccount, _ files: Int) -> Bool = { account, files in
        BranchReviewController.explainAlert(account: account, files: files).runModal() == .alertFirstButtonReturn
    }

    init(
        worktree: String, branch: String?, view: BranchReviewView = BranchReviewView(),
        reader: @escaping Reader = BranchReviewController.readWorktree,
        patchReader: @escaping PatchReader = { BranchReview.filePatch($0, in: $1) },
        makeWatcher: @escaping WatcherFactory = BranchReviewController.watch,
        reviewOpener: @escaping ReviewOpener = BranchReviewController.openReviewFile,
        branchCheck: @escaping BranchCheck = BranchReviewController.branchExists,
        headOrder: @escaping HeadOrder = BranchReviewController.isAncestor,
        explanationReader: @escaping ExplanationReader = { BranchReviewController.readExplanation(for: $0) },
        explainChecker: @escaping ExplainChecker = { BranchReview.ExplainAvailability.check() },
        explainer: @escaping Explainer = { BranchReviewController.explainOnItsBranch($0, cancellation: $1, progress: $2) },
        explainQueue: ExplainQueue = .shared
    ) {
        self.worktree = worktree
        self.branch = branch
        self.view = view
        self.reader = reader
        self.patchReader = patchReader
        self.makeWatcher = makeWatcher
        reviewFile = BranchReviewFile(opener: reviewOpener, branchCheck: branchCheck, isAncestor: headOrder)
        self.explanationReader = explanationReader
        self.explainChecker = explainChecker
        self.explainer = explainer
        self.explainQueue = explainQueue
        view.onRefresh = { [weak self] in
            self?.view.forgetCrashes()
            self?.reload(fetchBase: true)
            self?.checkExplain()
        }
        view.onExplain = { [weak self] fresh in self?.explain(fresh: fresh) }
        view.onCancelExplain = { [weak self] in self?.cancelExplain() }
        view.onIncludeUntracked = { [weak self] include in self?.includeUntracked(include) }
        view.onLoadFile = { [weak self] id, generation in self?.loadFile(id: id, generation: generation) }
        view.onPageReady = { [weak self] in
            guard let self else { return }
            // A page that loaded again has no selection: what it held shows.
            self.pageHasSelection = false
            if let held = self.held {
                self.show(held)
            } else {
                self.showCurrent()
            }
        }
        view.onSelection = { [weak self] active in self?.selectionChanged(active) }
        view.onReviewed = { [weak self] ids, reviewed, generation, sequence in
            self?.markReviewed(ids: ids, reviewed: reviewed, generation: generation, sequence: sequence)
        }
        view.onReload = { [weak self] in self?.bannerClicked() }
        view.onStatusAction = { [weak self] in self?.statusAction?.perform() }
        view.onWindowChange = { [weak self] inWindow in
            guard let self, self.isStarted else { return }
            // Closed: the watcher goes with it, and Explain stops. Back in a
            // window: watch again, and read what changed meanwhile once it
            // shows.
            if inWindow {
                self.watch()
                self.isStale = true
            } else {
                self.stopWatching()
                self.cancelExplain()
            }
        }
        updateHeader()
    }

    /// Loads the page and reads the branch, once.
    func start(fetchBase: Bool = false) {
        guard !isStarted else { return }
        isStarted = true
        view.load()
        // Before the first read: a change during it reads again, and a
        // column opened during a rebase comes back once it's over.
        watch()
        reload(fetchBase: fetchBase)
        checkExplain()
    }

    /// Reads the branch again; with `fetchBase`, the pull request's base
    /// is fetched first, the page's only write to the repository.
    func reload(fetchBase: Bool = false) {
        read(fetchBase: fetchBase, reason: .user)
    }

    private func read(fetchBase: Bool, reason: ReadReason) {
        guard isStarted else { return start(fetchBase: fetchBase) }
        guard !isReading else {
            if reason == .user {
                readAfterRead = fetchBase || readAfterRead == true
                updateHeader()
            } else {
                watchedReadWanted = true
            }
            return
        }
        isReading = true
        readReason = reason
        readStartedAt = Date()
        updateHeader()
        // A watched read keeps a status up (paused, another branch, and its
        // button) rather than blink "Reading" over it.
        if snapshot == nil, reason == .user || status == nil {
            showStatus("Reading \((followsWorktree ? nil : branch) ?? "the branch")…")
        }
        readPushes = pushes
        let known = pushes == pushesAnswered ? knownPullRequest : nil
        // The user waits on their read; a watched one yields to the apps.
        typealias Found = (BranchReview.Outcome, BranchReview.Handover?, BranchReview.Explanation?)
        Self.inBackground(on: .global(qos: reason == .user ? .userInitiated : .utility), { [reader, explanationReader, worktree] () -> Found in
            let (outcome, handover) = reader(worktree, fetchBase, fetchBase ? nil : known)
            guard case .snapshot(let snapshot) = outcome else { return (outcome, handover, nil) }
            return (outcome, handover, explanationReader(snapshot))
        }) { [weak self] result in
            self?.apply(result.0, handover: result.1, explanation: result.2)
        }
    }

    /// One read runs at a time: its answer is the latest.
    private func apply(
        _ outcome: BranchReview.Outcome, handover: BranchReview.Handover?, explanation found: BranchReview.Explanation?
    ) {
        isReading = false
        // An Explain of this branch that ended during the read left a newer
        // explanation.
        let explanation: BranchReview.Explanation?
        if case .snapshot(let fresh) = outcome, fresh.branch == explanationBranch, readStartedAt < explanationSetAt {
            explanation = self.explanation
        } else {
            explanation = found
        }
        let reason = readReason
        if reason == .watcher {
            lastWatchedReadEnded = Date()
            lastWatchedReadDuration = lastWatchedReadEnded.timeIntervalSince(readStartedAt)
        }
        defer {
            updateHeader()
            // The user's Refresh at once; a watched read spaced.
            if let fetchBase = readAfterRead {
                readAfterRead = nil
                read(fetchBase: fetchBase, reason: .user)
            } else if watchedReadWanted {
                watchedReadWanted = false
                scheduleWatchedRead(after: 0)
            }
        }
        let readAt = Date()
        var outcome = outcome
        if case .snapshot(var fresh) = outcome {
            knownPullRequest = fresh.knownPullRequest
            pushesAnswered = readPushes
            // A failed fetch still holds until the next Refresh fetches:
            // watched reads don't.
            if reason == .watcher, fresh.fetchProblem == nil, let shown = snapshot ?? pending?.snapshot ?? held?.snapshot,
               shown.branch == fresh.branch {
                fresh.fetchProblem = shown.fetchProblem
                outcome = .snapshot(fresh)
            }
        }
        // A watched read while the page shows the review never moves it
        // under the user: what changed waits behind a banner.
        if reason == .watcher, status == nil, let shown = snapshot {
            held = nil
            switch outcome {
            case .snapshot(let fresh) where fresh.branch != shown.branch:
                pending = nil
                return showWatchedBanner("The worktree is on \(fresh.branch) now, not \(shown.branch).", action: (
                    "Review \(fresh.branch)", { [weak self] in self?.reviewWorktreeBranch() }
                ))
            case .snapshot(let fresh) where fresh.head != shown.head:
                let unchanged = pending.map {
                    $0.snapshot == fresh && $0.handover == handover && $0.explanation == explanation
                } ?? false
                if !unchanged { pending = Read(snapshot: fresh, handover: handover, explanation: explanation, readAt: readAt) }
                return showWatchedBanner(Self.reloadMessage(from: shown, to: fresh), unchanged: unchanged)
            case .snapshot(let fresh):
                // Back to what the page shows (a rebase aborted, the branch
                // checked out again): what waited goes.
                if banner != nil { clearBanner() }
                // Nothing changed for the page (a build wrote in an ignored
                // folder): it stays as it is, open details and all.
                if fresh == shown, handover == self.handover, explanation == self.explanation {
                    quietReads += 1
                    return
                }
                quietReads = 0
                let read = Read(snapshot: fresh, handover: handover, explanation: explanation, readAt: readAt)
                // A new page would drop the user's selection: it waits.
                if pageHasSelection {
                    held = read
                    return
                }
                return show(read)
            case .paused(let operation):
                pending = nil
                return showWatchedBanner(Self.pauseMessage(operation))
            case .unavailable(let message):
                // The agent committed during the read, say: the next change
                // reads again, and Reload tries now.
                pending = nil
                return showWatchedBanner("Nirux couldn’t read the branch again: \(message)")
            }
        }
        let follows = reason == .user && followsWorktree
        if reason == .user { followsWorktree = false }
        let watched = reason == .watcher
        switch outcome {
        case .snapshot(let fresh):
            if let branch, fresh.branch != branch, !follows {
                return showInstead("The worktree is on \(fresh.branch) now, not \(branch).", action: (
                    "Review \(fresh.branch)", { [weak self] in self?.reviewWorktreeBranch() }
                ), watched: watched)
            }
            show(Read(snapshot: fresh, handover: handover, explanation: explanation, readAt: readAt))
        case .paused(let operation):
            showInstead(Self.pauseMessage(operation), watched: watched)
        case .unavailable(let message):
            showInstead(message, watched: watched)
        }
    }

    private func show(_ read: Read) {
        // How another branch's Explain ended isn't this one's; why Explain
        // can't run still is.
        if read.snapshot.branch != branch {
            if case .unavailable(let reason)? = availability { explainBar.message = reason } else { explainBar.message = nil }
        }
        branch = read.snapshot.branch
        handover = read.handover
        explanation = read.explanation
        readAt = read.readAt
        pending = nil
        held = nil
        banner = nil
        explanationWaits = false
        // Another branch's review isn't this one's.
        if review?.branch != read.snapshot.branch { review = nil }
        setSnapshot(read.snapshot)
        showCurrent()
        watch()
        openReview(for: read.snapshot)
    }

    private func showBanner(_ message: String, action: (title: String, perform: @MainActor () -> Void)? = nil) {
        banner = (message, action)
        view.showReload(message, action: action?.title)
    }

    /// A banner for a watched read. The same again (`unchanged`, and the
    /// same message) counts the read as quiet and isn't drawn again: a
    /// click on it isn't lost.
    private func showWatchedBanner(
        _ message: String, action: (title: String, perform: @MainActor () -> Void)? = nil, unchanged: Bool = true
    ) {
        if unchanged, banner?.message == message {
            quietReads += 1
            banner = (message, action)
            return
        }
        quietReads = 0
        showBanner(message, action: action)
    }

    /// No page, and a status that says why: a pause, a failed read, another
    /// branch, whose button reviews the branch the worktree is on. The same
    /// status again for a watched read counts it as quiet, and isn't drawn
    /// again.
    private func showInstead(
        _ message: String, action: (title: String, perform: @MainActor () -> Void)? = nil, watched: Bool
    ) {
        pending = nil
        if snapshot != nil { setSnapshot(nil) }
        if watched, status == message {
            quietReads += 1
            statusAction = action
            return
        }
        if watched { quietReads = 0 }
        showStatus(message, action: action)
    }

    private func clearBanner() {
        banner = nil
        pending = nil
        view.hideReload()
    }

    /// The page's selection came or went: once it goes, the page held for
    /// it shows.
    private func selectionChanged(_ active: Bool) {
        pageHasSelection = active
        guard !active else { return }
        if let held { return show(held) }
        if explanationWaits {
            explanationWaits = false
            showCurrent()
        }
    }

    /// Reviews the branch the worktree is on, read again now: it may have
    /// come back to this one since the banner offered the other.
    private func reviewWorktreeBranch() {
        followsWorktree = true
        reload()
    }

    /// The banner's button: its action, the new head, or a read now.
    private func bannerClicked() {
        if let action = banner?.action { return action.perform() }
        guard let pending else { return reload() }
        show(pending)
    }

    static func reloadMessage(from shown: BranchReview.Snapshot, to fresh: BranchReview.Snapshot) -> String {
        let head = String(fresh.head.prefix(7))
        let added = fresh.commits.filter { commit in !shown.commits.contains { $0.oid == commit.oid } }.count
        return added > 0
            ? "The branch moved to \(head): \(BranchReview.count(added, "new commit"))."
            : "The branch moved to \(head)."
    }

    // MARK: - Explain

    /// Checks claude and its account, for the bar: Explain is disabled with
    /// the reason when it can't run. At start, on Refresh, and before each
    /// Explain (`explain(fresh:)`), since the account may have changed.
    func checkExplain() {
        guard !isCheckingExplain, !isAskingToExplain, activeExplain == nil else { return }
        isCheckingExplain = true
        explainBar.state = .checking
        sendExplainBar()
        Self.inBackground(on: .global(qos: .userInitiated), explainChecker) { [weak self] availability in
            self?.checked(availability)
        }
    }

    private func checked(_ availability: BranchReview.ExplainAvailability) {
        isCheckingExplain = false
        // The reason it couldn't run before goes with it.
        if case .unavailable(let reason)? = self.availability, explainBar.message == reason { explainBar.message = nil }
        self.availability = availability
        let fresh = explainAfterCheck
        explainAfterCheck = nil
        // A run under way keeps its bar.
        guard activeExplain == nil else { return }
        switch availability {
        case .unavailable(let reason):
            explainBar.state = .unavailable
            explainBar.message = reason
            explainBar.account = nil
        case .ready(let cli, let account):
            explainBar.state = .ready
            explainBar.account = account.label
            if let fresh {
                // From the run loop, not this main-queue block: the notice's
                // modal loop would hold every other main-queue block (a
                // terminal's output) until it closes.
                isAskingToExplain = true
                RunLoop.main.perform(inModes: [.default]) { [weak self] in
                    MainActor.assumeIsolated { self?.start(fresh: fresh, cli: cli, account: account) }
                }
            }
        }
        sendExplainBar()
    }

    /// The page's Explain: only the files whose patch changed since the
    /// last explanation, or every file (`fresh`). claude and its account
    /// are checked first, and the user confirms what goes where.
    func explain(fresh: Bool) {
        guard snapshot != nil, activeExplain == nil, explainAfterCheck == nil, !isAskingToExplain else { return }
        explainBar.message = nil
        explainAfterCheck = fresh
        if isCheckingExplain {
            explainBar.state = .checking
            return sendExplainBar()
        }
        checkExplain()
    }

    private func start(fresh: Bool, cli: BranchReview.ClaudeCLI, account: BranchReview.ExplainAccount) {
        defer { isAskingToExplain = false }
        guard let asked = snapshot else { return sendExplainBar() }
        let bar = BranchReview.explainBar(explainBar, snapshot: asked, explanation: explanation)
        let files = fresh || !bar.explained ? bar.sendable : bar.changed + bar.unexplained
        guard confirmExplain(account, files) else { return sendExplainBar() }
        // Reads went on while the user read the notice: the page may show
        // a later head now, but not another branch.
        guard let snapshot = self.snapshot, snapshot.branch == asked.branch else { return sendExplainBar() }
        var job = BranchReview.ExplainJob(snapshot: snapshot, handover: handover, cli: cli)
        job.includeUntracked = explainBar.includeUntracked
        job.fresh = fresh
        job.requiresSubscription = !account.isBilledPerCall
        explainCount += 1
        let number = explainCount
        activeExplain = number
        explainCancelled = false
        explainBar.state = .queued
        explainBar.progress = nil
        let ticket = explainQueue.submit(
            worktree: ExplainQueue.worktreeKey(snapshot.root),
            Self.explainWork(job, explainer: explainer) { [weak self] progress in
                self?.explainProgressed(progress, number: number)
            },
            onStart: { [weak self] in self?.explainStarted(number: number) },
            completion: { [weak self, branch = snapshot.branch] result in
                self?.explainEnded(result, number: number, branch: branch)
            }
        )
        // A worktree being cleaned up drops it at once.
        guard activeExplain == number else { return }
        explainTicket = ticket
        sendExplainBar()
    }

    private func explainStarted(number: Int) {
        guard activeExplain == number else { return }
        explainBar.state = explainCancelled ? .stopping : .running
        explainBar.progress = .init(part: 1, parts: 1, reads: 0, retries: 0, startedAt: Date().timeIntervalSince1970 * 1000)
        sendExplainBar()
    }

    private func explainProgressed(_ progress: BranchReview.ExplainJobProgress, number: Int) {
        guard activeExplain == number, let startedAt = explainBar.progress?.startedAt else { return }
        explainBar.progress = .init(
            part: progress.part, parts: progress.parts, reads: progress.run.toolUses, retries: progress.run.retries,
            startedAt: startedAt
        )
        sendExplainBar()
    }

    private func explainEnded(_ result: BranchReview.ExplainResult?, number: Int, branch: String) {
        guard activeExplain == number else { return }
        let stoppedForCleanUp = explainTicket?.isStopped ?? !explainCancelled
        activeExplain = nil
        explainTicket = nil
        explainBar.progress = nil
        explainBar.state = availability.map { if case .ready = $0 { return .ready } else { return .unavailable } } ?? .ready
        guard let result else {
            // Left the line: the user cancelled, or Clean Up stopped it.
            explainBar.message = explainCancelled ? nil : "Explain didn’t run: this worktree is being cleaned up."
            return sendExplainBar()
        }
        // Not another branch's: the column may have moved on to it.
        guard (snapshot?.branch ?? self.branch) == branch else { return sendExplainBar() }
        // The run wrote the review file: the column's copy is behind.
        reloadReview()
        explainBar.message = stoppedForCleanUp && result.ending == .stopped(.cancelled)
            ? "Explain stopped: this worktree is being cleaned up."
            : result.ending.message
        guard let explained = result.explanation else { return sendExplainBar() }
        explanationSetAt = Date()
        explanationBranch = branch
        // What waits behind a banner or a selection was read before.
        if pending?.snapshot.branch == branch { pending?.explanation = explained }
        if held?.snapshot.branch == branch { held?.explanation = explained }
        guard explained != explanation else { return sendExplainBar() }
        explanation = explained
        // The new groups and summaries: the page shows them, once the
        // user's selection goes.
        if pageHasSelection || snapshot == nil {
            explanationWaits = pageHasSelection
            sendExplainBar()
        } else {
            showCurrent()
            updateHeader()
        }
    }

    /// The page's Cancel, or the column closing: an Explain waiting leaves
    /// the line, one under way stops and keeps what it reported.
    func cancelExplain() {
        explainAfterCheck = nil
        guard let explainTicket else { return }
        explainCancelled = true
        if explainBar.state == .running { explainBar.state = .stopping }
        explainTicket.cancel()
        if activeExplain != nil { sendExplainBar() }
    }

    private func includeUntracked(_ include: Bool) {
        explainBar.includeUntracked = include
        sendExplainBar()
    }

    /// Explain's bar on the page shown, without drawing the page again.
    private func sendExplainBar() {
        updateHeader()
        guard let snapshot, status == nil else { return }
        let bar = BranchReview.explainBar(explainBar, snapshot: snapshot, explanation: explanation)
        guard let json = Self.encode(bar) else { return }
        view.showExplain(json: json)
    }

    // MARK: - Following the worktree

    /// A change the watcher saw. On screen, the branch is read again once
    /// changes stop for a moment; off screen, the column is stale.
    func worktreeChanged(_ change: GitRepositoryChange) {
        guard isStarted else { return }
        // git's own files changed: what follows isn't a build's churn.
        if change != .worktree { quietReads = 0 }
        if change == .remoteBranch { pushes += 1 }
        guard isOnScreen() else {
            isStale = true
            return
        }
        scheduleWatchedRead(after: change == .worktree ? watchTiming.settle : watchTiming.metadataSettle)
    }

    struct WatchTiming {
        /// How long files must stop changing before a read: an agent
        /// writes in bursts. git's own files (a commit, a checkout) settle
        /// sooner.
        var settle: TimeInterval = 2
        var metadataSettle: TimeInterval = 0.5
        /// A burst that never stops (a build writing in the worktree)
        /// still reads this often; twice as long after each read that
        /// found nothing new, up to `quietMaxWait`.
        var maxWait: TimeInterval = 8
        var quietMaxWait: TimeInterval = 64
    }

    var watchTiming = WatchTiming()

    /// The read comes once the burst settles, at its max wait at the
    /// latest, and no sooner than the last watched read's length after it
    /// ended: a slow repository isn't read back to back.
    private func scheduleWatchedRead(after delay: TimeInterval) {
        let now = Date()
        let started = burstStartedAt ?? now
        burstStartedAt = started
        let maxWait = min(watchTiming.maxWait * pow(2, Double(min(quietReads, 16))), max(watchTiming.maxWait, watchTiming.quietMaxWait))
        var due = min(now.addingTimeInterval(delay), started.addingTimeInterval(maxWait))
        due = max(due, lastWatchedReadEnded.addingTimeInterval(lastWatchedReadDuration))
        changeCount += 1
        let change = changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, due.timeIntervalSince(now))) { [weak self] in
            guard let self, change == self.changeCount else { return }
            self.readWatched()
        }
    }

    /// The column shows (its workspace came to the front, its window was
    /// uncovered): a stale one reads the branch again, once it has shown a
    /// moment.
    func becameVisible() {
        guard isStale, isStarted, burstStartedAt == nil, isOnScreen() else { return }
        scheduleWatchedRead(after: watchTiming.metadataSettle)
    }

    private func readWatched() {
        burstStartedAt = nil
        guard isOnScreen() else {
            isStale = true
            return
        }
        isStale = false
        read(fetchBase: false, reason: .watcher)
    }

    /// Watches the snapshot's root, or before the first one, the
    /// worktree's top level found by walking up to its `.git`. Finding it
    /// and its layout reads the disk (a sleeping volume can block): off the
    /// main thread, as the workspace's watcher does.
    private func watch() {
        guard view.window != nil else { return }
        let branch = snapshot?.branch ?? self.branch
        let root = snapshot?.root
        if let root, let watcher, watchedRoot == root {
            watcher.branch = branch
            return
        }
        watchRequest += 1
        let request = watchRequest
        Self.inBackground(on: .global(qos: .utility), { [worktree] () -> (String, GitRepositoryLayout)? in
            guard let found = root ?? Self.topLevel(of: worktree) else { return nil }
            return (found, GitRepositoryLayout.resolve(worktreeRoot: found))
        }) { [weak self] resolved in
            guard let self, request == self.watchRequest, self.view.window != nil, let (found, layout) = resolved else { return }
            if let watcher = self.watcher, self.watchedRoot == found {
                watcher.branch = branch
                return
            }
            self.stopWatching()
            self.watcher = self.makeWatcher(layout, branch) { [weak self] change in self?.worktreeChanged(change) }
            self.watchedRoot = found
        }
    }

    /// The nearest folder at or above `folder` that holds a `.git`, file
    /// or folder: what git calls the top level. Path strings, not URLs:
    /// older Foundations walk `/..` up forever.
    nonisolated static func topLevel(of folder: String) -> String? {
        guard folder.hasPrefix("/") else { return nil }
        var current = (folder as NSString).standardizingPath
        // A path has fewer components than this; the bound only makes sure.
        for _ in 0..<256 {
            if FileManager.default.fileExists(atPath: (current as NSString).appendingPathComponent(".git")) { return current }
            let parent = (current as NSString).deletingLastPathComponent
            guard !parent.isEmpty, parent != current else { return nil }
            current = parent
        }
        return nil
    }

    private func stopWatching() {
        watchRequest += 1
        watcher?.stop()
        watcher = nil
        watchedRoot = nil
    }

    /// The real watcher: FSEvents on the worktree and its git folders.
    static func watch(
        layout: GitRepositoryLayout, branch: String?, onChange: @escaping @MainActor (GitRepositoryChange) -> Void
    ) -> GitRepositoryWatcher? {
        GitRepositoryWatcher(layout: layout, branch: branch, onChange: onChange)
    }

    private func setSnapshot(_ snapshot: BranchReview.Snapshot?) {
        self.snapshot = snapshot
        readFiles = [:]
        snapshotCount += 1
        let count = snapshotCount
        currentGeneration.withLock { $0 = count }
    }

    private func showStatus(_ message: String, action: (title: String, perform: @MainActor () -> Void)? = nil) {
        // A page held for a selection was of before: the status replaces it.
        held = nil
        status = message
        statusAction = action
        view.showStatus(message, action: action?.title)
    }

    /// The page, or what it says instead; for a page that loads again too.
    private func showCurrent() {
        // Without a snapshot, a status always says why: reading, paused.
        guard let snapshot else {
            if let status { view.showStatus(status, action: statusAction?.title) }
            return
        }
        // Twice: the page shows why instead of loading again.
        guard view.crashes < 2 else {
            return showStatus("The review page stopped while showing this branch. Refresh to try again.")
        }
        status = nil
        statusAction = nil
        let page = BranchReview.page(
            for: snapshot, handover: handover, explanation: explanation, explain: explainBar, generation: snapshotCount,
            readAt: readAt, review: pageReview()
        )
        guard let json = Self.encode(page) else { return }
        view.show(pageJSON: json)
        // A page that loaded again keeps the banner of what waits.
        if let banner { view.showReload(banner.message, action: banner.action?.title) }
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
        Self.inBackground(on: patchQueue, { [patchReader, currentGeneration] () -> BranchReview.FileChange?? in
            // Queued for a page another replaced since: not read at all.
            guard currentGeneration.withLock({ $0 }) == generation else { return .none }
            return .some(patchReader(file, snapshot))
        }) { [weak self] outcome in
            guard let self, generation == self.snapshotCount, let read = outcome else { return }
            if let read, read.patchHash != self.snapshot?.files[safe: id]?.patchHash {
                // Its hash, for the Reviewed checkbox.
                self.readFiles[id] = read
                self.sendReview()
            }
            self.send(read.map { BranchReview.FileDiff(id: id, generation: generation, read: $0) } ?? BranchReview.FileDiff(
                id: id, path: file.path, generation: generation,
                message: "Nirux couldn’t read this file’s diff: it no longer differs from the base, or git failed. Refresh."
            ))
        }
    }

    // MARK: - The review file (sections 6.3 and 8)

    /// Opens the review of the snapshot shown, off the main thread: a
    /// write the page asks for after it runs after it, on the same queue.
    private func openReview(for snapshot: BranchReview.Snapshot) {
        let generation = snapshotCount
        Self.inBackground(on: reviewQueue, { [reviewFile] in reviewFile.open(snapshot) }) { [weak self] state in
            guard let self, generation == self.snapshotCount else { return }
            self.apply(state)
        }
    }

    /// Reads the review file again, without opening it: after a writer
    /// that isn't this column (Explain) saved it.
    func reloadReview() {
        Self.inBackground(on: reviewQueue, { [reviewFile] in reviewFile.reload() }) { [weak self] state in
            guard let self, let state, state.branch == self.snapshot?.branch else { return }
            self.apply(state)
        }
    }

    /// Changes the stored review of the branch shown now, off the main
    /// thread, after what was asked before: under its lock, on the review
    /// as it is on disk. Changes asked for meanwhile are written together.
    /// Dropped if another branch shows by then. Nothing is written once
    /// the branch is gone, or while the review is read-only: the page says
    /// why. `completion` gets the review after the write, failed or not.
    func writeReview(
        _ change: @escaping @Sendable (inout BranchReview.Record) -> Void,
        completion: (@MainActor (BranchReviewState) -> Void)? = nil
    ) {
        guard let branch = snapshot?.branch else {
            completion?(review ?? BranchReviewState(
                branch: "", record: BranchReview.Record(), isKnown: false, problem: "No branch is shown.", canWrite: false
            ))
            return
        }
        reviewWrites += 1
        let id = reviewWrites
        writeCompletions[id] = completion
        reviewFile.enqueue(id: id, branch: branch, change)
        Self.inBackground(on: reviewQueue, { [reviewFile] in reviewFile.write(through: id) }) { [weak self] written in
            guard let self, let (ids, state) = written else { return }
            if state.branch == self.snapshot?.branch { self.apply(state) }
            for id in ids { self.writeCompletions.removeValue(forKey: id)?(state) }
        }
    }

    private func apply(_ state: BranchReviewState) {
        guard state != review else { return }
        review = state
        sendReview()
        onReviewChange?()
    }

    /// The page's Reviewed checkboxes: `ids` are its file ids, read against
    /// its generation; `sequence` counts its clicks. Each click is
    /// answered, written or not, so that the page shows the review again.
    private func markReviewed(ids: [Int], reviewed: Bool, generation: Int, sequence: Int) {
        let files = generation == snapshotCount
            ? ids.compactMap { id in snapshot?.files.indices.contains(id) == true ? readFiles[id] ?? snapshot?.files[id] : nil }
            : []
        guard !files.isEmpty, let head = snapshot?.head else { return acknowledge(sequence) }
        let date = Date()
        writeReview({ record in
            if reviewed {
                record.markReviewed(files, head: head, at: date)
            } else {
                record.clearReviewed(paths: files.map(\.path))
            }
        }, completion: { [weak self] _ in self?.acknowledge(sequence) })
    }

    private func acknowledge(_ sequence: Int) {
        reviewAcknowledged = max(reviewAcknowledged, sequence)
        sendReview()
    }

    /// The review as the page shows it; nil until the branch shown has
    /// been opened. A review that couldn't be read has no states: the page
    /// shows why.
    private func pageReview() -> BranchReview.Page.Review? {
        guard let snapshot, let review, review.branch == snapshot.branch else { return nil }
        let files = review.isKnown ? snapshot.files.indices.map { readFiles[$0] ?? snapshot.files[$0] } : []
        return BranchReview.review(
            of: review.record, files: files, generation: snapshotCount, problem: review.problem, canWrite: review.canWrite,
            acknowledged: reviewAcknowledged
        )
    }

    private func sendReview() {
        guard status == nil, let review = pageReview(), let json = Self.encode(review) else { return }
        view.showReview(json: json)
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
        // A read the worktree's changes started stays quiet: an agent at
        // work would make the pill blink. A Refresh queued behind one shows.
        // An Explain is neutral too: nothing here waits on the user.
        let userReads = isReading && (readReason == .user || readAfterRead != nil)
        if userReads {
            view.header.status = ColumnHeaderView.Status("Reading", tone: .neutral)
        } else {
            switch explainBar.state {
            case .running, .stopping: view.header.status = ColumnHeaderView.Status("Explaining", tone: .neutral)
            case .queued: view.header.status = ColumnHeaderView.Status("Queued", tone: .neutral)
            case .checking, .unavailable, .ready: view.header.status = nil
            }
        }
    }

    static func pauseMessage(_ operation: BranchReview.Operation) -> String {
        switch operation {
        case .conflicts:
            return "This worktree has conflicts to resolve. The review comes back once they’re resolved."
        case .rebase, .merge, .cherryPick, .revert:
            return "A \(operation.rawValue) is in progress in this worktree. The review comes back once it’s over."
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
