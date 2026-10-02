import Foundation

/// The Project Board's merge queue (docs/project-board.md, section 3): it
/// merges a confirmed list of pull requests one at a time, waiting for the
/// required checks before each merge and for the post-merge workflow after
/// it, and stops at the first problem.
///
/// This file holds the pure types. `MergeQueue.Engine` is the state
/// machine; the `gh` client and its parsers are in `MergeQueue+GitHub`
/// and `MergeQueue+Parsing`; `MergeQueueDriver` runs the engine's
/// requests and `MergeQueueController` owns a project's queue.
enum MergeQueue {}

// MARK: - Entries

extension MergeQueue {
    /// A pull request as the user confirmed it at Start.
    struct ConfirmedEntry: Equatable, Sendable {
        let number: Int
        /// The head the confirmation sheet showed: the only one the queue
        /// merges, with the merge commits of its own branch updates on top.
        let head: String
        /// Its head branch, where the local checks look for a worktree.
        let branch: String
    }

    /// Where a pull request is in the queue (section 3.5).
    enum Step: Equatable, Codable, Sendable {
        case waiting
        case preflight
        /// A branch update was sent from this head.
        case updating(from: String)
        case waitingForChecks(String)
        /// A failed required check is being rerun on this head.
        case rerunning(String)
        /// The last checks before the merge, then the merge, of this head.
        case merging(String)
        /// Merged as this commit; the post-merge workflow runs on it.
        case waitingForPostMerge(String)
        case done
        case stopped(StopReason)

        var isActive: Bool {
            switch self {
            case .waiting, .done, .stopped: return false
            default: return true
            }
        }
    }

    struct Entry: Equatable, Codable, Sendable {
        let number: Int
        let confirmedHead: String
        var branch: String
        /// The confirmed head, then the head of each of the queue's own
        /// branch updates on top of it.
        var heads: [String]
        var step: Step = .waiting
        /// Branch updates made since Start: at most two.
        var updates = 0
        /// The one rerun of a failed required check was used.
        var hasRerun = false
        /// Its merge commit, once merged.
        var mergeCommit: String?

        init(_ confirmed: ConfirmedEntry) {
            number = confirmed.number
            confirmedHead = confirmed.head.lowercased()
            branch = confirmed.branch
            heads = [confirmed.head.lowercased()]
        }

        /// "waiting for the nightly of #52".
        func stepDescription(workflow: String?) -> String {
            let pr = "#\(number)"
            switch step {
            case .waiting: return "\(pr) waiting"
            case .preflight: return "checking \(pr)"
            case .updating: return "updating the branch of \(pr)"
            case .waitingForChecks: return "waiting for the checks of \(pr)"
            case .rerunning: return "rerunning the failed checks of \(pr)"
            case .merging: return "merging \(pr)"
            case .waitingForPostMerge:
                return "waiting for the \(MergeQueue.workflowLabel(workflow)) of \(pr)"
            case .done: return "\(pr) merged"
            case .stopped(let reason): return "\(pr) stopped: \(reason.message)"
            }
        }
    }

    /// "nightly" for `nightly.yml`.
    static func workflowLabel(_ workflow: String?) -> String {
        guard let workflow else { return "post-merge workflow" }
        return (workflow as NSString).deletingPathExtension
    }
}

// MARK: - Queue

extension MergeQueue {
    /// The queue's state (section 3.5). The confirmation belongs to the
    /// board (B3): the engine starts from a confirmed list.
    enum Phase: Equatable, Sendable {
        case idle
        case running
        /// A rate limit: reads resume at this time (`systemUptime`).
        case paused(until: TimeInterval)
        /// Stop was pressed while a mutating call ran: it stops once the
        /// call has answered.
        case stopping
        case stopped(StopReason)
        case finished

        /// Running, paused or stopping: holding the repository's lock.
        var isActive: Bool {
            switch self {
            case .running, .paused, .stopping: return true
            case .idle, .stopped, .finished: return false
            }
        }
    }

