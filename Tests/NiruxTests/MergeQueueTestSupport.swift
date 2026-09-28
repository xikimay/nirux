import Foundation
import XCTest
@testable import Nirux

/// Shared by the merge queue's tests: settings, commits, pull requests and
/// a scripted GitHub ("world") that answers the engine's reads.
enum MQ {
    static let widgets = GitHubRepository(owner: "acme", name: "widgets")

    static func settings(
        requiredChecks: [String] = ["test"],
        postMergeWorkflow: String? = "nightly.yml",
        mergeMethod: BoardConfig.MergeMethod = .merge
    ) -> BoardConfig.QueueSettings {
        BoardConfig.QueueSettings(
            repository: "acme/widgets",
            gitHubRepository: widgets,
            baseBranch: "main",
            requiredChecks: requiredChecks,
            postMergeWorkflow: postMergeWorkflow,
            mergeMethod: mergeMethod,
            checksTimeoutMinutes: 30,
            postMergeTimeoutMinutes: 30
        )
    }

    /// A full SHA of one repeated hex digit: `sha("a")` is 40 a's.
    static func sha(_ digit: Character) -> String { String(repeating: digit, count: 40) }

    static func entry(_ number: Int, head: String, branch: String? = nil) -> MergeQueue.ConfirmedEntry {
        MergeQueue.ConfirmedEntry(number: number, head: head, branch: branch ?? "feat/\(number)")
    }

    static func pullRequest(
        _ number: Int,
        head: String,
        state: String = "OPEN",
        isDraft: Bool = false,
        base: String = "main",
        repository: GitHubRepository? = widgets,
        mergeable: String = "MERGEABLE",
        autoMerge: Bool = false,
        inMergeQueue: Bool = false,
        mergeCommit: String? = nil,
        parents: [String] = []
    ) -> MergeQueue.PullRequestSnapshot {
        MergeQueue.PullRequestSnapshot(
            number: number, state: state, isDraft: isDraft, headRefName: "feat/\(number)", headOid: head,
            baseRefName: base, headRepository: repository, mergeable: mergeable, hasAutoMerge: autoMerge,
            isInMergeQueue: inMergeQueue, mergeCommit: mergeCommit, mergeCommitParents: parents,
            url: "https://github.com/acme/widgets/pull/\(number)"
        )
    }

    static func checkRun(
        id: Int, name: String = "test", workflow: String? = "Tests", workflowID: Int? = nil, runID: Int? = 900,
        status: String = "COMPLETED", conclusion: String? = "SUCCESS"
    ) -> MergeQueue.CommitChecks.CheckRun {
        MergeQueue.CommitChecks.CheckRun(
            id: id, name: name, workflow: workflow, workflowID: workflowID,
            app: workflow == nil ? "some-app" : "github-actions",
            workflowRunID: runID, status: status, conclusion: conclusion
        )
    }

    static func checks(_ runs: MergeQueue.CommitChecks.CheckRun...) -> MergeQueue.CommitChecks {
        MergeQueue.CommitChecks(runs: runs, statuses: [])
    }

    static func run(
        _ id: Int, head: String, status: String = "completed", conclusion: String? = "success", event: String = "push",
        title: String? = nil
    ) -> MergeQueue.Run {
        MergeQueue.Run(id: id, status: status, conclusion: conclusion, headSha: head, event: event, title: title,
                       url: "https://github.com/acme/widgets/actions/runs/\(id)")
    }

    /// GitHub as the tests script it. Unscripted reads answer as a quiet
    /// repository would: no checks, nothing behind, no runs.
    struct World {
        var pullRequests: [Int: MergeQueue.PullRequestSnapshot] = [:]
        var checks: [String: MergeQueue.CommitChecks] = [:]
        var mainTip = MQ.sha("0")
        /// Commits of `main` each head lacks.
        var behind: [String: Int] = [:]
        /// Answers for other compares, by read.
        var compares: [MergeQueue.Read: MergeQueue.Comparison?] = [:]
        var commits: [String: MergeQueue.CommitInfo] = [:]
        var baseRuns: [MergeQueue.Run] = []
        var pushRuns: [String: [MergeQueue.Run]] = [:]
        var local = MergeQueue.LocalState()
        var rateLimit = MergeQueue.RateLimit(
            coreRemaining: 5000, coreReset: Date(timeIntervalSince1970: 0),
            graphQLRemaining: 5000, graphQLReset: Date(timeIntervalSince1970: 0)
        )
        var baseMergeQueue = false

        func answer(_ read: MergeQueue.Read) -> MergeQueue.ReadResult? {
            switch read {
            case .auth: return .signedIn
            case .rateLimit: return .rateLimit(rateLimit)
            case .baseMergeQueue: return .baseMergeQueue(baseMergeQueue)
            case .pullRequest(let number): return pullRequests[number].map { .pullRequest($0) }
            case .checks(let sha): return .checks(checks[sha] ?? MergeQueue.CommitChecks())
            case .compare(let base, let head):
                if let answer = compares[read] { return .comparison(answer) }
                if base == "main" {
                    let count = behind[head, default: 0]
                    return .comparison(MergeQueue.Comparison(
                        status: count > 0 ? "diverged" : "ahead", aheadBy: 1, behindBy: count, baseCommit: mainTip
                    ))
                }
                // A commit compared with main: already in it, main not past it.
                return .comparison(MergeQueue.Comparison(status: "identical", aheadBy: 0, behindBy: 0, baseCommit: base))
            case .commit(let sha): return commits[sha].map { .commit($0) }
            case .baseRuns: return .runs(baseRuns)
            case .pushRuns(let commit): return .runs(pushRuns[commit] ?? [])
            case .local: return .local(local)
            }
        }

