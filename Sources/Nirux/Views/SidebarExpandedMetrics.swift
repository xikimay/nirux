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
    static let onboardingCardGap: CGFloat = 8

    static let workspaceInsetX: CGFloat = 8
    static let workspacePaddingY: CGFloat = 14
    static let workspaceGap: CGFloat = 10
    static let titleHeight: CGFloat = 18
    static let titleAdvance: CGFloat = 22
    static let purposeHeight: CGFloat = 15
    static let purposeAdvance: CGFloat = 19
    static let phaseHeight: CGFloat = 16
    static let phaseAdvance: CGFloat = 20
    static let actionHeight: CGFloat = 14
    static let actionAdvance: CGFloat = 18
    static let summaryHeight: CGFloat = 14
    static let summaryAdvance: CGFloat = 18
    static let branchHeight: CGFloat = 14
    static let branchAdvance: CGFloat = 18
    static let diffHeight: CGFloat = 14
    static let diffAdvance: CGFloat = 22
    static let prStateHeight: CGFloat = 12
    static let prStateAdvance: CGFloat = 14
    static let prDetailHeight: CGFloat = 10
    static let prDetailAdvance: CGFloat = 12
    static let reviewHeight: CGFloat = 12
    static let reviewAdvance: CGFloat = 14
    static let columnGap: CGFloat = 10
    static let columnRowHeight: CGFloat = 18
    static let columnRowAdvance: CGFloat = 24
    static let countChipWidth: CGFloat = 34
    static let countChipHeight: CGFloat = 22

    // Allow / Deny block under a column holding a permission request. The
    // request text is printable ASCII in a monospaced font, hard-wrapped
    // at a fixed column so the lines are exactly the text, cut nowhere.
    static var approvalFont: NSFont { .monospacedSystemFont(ofSize: 10, weight: .regular) }
    static let approvalCharactersPerLine = 32
    static let approvalLineHeight: CGFloat = 13
    static let approvalInset: CGFloat = 7
    static let approvalButtonGap: CGFloat = 7
    static let approvalButtonWidth: CGFloat = 58
    static let approvalButtonHeight: CGFloat = 20
    /// Space left under the block, before the next column row.
    static let approvalBottomGap: CGFloat = 6

    static func approvalLines(_ text: String) -> [String] {
        var lines: [String] = []
        var rest = Substring(text)
        repeat {
            lines.append(String(rest.prefix(approvalCharactersPerLine)))
            rest = rest.dropFirst(approvalCharactersPerLine)
        } while !rest.isEmpty
        return lines
    }

    static func approvalBlockHeight(for approval: SidebarPermissionApproval) -> CGFloat {
        approvalInset + CGFloat(approvalLines(approval.text).count) * approvalLineHeight
            + approvalButtonGap + approvalButtonHeight + approvalInset
    }

    static func approvalBlockAdvance(for column: ColumnInfo) -> CGFloat {
        column.permissionApproval.map { approvalBlockHeight(for: $0) + approvalBottomGap } ?? 0
    }

    // Resume block under a column whose turn failed on an API error: the
    // error on one line, then the button or where it stands.
    static let resumeLineHeight: CGFloat = 14
    static let resumeButtonWidth: CGFloat = 66
    static let resumeBlockHeight: CGFloat = approvalInset + resumeLineHeight + approvalButtonGap
        + approvalButtonHeight + approvalInset

    static func resumeBlockAdvance(for column: ColumnInfo) -> CGFloat {
        guard case .stoppedOnError? = column.stuck else { return 0 }
        return resumeBlockHeight + approvalBottomGap
    }

    static func groupHeight(for infos: [WorkspaceInfo]) -> CGFloat {
        infos.reduce(CGFloat(0)) { total, info in
            total + workspaceHeight(for: info) + workspaceGap
        }
    }

    static func workspaceHeight(for workspace: WorkspaceInfo) -> CGFloat {
        var height = workspacePaddingY * 2 + titleAdvance
        if workspace.purpose != nil { height += purposeAdvance }
        height += phaseAdvance
        if workspace.sidebarAction != nil { height += actionAdvance }
        if workspace.lastSummary != nil { height += summaryAdvance }
        if let branch = workspace.gitBranch, branch != workspace.title { height += branchAdvance }
        if workspace.diffStats != nil { height += diffAdvance }
        if workspace.prInfo != nil {
            height += prStateAdvance
            if workspace.prInfo?.ciStatus != nil { height += prDetailAdvance }
            if let reviewDecision = workspace.prInfo?.reviewDecision, !reviewDecision.isEmpty {
                height += prDetailAdvance
            }
            if workspace.prFeedbackSummary != nil {
                height += prDetailAdvance
            }
        }
        if workspace.reviewBadges != nil { height += reviewAdvance }
        height += columnGap + CGFloat(workspace.columns.count) * columnRowAdvance
        height += workspace.columns.reduce(CGFloat(0)) {
            $0 + approvalBlockAdvance(for: $1) + resumeBlockAdvance(for: $1)
        }
        return height
    }
}
