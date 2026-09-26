import Foundation

/// Per-workspace scheduling of git-context and pull-request refreshes.
/// Owns one FSEvents watcher per followed repository, remembers what
/// changed since the last read, and decides on each heartbeat which
/// workspaces are due (see `GitRefreshPolicy` / `PullRequestRefreshPolicy`).
@MainActor
final class GitRefreshCoordinator {
    typealias WatcherFactory = @MainActor (
        _ layout: GitRepositoryLayout,
        _ branch: String?,
        _ onChange: @escaping @MainActor (GitRepositoryChange) -> Void
    ) -> GitRepositoryWatcher?
    /// Starts an asynchronous git-context read of `workspace` at the given
    /// working directory and reports its outcome; false when one is already
    /// in flight.
    typealias ObservationStarter = @MainActor (
        _ workspace: WorkspaceState,
        _ workingDirectory: String,
        _ completion: @escaping @MainActor @Sendable (GitContextDetectionResult) -> Void
    ) -> Bool
    /// Resolves a repository's layout (filesystem reads: may block on a
    /// sleeping or network volume) and delivers it on the main actor.
    typealias LayoutResolver = @MainActor (
        _ worktreeRoot: String,
        _ completion: @escaping @MainActor @Sendable (GitRepositoryLayout) -> Void
    ) -> Void

    /// A stream that failed to start is retried this often; the fallback
    /// poll covers the repository meanwhile.
    static let watcherRetryInterval: TimeInterval = 30

    @MainActor
    private final class Entry {
        weak var workspace: WorkspaceState?
        var tier: GitRefreshTier = .background
        var watcher: GitRepositoryWatcher?
        /// Repository the watcher follows, or is being set up for.
        var watchedRoot: String?
        var watcherGeneration: UInt64 = 0
        var watcherRetryAfter: TimeInterval?
        var watcherFailedRoot: String?
        var pendingChange: GitRepositoryChange?
        var lastGitRefresh: TimeInterval?
        var lastGitDirectory: String?
        var lastPullRequestRefresh: TimeInterval?
        var pushFollowUpUntil: TimeInterval?
        var pullRequestNotBefore: TimeInterval?
        var lastReadFailed = false
        var changedSinceDiffStats = false
        var diffStatsInFlight = 0
        var lastDiffStatsRefresh: TimeInterval?

        init(workspace: WorkspaceState) {
            self.workspace = workspace
        }
    }

    /// The heartbeat stops while the app is inactive; events that arrive
    /// meanwhile are only recorded and handled on resume.
    var isSuspended = false

    private var entries: [ObjectIdentifier: Entry] = [:]
    private let clock: @MainActor () -> TimeInterval
    private let makeWatcher: WatcherFactory
    private let startObservation: ObservationStarter
    private let resolveLayout: LayoutResolver

    init(
        clock: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        makeWatcher: @escaping WatcherFactory = { layout, branch, onChange in
            GitRepositoryWatcher(layout: layout, branch: branch, onChange: onChange)
        },
        startObservation: @escaping ObservationStarter = GitRefreshCoordinator.observeGitContext,
        resolveLayout: @escaping LayoutResolver = GitRefreshCoordinator.resolveLayoutInBackground
    ) {
        self.clock = clock
        self.makeWatcher = makeWatcher
        self.startObservation = startObservation
        self.resolveLayout = resolveLayout
    }

    /// Heartbeat: follow the listed workspaces, drop the others, and start
    /// the git reads that are due.
    func tick(_ workspaces: [(workspace: WorkspaceState, tier: GitRefreshTier)]) {
        let now = clock()
        var followed = Set<ObjectIdentifier>()
        for (workspace, tier) in workspaces {
            followed.insert(ObjectIdentifier(workspace))
            let entry = entry(for: workspace)
            entry.tier = tier
            reconcileWatcher(entry, workspace: workspace)
            refreshIfDue(entry, workspace: workspace, now: now, force: false)
        }
        for (id, entry) in entries where !followed.contains(id) {
            entry.watcher?.stop()
            entries[id] = nil
        }
    }

    /// Read now regardless of throttles: the workspace just gained focus,
    /// was revived from the archive, or its focused column changed.
    func refreshNow(_ workspace: WorkspaceState, tier: GitRefreshTier) {
        let entry = entry(for: workspace)
        entry.tier = tier
        reconcileWatcher(entry, workspace: workspace)
        refreshIfDue(entry, workspace: workspace, now: clock(), force: true)
    }

