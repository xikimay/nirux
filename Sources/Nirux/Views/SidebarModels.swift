import AppKit

struct ColumnInfo {
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
}

struct PRInfo {
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

struct WorkspaceInfo {
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

struct ProfileInfo: Equatable {
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
}

enum WorkspaceSidebarAction {
    case moveUp, moveDown, markActive, markInactive
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
