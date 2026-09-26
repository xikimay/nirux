import Foundation

/// How closely a workspace's git and pull-request state is followed.
enum GitRefreshTier: Equatable, Sendable {
    /// On screen: the active workspace, or every workspace of the active
    /// profile in pilot mode.
    case focused
    /// Listed but not on screen: followed, with slower throttles.
    case background
    /// Parked by the user: read once, then only when revived or focused.
    case archived
}

/// When to re-read a workspace's git context. Filesystem events make
/// refreshes event-driven; the intervals only throttle bursts (an agent
/// editing files continuously) and bound staleness when an event is missed.
enum GitRefreshPolicy {
    struct Intervals: Equatable, Sendable {
        /// Minimum spacing after HEAD, index, branch-ref or config changes.
        let metadata: TimeInterval
        /// Minimum spacing after working-tree edits (dirty bit only).
        let worktree: TimeInterval
        /// Safety-net poll for changes FSEvents cannot see (global git
        /// config, excludes files, dropped events).
        let fallback: TimeInterval
    }

    static func intervals(for tier: GitRefreshTier) -> Intervals? {
        switch tier {
        case .focused: Intervals(metadata: 1, worktree: 4, fallback: 30)
        case .background: Intervals(metadata: 5, worktree: 20, fallback: 120)
        case .archived: nil
        }
    }

    static func isDue(
        tier: GitRefreshTier,
        pendingChange: GitRepositoryChange?,
        workingDirectoryChanged: Bool,
        lastRefresh: TimeInterval?,
        now: TimeInterval
    ) -> Bool {
        guard let lastRefresh else { return true }
        guard let intervals = intervals(for: tier) else { return false }
        if workingDirectoryChanged { return true }
        let elapsed = now - lastRefresh
        switch pendingChange {
        case .metadata: return elapsed >= intervals.metadata
        case .worktree: return elapsed >= intervals.worktree
        case nil: return elapsed >= intervals.fallback
        }
    }
}

/// When to ask GitHub about a workspace's pull request again. Local git
/// changes already trigger a refresh through the context-change path; this
/// cadence only catches remote-side changes (CI, reviews, merges, a PR
/// opened from the command line). Every `gh pr list` spends GraphQL quota
/// shared with the user's own `gh` usage.
enum PullRequestRefreshPolicy {
    static func interval(for tier: GitRefreshTier, pullRequest: PRInfo?) -> TimeInterval? {
        let checksPending = pullRequest?.ciStatus == "PENDING"
            && pullRequest?.state.uppercased() == "OPEN"
        switch tier {
        case .focused: return checksPending ? 30 : 120
        case .background: return checksPending ? 120 : 600
        case .archived: return nil
        }
    }

    static func isDue(
        tier: GitRefreshTier,
        pullRequest: PRInfo?,
        lastRefresh: TimeInterval?,
        now: TimeInterval
    ) -> Bool {
        guard let interval = interval(for: tier, pullRequest: pullRequest) else { return false }
        guard let lastRefresh else { return true }
        return now - lastRefresh >= interval
    }
}