    /// The workspace's repository or branch may have moved: retarget its
    /// watcher right away instead of waiting for the next tick.
    func gitContextChanged(_ workspace: WorkspaceState) {
        guard let entry = entries[ObjectIdentifier(workspace)] else { return }
        reconcileWatcher(entry, workspace: workspace)
    }

    func pullRequestsDue(
        _ workspaces: [(workspace: WorkspaceState, tier: GitRefreshTier)]
    ) -> [WorkspaceState] {
        let now = clock()
        return workspaces.compactMap { workspace, tier in
            guard PRDetect.shouldRefresh(isInactive: workspace.isInactive, branch: workspace.gitBranch)
            else { return nil }
            let entry = entries[ObjectIdentifier(workspace)]
            if let notBefore = entry?.pullRequestNotBefore, now < notBefore { return nil }
            return PullRequestRefreshPolicy.isDue(
                tier: tier,
                pullRequest: workspace.prInfo,
                recentlyPushed: (entry?.pushFollowUpUntil ?? -.infinity) > now,
                lastRefresh: entry?.lastPullRequestRefresh,
                now: now
            ) ? workspace : nil
        }
    }

    func notePullRequestRefresh(_ workspace: WorkspaceState) {
        entry(for: workspace).lastPullRequestRefresh = clock()
    }

    /// Diff stats are recomputed with every PR refresh; in between, only
    /// after working-tree or metadata changes, at the tier's diff cadence.
    func diffStatsDue(
        _ workspaces: [(workspace: WorkspaceState, tier: GitRefreshTier)]
    ) -> [WorkspaceState] {
        let now = clock()
        return workspaces.compactMap { workspace, tier in
            guard PRDetect.shouldRefresh(isInactive: workspace.isInactive, branch: workspace.gitBranch),
                  let entry = entries[ObjectIdentifier(workspace)]
            else { return nil }
            // A slow repository must not pile up overlapping diffs.
            guard entry.diffStatsInFlight == 0 else { return nil }
            return GitRefreshPolicy.isDiffStatsDue(
                tier: tier,
                changedSinceLastRefresh: entry.changedSinceDiffStats,
                lastRefresh: entry.lastDiffStatsRefresh,
                now: now
            ) ? workspace : nil
        }
    }

    func noteDiffStatsRefresh(_ workspace: WorkspaceState) {
        let entry = entry(for: workspace)
        entry.changedSinceDiffStats = false
        entry.lastDiffStatsRefresh = clock()
        entry.diffStatsInFlight += 1
    }

    func finishDiffStatsRefresh(_ workspace: WorkspaceState) {
        guard let entry = entries[ObjectIdentifier(workspace)] else { return }
        entry.diffStatsInFlight = max(0, entry.diffStatsInFlight - 1)
    }

    /// Watcher callback, also the seam unit tests drive.
    func noteChange(_ change: GitRepositoryChange, for workspace: WorkspaceState) {
        guard let entry = entries[ObjectIdentifier(workspace)] else { return }
        if change == .remoteBranch {
            // A push (or fetch) of this branch: ask GitHub once it has had a
            // moment to move the PR's head, then follow it closely while CI
            // starts.
            let now = clock()
            entry.lastPullRequestRefresh = nil
            entry.pullRequestNotBefore = now + PullRequestRefreshPolicy.pushSettleDelay
            entry.pushFollowUpUntil = now + PullRequestRefreshPolicy.pushFollowUp
            return
        }
        entry.changedSinceDiffStats = true
        entry.pendingChange = max(entry.pendingChange ?? change, change)
        // An FSEvents flood (a build writing thousands of files) lands here
        // once per batch: decide on the throttle alone before resolving the
        // working directory; the tick catches directory changes.
        let now = clock()
        guard !isSuspended, entry.tier == .focused, GitRefreshPolicy.isDue(
            tier: entry.tier,
            pendingChange: entry.pendingChange,
            workingDirectoryChanged: false,
            lastRefresh: entry.lastGitRefresh,
            now: now
        ) else { return }
        refreshIfDue(entry, workspace: workspace, now: now, force: true)
    }

    static func resolveLayoutInBackground(
        _ worktreeRoot: String,
        completion: @escaping @MainActor @Sendable (GitRepositoryLayout) -> Void
    ) {
        DispatchQueue.global(qos: .utility).async {
            let layout = GitRepositoryLayout.resolve(worktreeRoot: worktreeRoot)
            DispatchQueue.main.async { completion(layout) }
        }
    }

