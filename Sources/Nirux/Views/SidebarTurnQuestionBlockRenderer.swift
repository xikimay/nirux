import AppKit

/// The texts of a question's block, as its renderer draws them and
/// `SidebarExpandedMetrics` measures them: the question whole, and under
/// their markers the choices a message lists or the options a dialog
/// offers.
@MainActor
enum SidebarQuestionText {
    typealias Metrics = SidebarExpandedMetrics

    static func question(_ text: String) -> NSAttributedString {
        NSAttributedString(string: AgentText.withoutMarks(text), attributes: [
            .font: Metrics.questionFont, .foregroundColor: Theme.Color.textPrimary,
        ])
    }

    static func questionHeight(_ text: String, width: CGFloat, maxLines: Int = Metrics.questionMaxLines) -> CGFloat {
        SidebarWrappedText.height(question(text), width: width, lineHeight: Metrics.questionLineHeight, maxLines: maxLines)
    }

    static func questionLabel(_ text: String, maxLines: Int = Metrics.questionMaxLines) -> NSTextField {
        let label = SidebarWrappedText.label(question(text), lineHeight: Metrics.questionLineHeight, maxLines: maxLines)
        label.toolTip = text
        return label
    }

    /// A list's items under their markers: all hang at one indent, past
    /// the widest marker.
    @MainActor
    struct Items {
        let texts: [NSAttributedString]
        let indent: CGFloat

        private func height(of item: NSAttributedString, width: CGFloat) -> CGFloat {
            SidebarWrappedText.height(
                item, width: width, lineHeight: Metrics.questionLineHeight, maxLines: Metrics.choiceMaxLines, indent: indent
            )
        }

        /// Stacked `choiceGap` apart; 0 without any.
        func height(width: CGFloat) -> CGFloat {
            guard !texts.isEmpty else { return 0 }
            return texts.reduce(CGFloat(0)) { $0 + height(of: $1, width: width) } + CGFloat(texts.count - 1) * Metrics.choiceGap
        }

        /// Their labels, stacked down from `top`.
        func labels(x: CGFloat, width: CGFloat, top: CGFloat) -> [NSTextField] {
            var y = top
            return texts.map { item in
                let height = height(of: item, width: width)
                let label = SidebarWrappedText.label(
                    item, lineHeight: Metrics.questionLineHeight, maxLines: Metrics.choiceMaxLines, indent: indent
                )
                label.frame = NSRect(x: x, y: y - height, width: width, height: height)
                label.toolTip = item.string.replacingOccurrences(of: "\t", with: " ")
                y -= height + Metrics.choiceGap
                return label
            }
        }
    }

    /// The choices as the message lists them, each under its own marker
    /// ("1.", "B)"), a dot for a bullet.
    static func choices(_ choices: [TurnEndChoice]) -> Items {
        items(choices.map { choice in
            (choice.marker ?? "•", NSAttributedString(string: AgentText.withoutMarks(choice.text), attributes: [
                .font: Metrics.questionFont, .foregroundColor: Theme.Color.textSecondary,
            ]))
        })
    }

    /// The options of a dialog's question, numbered as the terminal
    /// numbers them: the label and what the agent says it means, the label
    /// alone, and the tooltip that always has both.
    static func options(_ question: AgentDialog.Question) -> (whole: Items, labels: Items, toolTips: [String]) {
        let numbered = question.options.enumerated().map { index, option in
            (marker: "\(index + 1).", label: AgentText.withoutMarks(option.label),
             meaning: option.detail.map { " — \(AgentText.withoutMarks($0))" } ?? "")
        }
        @MainActor func label(_ text: String) -> NSMutableAttributedString {
            NSMutableAttributedString(string: text, attributes: [.font: Metrics.questionFont, .foregroundColor: Theme.Color.textPrimary])
        }
        let whole = items(numbered.map { option in
            let text = label(option.label)
            text.append(NSAttributedString(string: option.meaning, attributes: [
                .font: Metrics.questionFont, .foregroundColor: Theme.Color.textSecondary,
            ]))
            return (option.marker, text)
        })
        let labels = items(numbered.map { ($0.marker, label($0.label)) })
        return (whole, labels, numbered.map { "\($0.marker) \($0.label)\($0.meaning)" })
    }

    private static func items(_ items: [(marker: String, text: NSAttributedString)]) -> Items {
        let marker: [NSAttributedString.Key: Any] = [.font: Metrics.questionFont, .foregroundColor: Theme.Color.textTertiary]
        let widest = items.map { ceil(($0.marker as NSString).size(withAttributes: marker).width) }.max() ?? 0
        let texts = items.map { item in
            let text = NSMutableAttributedString(string: item.marker + "\t", attributes: marker)
            text.append(item.text)
            return text
        }
        return Items(texts: texts, indent: max(Metrics.choiceIndent, widest + Metrics.choiceMarkerGap))
    }
}

