import AppKit

enum SidebarExpandedMetrics {
    static let padding: CGFloat = 20
    static let verticalPadding: CGFloat = 20
    static let bottomReserve: CGFloat = 64

    static let spaceHeaderHeight: CGFloat = 66
    static let spaceHeaderBottomGap: CGFloat = 18

    static let sectionGap: CGFloat = 20
    static let sectionHeaderHeight: CGFloat = 18
    static let sectionHeaderAdvance: CGFloat = 28
    static let shortcutHintGap: CGFloat = 14
    static let shortcutHintHeight: CGFloat = 22

    static let workspaceInsetX: CGFloat = 8
    static let workspacePaddingY: CGFloat = 14
    static let workspaceGap: CGFloat = 10
    static let titleHeight: CGFloat = 18
    static let titleAdvance: CGFloat = 22
    static let branchHeight: CGFloat = 14
    static let branchAdvance: CGFloat = 18
    static let diffHeight: CGFloat = 14
    static let diffAdvance: CGFloat = 22
    static let prStateHeight: CGFloat = 12
    static let prStateAdvance: CGFloat = 14
    static let prDetailHeight: CGFloat = 10
    static let prDetailAdvance: CGFloat = 12
    static let columnGap: CGFloat = 10
    static let columnRowHeight: CGFloat = 18
    static let columnRowAdvance: CGFloat = 24
    static let countChipWidth: CGFloat = 34
    static let countChipHeight: CGFloat = 22

    static func groupHeight(for infos: [WorkspaceInfo]) -> CGFloat {
        infos.reduce(CGFloat(0)) { total, info in
            total + workspaceHeight(for: info) + workspaceGap
        }
    }

    private static func workspaceHeight(for workspace: WorkspaceInfo) -> CGFloat {
        var height = workspacePaddingY * 2 + titleAdvance
        if let branch = workspace.gitBranch, branch != workspace.title { height += branchAdvance }
        if workspace.diffStats != nil { height += diffAdvance }
        if workspace.prInfo != nil {
            height += prStateAdvance
            if workspace.prInfo?.ciStatus != nil { height += prDetailAdvance }
            if let reviewDecision = workspace.prInfo?.reviewDecision, !reviewDecision.isEmpty {
                height += prDetailAdvance
            }
        }
        height += columnGap + CGFloat(workspace.columns.count) * columnRowAdvance
        return height
    }
}
