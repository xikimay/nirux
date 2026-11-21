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
        struct Question: Equatable, Sendable {
            var id: String
            var handedToUser = false
        }

        /// Its workspace: what a later pass knows it by.
        var id: String
        var title: String
        var branch: String?
        /// list_tasks' "sub-task of": the task that started it.
        var parentTitle: String?
        /// list_tasks' words for a task that isn't the Lead's.
        var notYours: String?
        /// No repository: closing it moves its folder to the Trash.
        var isFolderTask = false
        /// What its agent waits on the user for.
        var waitsOnUser: String?
        /// The question to the Lead it waits on.
        var question: Question?
        /// The sidebar's, as last read.
        var pullRequest: PRInfo?
        /// When Nirux last read its pull request (or that it has none).
        var pullRequestReadAt: TimeInterval?
        /// GitHub's merged list has its pull request (`RepositoryReport.mergedLately`):
        /// newer than the sidebar's, which stops reading while Nirux is in
        /// the background.
        var mergedLately = false
        /// Its repository's base branch (`<remote>/HEAD`), when read.
        var repositoryBase: String?
        /// Its last agent hook event (`WorkspaceState.lastActivityAt`).
        var lastTurnAt: TimeInterval?
        /// The committer date of its newest commit not on its repository's
        /// base branch (of HEAD when that branch isn't known).
        var lastCommitAt: TimeInterval?
        /// Its result, when nothing came after it (`resultAt`).
        var resultAt: TimeInterval?

        /// The newest start of its pull request's checks: a push, or a rerun.
        var lastCheckRunAt: TimeInterval? {
            pullRequest?.checks.compactMap { $0.startedAt.flatMap(time(fromISO:)) }.max()
        }

        /// Its latest turn, commit or check run, and which.
        var lastActivity: (time: TimeInterval, what: String)? {
            [(lastTurnAt, "a turn"), (lastCommitAt, "a commit"), (lastCheckRunAt, "a check run")]
                .compactMap { time, what in time.map { ($0, what) } }
                .max { $0.0 < $1.0 }
        }

        /// No pull request, as read: a task whose branch was never read may
        /// have one.
        var hasNoPullRequest: Bool { pullRequest == nil && (isFolderTask || pullRequestReadAt != nil) }
    }

    struct ForgottenTask: Equatable, Sendable {
        enum Kind: Int, Comparable, Sendable {
            case closable, waiting, quiet

            static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }
        }

        let kind: Kind
        /// Its task, kind and last activity: a key the last read listed is
        /// no news.
        let key: String
        let lastActivity: TimeInterval?
        let line: String
    }

    /// The time of the result a task's Missions (as their child) last
    /// sent, when no question followed it, nor a tell typed after it or
    /// still on its way (a Lead's one-way tell too). `Mission.status`
    /// doesn't say: a held tell typed after the result makes it active again.
    static func resultAt(_ missions: [Mission]) -> TimeInterval? {
        let times = missions.flatMap(\.events).compactMap { event -> (TimeInterval, Bool)? in
            switch event.kind {
            case .completed: (event.timestamp, true)
            case .question: (event.timestamp, false)
            // When it was typed; one still on its way comes after anything.
            case .instruction: event.childConsumedAt.map { ($0, false) } ?? (event.expiredAt == nil ? (.infinity, false) : nil)
            case .response, .acknowledged: nil
            }
        }
        guard let last = times.max(by: { $0.0 < $1.0 }), last.1 else { return nil }
        return last.0
    }

    /// The tasks the Lead may have forgotten at `now`: closable, then
    /// waiting, then quiet, the longest without activity first.
    static func forgottenTasks(_ tasks: [TaskActivity], now: TimeInterval, timeZone: TimeZone = .current) -> [ForgottenTask] {
        tasks.compactMap { forgotten($0, now: now, timeZone: timeZone) }
            .sorted { ($0.kind, $0.lastActivity ?? -.infinity) < ($1.kind, $1.lastActivity ?? -.infinity) }
    }

    private static func forgotten(_ task: TaskActivity, now: TimeInterval, timeZone: TimeZone) -> ForgottenTask? {
        let last = task.lastActivity
        func entry(_ kind: ForgottenTask.Kind, _ reason: String, _ move: String) -> ForgottenTask {
            var line = "- “\(MissionPromptText.quoted(task.title))”"
            if let parent = task.parentTitle { line += " · sub-task of “\(MissionPromptText.quoted(parent))”" }
            if let branch = task.branch { line += " · branch \(MissionPromptText.quoted(branch))" }
            if let notYours = task.notYours { line += " · \(notYours)" }
            let activity = last.map { "last activity \(clock($0.time, timeZone: timeZone)) (\($0.what)), \(duration(now - $0.time)) ago" }
            line += " · \(reason) · \(kind == .quiet ? "quiet: " : "")\(activity ?? "no activity recorded") → \(move)"
            let key = "\(task.id) \(kind.rawValue) \(Int(last?.time ?? 0))"
            return ForgottenTask(kind: kind, key: key, lastActivity: last?.time, line: line)
        }
        // Not its own to close: its parent's, else the user's.
        let owner = task.notYours.map { _ in task.parentTitle.map { "tell “\(MissionPromptText.quoted($0))”, the task that started it" } ?? "ask the user" }
        let pull = task.pullRequest
        if let pull, task.mergedLately || pull.state == .merged {
            return entry(.closable, "PR #\(pull.number) merged", "close_task")
        }
        if let pull, pull.state == .closed {
            return entry(.closable, "PR #\(pull.number) closed unmerged", "ask the user whether it was dropped, then close_task")
        }
        guard let last else { return nil }
        if task.hasNoPullRequest, let result = task.resultAt, last.time <= result + resultTurn {
            // A day since the result, whatever came just before it.
            guard now - max(last.time, result) >= unattendedAfter else { return nil }
            let close = task.isFolderTask ? "close_task once the user has its result (its folder goes to the Trash)" : "close_task"
            return entry(.closable, "result sent \(clock(result, timeZone: timeZone)), nothing since, no pull request", owner ?? close)
        }
        let idle = now - last.time
        if let pull, isWaiting(pull, repositoryBase: task.repositoryBase) {
            guard idle >= unattendedAfter else { return nil }
            return entry(.waiting, "PR #\(pull.number) green and mergeable, unmerged", "ask the user to merge it")
        }
        guard idle >= quietAfter else { return nil }
        let reason = pull.map { openPullRequest($0, repositoryBase: task.repositoryBase) }
            ?? (task.hasNoPullRequest ? "no pull request" : "its pull request not read yet")
        return entry(.quiet, reason, quietMove(task, owner: owner))
    }

    /// What it waits on first: the user, through the Lead or in its
    /// terminal; then the Lead's answer; then its owner.
    private static func quietMove(_ task: TaskActivity, owner: String?) -> String {
        if let question = task.question {
            return question.handedToUser ? "ask the user: it waits on their answer to question \(question.id)" : "reply to its question \(question.id)"
        }
        if let wait = task.waitsOnUser { return "ask the user: it waits on them (\(wait))" }
        return owner ?? "tell it what comes next, or close_task if it was dropped"
    }

    /// Open, green (or with no check at all), mergeable, no draft, no
    /// change asked by a review, not set to merge by itself, and on its
    /// repository's base branch: a stacked one waits for its parent, a base
    /// gh or git didn't name holds nothing back.
    private static func isWaiting(_ pull: PRInfo, repositoryBase: String?) -> Bool {
        let green = pull.ciStatus == "SUCCESS" || (pull.ciStatus == nil && pull.checks.isEmpty)
        return pull.state == .open && !pull.isDraft && green && pull.mergeable == "MERGEABLE"
            && pull.reviewDecision != "CHANGES_REQUESTED" && !pull.autoMerges && isOnBase(pull, repositoryBase: repositoryBase)
    }

    private static func isOnBase(_ pull: PRInfo, repositoryBase: String?) -> Bool {
        repositoryBase == nil || pull.baseRefName == nil || pull.baseRefName == repositoryBase
    }

    /// "PR #602 open, checks failing, conflicting".
    private static func openPullRequest(_ pull: PRInfo, repositoryBase: String?) -> String {
        let checks = ["FAILURE": "checks failing", "PENDING": "checks running", "SUCCESS": "checks green"]
        let details = [
            pull.ciStatus.flatMap { checks[$0] }, pull.mergeable == "CONFLICTING" ? "conflicting" : nil,
            pull.reviewDecision == "CHANGES_REQUESTED" ? "changes requested" : nil, pull.autoMerges ? "set to merge by itself" : nil,
            isOnBase(pull, repositoryBase: repositoryBase) ? nil : pull.baseRefName.map { "on \(MissionPromptText.quoted($0))" }
        ].compactMap { $0 }
        return "PR #\(pull.number) \(pull.isDraft ? "draft" : "open")" + details.map { ", " + $0 }.joined()
    }

    /// A repository's base branch: `<remote>/HEAD` of its GitHub base remote.
    struct Base: Equatable, Sendable {
        var remote: String
        var branch: String

        var ref: String { "refs/remotes/\(remote)/\(branch)" }
    }

    /// Each folder's base branch; a folder git can't tell is left out.
    /// Never on the main thread.
    static func baseBranches(_ remotes: [(folder: String, read: GitHubBaseRemote.Read)]) -> [String: Base] {
        var bases: [String: Base] = [:]
        for (folder, read) in remotes {
            guard case .gitHub(_, let remote) = read, let branch = BoardConfigSuggestions.defaultBranch(of: remote, at: folder) else { continue }
            bases[folder] = Base(remote: remote, branch: branch)
        }
        return bases
    }

    /// Each folder's newest commit not on `base` (a full ref), by its
    /// committer date; of HEAD without a base. The folders are read at once;
    /// nil where git can't say, or for a branch with no commit of its own.
    /// Never on the main thread.
    static func commitTimes(_ folders: [(folder: String, base: String?)]) -> [TimeInterval?] {
        let times = OSAllocatedUnfairLock(initialState: [Int: TimeInterval]())
        DispatchQueue.concurrentPerform(iterations: folders.count) { index in
            let (folder, base) = folders[index]
            let output = GitCommand.output(["log", "-1", "--format=%ct", "HEAD"] + (base.map { ["--not", $0] } ?? []), cwd: folder, timeout: 10)
            guard let time = output.flatMap({ TimeInterval($0.trimmingCharacters(in: .whitespacesAndNewlines)) }) else { return }
            times.withLock { $0[index] = time }
        }
        return times.withLock { found in folders.indices.map { found[$0] } }
    }

    /// From when GitHub's merged list must reach for the tasks' pull
    /// requests: the oldest read of an open one, when it came before the
    /// window, a week back at most; nil when the window covers them.
    static func mergedSince(_ tasks: [TaskActivity], window: Window) -> TimeInterval? {
        guard let oldest = tasks.compactMap({ $0.pullRequest?.state == .open ? $0.pullRequestReadAt : nil }).min(),
              oldest < window.start
        else { return nil }
        return max(oldest, window.end - DailyPassState.longestWindow)
    }

    /// The tasks read on the main thread, with what was read of them off
    /// it: each one's last commit (`Reads.commits`, in order), its
    /// repository's base branch, and whether GitHub's merged list has its
    /// pull request.
    static func tasks(_ tasks: [(activity: TaskActivity, repository: String?)], with reads: Reads) -> [TaskActivity] {
        zip(tasks, reads.commits).map { task, commit in
            var activity = task.activity
            activity.lastCommitAt = commit
            activity.repositoryBase = task.repository.flatMap { reads.bases[$0]?.branch }
            if let pull = activity.pullRequest, let repository = GitHubRepository(pullRequestURL: pull.url) {
                activity.mergedLately = reads.repositories.contains { report in
                    GitHubRepository(ownerAndName: report.name) == repository && report.mergedLately.contains(pull.number)
                }
            }
            return activity
        }
    }

    /// What the pass reads off the main thread.
    struct Reads: Sendable {
        var repositories: [RepositoryReport]
        var findings: [ReviewFindings.Entry]
        /// Each task folder's last commit, in order.
        var commits: [TimeInterval?]
        /// Each repository folder's base branch.
        var bases: [String: Base]
    }
}
