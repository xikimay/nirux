import AppKit

/// The block of a card whose Claude ended its turn on a question: the
/// question (unless the status line above says it), then Reply…, and No
/// and Yes when a plain yes or no answers it (macOS order, the yes last at
/// the right edge). The buttons arm like Allow / Deny: "yes" can start a
/// merge or a push.
@MainActor
struct SidebarTurnQuestionBlockRenderer {
    let question: SidebarTurnQuestion
    let showsQuestion: Bool
    let workspaceIndex: Int
    let columnIndex: Int
    /// Left edge and width of the card's content.
    let x: CGFloat
    let width: CGFloat
    let top: CGFloat

    func render() -> SidebarApprovalBlockRenderer.Result {
        let metrics = SidebarExpandedMetrics.self
        let height = metrics.buttonHeight
        let blockFrame = NSRect(x: x, y: top - height, width: width, height: height)
        var views: [NSView] = []
        var hitAreas: [SidebarHitArea] = []
        var buttons: [String: SidebarBadgeView] = [:]

        var answers: [(SidebarTurnAnswer, SidebarBadgeView)] = [
            (.reply, SidebarActionButton.secondary("Reply…", label: "Reply to: \(question.text)")),
        ]
        if question.isYesNo {
            answers.append((.no, SidebarActionButton.secondary("No", label: "Answer no to: \(question.text)")))
            answers.append((.yes, SidebarActionButton.primary("Yes", label: "Answer yes to: \(question.text)")))
        }
        var right = x + width
        for (answer, button) in answers.reversed() {
            let buttonWidth = max(button.fittingWidth, answer == .reply ? 0 : 44)
            button.frame = NSRect(x: right - buttonWidth, y: top - height, width: buttonWidth, height: metrics.buttonHeight)
            right = button.frame.minX - metrics.buttonGap
            views.append(button)
            let region = SidebarHitRegion.turnAnswer(
                workspaceIndex: workspaceIndex, columnIndex: columnIndex, question: question, answer: answer
            )
            if let key = SidebarView.armedButtonKey(for: region) { buttons[key] = button }
            hitAreas.append(SidebarHitArea(frame: button.frame.insetBy(dx: -3, dy: -3), region: region))
        }
        if showsQuestion {
            views.append(questionLine(y: top - (height + metrics.actionLineHeight) / 2, width: right - x))
        }
        hitAreas.append(SidebarHitArea(frame: blockFrame, region: .actionBlock(workspaceIndex: workspaceIndex)))
        return SidebarApprovalBlockRenderer.Result(views: views, hitAreas: hitAreas, buttons: buttons)
    }

    /// The question, clipped to what's left of the line; whole in the
    /// tooltip.
    private func questionLine(y: CGFloat, width: CGFloat) -> NSTextField {
        let label = NSTextField.sidebarLine(NSAttributedString(string: question.text, attributes: [
            .font: Theme.Font.caption, .foregroundColor: Theme.Color.waiting,
        ]))
        label.frame = NSRect(x: x, y: y - 1, width: max(0, width), height: SidebarExpandedMetrics.actionLineHeight + 2)
        label.toolTip = question.text
        label.setAccessibilityLabel("Claude asks: \(question.text)")
        return label
    }
}
