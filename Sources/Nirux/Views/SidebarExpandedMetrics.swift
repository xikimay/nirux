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
    static let countChipWidth: CGFloat = 34
    static let countChipHeight: CGFloat = 22

    // The workspace card: state and title / branch and diff / column chips
    // and the pull request, then an action block only when there is
    // something to do.
    static let workspaceInsetX: CGFloat = 8
    static let workspaceGap: CGFloat = 6
    static let cardPaddingX: CGFloat = 10
    static let cardPaddingY = Theme.Space.sm
    static let cardRowGap = Theme.Space.xs
    /// Lines 2 and 3 start under the title, past the state dot.
    static let cardIndent = Theme.Space.lg
    static let titleRowHeight: CGFloat = 16
    static let branchRowHeight: CGFloat = 14
    /// Extra space above the chips.
    static let chipRowTopGap: CGFloat = 2
    static let chipHeight: CGFloat = 20
    static let chipGap = Theme.Space.xs
    static let chipPaddingX: CGFloat = 6
    static let stateDotSize: CGFloat = 8
    static let menuButtonWidth: CGFloat = 18
    static let menuButtonHeight: CGFloat = 16

    // An INACTIVE workspace that asks nothing: one line.
    static let compactRowHeight: CGFloat = 26

    // A workspace's children (docs/sidebar-groups.md): indented, under its
    // summary row.
    static let groupIndent = Theme.Space.md
    static let groupToggleHeight: CGFloat = 18

    // The action block: rows separated by `actionRowGap`; a line above it
    // unless it only says something (the next step, the review badges).
    static let actionBlockGap: CGFloat = 8
    static let quietBlockGap: CGFloat = 6
    static let actionRowGap: CGFloat = 6
    static let actionLineHeight: CGFloat = 14
    static let buttonHeight: CGFloat = 22
    static let buttonPaddingX: CGFloat = 10
    static let buttonGap: CGFloat = 6

    // Allow / Deny: the request text is printable ASCII in a monospaced
    // font, hard-wrapped at a fixed column so the lines are exactly the
    // text, cut nowhere.
    static var approvalFont: NSFont { Theme.Font.code }
    static let approvalCharactersPerLine = 26
    static let approvalLineHeight: CGFloat = 16
    /// 26 characters of `approvalFont` take 193 of a child card's box, 200.
    static let approvalBoxPaddingX: CGFloat = 6
    static let approvalBoxPaddingY: CGFloat = 6

    static func approvalLines(_ text: String) -> [String] {
        var lines: [String] = []
        var rest = Substring(text)
        repeat {
            lines.append(String(rest.prefix(approvalCharactersPerLine)))
            rest = rest.dropFirst(approvalCharactersPerLine)
        } while !rest.isEmpty
        return lines
    }

    static func approvalBoxHeight(for approval: SidebarPermissionApproval) -> CGFloat {
        CGFloat(approvalLines(approval.text).count) * approvalLineHeight + approvalBoxPaddingY * 2
    }

    /// "claude wants to run", the request, then the buttons (or the
    /// decision on its way).
    static func approvalBlockHeight(for approval: SidebarPermissionApproval) -> CGFloat {
        actionLineHeight + actionRowGap + approvalBoxHeight(for: approval) + actionRowGap + buttonHeight
    }

    /// The error and Resume on one line, or the error over where Resume
    /// stands.
    static func resumeBlockHeight(for resume: SidebarStuckState.Resume) -> CGFloat {
        resume.status == nil ? buttonHeight : actionLineHeight + actionRowGap + actionLineHeight
    }

    static func height(of action: SidebarCardAction) -> CGFloat {
        switch action {
        case .approval(_, _, let approval): return approvalBlockHeight(for: approval)
        case .resume(_, _, _, _, let resume): return resumeBlockHeight(for: resume)
        case .blocker, .cleanup, .reviewBadges, .next: return actionLineHeight
        }
    }

    /// The block under line 3, gap included; 0 without actions.
    static func actionBlockHeight(_ actions: [SidebarCardAction]) -> CGFloat {
        guard !actions.isEmpty else { return 0 }
        let top = actions.allSatisfy(\.isQuiet) ? quietBlockGap : actionBlockGap + 1 + actionBlockGap
        let rows = actions.reduce(CGFloat(0)) { $0 + height(of: $1) }
        return top + rows + CGFloat(actions.count - 1) * actionRowGap
    }

    @MainActor
    static func groupHeight(for infos: [WorkspaceInfo], sidebarWidth: CGFloat) -> CGFloat {
        infos.reduce(CGFloat(0)) { total, info in
            total + workspaceHeight(for: info, sidebarWidth: sidebarWidth) + workspaceGap
        }
    }

    @MainActor
    static func workspaceHeight(for workspace: WorkspaceInfo, sidebarWidth: CGFloat) -> CGFloat {
        SidebarCardLayout(workspace: workspace, sidebarWidth: sidebarWidth).height
    }
}
