import Foundation

/// Follows one Claude transcript for a column: each refresh reads what was
/// appended since the last one on a background queue and reports the
/// session's usage on the main actor. At most one read per follower is in
/// flight and reads start at most once per `minInterval`; a refresh asked
/// meanwhile is dropped (the next heartbeat asks again). A read that
/// stopped at its budget continues right away, and the usage is reported
/// only once caught up — never mid-history while catching up on a long
/// transcript.
final class ClaudeUsageFollower: @unchecked Sendable {
    let path: String
    /// Serial: readers are only touched here, and one queue for every
    /// column keeps a burst of catch-ups from fanning out across threads.
    private static let queue = DispatchQueue(label: "com.nirux.claude-usage", qos: .utility)
    /// Confined to `queue`.
    private var reader: ClaudeTranscriptReader
    @MainActor private var isReading = false
    @MainActor private var isCancelled = false
    /// The column following it: once gone, a catch-up stops mid-file.
    @MainActor private weak var owner: AnyObject?
    @MainActor private var lastReadAt: TimeInterval = -.infinity
    /// Header refreshes come up to four times a second while an agent's
    /// title spins; the usage needn't follow that closely.
    static let minInterval: TimeInterval = 1

    @MainActor
    init(path: String, owner: AnyObject) {
        self.path = path
        reader = ClaudeTranscriptReader(path: path)
        self.owner = owner
    }

    /// The column stopped following this transcript: report nothing more.
    @MainActor
    func cancel() {
        isCancelled = true
    }

    @MainActor
    func refresh(onUsage: @escaping @MainActor @Sendable (ClaudeSessionUsage) -> Void) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastReadAt >= Self.minInterval else { return }
        read(onUsage: onUsage)
    }

    @MainActor
    private func read(onUsage: @escaping @MainActor @Sendable (ClaudeSessionUsage) -> Void) {
        guard !isReading, !isCancelled, owner != nil else { return }
        isReading = true
        lastReadAt = ProcessInfo.processInfo.systemUptime
        Self.queue.async { [self] in
            let caughtUp = reader.readAppended()
            let usage = reader.usage
            DispatchQueue.main.async {
                self.isReading = false
                guard !self.isCancelled, self.owner != nil else { return }
                if caughtUp {
                    onUsage(usage)
                } else {
                    self.read(onUsage: onUsage)
                }
            }
        }
    }
}
