import Foundation
import os

/// The tasks the Lead may have forgotten (docs/design/daily-pass.md,
/// "Forgotten tasks"): closable, waiting on a merge, or quiet. The digest
/// lists them; nothing here closes or tells anything.
extension DailyPass {
    /// A result nobody acted on, or a pull request green and mergeable
    /// nobody merged, after this long without activity.
    static let unattendedAfter: TimeInterval = 86_400
    /// Any other open task, after this long without activity.
    static let quietAfter: TimeInterval = 3 * 86_400
    /// The turn that sends a result rarely runs on longer: activity past it
    /// is new work.
    static let resultTurn: TimeInterval = 3600

    /// What the pass reads of an open task, from what Nirux already keeps.
    struct TaskActivity: Equatable, Sendable {
        var title: String
        var branch: String?
        /// list_tasks' words for a task that isn't the Lead's.
        var notYours: String?
        /// What its agent waits on the user for.
        var waitsOnUser: String?
        /// The sidebar's.
        var pullRequest: PRInfo?
        /// Its repository's base branch (`<remote>/HEAD`), when read.
        var repositoryBase: String?
        /// Its last agent hook event (`WorkspaceState.lastActivityAt`).
        var lastTurnAt: TimeInterval?
        /// Its HEAD's committer date.
        var lastCommitAt: TimeInterval?
        /// Its result, when nothing came after it (`resultAt`).
        var resultAt: TimeInterval?

        /// The newest start of its pull request's checks: a push starts them.
        var lastPushAt: TimeInterval? {
            pullRequest?.checks.compactMap { $0.startedAt.flatMap(time(fromISO:)) }.max()
        }

        /// Its latest turn, commit or push, and which.
        var lastActivity: (time: TimeInterval, what: String)? {
            [(lastTurnAt, "a turn"), (lastCommitAt, "a commit"), (lastPushAt, "a push")]
                .compactMap { time, what in time.map { ($0, what) } }
                .max { $0.0 < $1.0 }
        }
    }

    struct ForgottenTask: Equatable, Sendable {
        enum Kind: Int, Comparable, Sendable {
            case closable, waiting, quiet

            static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }
        }

