import AppKit

enum SidebarExpandedMetrics {
    // Top to bottom: the space picker, the Tasks header and the cards;
    // the Archived row at the bottom, its list above it.
    static let topPadding = Theme.Space.md
    static let pickerHeight: CGFloat = 32
    static let pickerDotSize: CGFloat = 10
    static let pickerBottomGap = Theme.Space.md
    static let tasksHeaderHeight: CGFloat = 26
    static let headerButtonSize: CGFloat = 20
    static let onboardingCardGap: CGFloat = 8
    /// The least room between the last card and the archived block.
    static let archivedGap = Theme.Space.md
    static let archivedRowHeight: CGFloat = 30
    /// Between the archived list and the Archived row under it.
    static let archivedListGap: CGFloat = 6
    static let bottomPadding = Theme.Space.sm

    // A task row: the state mark and title, the status line; the selected
    // row adds its columns; then an action block only when there is
    // something to do.
    static let workspaceInsetX: CGFloat = 8
    static let workspaceGap: CGFloat = 2
    /// A Mission child's row, under its parent's.
    static let nestIndent: CGFloat = 12
    static let cardPaddingX: CGFloat = 10
    static let rowPaddingY: CGFloat = 7
    static let titleRowHeight: CGFloat = 16
    static let statusGap: CGFloat = 2
    static let statusRowHeight: CGFloat = 15
    /// Above the selected row's columns.
    static let columnsGap: CGFloat = 6
    static let chipHeight: CGFloat = 20
    static let chipGap = Theme.Space.xs
    static let chipPaddingX: CGFloat = 6
    static let stateDotSize: CGFloat = 8
    /// Where row text starts, past the state dot: titles, status lines,
    /// columns, the space picker's name, the Archived row's.
    static var textX: CGFloat { workspaceInsetX + cardPaddingX + stateDotSize + Theme.Space.sm }
    /// The middle of the state marks' column, where the picker's dot and the
    /// Archived row's icon center.
    static var markCenterX: CGFloat { workspaceInsetX + cardPaddingX + stateDotSize / 2 }
    static let menuButtonWidth: CGFloat = 18
    static let menuButtonHeight: CGFloat = 16

    /// The Lead's row: its sign, its title, its state; one line.
    static let leadRowHeight: CGFloat = 32
    /// Between the Lead's row and the Tasks header.
    static let leadGap = Theme.Space.xs

    // An archived workspace that asks nothing: one line.
    static let compactRowHeight: CGFloat = 26

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
    static let approvalCharactersPerLine = 28
    static let approvalLineHeight: CGFloat = 16
    /// 28 characters of `approvalFont` take 208 of the box's 212.
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

    // A question on a card: what the agent wrote, whole, over what
    // answers it. Lines of text wrap (`SidebarWrappedText`).
    static var questionFont: NSFont { Theme.Font.body }
    static let questionLineHeight: CGFloat = 15
    static let questionMaxLines = 8
    /// A choice the message lists, a dialog's option, under its marker:
    /// 18 points in, or past a marker wider than "1.".
    static let choiceMaxLines = 6
    static let choiceIndent: CGFloat = 18
    static let choiceMarkerGap: CGFloat = 6
    static let choiceGap: CGFloat = 2
    /// Between the choices and the question, the question and its options.
    static let questionGap: CGFloat = 5
    /// The selected row's next step, a Mission question's line.
    static let nextStepMaxLines = 3
    static let missionQuestionMaxLines = 2

    /// The choices the message lists, the question, then the buttons.
    @MainActor
    static func turnQuestionBlockHeight(for question: SidebarTurnQuestion, width: CGFloat) -> CGFloat {
        let choices = SidebarQuestionText.choices(question.choices).height(width: width)
        return (choices > 0 ? choices + questionGap : 0) + SidebarQuestionText.questionHeight(question.text, width: width)
            + actionRowGap + buttonHeight
    }

    /// A dialog's question, and each of its options: as long as its hook
    /// lets them be (`AgentDialog.bounded`), in wide letters too, so none
    /// is cut.
    static let dialogMaxLines = 18
    /// Between two questions of one dialog.
    static let dialogQuestionGap: CGFloat = 10
    /// A dialog's block taller than this leaves what each option means to
    /// its tooltip and to the terminal: several questions with all they
    /// offer would take the sidebar from the other rows.
    static let dialogDetailsMaxHeight: CGFloat = 420

    /// Whether the block says what each option means, next to its label.
    @MainActor
    static func dialogShowsDetails(_ dialog: AgentDialog, width: CGFloat) -> Bool {
        dialogBlockHeight(for: dialog, width: width, details: true) <= dialogDetailsMaxHeight
    }

    /// Each question with its options, then where to answer.
    @MainActor
    static func dialogBlockHeight(for dialog: AgentDialog, width: CGFloat) -> CGFloat {
        dialogBlockHeight(for: dialog, width: width, details: dialogShowsDetails(dialog, width: width))
    }

    @MainActor
    private static func dialogBlockHeight(for dialog: AgentDialog, width: CGFloat, details: Bool) -> CGFloat {
        dialog.questions.reduce(CGFloat(0)) { height, question in
            // One question over the options it offers.
            let options = SidebarQuestionText.options(question, details: details).height(width: width)
            return height + SidebarQuestionText.questionHeight(question.text, width: width, maxLines: dialogMaxLines)
                + (options > 0 ? questionGap + options : 0)
        } + CGFloat(max(dialog.questions.count - 1, 0)) * dialogQuestionGap + actionRowGap + actionLineHeight
    }

    /// `width`: the block's, the card's content. `textWidth`: a line's
    /// that starts under the title.
    @MainActor
    static func height(of action: SidebarCardAction, width: CGFloat, textWidth: CGFloat) -> CGFloat {
        switch action {
        case .approval(_, _, let approval): return approvalBlockHeight(for: approval)
        case .resume(_, _, _, _, let resume): return resumeBlockHeight(for: resume)
        case .turnQuestion(_, let question): return turnQuestionBlockHeight(for: question, width: width)
        case .dialog(_, let dialog): return dialogBlockHeight(for: dialog, width: width)
        case .next(let text):
            return SidebarWrappedText.height(
                SidebarWorkspaceCardRenderer.nextText(text), width: textWidth, lineHeight: actionLineHeight, maxLines: nextStepMaxLines
            )
        case .missionQuestion(_, let question):
            return SidebarWrappedText.height(
                SidebarWorkspaceCardRenderer.missionQuestionText(question), width: textWidth, lineHeight: actionLineHeight,
                maxLines: missionQuestionMaxLines
            )
        case .cleanup, .reviewBadges, .ruleProposals: return actionLineHeight
        }
    }

    /// The block under line 3, gap included; 0 without actions.
    @MainActor
    static func actionBlockHeight(_ actions: [SidebarCardAction], width: CGFloat, textWidth: CGFloat) -> CGFloat {
        guard !actions.isEmpty else { return 0 }
        let top = actions.allSatisfy(\.isQuiet) ? quietBlockGap : actionBlockGap + 1 + actionBlockGap
        let rows = actions.reduce(CGFloat(0)) { $0 + height(of: $1, width: width, textWidth: textWidth) }
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
