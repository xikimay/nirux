import Foundation

/// Routes agent hook events to the column that emitted them.
///
/// Claude Code hooks and Codex `notify` invoke `Nirux --hook`, which appends
/// one JSON line per event to `hook-events.jsonl` in the state directory.
/// This center watches the file AND its directory (appends only fire on the
/// file's own vnode), drains it debounced, and dispatches each event to the
/// matching column's PtySession via `resolver`.
///
/// The file doubles as a queue: events emitted while Nirux isn't running are
/// replayed on launch so agent statuses catch up immediately.
@MainActor
final class AgentHookCenter {
    static let shared = AgentHookCenter()

    /// Pure path computation — the hook-receiver process (nonisolated CLI
    /// entry point) writes here too.
    nonisolated static var eventsURL: URL {
        Persistence.stateDirectory.appendingPathComponent("hook-events.jsonl")
    }

    struct Resolution {
        let workspace: WorkspaceState
        let column: ColumnState
        let columnIndex: Int
        /// App active AND focused column of the active workspace (or any
        /// focused column in pilot mode) — see resolveAgentColumn.
        let isUserFocused: Bool
    }

    struct AppliedEvent {
        let event: AgentHookEvent
        let resolution: Resolution
    }

    /// Given NIRUX_AGENT_UUID, locate the owning column. Set by the shell.
    var resolver: ((String) -> Resolution?)?
    var onEventsApplied: (([AppliedEvent]) -> Void)?
    var onEventReceived: ((AgentHookEvent, Resolution?) -> Void)?

    private var dirSource: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?
    private var dirFd: Int32 = -1
    private var pendingDrain: DispatchWorkItem?
    private var started = false

    /// Upper bound for one drain. If the app stays closed for days while
    /// hooked agents keep working the file grows unboundedly; only the tail
    /// matters (the latest status per session).
    private static let maxDrainBytes = 1_000_000

    func start() {
        guard !started else { return }
        started = true

        // Two watchers, because vnode events don't cover both cases:
        // - the DIRECTORY fires when hook-events.jsonl is created/renamed/
        //   deleted (first event ever, or the next event after a drain),
        // - the FILE itself fires when a receiver appends to it — appends
        //   don't touch directory metadata, so a dir-only watcher would
        //   miss them entirely.
        let dirPath = Persistence.stateDirectory.path
        dirFd = open(dirPath, O_RDONLY | O_DIRECTORY)
        if dirFd >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: dirFd,
                eventMask: [.write, .extend, .rename, .delete],
                queue: .main
            )
            source.setEventHandler { [weak self] in
                self?.watchEventsFileIfPresent()
                self?.scheduleDrain()
            }
            source.setCancelHandler { [dirFd] in close(dirFd) }
            source.resume()
            dirSource = source
        } else {
            NSLog("[AgentHooks] cannot watch state dir %@ — hook status disabled", dirPath)
        }
        watchEventsFileIfPresent()

        // Replay anything queued while the app was closed.
        drain()
    }

    private func watchEventsFileIfPresent() {
        guard fileSource == nil else { return }
        let fd = open(Self.eventsURL.path, O_RDONLY)
        guard fd >= 0 else { return } // not created yet — the dir watcher will call back
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename, .revoke],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            // The drain renames the file aside — the vnode we were watching
            // is now the processing file, so re-attach to the fresh log on
            // the next directory event instead of draining a deleted node.
            if !source.data.isDisjoint(with: [.delete, .rename, .revoke]) {
                self.fileSource?.cancel()
                self.fileSource = nil
                return
            }
            self.scheduleDrain()
        }
        source.setCancelHandler { [fd] in close(fd) }
        source.resume()
        fileSource = source
    }

    /// Coalesce rapid hook bursts (PreToolUse storms) into one read.
    private func scheduleDrain() {
        guard pendingDrain == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            self?.pendingDrain = nil
            self?.drain()
        }
        pendingDrain = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: item)
    }

    /// Move the events file aside and process it, then delete. Receivers
    /// appending DURING the drain create a fresh log (O_CREAT) — nothing is
    /// lost between read and truncate, unlike read-then-truncate-in-place.
    /// Public so tests and the launch path can force a cycle.
    func drain() {
        let url = Self.eventsURL
        let aside = url.deletingPathExtension().appendingPathExtension("processing")
        let fm = FileManager.default
        try? fm.removeItem(at: aside)
        do {
            try fm.moveItem(at: url, to: aside)
        } catch {
            return // no log file (yet) — the common case
        }
        defer { try? fm.removeItem(at: aside) }

        guard var slice = try? Data(contentsOf: aside), !slice.isEmpty else { return }
        if slice.count > Self.maxDrainBytes {
            slice = slice.suffix(Self.maxDrainBytes / 4)
            // Drop the partial first line of the tail slice.
            if let nl = slice.firstIndex(of: 0x0A) { slice = slice.suffix(from: slice.index(after: nl)) }
        }

        let decoder = JSONDecoder()
        var appliedEvents: [AppliedEvent] = []
        for line in slice.split(separator: 0x0A) {
            guard let event = try? decoder.decode(AgentHookEvent.self, from: Data(line)) else { continue }
            if let appliedEvent = dispatch(event) { appliedEvents.append(appliedEvent) }
        }
        // One sidebar refresh per drain, not per event: updateSidebar does a
        // full process-table scan, and a PreToolUse storm (or launch replay
        // of a long backlog) would otherwise run dozens back-to-back on the
        // main thread.
        if !appliedEvents.isEmpty { onEventsApplied?(appliedEvents) }
    }

    @discardableResult
    func dispatch(_ event: AgentHookEvent) -> AppliedEvent? {
        let resolution = event.agentUUID.flatMap { resolver?($0) }
        onEventReceived?(event, resolution)
        if let resolution, let pty = resolution.column.pty {
            let firedAttention = pty.applyAgentHook(event, isUserFocused: resolution.isUserFocused)
            if firedAttention {
                resolution.column.notifyAgentAttention()
            }
        }
        return resolution.map { AppliedEvent(event: event, resolution: $0) }
    }

    func stop() {
        pendingDrain?.cancel()
        pendingDrain = nil
        dirSource?.cancel()
        dirSource = nil
        dirFd = -1
        fileSource?.cancel()
        fileSource = nil
        started = false
    }
}
