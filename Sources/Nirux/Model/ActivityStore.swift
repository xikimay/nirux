import Foundation

/// One row in the activity feed — a signal event from an agent, captured
/// while the user may have been elsewhere (other column, other app, app
/// closed: events queued on disk are replayed into the feed on launch).
struct ActivityEntry: Codable, Equatable {
    enum Category: String, Codable {
        case attention     // permission prompt / waiting for input
        case turnComplete  // agent finished a turn
        case sessionStart
        case sessionEnd
    }

    let category: Category
    /// "claude" / "codex".
    let agentKind: String
    /// Routing target for click-to-focus. Nil when the column is gone —
    /// the row then focuses the workspace only (or nothing if that's gone
    /// too; the row is still a valid historical record).
    let workspaceID: String?
    let columnIndex: Int?
    /// Workspace title at event time (titles change; the entry freezes it).
    let workspaceTitle: String
    /// Notification message / codex final message — nil for lifecycle rows.
    let detail: String?
    /// Epoch seconds (the hook receiver's clock).
    let timestamp: TimeInterval

    init(
        category: Category, agentKind: String, workspaceID: String?,
        columnIndex: Int?, workspaceTitle: String, detail: String?,
        timestamp: TimeInterval
    ) {
        self.category = category
        self.agentKind = agentKind
        self.workspaceID = workspaceID
        self.columnIndex = columnIndex
        self.workspaceTitle = workspaceTitle
        self.detail = detail
        self.timestamp = timestamp
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
        workspaceID = event.workspaceID
        self.columnIndex = columnIndex
        self.workspaceTitle = workspaceTitle
        detail = event.detail
        timestamp = event.timestamp
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

    static var fileURL: URL {
        Persistence.stateDirectory.appendingPathComponent("activity.json")
    }

    /// What the sidebar feed shows: signal rows only. Lifecycle rows
    /// (sessionStart/sessionEnd) stay recorded but drown the feed — a
    /// typical backlog is mostly starts/ends the user can't act on.
    var feedEntries: [ActivityEntry] {
        entries.filter { $0.category == .attention || $0.category == .turnComplete }
    }

    /// Feed rows the user hasn't seen yet — drives the ACTIVITY badge.
    var unreadCount: Int {
        feedEntries.filter { $0.timestamp > lastReadTimestamp }.count
    }

    /// The feed has been visible to the user — everything currently in it
    /// counts as seen.
    func markAllRead() {
        guard let newest = entries.map(\.timestamp).max(), newest > lastReadTimestamp else { return }
        lastReadTimestamp = newest
        scheduleSave()
        scheduleChangeNotification()
    }

    func record(_ entry: ActivityEntry) {
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

    /// On-disk shape of activity.json. Older builds wrote a bare
    /// [ActivityEntry] array — decode() accepts both.
    private struct Archive: Codable {
        var entries: [ActivityEntry]
        var lastReadTimestamp: TimeInterval?
    }

    /// Pure decode so tests can exercise format compat without touching the
    /// state directory. Legacy array files predate read tracking — their
    /// whole history counts as read (a badge of 100 on first launch after
    /// the update would be exactly the noise this feature removes).
    nonisolated static func decode(_ data: Data) -> (entries: [ActivityEntry], lastReadTimestamp: TimeInterval)? {
        if let archive = try? JSONDecoder().decode(Archive.self, from: data) {
            return (archive.entries, archive.lastReadTimestamp ?? archive.entries.map(\.timestamp).max() ?? 0)
        }
        if let legacy = try? JSONDecoder().decode([ActivityEntry].self, from: data) {
            return (legacy, legacy.map(\.timestamp).max() ?? 0)
        }
        return nil
    }

    func encoded() -> Data? {
        try? JSONEncoder().encode(Archive(entries: entries, lastReadTimestamp: lastReadTimestamp))
    }

    func load() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let decoded = Self.decode(data) else { return }
        entries = Array(decoded.entries.prefix(Self.maxEntries))
        lastReadTimestamp = decoded.lastReadTimestamp
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
    }

    private func saveNow() {
        guard let data = encoded() else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }
}
