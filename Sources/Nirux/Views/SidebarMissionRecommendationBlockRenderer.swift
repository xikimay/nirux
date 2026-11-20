import AppKit

/// The block under a Mission question that waits on the user, when its
/// child recommends an answer: the recommendation under its heading (what
/// the child needs, for an access question), then Reply…, and Accept when
/// the user may send the recommendation as the answer. Both arm like
/// Allow / Deny: Accept answers for the user.
@MainActor
struct SidebarMissionRecommendationBlockRenderer {
    typealias Metrics = SidebarExpandedMetrics

    let question: SidebarMissionQuestion
    let workspaceIndex: Int
    let columnIndex: Int
    /// Left edge and width of the card's content.
    let x: CGFloat
    let width: CGFloat
    let top: CGFloat

    static let maxLines = 4

    /// "Recommended  <text>": the heading grey, the text as a question's.
    static func text(_ question: SidebarMissionQuestion) -> NSAttributedString {
        let text = NSMutableAttributedString(string: question.recommendationTitle, attributes: [
            .font: Metrics.questionFont, .foregroundColor: Theme.Color.textTertiary,
        ])
        text.append(SidebarColumnChip.spacer(6))
        text.append(NSAttributedString(string: question.recommendation ?? "", attributes: [
            .font: Metrics.questionFont, .foregroundColor: Theme.Color.textPrimary,
        ]))
        return text
    }

    static func textHeight(_ question: SidebarMissionQuestion, width: CGFloat) -> CGFloat {
        SidebarWrappedText.height(text(question), width: width, lineHeight: Metrics.questionLineHeight, maxLines: maxLines)
    }

    static func height(of question: SidebarMissionQuestion, width: CGFloat) -> CGFloat {
        textHeight(question, width: width) + Metrics.actionRowGap + Metrics.buttonHeight
    }

    /// Reply…, then Accept at the right edge when there is one and the
    /// block shows it whole: Accept sends it all, and the popover has it.
    static func answers(_ question: SidebarMissionQuestion, width: CGFloat) -> [(accepts: Bool, title: String, label: String)] {
        var answers = [(accepts: false, title: "Reply…", label: "Reply to: \(question.text)")]
        let whole = SidebarWrappedText.height(text(question), width: width, lineHeight: Metrics.questionLineHeight, maxLines: .max)
        if let recommendation = question.acceptableRecommendation, textHeight(question, width: width) >= whole {
            answers.append((accepts: true, title: "Accept", label: "Accept the recommendation: \(recommendation)"))
        }
        return answers
    }

    func render() -> SidebarApprovalBlockRenderer.Result {
        let height = Self.height(of: question, width: width)
        let label = SidebarWrappedText.label(Self.text(question), lineHeight: Metrics.questionLineHeight, maxLines: Self.maxLines)
        let textHeight = Self.textHeight(question, width: width)
        label.frame = NSRect(x: x, y: top - textHeight, width: width, height: textHeight)
        label.toolTip = question.recommendationLine
        label.setAccessibilityLabel(question.recommendationLine)
        var views: [NSView] = [label]
        var hitAreas: [SidebarHitArea] = []
        var buttons: [String: SidebarBadgeView] = [:]
        var right = x + width
        for answer in Self.answers(question, width: width).reversed() {
            let button = answer.accepts
                ? SidebarActionButton.primary(answer.title, label: answer.label)
                : SidebarActionButton.secondary(answer.title, label: answer.label)
            let buttonWidth = button.fittingWidth
            button.frame = NSRect(x: right - buttonWidth, y: top - height, width: buttonWidth, height: Metrics.buttonHeight)
            right = button.frame.minX - Metrics.buttonGap
            views.append(button)
            let region = SidebarHitRegion.missionAnswer(
                workspaceIndex: workspaceIndex, columnIndex: columnIndex, questionID: question.questionID, accepts: answer.accepts
            )
            if let key = SidebarView.armedButtonKey(for: region) { buttons[key] = button }
            hitAreas.append(SidebarHitArea(frame: button.frame.insetBy(dx: -3, dy: -3), region: region))
        }
        // Between the buttons a click does nothing.
        let buttonsLine = NSRect(x: x, y: top - height - 3, width: width, height: Metrics.buttonHeight + 6)
        hitAreas.append(SidebarHitArea(frame: buttonsLine, region: .actionBlock(workspaceIndex: workspaceIndex)))
        return SidebarApprovalBlockRenderer.Result(views: views, hitAreas: hitAreas, buttons: buttons)
    }
}
