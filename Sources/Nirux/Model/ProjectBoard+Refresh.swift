import Foundation

// MARK: - Cadence

extension ProjectBoard {
    enum Source: CaseIterable, Hashable, Sendable {
        /// `git worktree list` in the project's folders: local and cheap.
        case worktrees
        /// The batched `gh pr list --state open`.
        case openPullRequests
        /// `gh pr list --state merged`, for the "merged, clean up" rows.
        case mergedPullRequests
        /// The last run of the post-merge workflow on the base branch.
        case postMergeRun
    }

    /// When the board reads each source (docs/project-board.md, section 6):
    /// only while it is on screen; worktrees and open pull requests every
    /// 60 s, or 30 s while a check of an open pull request runs; merged
    /// pull requests every 10 minutes; the post-merge run every 5. A source
    /// being read isn't read again meanwhile. Times are seconds of a
    /// monotonic clock, injected (the board passes `ProjectBoard.clock()`).
    struct RefreshSchedule: Equatable {
        private(set) var lastStarted: [Source: TimeInterval] = [:]
        private(set) var inFlight: Set<Source> = []
        /// Expired while being read: the answer may predate the change, so
        /// the source is due again as soon as it lands.
        private(set) var expiredWhileReading: Set<Source> = []

        static func interval(of source: Source, hasPendingChecks: Bool) -> TimeInterval {
            switch source {
            case .worktrees: return 60
            case .openPullRequests: return hasPendingChecks ? 30 : 60
            case .mergedPullRequests: return 600
            case .postMergeRun: return 300
            }
        }

        /// The sources to read now, among `available` (the GitHub ones need
        /// a configured repository).
        func due(now: TimeInterval, onScreen: Bool, hasPendingChecks: Bool, available: Set<Source>) -> [Source] {
            guard onScreen else { return [] }
            return Source.allCases.filter { source in
                guard available.contains(source), !inFlight.contains(source) else { return false }
                guard let last = lastStarted[source] else { return true }
                return now - last >= Self.interval(of: source, hasPendingChecks: hasPendingChecks)
            }
        }

        mutating func start(_ source: Source, now: TimeInterval) {
            lastStarted[source] = now
            inFlight.insert(source)
        }

        mutating func finish(_ source: Source) {
            inFlight.remove(source)
            if expiredWhileReading.remove(source) != nil { lastStarted[source] = nil }
        }

        /// `source` is due at the next tick, or as soon as the read of it
        /// that is running lands.
        mutating func expire(_ source: Source) {
            if inFlight.contains(source) {
                expiredWhileReading.insert(source)
            } else {
                lastStarted[source] = nil
            }
        }

        /// A new project or config: everything is due at once, and reads
        /// still running answer for what the board no longer shows.
        mutating func reset() {
            lastStarted = [:]
            inFlight = []
            expiredWhileReading = []
        }

        /// Refresh: everything is due at once, but a read still running is
        /// not started again.
        mutating func makeEverythingDue() {
            lastStarted = [:]
        }
    }
}

extension ProjectBoard {
    /// Seconds of a monotonic clock that keeps counting while the Mac
    /// sleeps (unlike `systemUptime`): after a night asleep, everything is
    /// due.
    static func clock() -> TimeInterval {
        TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000
    }
}

// MARK: - Local repositories

extension ProjectBoard {
    struct LocalSnapshot: Equatable, Sendable {
        var repositories: [LocalRepository] = []
        /// Each folder read, as the rows compare paths (symlinks resolved).
        var folders: [String: String] = [:]
        /// The folders read that aren't there: their workspace's worktree
        /// was removed under it.
        var missingFolders: Set<String> = []
    }

    /// The repositories the project's folders are in, each listed once
    /// (by its first entry). Runs git: call it off the main thread.
    static func readLocal(folders: [String], tools: WorktreeCleanup.Tools = .installed) -> LocalSnapshot {
        var snapshot = LocalSnapshot()
        var listed: Set<String> = []
        var listedPaths: Set<String> = []
        for folder in folders where snapshot.folders[folder] == nil {
            let comparable = NiruxShellView.comparablePath(folder)
            snapshot.folders[folder] = comparable
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue else {
                snapshot.missingFolders.insert(folder)
                continue
            }
            // In a worktree already listed, unless a checkout of its own
            // starts there: its repository is known.
            let isListed = listedPaths.contains { ProjectBoard.contains($0, comparable) }
            guard !isListed || FileManager.default.fileExists(atPath: folder + "/.git"),
                  !listedPaths.contains(comparable),
                  let listing = WorktreeCleanup.worktreeListing(in: folder, tools: tools),
                  let first = listing.first,
                  listed.insert(NiruxShellView.comparablePath(first.path)).inserted
            else { continue }
            let worktrees = listing.map { entry -> WorktreeCleanup.ListedWorktree in
                var resolved = entry
                resolved.path = NiruxShellView.comparablePath(entry.path)
                // A folder deleted by hand that git doesn't flag yet: the
                // board would otherwise list again and again to see it go.
                if !entry.isBare, !FileManager.default.fileExists(atPath: entry.path) { resolved.isPrunable = true }
                return resolved
            }
            let remotes = WorktreeCleanup.git(["remote", "-v"], in: folder, tools: tools)
            listedPaths.formUnion(worktrees.map(\.path))
            snapshot.repositories.append(LocalRepository(
                worktrees: worktrees,
                remotes: remotes.status == 0 ? parseRemotes(remotes.stdout) : []
            ))
        }
        return snapshot
    }

    /// The GitHub repositories of `git remote -v`, each once.
    static func parseRemotes(_ output: String) -> [GitHubRepository] {
        var repositories: [GitHubRepository] = []
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: "\t", maxSplits: 1)
            guard fields.count == 2 else { continue }
            var url = String(fields[1])
            for suffix in [" (fetch)", " (push)"] where url.hasSuffix(suffix) { url.removeLast(suffix.count) }
            if let repository = GitHubRepository(remoteURL: url), !repositories.contains(repository) {
                repositories.append(repository)
            }
        }
        return repositories
    }
}