        let kind: Kind
        /// When it became forgotten: news in a window that holds it. Nil for
        /// a merged or closed pull request: a merge is news when GitHub
        /// lists it in the window.
        let since: TimeInterval?
        let lastActivity: TimeInterval?
        let line: String
    }

    /// The time of the result a task's Missions (as their child) last
    /// sent, when no question followed it, nor a tell typed or still on its
    /// way. `Mission.status` doesn't say: a held tell typed after the
    /// result makes it active again.
    static func resultAt(_ missions: [Mission]) -> TimeInterval? {
        let events = missions.flatMap(\.events).filter { event in
            switch event.kind {
            case .completed, .question: true
            case .instruction: event.expiredAt == nil || event.childConsumedAt != nil
            case .response, .acknowledged: false
            }
        }
        guard let last = events.max(by: { $0.timestamp < $1.timestamp }), last.kind == .completed else { return nil }
        return last.timestamp
    }

    /// The tasks the Lead may have forgotten at `now`: closable, then
    /// waiting, then quiet, the longest without activity first.
    static func forgottenTasks(_ tasks: [TaskActivity], now: TimeInterval, timeZone: TimeZone = .current) -> [ForgottenTask] {
        tasks.compactMap { forgotten($0, now: now, timeZone: timeZone) }
            .sorted { ($0.kind, $0.lastActivity ?? -.infinity) < ($1.kind, $1.lastActivity ?? -.infinity) }
    }

    private static func forgotten(_ task: TaskActivity, now: TimeInterval, timeZone: TimeZone) -> ForgottenTask? {
        let last = task.lastActivity
        func entry(_ kind: ForgottenTask.Kind, after delay: TimeInterval?, _ reason: String, _ move: String) -> ForgottenTask {
            var line = "- “\(MissionPromptText.quoted(task.title))”"
            if let branch = task.branch { line += " · branch \(MissionPromptText.quoted(branch))" }
            if let notYours = task.notYours { line += " · \(notYours)" }
            let activity = last.map { "last activity \(clock($0.time, timeZone: timeZone)) (\($0.what)), \(duration(now - $0.time)) ago" }
            line += " · \(reason) · \(kind == .quiet ? "quiet: " : "")\(activity ?? "no activity recorded") → \(move)"
            let since = delay.flatMap { delay in last.map { $0.time + delay } }
            return ForgottenTask(kind: kind, since: since, lastActivity: last?.time, line: line)
        }
        let pull = task.pullRequest
        if let pull, ["MERGED", "CLOSED"].contains(pull.state) {
            return entry(.closable, after: nil, "PR #\(pull.number) " + (pull.state == "MERGED" ? "merged" : "closed unmerged"), "close_task")
        }
        guard let last else { return nil }
        let idle = now - last.time
        if pull == nil, let result = task.resultAt, last.time <= result + resultTurn {
            guard idle >= unattendedAfter else { return nil }
            let reason = "result sent \(clock(result, timeZone: timeZone)), nothing since, no pull request"
            return entry(.closable, after: unattendedAfter, reason, "close_task")
        }
        if let pull, isWaiting(pull, repositoryBase: task.repositoryBase) {
            guard idle >= unattendedAfter else { return nil }
            return entry(.waiting, after: unattendedAfter, "PR #\(pull.number) green and mergeable, unmerged", "ask the user to merge it")
        }
        guard idle >= quietAfter else { return nil }
        let move = task.waitsOnUser.map { "ask the user: it waits on them (\($0))" }
            ?? (task.notYours == nil ? "tell it what comes next, or close_task if it was dropped" : "ask the user")
        return entry(.quiet, after: quietAfter, pull.map { openPullRequest($0, repositoryBase: task.repositoryBase) } ?? "no pull request", move)
    }

    /// Open, green, mergeable, no draft, and on its repository's base
    /// branch as the Board reads it: a stacked one waits for its parent, a
    /// base gh or git didn't name holds nothing back.
    private static func isWaiting(_ pull: PRInfo, repositoryBase: String?) -> Bool {
        pull.state == "OPEN" && !pull.isDraft && pull.ciStatus == "SUCCESS" && pull.mergeable == "MERGEABLE"
            && isOnBase(pull, repositoryBase: repositoryBase)
    }

    private static func isOnBase(_ pull: PRInfo, repositoryBase: String?) -> Bool {
        repositoryBase == nil || pull.baseRefName == nil || pull.baseRefName == repositoryBase
    }

    /// "PR #602 open, checks failing, conflicting".
    private static func openPullRequest(_ pull: PRInfo, repositoryBase: String?) -> String {
        let checks = ["FAILURE": "checks failing", "PENDING": "checks running", "SUCCESS": "checks green"]
        let details = [
            pull.ciStatus.flatMap { checks[$0] }, pull.mergeable == "CONFLICTING" ? "conflicting" : nil,
            isOnBase(pull, repositoryBase: repositoryBase) ? nil : pull.baseRefName.map { "on \(MissionPromptText.quoted($0))" }
        ].compactMap { $0 }
        return "PR #\(pull.number) \(pull.isDraft ? "draft" : "open")" + details.map { ", " + $0 }.joined()
    }

    /// Each folder's HEAD committer date, the folders read at once; nil
    /// where git can't say. Never on the main thread.
    static func commitTimes(_ folders: [String]) -> [TimeInterval?] {
        let times = OSAllocatedUnfairLock(initialState: [Int: TimeInterval]())
        DispatchQueue.concurrentPerform(iterations: folders.count) { index in
            let output = GitCommand.output(["log", "-1", "--format=%ct", "HEAD"], cwd: folders[index], timeout: 10)
            guard let time = output.flatMap({ TimeInterval($0.trimmingCharacters(in: .whitespacesAndNewlines)) }) else { return }
            times.withLock { $0[index] = time }
        }
        return times.withLock { found in folders.indices.map { found[$0] } }
    }

    /// Each folder's base branch (`<remote>/HEAD` of its GitHub base
    /// remote, as the Board reads it); a folder git can't tell is left out.
    /// Never on the main thread.
    static func baseBranches(_ remotes: [(folder: String, read: GitHubBaseRemote.Read)]) -> [String: String] {
        var bases: [String: String] = [:]
        for (folder, read) in remotes {
            guard case .gitHub(_, let remote) = read, let base = BoardConfigSuggestions.defaultBranch(of: remote, at: folder) else { continue }
            bases[folder] = base
        }
        return bases
    }

    /// The tasks read on the main thread, with what was read of them off
    /// it: each one's last commit (`Reads.commits`, in order) and its
    /// repository's base branch.
    static func tasks(_ tasks: [(activity: TaskActivity, repository: String?)], with reads: Reads) -> [TaskActivity] {
        zip(tasks, reads.commits).map { task, commit in
            var activity = task.activity
            activity.lastCommitAt = commit
            activity.repositoryBase = task.repository.flatMap { reads.bases[$0] }
            return activity
        }
    }

    /// What the pass reads off the main thread.
    struct Reads: Sendable {
        var repositories: [RepositoryReport]
        var findings: [ReviewFindings.Entry]
        /// Each task folder's HEAD committer date, in order.
        var commits: [TimeInterval?]
        /// Each repository folder's base branch.
        var bases: [String: String]
    }
}
