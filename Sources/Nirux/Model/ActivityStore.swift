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
    /// Sidebar refresh trigger — set by the shell.
    var onChange: (() -> Void)?

    private static let maxEntries = 100
    private static let saveDebounce: TimeInterval = 5
    private var pendingSave: DispatchWorkItem?

    static var fileURL: URL {
        Persistence.stateDirectory.appendingPathComponent("activity.json")
    }

    func record(_ entry: ActivityEntry) {
        entries.insert(entry, at: 0)
        if entries.count > Self.maxEntries {
            entries.removeLast(entries.count - Self.maxEntries)
        }
        scheduleSave()
        onChange?()
    }

    func load() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let decoded = try? JSONDecoder().decode([ActivityEntry].self, from: data) else { return }
        entries = Array(decoded.prefix(Self.maxEntries))
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.saveNow() }
        pendingSave = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.saveDebounce, execute: item)
    }

    private func saveNow() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }
}
