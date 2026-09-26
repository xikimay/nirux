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
        /// Minimum spacing of `git diff --shortstat` after changes: the
        /// dirty bit alone does not move while an agent keeps editing.
        let diffStats: TimeInterval
    }

    /// An archived workspace whose one read produced no context (read
    /// failure, volume not mounted yet) is retried this slowly.
    static let archivedRetryInterval: TimeInterval = 120

    static func intervals(for tier: GitRefreshTier) -> Intervals? {
        switch tier {
        case .focused: Intervals(metadata: 1, worktree: 4, fallback: 30, diffStats: 10)
        case .background: Intervals(metadata: 5, worktree: 20, fallback: 120, diffStats: 60)
        case .archived: nil
        }
    }

    static func isDue(
        tier: GitRefreshTier,
        pendingChange: GitRepositoryChange?,
        workingDirectoryChanged: Bool,
        lastRefresh: TimeInterval?,
        hasContext: Bool = true,
        now: TimeInterval
    ) -> Bool {
        guard let lastRefresh else { return true }
        guard let intervals = intervals(for: tier) else {
            return !hasContext && now - lastRefresh >= archivedRetryInterval
        }
        if workingDirectoryChanged { return true }
        let elapsed = now - lastRefresh
        switch pendingChange {
        case .metadata: return elapsed >= intervals.metadata
        case .worktree: return elapsed >= intervals.worktree
        case .remoteBranch, nil: return elapsed >= intervals.fallback
        }
    }

    static func isDiffStatsDue(
        tier: GitRefreshTier,
        changedSinceLastRefresh: Bool,
        lastRefresh: TimeInterval?,
        now: TimeInterval
    ) -> Bool {
        guard changedSinceLastRefresh, let intervals = intervals(for: tier) else { return false }
        guard let lastRefresh else { return true }
        return now - lastRefresh >= intervals.diffStats
    }
}

/// When to ask GitHub about a workspace's pull request again. Local git
/// changes already trigger a refresh through the context-change path, and
/// a push triggers one right away; this cadence only catches remote-side
/// changes (CI, reviews, merges, a PR opened from the command line). Every
/// `gh pr list` spends GraphQL quota shared with the user's own `gh` usage.
enum PullRequestRefreshPolicy {
    /// After a push, follow the branch at the pending-CI cadence for this
    /// long: checks usually show up only after the first refresh.
    static let pushFollowUp: TimeInterval = 300
    /// Right after a push GitHub may still report the previous head.
    static let pushSettleDelay: TimeInterval = 10

    static func interval(
        for tier: GitRefreshTier,
        pullRequest: PRInfo?,
        recentlyPushed: Bool = false
    ) -> TimeInterval? {
        let checksPending = pullRequest?.ciStatus == "PENDING"
            && pullRequest?.state.uppercased() == "OPEN"
        let isHot = checksPending || recentlyPushed
        switch tier {
        case .focused: return isHot ? 30 : 120
        case .background: return isHot ? 120 : 600
        case .archived: return nil
        }
    }

    static func isDue(
        tier: GitRefreshTier,
        pullRequest: PRInfo?,
        recentlyPushed: Bool = false,
        lastRefresh: TimeInterval?,
        now: TimeInterval
    ) -> Bool {
        guard let interval = interval(for: tier, pullRequest: pullRequest, recentlyPushed: recentlyPushed)
        else { return false }
        guard let lastRefresh else { return true }
        return now - lastRefresh >= interval
    }
}
