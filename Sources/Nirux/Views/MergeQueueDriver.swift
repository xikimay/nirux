import Foundation

/// What a queue needs from the app for its local reads (section 3.2, step
/// 1): the project's folders, the branch's worktrees (read off the main
/// thread), and the agents busy in them (on the main thread).
struct MergeQueueLocalAccess {
    typealias Inspect = @Sendable (
        _ folders: [String], _ branch: String, _ head: String, _ settings: BoardConfig.QueueSettings,
        _ client: any MergeQueueGitHub
    ) -> Result<MergeQueue.LocalInspection, MergeQueue.ClientError>

    /// The project's workspace folders, where its repositories are found.
    var folders: @MainActor () -> [String]
    /// Off the main thread: the branch's worktrees, checked.
    var inspect: Inspect = { folders, branch, head, settings, client in
        MergeQueue.inspectLocal(folders: folders, branch: branch, head: head, settings: settings, client: client)
    }
    /// The agents working or waiting on a dialog in these worktrees.
    var busyAgents: @MainActor (_ worktrees: [String], _ allWorktrees: [String]) -> [String]
}

/// The queue's clocks: `systemUptime` for every wait and timeout (it stops
/// while the Mac sleeps, and each wait reads GitHub again after a wake),
/// and the date, for a rate limit's reset time.
struct MergeQueueClock: Sendable {
    var now: @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var date: @Sendable () -> Date = { Date() }
    /// Runs `work` on the main thread after `delay` seconds of the same
    /// clock (Dispatch's doesn't count sleep either).
    var after: @Sendable (_ delay: TimeInterval, _ work: @escaping @MainActor @Sendable () -> Void) -> Void = {
        delay, work in MergeQueueDriver.onMain(after: delay, work)
    }
}

/// Runs one merge queue's engine: each request the engine returns runs
/// off the main thread, and its answer comes back as the next event, on
/// the main thread. One request at a time; a Stop drops any answer still
/// on its way, except a mutation's, which the engine waits for.
@MainActor
final class MergeQueueDriver {
    private(set) var engine: MergeQueue.Engine
    let client: any MergeQueueGitHub
    private let local: MergeQueueLocalAccess
    private let clock: MergeQueueClock

    /// After every event: the engine now, and what it noted.
    var onUpdate: ((MergeQueue.Engine, [MergeQueue.Note]) -> Void)?
    /// Before and after each mutation: its command line, then its result.
    var onMutation: ((MergeQueue.Mutation, _ command: String, MergeQueue.MutationResult?) -> Void)?

    init(engine: MergeQueue.Engine, client: any MergeQueueGitHub, local: MergeQueueLocalAccess, clock: MergeQueueClock) {
        self.engine = engine
        self.client = client
        self.local = local
        self.clock = clock
    }

    func start() { send(.start) }

    func stop() { send(.stop) }

    func send(_ event: MergeQueue.Event) {
        let output = engine.handle(event, now: clock.now())
        // The request goes out before anyone hears of the step: a Stop from
        // a listener finds a mutation already sent, never one about to be.
        if let request = output.request { run(request) }
        onUpdate?(engine, output.notes)
    }

    private func run(_ request: MergeQueue.Request) {
        switch request.action {
        case .read(let reads, let delay):
            guard delay > 0 else { return performReads(reads, id: request.id) }
            clock.after(delay) { [weak self] in self?.performReads(reads, id: request.id) }
        case .mutate(let mutation):
            let client = self.client
            let settings = engine.settings
            let command = client.commandLine(mutation, settings: settings)
            onMutation?(mutation, command, nil)
            Self.runOffMain({ client.mutate(mutation, settings: settings) }, then: { [weak self] result in
                guard let self else { return }
                self.onMutation?(mutation, command, result)
                self.send(.mutated(requestID: request.id, result))
            })
        }
    }