    /// Why the queue, or a pull request, stopped. `kind` is for code (the
    /// board offers "Ask Agent to Resolve" on a conflict); `message` is for
    /// the user and the journal.
    struct StopReason: Equatable, Codable, Sendable {
        enum Kind: String, Codable, Sendable {
            case user
            case interrupted
            case dryRun
            /// Start refused: gh, the rate limit, GitHub's merge queue.
            case setup
            /// GitHub didn't answer reads, or refused one.
            case github
            case notMergeable
            case changed
            case conflict
            case agentBusy
            case local
            case update
            case checks
            case merge
            case postMerge
        }

        let kind: Kind
        let message: String
        /// A page that shows the problem: two heads compared, a run.
        var url: String?

        /// A token that a gh error echoes never reaches the saved queue.
        init(kind: Kind, message: String, url: String? = nil) {
            self.kind = kind
            self.message = MergeQueue.redacted(message)
            self.url = url
        }
    }

    /// GitHub tokens (`ghp_…`, `gho_…`, `github_pat_…`) masked.
    static func redacted(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"\b(gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})"#,
            with: "[token]",
            options: .regularExpression
        )
    }
}

// MARK: - Requests

extension MergeQueue {
    /// What the engine asks the driver to read. A batch of them is read
    /// together, and answered together.
    enum Read: Hashable, Sendable {
        /// `gh auth status`.
        case auth
        /// `gh api rate_limit`, which costs nothing.
        case rateLimit
        /// Whether the base branch requires GitHub's merge queue.
        case baseMergeQueue
        case pullRequest(Int)
        /// The check runs and commit statuses of a commit.
        case checks(String)
        /// REST `compare/{base}...{head}`: each a branch or a commit.
        case compare(base: String, head: String)
        /// A commit's committer and parents.
        case commit(String)
        /// The post-merge workflow's runs on the base branch, any event.
        case baseRuns
        /// The post-merge workflow's push runs of a merge commit.
        case pushRuns(commit: String)
        /// The branch's local worktrees and the agents in them.
        case local(branch: String, head: String)
    }

    enum ReadResult: Equatable, Sendable {
        case signedIn
        case rateLimit(RateLimit)
        case baseMergeQueue(Bool)
        case pullRequest(PullRequestSnapshot)
        case checks(CommitChecks)
        /// Nil: GitHub doesn't know one of the commits (404).
        case comparison(Comparison?)
        case commit(CommitInfo)
        case runs([Run])
        case local(LocalState)
    }

    /// Why a batch of reads failed.
    enum ReadFailure: Error, Equatable, Sendable {
        case ghMissing
        case notSignedIn(String)
        /// The primary rate limit: reads resume at this time (`systemUptime`).
        case rateLimited(resumeAt: TimeInterval)
        case secondaryRateLimit
        /// GitHub answered with an error a retry won't change (a 404, a 422).
        case refused(String)
        /// No answer, a server error, or output Nirux can't read: retried.
        case transient(String)
    }

    enum Mutation: Equatable, Sendable {
        /// `PUT pulls/{n}/update-branch` with `expected_head_sha`.
        case updateBranch(number: Int, expectedHead: String)
        /// `gh run rerun <id> --failed`.
        case rerun(runID: Int)
        /// `gh pr merge <n> --<method> --match-head-commit <sha>`.
        case merge(number: Int, head: String, method: BoardConfig.MergeMethod)
    }

    enum MutationResult: Equatable, Sendable {
        /// gh exited 0.
        case sent
        /// GitHub refused it: its HTTP status when gh says, and its message.
        case refused(status: Int?, message: String)
        /// No clear answer (a timeout, a server error): it may have taken
        /// effect.
        case uncertain(String)
        case rateLimited(String)
        /// The dry-run client didn't send it: the command it would run, and
        /// why this build is a dry run.
        case dryRun(command: String, reason: String)

        var isUncertain: Bool {
            if case .uncertain = self { return true }
            return false
        }
    }

    struct Request: Equatable, Sendable {
        enum Action: Equatable, Sendable {
            /// Read these, after waiting `after` seconds.
            case read([Read], after: TimeInterval)
            /// Never sent twice: after a failure the engine reads again.
            case mutate(Mutation)
        }

        let id: Int
        let action: Action

