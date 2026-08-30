import Foundation

/// One row in the activity feed — a signal event from an agent, captured
/// while the user may have been elsewhere (other column, other app, app
/// closed: events queued on disk are replayed into the feed on launch).
struct ActivityEntry: Codable, Hashable {
    enum Category: String, Codable {
        case attention     // permission prompt / waiting for input
        case turnComplete  // agent finished a turn
        case sessionStart
        case sessionEnd
        case missionQuestion
        case missionCompleted
        case missionResponse
    }

    let category: Category
    /// "claude" / "codex".
    let agentKind: String
    /// NIRUX_AGENT_UUID of the emitting column — fixed per terminal
    /// column, so it identifies "the column this agent lives in" rather
    /// than one agent session. Primary click-to-focus target: unlike
    /// columnIndex it survives column reordering. Optional so pre-existing
    /// activity.json entries (and hooks running outside Nirux, which lack
    /// the env var) still decode.
    let agentUUID: String?
    /// Positional fallback for click-to-focus when the agent UUID no
    /// longer resolves (agent exited but its workspace lives on). Nil
    /// when the column is gone — the row then focuses the workspace only
    /// (or nothing if that's gone too; the row is still a valid
    /// historical record).
    let workspaceID: String?
    let columnIndex: Int?
    /// Workspace title at event time (titles change; the entry freezes it).
    let workspaceTitle: String
    /// Notification message / codex final message — nil for lifecycle rows.
    let detail: String?
    /// Epoch seconds (the hook receiver's clock).
    let timestamp: TimeInterval
    /// Stable delivery identity for explicit Mission events. Optional so the
    /// existing activity.json wire format remains backward-compatible.
    let missionID: String?
    let missionEventID: String?

    init(
        category: Category, agentKind: String, agentUUID: String? = nil,
        workspaceID: String?, columnIndex: Int?, workspaceTitle: String,
        detail: String?, timestamp: TimeInterval,
        missionID: String? = nil, missionEventID: String? = nil
    ) {
        self.category = category
        self.agentKind = agentKind
        self.agentUUID = agentUUID
        self.workspaceID = workspaceID
        self.columnIndex = columnIndex
        self.workspaceTitle = workspaceTitle
        self.detail = detail
        self.timestamp = timestamp
        self.missionID = missionID
        self.missionEventID = missionEventID
    }

    /// Events worth a feed row. UserPromptSubmit/PreToolUse fire far too
    /// often — they drive the status machine, not the feed.
    init?(event: AgentHookEvent, workspaceTitle: String, columnIndex: Int?) {
        switch event.name {
        case .notification: category = .attention
        case .stop, .turnComplete: category = .turnComplete
        case .sessionStart: category = .sessionStart
        case .sessionEnd: category = .sessionEnd
        case .userPromptSubmit, .preToolUse: return nil
        }
        agentKind = event.kind.rawValue
        agentUUID = event.agentUUID
        workspaceID = event.workspaceID
        self.columnIndex = columnIndex
        self.workspaceTitle = workspaceTitle
        detail = event.detail
        timestamp = event.timestamp
        missionID = nil
        missionEventID = nil
    }
}

/// Rolling log of agent signal events, newest first, persisted to
/// activity.json in the state directory. The sidebar renders it as the
/// "while you were away" feed.
@MainActor
final class ActivityStore {
    static let shared = ActivityStore()

    private(set) var entries: [ActivityEntry] = []
    /// Everything at or before this instant has been seen by the user
    /// (feed on screen while the app was active). Persisted so unread
    /// state survives relaunches.
    private(set) var lastReadTimestamp: TimeInterval = 0
    /// Sidebar refresh trigger — set by the shell.
    var onChange: (() -> Void)?

    private static let maxEntries = 100
    private static let saveDebounce: TimeInterval = 5
    private var pendingSave: DispatchWorkItem?
    /// False in tests: the store is a singleton path onto the real state
    /// directory, and record()/markRead() must not schedule writes into
    /// the developer's live activity.json from a unit test.
    private let persistsToDisk: Bool

    init(persistsToDisk: Bool = true) {
        self.persistsToDisk = persistsToDisk
    }

    static var fileURL: URL {
        Persistence.stateDirectory.appendingPathComponent("activity.json")
    }

    /// Read state lives in a sidecar, NOT in activity.json: the entries
    /// file keeps the bare-array format older builds read and write, so a
    /// nightly downgrade round-trips the history instead of wiping it.
    static var readStateURL: URL {
        Persistence.stateDirectory.appendingPathComponent("activity-read.json")
    }

    /// What the sidebar feed shows: signal rows only. Lifecycle rows
    /// (sessionStart/sessionEnd) stay recorded but drown the feed — a
    /// typical backlog is mostly starts/ends the user can't act on.
    /// Consecutive repeats from the same column (an agent finishing turn
    /// after turn) coalesce into their newest occurrence so six visible
    /// rows cover six distinct things, not one chatty agent.
    var feedEntries: [ActivityEntry] {
        var result: [ActivityEntry] = []
        for entry in entries where [
            ActivityEntry.Category.attention,
            .turnComplete,
            .missionQuestion,
            .missionCompleted,
            .missionResponse
        ].contains(entry.category) {
            if let last = result.last,
               last.category == entry.category,
               last.agentKind == entry.agentKind,
               last.agentUUID == entry.agentUUID,
               last.workspaceID == entry.workspaceID,
               last.columnIndex == entry.columnIndex {
                continue  // entries are newest-first; keep the newest of the run
            }
            result.append(entry)
        }
        return result
    }

