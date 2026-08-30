import AppKit

struct ColumnInfo: Hashable {
    let index: Int
    let processName: String?
    let abbreviatedCwd: String?
    let isFocused: Bool
    let isWebView: Bool
    let webTitle: String?
    let terminalTitle: String?
    let agentStatus: AgentStatus
    let isEditor: Bool
    let editorFileName: String?
    /// Active editor tab has unsaved changes — rendered as a dirty dot
    /// next to the file name.
    var editorIsDirty: Bool = false
    /// Elapsed time since the foreground process started — shown for
    /// working agents ("· 12m"). Nil for non-terminal columns / idle shells.
    var agentElapsedSeconds: TimeInterval? = nil

    /// Hashable is hand-written to compare `agentElapsedSeconds` at the
    /// granularity it's *displayed* ("12m" via shortDuration), not raw
    /// seconds: the sidebar's render-signature gate would otherwise see a
    /// change on every 2s heartbeat while an agent merely gets older.
    private var elapsedDisplay: String? {
        guard agentStatus == .working, let agentElapsedSeconds else { return nil }
        return PilotSidebarRenderer.shortDuration(agentElapsedSeconds)
    }

    static func == (lhs: ColumnInfo, rhs: ColumnInfo) -> Bool {
        lhs.index == rhs.index
            && lhs.processName == rhs.processName
            && lhs.abbreviatedCwd == rhs.abbreviatedCwd
            && lhs.isFocused == rhs.isFocused
            && lhs.isWebView == rhs.isWebView
            && lhs.webTitle == rhs.webTitle
            && lhs.terminalTitle == rhs.terminalTitle
            && lhs.agentStatus == rhs.agentStatus
            && lhs.isEditor == rhs.isEditor
            && lhs.editorFileName == rhs.editorFileName
            && lhs.editorIsDirty == rhs.editorIsDirty
            && lhs.elapsedDisplay == rhs.elapsedDisplay
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(index)
        hasher.combine(processName)
        hasher.combine(abbreviatedCwd)
        hasher.combine(isFocused)
        hasher.combine(isWebView)
        hasher.combine(webTitle)
        hasher.combine(terminalTitle)
        hasher.combine(agentStatus)
        hasher.combine(isEditor)
        hasher.combine(editorFileName)
        hasher.combine(editorIsDirty)
        hasher.combine(elapsedDisplay)
    }
}

struct PRInfo: Hashable {
    let number: Int
    let state: String
    let isDraft: Bool
    let ciStatus: String?
    let failedCheckUrl: String?
    let reviewDecision: String?
    let mergeable: String?
    let url: String
    let additions: Int?
    let deletions: Int?
    let changedFiles: Int?
}

struct WorkspaceInfo: Hashable {
    /// Stable workspace identity (WorkspaceState.id). Used to re-resolve
    /// `index` when the store may have mutated since this snapshot.
    let id: String
    let index: Int
    let title: String
    let profileID: String
    let isInactive: Bool
    let columnCount: Int
    let focusedColumn: Int
    let gitBranch: String?
    let hasNotification: Bool
    let isActive: Bool
    let columns: [ColumnInfo]
    let prInfo: PRInfo?
    let diffStats: String?
}

struct ProfileInfo: Hashable {
    let id: String
    let name: String
    let colorHex: String
    let isActive: Bool
    let workspaceCount: Int
    let hasAttention: Bool
}

struct SidebarHitArea {
    let frame: NSRect
    let region: SidebarHitRegion
}

enum SidebarHitRegion {
    case spaceHeader
    case link(url: String, label: NSTextField)
    case column(workspaceIndex: Int, columnIndex: Int)
    case workspace(Int)
    /// The "⋯" button on a workspace card — opens the workspace action menu.
    case workspaceMenu(Int)
    /// Legacy shape retained for the upstream hover helper. The Activity feed
    /// no longer creates or handles these regions.
    case activity(Int)
}

/// Full parameter set of SidebarView.update(...) — stashed while a
/// drag-reorder is in flight and replayed when the drag ends.
struct SidebarUpdatePayload {
    let profiles: [ProfileInfo]
    let workspaces: [WorkspaceInfo]
}

enum WorkspaceSidebarAction {
    case moveUp, moveDown, markActive, markInactive
    case close, rename, newWorkspace
    case closeColumn(columnIndex: Int)
}

/// Hover highlight target in the expanded sidebar. Links have their own
/// dedicated hover treatment; this covers the rest.
enum SidebarHoverTarget: Equatable {
    case spaceHeader
    case workspaceCard(Int)
    case menuBadge(Int)
    case columnRow(workspaceIndex: Int, columnIndex: Int)

    /// The card containing the target — hovering any sub-region keeps the
    /// whole card lit. Nil for targets outside the workspace list.
    var workspaceIndex: Int? {
        switch self {
        case .spaceHeader: return nil
        case .workspaceCard(let index), .menuBadge(let index): return index
        case .columnRow(let workspaceIndex, _): return workspaceIndex
        }
    }
}

enum SidebarDotIndicatorAction: Equatable {
    case selectProfile(String)
    case createProfile
}

struct SidebarDotIndicatorItem: Equatable {
    let action: SidebarDotIndicatorAction
    let colorHex: String
    let isActive: Bool
    let hasAttention: Bool
    let label: String?
}
