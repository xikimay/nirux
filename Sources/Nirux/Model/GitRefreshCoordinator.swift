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
    /// working directory; false when one is already in flight.
    typealias ObservationStarter = @MainActor (_ workspace: WorkspaceState, _ workingDirectory: String) -> Bool

    private final class Entry {
        weak var workspace: WorkspaceState?
        var tier: GitRefreshTier = .background
        var watcher: GitRepositoryWatcher?
        var watchedRoot: String?
        var pendingChange: GitRepositoryChange?
        var lastGitRefresh: TimeInterval?
        var lastGitDirectory: String?
        var lastPullRequestRefresh: TimeInterval?

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

    init(
        clock: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        makeWatcher: @escaping WatcherFactory = { layout, branch, onChange in
            GitRepositoryWatcher(layout: layout, branch: branch, onChange: onChange)
        },
        startObservation: @escaping ObservationStarter = GitRefreshCoordinator.observeGitContext
    ) {
        self.clock = clock
        self.makeWatcher = makeWatcher
        self.startObservation = startObservation
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
            let lastRefresh = entries[ObjectIdentifier(workspace)]?.lastPullRequestRefresh
            return PullRequestRefreshPolicy.isDue(
                tier: tier,
                pullRequest: workspace.prInfo,
                lastRefresh: lastRefresh,
                now: now
            ) ? workspace : nil
        }
    }

    func notePullRequestRefresh(_ workspace: WorkspaceState) {
        entry(for: workspace).lastPullRequestRefresh = clock()
    }

    /// Watcher callback, also the seam unit tests drive.
    func noteChange(_ change: GitRepositoryChange, for workspace: WorkspaceState) {
        guard let entry = entries[ObjectIdentifier(workspace)] else { return }
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

    static func observeGitContext(of workspace: WorkspaceState, at workingDirectory: String) -> Bool {
        guard let observation = workspace.beginGitContextObservation(at: workingDirectory) else {
            return false
        }
        GitDetect.contextAsync(at: workingDirectory) { [weak workspace] result in
            workspace?.applyGitContextObservation(result, observation: observation)
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
        // then left alone: skip even the working-directory lookup.
        if !force, entry.tier == .archived, entry.lastGitRefresh != nil { return }
        let directory = URL(fileURLWithPath: workspace.focusedWorkingDirectory).standardizedFileURL.path
        let isDue = force || GitRefreshPolicy.isDue(
            tier: entry.tier,
            pendingChange: entry.pendingChange,
            workingDirectoryChanged: directory != entry.lastGitDirectory,
            lastRefresh: entry.lastGitRefresh,
            now: now
        )
        // An in-flight read may predate the pending change: keep it pending
        // and retry on the next tick.
        guard isDue, startObservation(workspace, directory) else { return }
        entry.pendingChange = nil
        entry.lastGitRefresh = now
        entry.lastGitDirectory = directory
    }

    private func reconcileWatcher(_ entry: Entry, workspace: WorkspaceState) {
        let root = entry.tier == .archived ? nil : workspace.gitContext?.identity.repositoryRoot
        let branch = workspace.gitContext?.branch
        guard root != entry.watchedRoot else {
            entry.watcher?.branch = branch
            return
        }
        entry.watcher?.stop()
        entry.watcher = nil
        entry.watchedRoot = root
        guard let root else { return }
        let onChange: @MainActor (GitRepositoryChange) -> Void = { [weak self, weak workspace] change in
            guard let self, let workspace else { return }
            self.noteChange(change, for: workspace)
        }
        entry.watcher = makeWatcher(GitRepositoryLayout.resolve(worktreeRoot: root), branch, onChange)
    }
}
