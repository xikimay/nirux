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
    /// Elapsed time in the agent's current turn — shown for working agents
    /// ("· 12m"). Nil for non-terminal columns / between turns.
    var agentElapsedSeconds: TimeInterval?
    /// Why the agent waits on the user (set with `.needsAttention`).
    var attentionReason: AgentAttentionReason?
    /// A permission request the sidebar can answer (Allow / Deny).
    var permissionApproval: SidebarPermissionApproval?

    /// Hashable is hand-written to compare `agentElapsedSeconds` at the
    /// granularity it's *displayed* ("12m" via shortDuration), not raw
    /// seconds: the sidebar's render-signature gate would otherwise see a
    /// change on every 2s heartbeat while an agent merely gets older.
    var elapsedDisplay: String? {
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
            && lhs.attentionReason == rhs.attentionReason
            && lhs.permissionApproval == rhs.permissionApproval
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
        hasher.combine(attentionReason)
        hasher.combine(permissionApproval)
    }
}

/// A permission request answerable from the sidebar (see
/// `PermissionApproval`).
struct SidebarPermissionApproval: Hashable {
    let requestID: String
    let toolName: String
    /// Exactly what the call does, as the receiver checked it.
    let text: String
    /// Buttons, the decision on its way, or its failure.
    let display: PermissionApprovalTicket.Display

    init?(_ request: AgentPermissionRequest, now: TimeInterval) {
        guard let ticket = request.approval, let toolName = request.toolName,
              let display = ticket.display(now: now) else { return nil }
        requestID = ticket.requestID
        self.toolName = toolName
        text = ticket.text
        self.display = display
    }
}

struct PRInfo: Hashable, Sendable {
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
    let purpose: String?
    let nextStep: String?
    let blocker: String?
    let phase: WorkspacePhase
    let lastSummary: String?
    let lastActivityAt: TimeInterval?

    var sidebarAction: (text: String, isBlocker: Bool)? {
        if let blocker = normalizedContextText(blocker) {
            return ("Blocker: \(blocker)", true)
        }
        if let nextStep = normalizedContextText(nextStep) {
            return ("Next: \(nextStep)", false)
        }
        return nil
    }

    private func normalizedContextText(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
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
    /// Allow / Deny under a column holding a permission request.
    case permissionDecision(
        workspaceIndex: Int, columnIndex: Int, requestID: String, behavior: PermissionApproval.Behavior
    )
    /// The rest of that block: clicks there do nothing (a press meant for
    /// a button that just moved must not reach the card below).
    case permissionBlock(workspaceIndex: Int)
}

/// Full parameter set of SidebarView.update(...) — stashed while a
/// drag-reorder is in flight and replayed when the drag ends.
struct SidebarUpdatePayload {
    let profiles: [ProfileInfo]
    let workspaces: [WorkspaceInfo]
}

enum WorkspaceSidebarAction {
    case moveUp, moveDown, markActive, markInactive
    case close, rename, editContext, newWorkspace
    case closeColumn(columnIndex: Int)
    case moveToProfile(String)
}

/// Hover highlight target in the expanded sidebar. Links have their own
/// dedicated hover treatment; this covers the rest.
enum SidebarHoverTarget: Equatable {
    case spaceHeader
    case workspaceCard(Int)
    case menuBadge(Int)
    case columnRow(workspaceIndex: Int, columnIndex: Int)
    case approvalButton(workspaceIndex: Int, key: String)

    /// The card containing the target — hovering any sub-region keeps the
    /// whole card lit. Nil for targets outside the workspace list.
    var workspaceIndex: Int? {
        switch self {
        case .spaceHeader: return nil
        case .workspaceCard(let index), .menuBadge(let index): return index
        case .columnRow(let workspaceIndex, _), .approvalButton(let workspaceIndex, _): return workspaceIndex
        }
    }

    /// Key of an Allow / Deny button's view in `SidebarView.approvalButtonViews`.
    static func approvalButtonKey(requestID: String, behavior: PermissionApproval.Behavior) -> String {
        "\(requestID)|\(behavior.rawValue)"
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
    /// A space with no workspaces: drawn as a ring rather than a filled dot.
    var isEmpty: Bool = false
}
