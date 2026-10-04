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
        fileprivate(set) var isRunning = false
        fileprivate weak var queue: ExplainQueue?

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

    /// Runs waiting behind the one under way.
    var waitingCount: Int { waiting.count }

    /// `work` runs once the runs before it are over, off the main thread,
    /// with the ticket's cancellation. `onStart` says it began: on an idle
    /// queue, before `submit` returns. The next run starts once
    /// `completion` returned, so a run it submits waits behind those
    /// already waiting.
    @discardableResult
    func submit<T: Sendable>(
        _ work: @escaping @Sendable (BoundedProcess.Cancellation) -> T,
        onStart: @escaping @MainActor @Sendable () -> Void = {},
        completion: @escaping @MainActor @Sendable (T?) -> Void
    ) -> Ticket {
        let ticket = Ticket()
        ticket.queue = self
        let cancellation = ticket.cancellation
        waiting.append(Waiting(ticket: ticket, start: { [weak self] in
            ticket.isRunning = true
            onStart()
            Self.inBackground({ work(cancellation) }) { result in
                ticket.isRunning = false
                completion(result)
                self?.running = nil
                self?.startNext()
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

    /// Every run, waiting or under way: Nirux quits.
    func cancelAll() {
        let dropped = waiting
        waiting = []
        for entry in dropped { entry.dropped() }
        running?.cancellation.cancel()
    }

    private func cancel(_ ticket: Ticket) {
        if let index = waiting.firstIndex(where: { $0.ticket === ticket }) {
            waiting.remove(at: index).dropped()
        } else if running === ticket {
            ticket.cancellation.cancel()
        }
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
