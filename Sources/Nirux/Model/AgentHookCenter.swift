import Foundation

/// Routes agent hook events to the column that emitted them.
///
/// Claude Code hooks and Codex `notify` invoke `Nirux --hook`, which appends
/// one JSON line per event to `hook-events.jsonl` in the state directory.
/// This center watches that file (directory-level vnode source, so the very
/// first creation is caught too), drains it debounced, and dispatches each
/// event to the matching column's PtySession via `resolver`.
///
/// The file doubles as a queue: events emitted while Nirux isn't running are
/// replayed on launch (mostly useful for the activity feed — statuses
/// self-correct within one heartbeat).
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
        /// Same definition updateSidebar uses: focused column of the active
        /// workspace (or any focused column in pilot mode).
        let isUserFocused: Bool
    }

    /// Given NIRUX_AGENT_UUID, locate the owning column. Set by the shell.
    var resolver: ((String) -> Resolution?)?
    /// Every event, resolved or not — the activity feed taps this.
    var onActivity: ((AgentHookEvent, Resolution?) -> Void)?
    /// A status was applied — lets the shell refresh the sidebar immediately
    /// instead of waiting for the next heartbeat.
    var onEventApplied: (() -> Void)?

    private var watchSource: DispatchSourceFileSystemObject?
    private var dirFd: Int32 = -1
    private var pendingDrain: DispatchWorkItem?
    private var started = false

    /// Upper bound for one drain. If the app stays closed for days while
    /// hooked agents keep working the file grows unboundedly; only the tail
    /// matters (latest status per session, recent activity).
    private static let maxDrainBytes = 1_000_000

    func start() {
        guard !started else { return }
        started = true

        let path = Persistence.stateDirectory.path
        dirFd = open(path, O_RDONLY | O_DIRECTORY)
        if dirFd >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: dirFd,
                eventMask: [.write, .extend, .rename, .delete],
                queue: .main
            )
            source.setEventHandler { [weak self] in self?.scheduleDrain() }
            source.setCancelHandler { [dirFd] in close(dirFd) }
            source.resume()
            watchSource = source
        } else {
            NSLog("[AgentHooks] cannot watch state dir %@ — hook status disabled", path)
        }

        // Replay anything queued while the app was closed.
        drain()
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

    /// Read + truncate the events file, then dispatch in order. Public so
    /// tests and the launch path can force a cycle.
    func drain() {
        let url = Self.eventsURL
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.truncateFile(atOffset: 0)
            try? handle.close()
        }

        var slice = data
        if data.count > Self.maxDrainBytes {
            slice = data.suffix(Self.maxDrainBytes / 4)
            // Drop the partial first line of the tail slice.
            if let nl = slice.firstIndex(of: 0x0A) { slice = slice.suffix(from: slice.index(after: nl)) }
        }

        let decoder = JSONDecoder()
        for line in slice.split(separator: 0x0A) {
            guard let event = try? decoder.decode(AgentHookEvent.self, from: Data(line)) else { continue }
            dispatch(event)
        }
    }

    private func dispatch(_ event: AgentHookEvent) {
        let resolution = event.agentUUID.flatMap { resolver?($0) }
        if let resolution, let pty = resolution.column.pty {
            let firedAttention = pty.applyAgentHook(event, isUserFocused: resolution.isUserFocused)
            if firedAttention {
                resolution.column.notifyAgentAttention()
            }
            onEventApplied?()
        }
        onActivity?(event, resolution)
    }

    func stop() {
        pendingDrain?.cancel()
        pendingDrain = nil
        watchSource?.cancel()
        watchSource = nil
        dirFd = -1
        started = false
    }
}