    private func performReads(_ reads: [MergeQueue.Read], id: Int) {
        // Stopped meanwhile: nothing is read.
        guard engine.request?.id == id else { return }
        let client = self.client
        let settings = engine.settings
        let folders = reads.contains(where: Self.isLocal) ? local.folders() : []
        let inspect = local.inspect
        Self.runOffMain({
            Self.fetch(reads, client: client, settings: settings, folders: folders, inspect: inspect)
        }, then: { [weak self] fetched in
            self?.finishReads(fetched, id: id)
        })
    }

    private struct Fetched: Sendable {
        var answers: [MergeQueue.Read: MergeQueue.ReadResult] = [:]
        var inspections: [MergeQueue.Read: MergeQueue.LocalInspection] = [:]
        var error: MergeQueue.ClientError?
    }

    private nonisolated static func isLocal(_ read: MergeQueue.Read) -> Bool {
        if case .local = read { return true }
        return false
    }

    /// Reads in order, stopping at the first failure.
    private nonisolated static func fetch(
        _ reads: [MergeQueue.Read],
        client: any MergeQueueGitHub,
        settings: BoardConfig.QueueSettings,
        folders: [String],
        inspect: MergeQueueLocalAccess.Inspect
    ) -> Fetched {
        var fetched = Fetched()
        for read in reads {
            let result: Result<Void, MergeQueue.ClientError>
            if case .local(let branch, let head) = read {
                result = inspect(folders, branch, head, settings, client).map { fetched.inspections[read] = $0 }
            } else {
                result = client.read(read, settings: settings).map { fetched.answers[read] = $0 }
            }
            if case .failure(let error) = result {
                fetched.error = error
                break
            }
        }
        return fetched
    }

    private func finishReads(_ fetched: Fetched, id: Int) {
        guard engine.request?.id == id else { return }
        if let error = fetched.error {
            return send(.read(requestID: id, .failure(readFailure(error))))
        }
        var answers = fetched.answers
        for (read, inspection) in fetched.inspections {
            let worktrees = inspection.worktrees.map(\.path)
            answers[read] = .local(MergeQueue.LocalState(
                busyAgents: worktrees.isEmpty ? [] : local.busyAgents(worktrees, inspection.allWorktreePaths),
                worktrees: inspection.worktrees
            ))
        }
        send(.read(requestID: id, .success(answers)))
    }

    /// A read's error, as the engine handles it (section 4).
    func readFailure(_ error: MergeQueue.ClientError) -> MergeQueue.ReadFailure {
        MergeQueue.readFailure(error, now: clock.now(), date: clock.date())
    }

    /// Runs `work` off the main thread, then `completion` on it. Both are
    /// taken through this nonisolated function's `@Sendable` parameters, so
    /// neither closure inherits the caller's main-actor isolation: Swift 6.1
    /// traps a main-actor closure run on another thread (#48).
    nonisolated static func runOffMain<Value: Sendable>(
        _ work: @escaping @Sendable () -> Value,
        then completion: @escaping @MainActor @Sendable (Value) -> Void
    ) {
        DispatchQueue.global(qos: .utility).async {
            let value = work()
            DispatchQueue.main.async { @MainActor in
                completion(value)
            }
        }
    }

    nonisolated static func onMain(after delay: TimeInterval, _ work: @escaping @MainActor @Sendable () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay)) { @MainActor in
            work()
        }
    }
}

extension MergeQueue {
    /// A client error on a read: a rate limit pauses until its reset (a
    /// minute when unknown); a server error, no answer or unreadable
    /// output is retried; anything else GitHub refused stops.
    static func readFailure(_ error: ClientError, now: TimeInterval, date: Date) -> ReadFailure {
        switch error {
        case .ghMissing:
            return .ghMissing
        case .notSignedIn(let message):
            return .notSignedIn(message)
        case .rateLimited(let reset):
            // The reset is to the second: a few more make sure it passed.
            let wait = reset.map { max(0, $0.timeIntervalSince(date)) + 5 } ?? 60
            return .rateLimited(resumeAt: now + wait)
        case .secondaryRateLimit:
            return .secondaryRateLimit
        case .refused:
            return .refused(GitHubCLIQueueClient.message(of: error))
        case .noAnswer, .unreadable:
            return .transient(GitHubCLIQueueClient.message(of: error))
        }
    }
}
