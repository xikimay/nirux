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
    /// monotonic clock, injected (the board passes `systemUptime`).
    struct RefreshSchedule: Equatable {
        private(set) var lastStarted: [Source: TimeInterval] = [:]
        private(set) var inFlight: Set<Source> = []

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
        }

        /// `source` is due at the next tick, unless a read of it is running.
        mutating func expire(_ source: Source) {
            guard !inFlight.contains(source) else { return }
            lastStarted[source] = nil
        }

        /// Refresh, a new project or config: everything is due at once, and
        /// reads still running answer for what the board no longer shows.
        mutating func reset() {
            lastStarted = [:]
            inFlight = []
        }
    }
}

// MARK: - Local repositories

extension ProjectBoard {
    struct LocalSnapshot: Equatable, Sendable {
        var repositories: [LocalRepository] = []
        /// Each folder read, as the rows compare paths (symlinks resolved).
        var folders: [String: String] = [:]
    }

    /// The repositories the project's folders are in, each listed once
    /// (by its first entry). Runs git: call it off the main thread.
    static func readLocal(folders: [String], tools: WorktreeCleanup.Tools = .installed) -> LocalSnapshot {
        var snapshot = LocalSnapshot()
        var listed: Set<String> = []
        for folder in folders where snapshot.folders[folder] == nil {
            snapshot.folders[folder] = NiruxShellView.comparablePath(folder)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue,
                  let listing = WorktreeCleanup.worktreeListing(in: folder, tools: tools),
                  let first = listing.first,
                  listed.insert(NiruxShellView.comparablePath(first.path)).inserted
            else { continue }
            let worktrees = listing.map { entry -> WorktreeCleanup.ListedWorktree in
                var resolved = entry
                resolved.path = NiruxShellView.comparablePath(entry.path)
                return resolved
            }
            let remotes = WorktreeCleanup.git(["remote", "-v"], in: folder, tools: tools)
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