        /// A pull request `number` at `head`, merged as `commit` on `mainTip`.
        mutating func merge(_ number: Int, as commit: String) {
            guard let open = pullRequests[number] else { return }
            pullRequests[number] = MQ.pullRequest(number, head: open.headOid, state: "MERGED", mergeCommit: commit,
                                                  parents: [mainTip, open.headOid])
            mainTip = commit
        }
    }

    /// The engine, a clock, and helpers to answer its requests.
    struct Harness {
        var engine: MergeQueue.Engine
        var now: TimeInterval = 1_000
        var notes: [MergeQueue.Note] = []
        /// Every mutation the engine asked for, in order.
        var mutations: [MergeQueue.Mutation] = []

        init(settings: BoardConfig.QueueSettings = MQ.settings(), entries: [MergeQueue.ConfirmedEntry]) {
            engine = MergeQueue.Engine(settings: settings, entries: entries)
        }

        var phase: MergeQueue.Phase { engine.phase }

        var stopReason: MergeQueue.StopReason? {
            if case .stopped(let reason) = engine.phase { return reason }
            return nil
        }

        var pendingReads: [MergeQueue.Read]? {
            if case .read(let reads, _)? = engine.request?.action { return reads }
            return nil
        }

        var pendingDelay: TimeInterval? {
            if case .read(_, let delay)? = engine.request?.action { return delay }
            return nil
        }

        var pendingMutation: MergeQueue.Mutation? {
            if case .mutate(let mutation)? = engine.request?.action { return mutation }
            return nil
        }

        mutating func send(_ event: MergeQueue.Event) {
            let output = engine.handle(event, now: now)
            notes += output.notes
            if case .mutate(let mutation)? = output.request?.action { mutations.append(mutation) }
        }

        mutating func start() { send(.start) }

        /// Answers the pending batch of reads from `world`, after its delay.
        mutating func answer(_ world: World) {
            guard let request = engine.request, case .read(let reads, let delay) = request.action else {
                return XCTFail("no read pending")
            }
            now += delay
            var answers: [MergeQueue.Read: MergeQueue.ReadResult] = [:]
            for read in reads { answers[read] = world.answer(read) }
            send(.read(requestID: request.id, .success(answers)))
        }

        mutating func fail(_ failure: MergeQueue.ReadFailure) {
            guard let request = engine.request, case .read(_, let delay) = request.action else {
                return XCTFail("no read pending")
            }
            now += delay
            send(.read(requestID: request.id, .failure(failure)))
        }

        mutating func mutated(_ result: MutationResult) {
            guard let request = engine.request, request.isMutation else { return XCTFail("no mutation pending") }
            send(.mutated(requestID: request.id, result))
        }

        typealias MutationResult = MergeQueue.MutationResult

        /// Answers reads from `world` until `isDone`, or fails.
        mutating func answer(_ world: World, until isDone: (Harness) -> Bool, limit: Int = 500) {
            for _ in 0..<limit {
                if isDone(self) { return }
                guard pendingReads != nil else { return XCTFail("no read pending: \(phase)") }
                answer(world)
            }
            XCTFail("never got there")
        }

        /// Answers reads from `world` until the engine asks for a mutation
        /// (returned), stops or finishes.
        @discardableResult
        mutating func run(_ world: World, limit: Int = 1_000) -> MergeQueue.Mutation? {
            for _ in 0..<limit {
                guard let request = engine.request else { return nil }
                if case .mutate(let mutation) = request.action { return mutation }
                answer(world)
            }
            XCTFail("the engine kept reading")
            return nil
        }

        func noted(_ text: String) -> Bool {
            notes.contains { $0.message.contains(text) }
        }
    }
}

/// A typed fake GitHub for the merge queue: answers reads from a world,
/// records every call, never runs gh.
final class FakeQueueClient: MergeQueueGitHub, @unchecked Sendable {
    let isDryRun: Bool
    private let lock = NSLock()
    private var world: MQ.World
    private var recordedReads: [MergeQueue.Read] = []
    private var recordedMutations: [MergeQueue.Mutation] = []

    init(world: MQ.World = MQ.World(), isDryRun: Bool = false) {
        self.world = world
        self.isDryRun = isDryRun
    }

    var reads: [MergeQueue.Read] { lock.withLock { recordedReads } }
    var mutations: [MergeQueue.Mutation] { lock.withLock { recordedMutations } }

    func update(_ change: (inout MQ.World) -> Void) {
        lock.withLock { change(&world) }
    }

    func read(_ read: MergeQueue.Read, settings: BoardConfig.QueueSettings) -> Result<MergeQueue.ReadResult, MergeQueue.ClientError> {
        lock.withLock {
            recordedReads.append(read)
            return world.answer(read).map { .success($0) } ?? .failure(.noAnswer("unscripted \(read)"))
        }
    }

    func mutate(_ mutation: MergeQueue.Mutation, settings: BoardConfig.QueueSettings) -> MergeQueue.MutationResult {
        lock.withLock {
            recordedMutations.append(mutation)
            return isDryRun ? .dryRun(commandLine(mutation, settings: settings)) : .sent
        }
    }

    func commandLine(_ mutation: MergeQueue.Mutation, settings: BoardConfig.QueueSettings) -> String {
        "gh \(mutation)"
    }
}