        var isMutation: Bool {
            if case .mutate = action { return true }
            return false
        }
    }

    enum Event: Equatable, Sendable {
        case start
        case stop
        case read(requestID: Int, Result<[Read: ReadResult], ReadFailure>)
        case mutated(requestID: Int, MutationResult)
    }

    /// A line for the journal: what the engine decided, and on which pull
    /// request.
    struct Note: Equatable, Sendable {
        let number: Int?
        let step: String
        let message: String
    }
}

// MARK: - What GitHub says

extension MergeQueue {
    struct PullRequestSnapshot: Equatable, Sendable {
        let number: Int
        /// OPEN, MERGED or CLOSED.
        let state: String
        let isDraft: Bool
        let headRefName: String
        let headOid: String
        let baseRefName: String
        /// Nil when GitHub no longer knows it (a deleted fork).
        let headRepository: GitHubRepository?
        /// MERGEABLE, CONFLICTING or UNKNOWN (GitHub is computing it).
        let mergeable: String
        let hasAutoMerge: Bool
        let isInMergeQueue: Bool
        let mergeCommit: String?
        let mergeCommitParents: [String]
        let url: String

        var isOpen: Bool { state == "OPEN" }
    }

    struct CommitChecks: Equatable, Sendable {
        struct CheckRun: Equatable, Sendable {
            let id: Int
            let name: String
            /// The GitHub Actions workflow that made it; nil for another app.
            let workflow: String?
            /// That workflow's id: two workflow files may share a name.
            let workflowID: Int?
            /// The app that made it (`github-actions`, `vercel`).
            let app: String?
            /// The workflow run to rerun; nil for another app's check.
            let workflowRunID: Int?
            /// QUEUED, IN_PROGRESS, COMPLETED…
            let status: String
            /// SUCCESS, FAILURE… once completed.
            let conclusion: String?
        }

        struct Status: Equatable, Sendable {
            let context: String
            /// SUCCESS, PENDING, FAILURE, ERROR, EXPECTED.
            let state: String
        }

        var runs: [CheckRun] = []
        var statuses: [Status] = []
    }

    struct Comparison: Equatable, Sendable {
        /// `ahead`, `behind`, `diverged` or `identical`.
        let status: String
        /// Commits of the head that the base doesn't have.
        let aheadBy: Int
        /// Commits of the base that the head doesn't have.
        let behindBy: Int
        /// The base's commit: the base branch's tip, when it names a branch.
        let baseCommit: String
    }

    struct CommitInfo: Equatable, Sendable {
        let sha: String
        /// `web-flow` for a commit GitHub made; nil for an email that isn't
        /// a GitHub account's.
        let committerLogin: String?
        let parents: [String]
    }

    /// A run of the post-merge workflow.
    struct Run: Equatable, Sendable {
        let id: Int
        /// `completed`, `in_progress`, `queued`, `waiting`…
        let status: String
        /// `success`, `failure`, `cancelled`… once completed.
        let conclusion: String?
        let headSha: String
        /// `push`, `workflow_dispatch`…
        let event: String
        /// 1, then 2… for each rerun of the same run.
        var attempt = 1
        /// The commit's first line, for a push.
        let title: String?
        let url: String?

        var isCompleted: Bool { status == "completed" }
        /// A rerun is the same run, but not the same result.
        var attemptKey: String { "\(id)#\(attempt)" }
    }

    struct RateLimit: Equatable, Sendable {
        let coreRemaining: Int
        let coreReset: Date
        let graphQLRemaining: Int
        let graphQLReset: Date
    }

    /// The pull request's branch on this Mac.
    struct LocalState: Equatable, Sendable {
        /// The agents working or waiting on a dialog in its worktrees, or in
        /// another workspace's shell inside one: "claude working in “api”".
        var busyAgents: [String] = []
        var worktrees: [LocalWorktree] = []
    }

    struct LocalWorktree: Equatable, Sendable {
        enum Problem: Equatable, Sendable {
            case trackedChanges
            case unpushed
            case unreadable(String)
        }

        let path: String
        /// Nil: its tracked files are committed and its commits pushed.
        let problem: Problem?
    }
}
