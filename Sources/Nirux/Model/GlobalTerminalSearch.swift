import Foundation

/// Search Everywhere's engine: reads each terminal's text off the main
/// thread, one terminal after the other, and hands its matches to the main
/// actor as soon as that terminal is done. Nothing is kept between
/// searches: a terminal's text is read, searched and dropped, so memory
/// holds one terminal's text at a time (Ghostty's scrollback limit bounds
/// it) plus the matches kept.
@MainActor
final class GlobalTerminalSearch {
    /// Reads one terminal's text; nil when it has none to give (no surface
    /// yet, a column closed meanwhile).
    typealias Reader = @Sendable () -> String?

    /// The newest matches kept per terminal: a needle printed on every
    /// prompt would otherwise fill the list with one terminal. A pick
    /// reaches at most `TerminalSearchSession.maxPickSteps` matches up.
    nonisolated static let matchesPerTerminal = TerminalSearchSession.maxPickSteps

    fileprivate nonisolated static let queue = DispatchQueue(label: "nirux.global-search", qos: .userInitiated)
    /// Set when the running search is superseded: its reads stop at the
    /// next terminal, and what they still deliver is dropped.
    private var running: Cancellation?

    var isRunning: Bool { running != nil }

    /// Starts a search, ending the one running. `onMatches` gets the index
    /// in `readers` of each terminal that has matches, in `readers` order;
    /// `onDone`, once every terminal was read. Neither is called after a
    /// `cancel` or another `start`.
    func start(
        needle: String,
        readers: [Reader],
        onMatches: @escaping @MainActor @Sendable (Int, ScrollbackSearch.Result) -> Void,
        onDone: @escaping @MainActor @Sendable () -> Void
    ) {
        cancel()
        let cancellation = Cancellation()
        running = cancellation
        Self.scan(
            needle: needle,
            readers: readers,
            cancellation: cancellation,
            deliver: { [weak self] index, result in
                guard self?.running === cancellation else { return }
                onMatches(index, result)
            },
            finish: { [weak self] in
                guard let self, running === cancellation else { return }
                running = nil
                onDone()
            }
        )
    }

    func cancel() {
        running?.cancel()
        running = nil
    }

    /// The closures are taken through this nonisolated function's
    /// `@Sendable` parameters, so none of them inherits the caller's
    /// main-actor isolation: Swift 6.1 traps a main-actor closure run on
    /// another thread (#48).
    private nonisolated static func scan(
        needle: String,
        readers: [Reader],
        cancellation: Cancellation,
        deliver: @escaping @MainActor @Sendable (Int, ScrollbackSearch.Result) -> Void,
        finish: @escaping @MainActor @Sendable () -> Void
    ) {
        queue.async {
            for (index, read) in readers.enumerated() {
                guard !cancellation.isCancelled else { return }
                guard let text = read() else { continue }
                guard !cancellation.isCancelled else { return }
                let result = ScrollbackSearch.search(needle, in: text, limit: matchesPerTerminal)
                guard result.total > 0 else { continue }
                DispatchQueue.main.async { @MainActor in deliver(index, result) }
            }
            DispatchQueue.main.async { @MainActor in finish() }
        }
    }
}

extension GlobalTerminalSearch {
    /// Finds a picked match again in its terminal's text, off the main
    /// thread (`ScrollbackSearch.relocate`): output may have been printed
    /// and old lines dropped since the search. Nil when the terminal has no
    /// text to give.
    nonisolated static func relocate(
        _ match: ScrollbackSearch.Match,
        of needle: String,
        read: @escaping Reader,
        then completion: @escaping @MainActor @Sendable ((fromBottom: Int, total: Int, textBytes: Int)?) -> Void
    ) {
        queue.async {
            let found = read().map { text in
                let place = ScrollbackSearch.relocate(
                    context: match.context, fromBottom: match.fromBottom, of: needle, in: text
                )
                return (fromBottom: place.fromBottom, total: place.total, textBytes: text.utf8.count)
            }
            DispatchQueue.main.async { @MainActor in completion(found) }
        }
    }
}

/// A flag the main actor sets and the search queue reads.
private final class Cancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}