/// The block of a card whose Claude ended its turn on a question: the
/// choices the message lists next to it, the question whole, then on a
/// line of their own Reply…, and No and Yes when a plain yes or no answers
/// it (macOS order, the yes last at the right edge). At the left of that
/// line, a quiet Dismiss puts the question aside: it stays on the card
/// until answered otherwise, and not every turn that asks needs an answer.
/// The buttons arm like Allow / Deny: "yes" can start a merge or a push.
@MainActor
struct SidebarTurnQuestionBlockRenderer {
    let question: SidebarTurnQuestion
    let workspaceIndex: Int
    let columnIndex: Int
    /// Left edge and width of the card's content.
    let x: CGFloat
    let width: CGFloat
    let top: CGFloat

    func render() -> SidebarApprovalBlockRenderer.Result {
        let metrics = SidebarExpandedMetrics.self
        let height = metrics.turnQuestionBlockHeight(for: question, width: width)
        var views: [NSView] = []
        var hitAreas: [SidebarHitArea] = []
        var buttons: [String: SidebarBadgeView] = [:]

        var y = top
        let choices = SidebarQuestionText.choices(question.choices)
        if !choices.texts.isEmpty {
            views += choices.labels(x: x, width: width, top: y)
            y -= choices.height(width: width) + metrics.questionGap
        }
        let asked = SidebarQuestionText.questionLabel(question.text)
        let askedHeight = SidebarQuestionText.questionHeight(question.text, width: width)
        asked.frame = NSRect(x: x, y: y - askedHeight, width: width, height: askedHeight)
        asked.setAccessibilityLabel("Claude asks: \(question.text)")
        views.append(asked)

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
        // Its word starts where the question's lines do.
        let dismiss = SidebarActionButton.quiet("Dismiss", label: "Dismiss this question without answering it")
        dismiss.toolTip = "Take this question off the row without answering it. Claude still waits at its prompt."
        dismiss.frame = NSRect(
            x: x + 2 - metrics.buttonPaddingX, y: top - height, width: dismiss.fittingWidth, height: metrics.buttonHeight
        )
        views.append(dismiss)
        let region = SidebarHitRegion.turnAnswer(
            workspaceIndex: workspaceIndex, columnIndex: columnIndex, question: question, answer: .dismiss
        )
        if let key = SidebarView.armedButtonKey(for: region) { buttons[key] = dismiss }
        hitAreas.append(SidebarHitArea(frame: dismiss.frame.insetBy(dx: 0, dy: -3), region: region))
        // Between the buttons a click does nothing. On the question and its
        // choices it is the row's: it selects the task, as on any line.
        let buttonsLine = NSRect(x: x, y: top - height - 3, width: width, height: metrics.buttonHeight + 6)
        hitAreas.append(SidebarHitArea(frame: buttonsLine, region: .actionBlock(workspaceIndex: workspaceIndex)))
        return SidebarApprovalBlockRenderer.Result(views: views, hitAreas: hitAreas, buttons: buttons)
    }
}

/// The block of a card whose agent shows a question dialog (Claude's
/// AskUserQuestion): each of its questions whole over the options it
/// offers, then where to answer. A dialog too tall for the sidebar gives
/// way by steps (`SidebarDialogLayout`). Nothing to press: a click
/// anywhere on it brings the dialog's column in front, as a click on its
/// chip does.
@MainActor
struct SidebarDialogBlockRenderer {
    let dialog: AgentDialog
    let workspaceIndex: Int
    let columnIndex: Int
    /// Left edge and width of the card's content.
    let x: CGFloat
    let width: CGFloat
    let top: CGFloat

    func render() -> SidebarApprovalBlockRenderer.Result {
        let metrics = SidebarExpandedMetrics.self
        let layout = SidebarDialogLayout.make(dialog, width: width)
        var views: [NSView] = []
        var y = top
        @MainActor @discardableResult
        func place(_ line: SidebarDialogLayout.Line, indent: CGFloat = 0) -> NSTextField {
            let label = SidebarWrappedText.label(line.text, lineHeight: metrics.questionLineHeight, maxLines: line.lines, indent: indent)
            label.frame = NSRect(x: x, y: y - line.height, width: width, height: line.height)
            label.toolTip = line.toolTip
            views.append(label)
            y -= line.height
            return label
        }
        for (position, question) in layout.questions.enumerated() {
            if position > 0 { y -= metrics.dialogQuestionGap }
            place(question.asked).setAccessibilityLabel("Claude asks: \(question.asked.toolTip)")
            if !question.options.isEmpty { y -= metrics.questionGap }
            for (index, option) in question.options.enumerated() {
                if index > 0 { y -= metrics.choiceGap }
                place(option, indent: question.indent).setAccessibilityLabel(option.toolTip)
            }
        }
        y -= metrics.actionRowGap
        let hint = NSTextField.sidebarLine(NSAttributedString(string: layout.hint, attributes: [
            .font: Theme.Font.caption, .foregroundColor: Theme.Color.textTertiary,
        ]))
        hint.frame = NSRect(x: x, y: y - metrics.actionLineHeight - 1, width: width, height: metrics.actionLineHeight + 2)
        views.append(hint)
        let block = NSRect(x: x, y: top - layout.height, width: width, height: layout.height)
        return SidebarApprovalBlockRenderer.Result(
            views: views,
            hitAreas: [SidebarHitArea(frame: block, region: .column(workspaceIndex: workspaceIndex, columnIndex: columnIndex))],
            buttons: [:]
        )
    }
}
