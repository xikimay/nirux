import Foundation

/// Whether a pull request holds a result Nirux waits for, so the Mac stays
/// awake for it (`KeepAwakeController.isAwaitingChecks`): checks running, a
/// push not read yet, or a red read a follow-up round may still answer. Each
/// head counts for a while only, from the first read that showed it so: a
/// check that never ends (a status never posted, a job waiting for an
/// approval) lets the Mac sleep again.
struct ChecksWatch: Equatable, Sendable {
    struct Read: Equatable, Sendable {
        let id: String
        let pullRequest: PRInfo?
        /// Epoch seconds of the last read; nil: none yet.
        let readAt: TimeInterval?
        /// A push less than `PullRequestRefreshPolicy.pushFollowUp` ago:
        /// the read that shows its checks is still to come.
        let pushedRecently: Bool
    }

    /// A read older than this tells nothing: an archived workspace's, or
    /// `gh` failing.
    static let readWindow: TimeInterval = 600
    /// Checks running this long on one head never end.
    static let pendingLimit: TimeInterval = 3 * 3_600
    /// A follow-up round answers a red read within this: its wait, a
    /// background read, the triage.
    static let failureLimit: TimeInterval = 900

    private struct Seen: Equatable, Sendable {
        let state: String
        let at: TimeInterval
    }

    /// Each pull request's head and status, and when a read first showed them.
    private var seen: [String: Seen] = [:]

    mutating func awaits(_ reads: [Read], now: TimeInterval) -> Bool {
        var next: [String: Seen] = [:]
        var awaits = false
        for read in reads {
            // Until a read says its checks settled (a fetch moves the branch too).
            if read.pushedRecently, read.pullRequest?.ciStatus.map({ Self.limit($0) != nil }) ?? true { awaits = true }
            guard let pullRequest = read.pullRequest, pullRequest.state == .open, let readAt = read.readAt,
                  let status = pullRequest.ciStatus, let limit = Self.limit(status)
            else { continue }
            let state = (pullRequest.headRefOid ?? pullRequest.url) + " " + status
            // A stale read holds nothing, but keeps when its state was first seen.
            let first = seen[read.id].flatMap { $0.state == state ? $0.at : nil } ?? readAt
            next[read.id] = Seen(state: state, at: first)
            if now - readAt < Self.readWindow, now - first < limit { awaits = true }
        }
        seen = next
        return awaits
    }

    private static func limit(_ status: String) -> TimeInterval? {
        switch status {
        case "PENDING": pendingLimit
        case "FAILURE": failureLimit
        default: nil
        }
    }
}
