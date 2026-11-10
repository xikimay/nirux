import AppKit

/// What a light says of an agent: green while it works, its signal's color
/// while it waits on the user (amber) or broke (red). Work breathes, a wait
/// or an error pulses (see `EdgeGlowView`).
enum AgentLight: Equatable {
    case working
    case alert(AttentionSignal)

    @MainActor
    var color: NSColor {
        switch self {
        case .working: return Theme.Color.working
        case .alert(let signal): return SidebarRenderer.color(for: signal)
        }
    }
}

/// The lights of the space on screen: each column's own, and for an agent
/// out of view that waits or broke, the viewport's edge on its side.
struct AgentLightPlan: Equatable {
    /// The agent an edge's glow stands for: its pill names it, a click
    /// goes to it.
    struct EdgeAlert: Equatable {
        let signal: AttentionSignal
        let workspaceID: String
        /// `ColumnState.id`.
        let columnID: UUID?
        /// "Cookies needs permission", "claude has a question".
        let text: String
    }

    /// Lit columns, by `ColumnState.id`.
    var columns: [UUID: AgentLight] = [:]
    var left: EdgeAlert?
    var right: EdgeAlert?
    var top: EdgeAlert?
    var bottom: EdgeAlert?

    /// A name longer than this is cut in a pill.
    static let nameLimit = 28

    /// A column's light: a wait or an error first, then work. The focused
    /// column lights up too (more softly, see `EdgeGlowView.isSoft`): its
    /// dialog still waits while the user is in another app. A finished
    /// turn shows none.
    static func light(of column: ColumnInfo) -> AgentLight? {
        if let signal = alert(of: column) { return .alert(signal) }
        return column.agentStatus == .working ? .working : nil
    }

    /// What a column asks of the user, a finished turn left out.
    static func alert(of column: ColumnInfo) -> AttentionSignal? {
        column.attention.flatMap { $0 == .finished ? nil : $0 }
    }

    /// `infos`: the workspaces of the space on screen, top to bottom.
    /// `shows`: whether the viewport shows a column of the active one (see
    /// `NiruxShellView.showsColumn`). A column it shows lights itself: the
    /// edges glow only for agents out of view, the left and right ones for
    /// the active workspace's columns scrolled out, the top and bottom ones
    /// for the workspaces above and below.
    @MainActor
    static func make(infos: [WorkspaceInfo], activeIndex: Int, shows: (ColumnInfo) -> Bool) -> AgentLightPlan {
        var plan = AgentLightPlan()
        for column in infos.flatMap(\.columns) {
            if let id = column.id, let light = light(of: column) { plan.columns[id] = light }
        }
        if let active = infos.first(where: { $0.index == activeIndex }) {
            let hidden = active.columns.filter { !shows($0) }.map { (workspace: active, column: $0) }
            let focused = active.focusedColumn
            // Nearest first: at equal urgency the edge names the closest.
            plan.left = edgeAlert(among: Array(hidden.filter { $0.column.index < focused }.reversed()), namesWorkspace: false)
            plan.right = edgeAlert(among: hidden.filter { $0.column.index > focused }, namesWorkspace: false)
        }
        let position = infos.firstIndex { $0.index == activeIndex } ?? 0
        func columns(of workspaces: [WorkspaceInfo]) -> [(workspace: WorkspaceInfo, column: ColumnInfo)] {
            workspaces.flatMap { workspace in workspace.columns.map { (workspace, $0) } }
        }
        plan.top = edgeAlert(among: columns(of: Array(infos.prefix(position).reversed())), namesWorkspace: true)
        plan.bottom = edgeAlert(among: columns(of: Array(infos.dropFirst(position + 1))), namesWorkspace: true)
        return plan
    }

    /// The most urgent wait or error among `candidates`, the first of them
    /// at equal urgency.
    @MainActor
    private static func edgeAlert(
        among candidates: [(workspace: WorkspaceInfo, column: ColumnInfo)], namesWorkspace: Bool
    ) -> EdgeAlert? {
        var best: (signal: AttentionSignal, workspace: WorkspaceInfo, column: ColumnInfo)?
        for candidate in candidates {
            guard let signal = alert(of: candidate.column) else { continue }
            if best.map({ signal > $0.signal }) ?? true { best = (signal, candidate.workspace, candidate.column) }
        }
        guard let best else { return nil }
        let name = namesWorkspace ? best.workspace.title : SidebarRenderer.columnName(best.column)
        let headline = best.column.attentionSummary?.headline ?? (best.signal == .waiting ? "needs you" : "stopped")
        return EdgeAlert(
            signal: best.signal, workspaceID: best.workspace.id, columnID: best.column.id,
            text: "\(shortened(name)) \(headline)"
        )
    }

    private static func shortened(_ name: String) -> String {
        name.count > nameLimit ? name.prefix(nameLimit - 1).trimmingCharacters(in: .whitespaces) + "…" : name
    }

    /// The user is back in the app: the columns' waits and errors are
    /// seen, work goes on (see `NiruxShellView.clearAllAgentAttention`).
    /// The edges stay as they are until the next refresh: a dialog still
    /// open out of view keeps its glow, without its pill coming back.
    mutating func clearColumnAlerts() {
        columns = columns.filter { $0.value == .working }
        (left, right, top, bottom) = (nil, nil, nil, nil)
    }

    /// The agents the edges stand for.
    var edgeAlerts: [EdgeAlert] { [left, right, top, bottom].compactMap { $0 } }
}

/// Finds the turns that just ended, for one sweep of light each: only
/// those an agent reported itself (`ColumnInfo.turnEndedAt`). An agent
/// without hooks that falls silent may sit in its own prompt, and one that
/// died reports nothing: neither sweeps.
struct TurnEndSweeps {
    /// The last turn end seen of each column.
    private var seen: [UUID: TimeInterval] = [:]

    /// The columns whose turn ended since the last call, with nothing to
    /// ask and no work going on.
    mutating func update(columns: [ColumnInfo]) -> Set<UUID> {
        var ended: Set<UUID> = []
        var current: [UUID: TimeInterval] = [:]
        for column in columns {
            guard let id = column.id else { continue }
            current[id] = column.turnEndedAt
            // A column seen for the first time ended nothing in front of
            // the user.
            guard let last = seen[id], column.turnEndedAt > last else { continue }
            // A wait or an error has its own light.
            let asks = column.attention.map { $0 != .finished } ?? false
            if column.agentStatus != .working, !asks { ended.insert(id) }
        }
        // Closed columns, and those of a space left behind, are forgotten.
        seen = current
        return ended
    }
}