    static func observeGitContext(
        of workspace: WorkspaceState,
        at workingDirectory: String,
        completion: @escaping @MainActor @Sendable (GitContextDetectionResult) -> Void
    ) -> Bool {
        guard let observation = workspace.beginGitContextObservation(at: workingDirectory) else {
            return false
        }
        GitDetect.contextAsync(at: workingDirectory) { [weak workspace] result in
            // A superseded read's outcome says nothing about the current one.
            guard let workspace,
                  workspace.applyGitContextObservation(result, observation: observation) != .stale
            else { return }
            completion(result)
        }
        return true
    }

    private func entry(for workspace: WorkspaceState) -> Entry {
        let id = ObjectIdentifier(workspace)
        if let entry = entries[id], entry.workspace === workspace { return entry }
        entries[id]?.watcher?.stop()
        let entry = Entry(workspace: workspace)
        entries[id] = entry
        return entry
    }

    private func refreshIfDue(_ entry: Entry, workspace: WorkspaceState, now: TimeInterval, force: Bool) {
        // Archived workspaces are read once so their card isn't blank,
        // then left alone (retried only if that read failed): skip even the
        // working-directory lookup.
        if !force, entry.tier == .archived, entry.lastGitRefresh != nil, !entry.lastReadFailed { return }
        let directory = URL(fileURLWithPath: workspace.focusedWorkingDirectory).standardizedFileURL.path
        let isDue = force || GitRefreshPolicy.isDue(
            tier: entry.tier,
            pendingChange: entry.pendingChange,
            workingDirectoryChanged: directory != entry.lastGitDirectory,
            lastRefresh: entry.lastGitRefresh,
            lastReadFailed: entry.lastReadFailed,
            now: now
        )
        // An in-flight read may predate the pending change: keep it pending
        // and retry on the next tick.
        guard isDue, startObservation(workspace, directory, { [weak entry] result in
            entry?.lastReadFailed = result == .failure
        }) else { return }
        entry.pendingChange = nil
        entry.lastGitRefresh = now
        entry.lastGitDirectory = directory
    }

    private func reconcileWatcher(_ entry: Entry, workspace: WorkspaceState) {
        let root = entry.tier == .archived ? nil : workspace.gitContext?.identity.repositoryRoot
        guard root != entry.watchedRoot else {
            entry.watcher?.branch = workspace.gitContext?.branch
            return
        }
        if let root, root == entry.watcherFailedRoot,
           let retryAfter = entry.watcherRetryAfter, clock() < retryAfter {
            // Back to the failed repository during its backoff: drop any
            // watcher or pending setup for the repository just left.
            entry.watcher?.stop()
            entry.watcher = nil
            entry.watchedRoot = nil
            entry.watcherGeneration &+= 1
            return
        }
        entry.watcher?.stop()
        entry.watcher = nil
        entry.watchedRoot = root
        entry.watcherGeneration &+= 1
        guard let root else { return }
        let generation = entry.watcherGeneration
        resolveLayout(root) { [weak self, weak entry] layout in
            // The target may have moved on while the layout was resolved.
            guard let self, let entry, entry.watcherGeneration == generation,
                  let workspace = entry.workspace else { return }
            self.startWatcher(entry, workspace: workspace, root: root, layout: layout)
        }
    }

    private func startWatcher(
        _ entry: Entry,
        workspace: WorkspaceState,
        root: String,
        layout: GitRepositoryLayout
    ) {
        let onChange: @MainActor (GitRepositoryChange) -> Void = { [weak self, weak workspace] change in
            guard let self, let workspace else { return }
            self.noteChange(change, for: workspace)
        }
        guard let watcher = makeWatcher(layout, workspace.gitContext?.branch, onChange) else {
            entry.watchedRoot = nil
            entry.watcherFailedRoot = root
            entry.watcherRetryAfter = clock() + Self.watcherRetryInterval
            return
        }
        entry.watcherFailedRoot = nil
        entry.watcherRetryAfter = nil
        entry.watcher = watcher
        // Changes between the read that found this repository and the
        // stream's start produced no event: read once more.
        entry.pendingChange = max(entry.pendingChange ?? .metadata, .metadata)
        entry.changedSinceDiffStats = true
    }
}
