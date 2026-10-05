import Foundation

/// One Explain run at a time in the whole app (docs/branch-review.md,
/// section 4.3): a second waits in line. A run works off the main thread
/// and can be cancelled, waiting or under way; its completion comes back
/// on the main actor, with nil when it was cancelled before it started.
@MainActor
final class ExplainQueue {
    static let shared = ExplainQueue()

    /// A run, waiting or under way.
    @MainActor
    final class Ticket {
        let cancellation = BoundedProcess.Cancellation()
        /// The worktree it explains, as `stop(worktree:then:)` names it.
        let worktree: String?
        fileprivate(set) var isRunning = false
        /// `stop(worktree:then:)` stopped it, not its owner.
        fileprivate(set) var isStopped = false
        fileprivate weak var queue: ExplainQueue?

        fileprivate init(worktree: String?) {
            self.worktree = worktree
        }

        /// Waiting, it leaves the line; under way, its run is told to stop.
        func cancel() {
            queue?.cancel(self)
        }
    }

    private struct Waiting {
        let ticket: Ticket
        let start: @MainActor () -> Void
        let dropped: @MainActor () -> Void
    }

    private var waiting: [Waiting] = []
    private var running: Ticket?
    /// Worktrees whose runs are stopped, and how many stops hold each:
    /// Clean Up deletes a review file once its branch is gone, and a run
    /// that ended after would create it again.
    private var stopped: [String: Int] = [:]
    /// What waits for the run under way to end.
    private var afterRun: [@MainActor () -> Void] = []
    /// Left once the run under way returned, off the main thread: quitting
    /// waits on it, while the main thread can't take completions.
    private let runGroup = DispatchGroup()

    /// Runs waiting behind the one under way.
    var waitingCount: Int { waiting.count }

    /// `work` runs once the runs before it are over, off the main thread,
    /// with the ticket's cancellation. `onStart` says it began: on an idle
    /// queue, before `submit` returns. The next run starts once
    /// `completion` returned, so a run it submits waits behind those
    /// already waiting. A run for a stopped `worktree` never runs: its
    /// completion gets nil at once.
    @discardableResult
    func submit<T: Sendable>(
        worktree: String? = nil,
        _ work: @escaping @Sendable (BoundedProcess.Cancellation) -> T,
        onStart: @escaping @MainActor @Sendable () -> Void = {},
        completion: @escaping @MainActor @Sendable (T?) -> Void
    ) -> Ticket {
        let ticket = Ticket(worktree: worktree)
        ticket.queue = self
        if let worktree, stopped[worktree] != nil {
            completion(nil)
            return ticket
        }
        let cancellation = ticket.cancellation
        let group = runGroup
        waiting.append(Waiting(ticket: ticket, start: { [weak self] in
            ticket.isRunning = true
            onStart()
            group.enter()
            Self.inBackground({
                defer { group.leave() }
                return work(cancellation)
            }) { result in
                ticket.isRunning = false
                completion(result)
                self?.running = nil
                self?.finishedRun()
            }
        }, dropped: { completion(nil) }))
        startNext()
        return ticket
    }

    private func startNext() {
        guard running == nil, !waiting.isEmpty else { return }
        let next = waiting.removeFirst()
        running = next.ticket
        next.start()
    }

    private func finishedRun() {
        let waiters = afterRun
        afterRun = []
        waiters.forEach { $0() }
        startNext()
    }

    /// Every run, waiting or under way: Nirux quits. Waits up to `timeout`
    /// for the run under way to return, its claude stopped: the main
    /// thread is busy quitting, and a claude left behind would run on.
    func cancelAll(waitingUpTo timeout: TimeInterval = 0) {
        let dropped = waiting
        waiting = []
        for entry in dropped { entry.dropped() }
        running?.cancellation.cancel()
        if timeout > 0 { _ = runGroup.wait(timeout: .now() + timeout) }
    }

    /// Stops `worktree`'s runs, waiting or under way, and refuses new
    /// ones until `resume(worktree:)`. `then` runs once none of them is
    /// under way: at once if none was.
    func stop(worktree: String, then: @escaping @MainActor () -> Void) {
        stopped[worktree, default: 0] += 1
        let dropped = waiting.filter { $0.ticket.worktree == worktree }
        waiting.removeAll { $0.ticket.worktree == worktree }
        for entry in dropped {
            entry.ticket.isStopped = true
            entry.dropped()
        }
        guard let running, running.worktree == worktree else { return then() }
        running.isStopped = true
        running.cancellation.cancel()
        afterRun.append(then)
    }

    /// `worktree` takes runs again, once every `stop` of it is resumed.
    func resume(worktree: String) {
        guard let count = stopped[worktree] else { return }
        stopped[worktree] = count > 1 ? count - 1 : nil
    }

    private func cancel(_ ticket: Ticket) {
        if let index = waiting.firstIndex(where: { $0.ticket === ticket }) {
            waiting.remove(at: index).dropped()
        } else if running === ticket {
            ticket.cancellation.cancel()
        }
    }

    /// How `submit` and `stop` name a worktree: its folder, symlinks and
    /// case resolved, as Clean Up names it.
    nonisolated static func worktreeKey(_ path: String) -> String {
        path.realPath ?? URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// `work` on a global queue, then `completion` on the main actor.
    /// Nonisolated, so that `work` is never a main-actor closure run off
    /// the main thread (#48).
    nonisolated private static func inBackground<T: Sendable>(
        _ work: @escaping @Sendable () -> T, then completion: @escaping @MainActor @Sendable (T) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = work()
            DispatchQueue.main.async { completion(result) }
        }
    }
}