    /// An attention row is "handled" when the same agent signaled again
    /// afterwards (turn finished, new prompt…): the user already gave it
    /// what it was waiting for, so the row shouldn't keep the urgent
    /// look. Pure over the feed itself — live column state is unreliable
    /// here (attention flags are cleared wholesale on app activation).
    nonisolated static func isAttentionSuperseded(at index: Int, in feed: [ActivityEntry]) -> Bool {
        guard let entry = feed[safe: index],
              entry.category == .attention || entry.category == .missionQuestion
        else { return false }
        return feed[..<index].contains { newer in
            if let missionID = entry.missionID { return newer.missionID == missionID }
            if let uuid = entry.agentUUID { return newer.agentUUID == uuid }
            // Positional fallback needs SOME identity: events from hooks
            // running outside Nirux have nil workspace, column and uuid,
            // and two unrelated external sessions must not "handle" each
            // other's attention rows.
            guard entry.workspaceID != nil || entry.columnIndex != nil else { return false }
            return newer.workspaceID == entry.workspaceID && newer.columnIndex == entry.columnIndex
        }
    }

    /// Feed rows the user hasn't seen yet — drives the ACTIVITY badge.
    var unreadCount: Int {
        let feed = feedEntries
        return feed.enumerated().filter { index, entry in
            guard entry.category != .missionResponse,
                  entry.timestamp > lastReadTimestamp
            else { return false }
            return entry.category != .missionQuestion
                || !Self.isAttentionSuperseded(at: index, in: feed)
        }.count
    }

    /// Newest recorded timestamp — captured by the shell when the read
    /// dwell starts, so entries arriving mid-dwell stay unread.
    var newestTimestamp: TimeInterval? {
        entries.map(\.timestamp).max()
    }

    /// Everything at or before `cutoff` has been visible to the user.
    /// Saved immediately (the sidecar is tiny): a crash before the 5s
    /// entry debounce must not resurrect rows the user already saw.
    func markRead(upTo cutoff: TimeInterval) {
        guard cutoff > lastReadTimestamp else { return }
        lastReadTimestamp = cutoff
        saveReadStateNow()
        scheduleChangeNotification()
    }

    /// The whole feed has been visible (e.g. sidebar collapsed after
    /// being on screen) — everything currently recorded counts as seen.
    func markAllRead() {
        guard let newest = newestTimestamp else { return }
        markRead(upTo: newest)
    }

    func record(_ entry: ActivityEntry) {
        if let eventID = entry.missionEventID,
           entries.contains(where: { $0.missionEventID == eventID }) {
            return
        }
        entries.insert(entry, at: 0)
        if entries.count > Self.maxEntries {
            entries.removeLast(entries.count - Self.maxEntries)
        }
        scheduleSave()
        scheduleChangeNotification()
    }

    /// Coalesce change notifications: a drain replaying a backlog records
    /// dozens of entries in one pass, and onChange triggers a full sidebar
    /// refresh (process-table scan) each time without this.
    private var pendingNotify: DispatchWorkItem?

    private func scheduleChangeNotification() {
        guard pendingNotify == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            self?.pendingNotify = nil
            self?.onChange?()
        }
        pendingNotify = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: item)
    }

    private struct ReadState: Codable {
        var lastReadTimestamp: TimeInterval
    }

    nonisolated static func decodeReadState(_ data: Data) -> TimeInterval? {
        (try? JSONDecoder().decode(ReadState.self, from: data))?.lastReadTimestamp
    }

    /// Pure resolution of the initial read mark so tests can exercise it
    /// without touching the state directory. No sidecar (first launch
    /// after the update, or a downgrade cycle deleted trust in it) means
    /// the whole existing history counts as read — a badge of 100 stale
    /// rows on upgrade would be exactly the noise this feature removes.
    nonisolated static func initialReadTimestamp(
        entries: [ActivityEntry], sidecar: TimeInterval?
    ) -> TimeInterval {
        sidecar ?? entries.map(\.timestamp).max() ?? 0
    }

    func load() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let decoded = try? JSONDecoder().decode([ActivityEntry].self, from: data) else { return }
        entries = Array(decoded.prefix(Self.maxEntries))
        let sidecar = (try? Data(contentsOf: Self.readStateURL)).flatMap(Self.decodeReadState)
        lastReadTimestamp = Self.initialReadTimestamp(entries: entries, sidecar: sidecar)
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.saveNow() }
        pendingSave = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.saveDebounce, execute: item)
    }

    /// Persist immediately — called by the app delegate on terminate so the
    /// last few seconds of events survive the quit.
    func flush() {
        pendingSave?.cancel()
        pendingSave = nil
        saveNow()
        saveReadStateNow()
    }

    private func saveNow() {
        guard persistsToDisk, let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }

    private func saveReadStateNow() {
        guard persistsToDisk,
              let data = try? JSONEncoder().encode(ReadState(lastReadTimestamp: lastReadTimestamp))
        else { return }
        try? data.write(to: Self.readStateURL, options: .atomic)
    }
}
