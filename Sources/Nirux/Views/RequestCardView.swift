import AppKit

/// An agent's request as the glass interface's inbox and the rail's callout
/// show it (docs/design/glass-interface.md).
struct WaitingRequest: Equatable {
    enum Kind: Equatable {
        case permission(SidebarPermissionApproval)
        case question(SidebarTurnQuestion)
        /// A question dialog (AskUserQuestion): its first question; only the
        /// terminal answers.
        case dialog(question: String, more: Int)
        case mission(SidebarMissionQuestion)
        /// A prompt only the terminal answers: a folder's trust, a resumed
        /// session's choice.
        case terminal(String)
    }

    /// The task to go to.
    var taskID: String
    /// The column whose agent asks: the receivers find it there.
    var columnID: UUID
    var taskTitle: String
    var icon: StateIcon
    /// How long it has waited ("4m"), worded by the caller.
    var waited: String?
    var kind: Kind

    /// The request itself, never its task: a request that takes another's
    /// place gets a card of its own, its buttons unarmed.
    var id: String {
        switch kind {
        case .permission(let approval): return "permission \(approval.requestID)"
        case .question(let question): return "question \(question.columnID) \(question.turnEndedAt)"
        case let .dialog(question, _): return "dialog \(columnID) \(question)"
        case .mission(let question): return "mission \(question.questionID)"
        case .terminal(let prompt): return "terminal \(columnID) \(prompt)"
        }
    }

    /// What VoiceOver says before the request's text.
    var asker: String {
        switch kind {
        case .question, .dialog: return "Claude asks"
        case .mission: return "The agent asks"
        case .permission, .terminal: return "The terminal asks"
        }
    }

    /// Only the terminal answers it: the inbox leads there.
    var answersInTerminal: Bool {
        switch kind {
        case .dialog, .terminal: return true
        case .permission(let approval): return approval.display == .undelivered
        case .question, .mission: return false
        }
    }

    /// What the agent does, after the task's title.
    var verb: String {
        if case .permission(let approval) = kind { return RequestChoices.permissionVerb(toolName: approval.toolName) }
        return "asks"
    }
}

/// One request: its task (state icon, title, what the agent wants, how long
/// it has waited, or "Open task" in the callout), the request itself (the
/// exact command in its box, the question), then its answers from
/// `RequestChoices` or where to answer. A button takes a click only when
/// its container's arming says so (`canAnswer`), on a single click.
final class RequestCardView: NSView {
    /// What ends the header: the wait (the inbox) or the way to the task (the
    /// callout).
    enum Trailing {
        case waited, openTask
    }

    static let padding = Theme.Space.md
    private static let gap = Theme.Space.sm
    private static let headerHeight: CGFloat = 18
    typealias Metrics = SidebarExpandedMetrics
    /// One character of the command's font: the box's lines are cut by it.
    private static let characterWidth = ("0" as NSString).size(withAttributes: [.font: Metrics.approvalFont]).width

    /// A click on an answer, with its button to anchor what it opens (Reply…).
    var onAnswer: ((RequestChoice, NSView) -> Void)?
    /// Asked at the press and at the release: the container's arming.
    var canAnswer: ((RequestChoice) -> Bool)?
    var onOpenTask: (() -> Void)?
    /// A click on the card, not on a button.
    var onClick: (() -> Void)?

    /// The keyboard's choice in the inbox.
    var isChosen = false {
        didSet { layer?.backgroundColor = isChosen ? Theme.Color.fillSelected.cgColor : nil }
    }

    let trailing: Trailing
    private(set) var request: WaitingRequest?
    let iconView = StateIconView(StateIcon(.idle), size: 14)
    let titleLabel = NSTextField(labelWithString: "")
    let verbLabel = NSTextField(labelWithString: "")
    let waitedLabel = NSTextField(labelWithString: "")
    let openButton = NiruxButton(title: "Open task", kind: .quiet, size: .small)
    /// In the inbox, a request only the terminal answers: the way there.
    let terminalButton = NiruxButton(title: "Open task", kind: .secondary, size: .small)
    /// The command, exact, in its box.
    let box = NSView()
    let commandLabel = NSTextField(labelWithString: "")
    /// The question, a dialog's or a prompt's text, as a row wraps it.
    let textLabel = SidebarWrappedText.label(NSAttributedString(), lineHeight: Metrics.questionLineHeight, maxLines: Metrics.questionMaxLines)
    /// What a question chooses between, as its message lists it: the row's
    /// items under their markers.
    let choicesView = NSView()
    private var choices = SidebarQuestionText.choices([])
    /// The width the choices' labels were made for.
    private var choicesWidth: CGFloat?
    /// Where to answer, or the decision on its way.
    let noteLabel = NSTextField(labelWithString: "")
    private(set) var answerButtons: [RequestChoice: NiruxButton] = [:]
    /// The answers in their order, left to right; a quiet one stands apart
    /// on the left.
    private var buttonOrder: [RequestChoice] = []
    /// The command's lines as its box shows them.
    private(set) var commandLines: [String] = []
    /// The answers shown: the buttons stay while they don't change (a
    /// press, a hover survive the wait's minute ticking).
    private var shownButtons: [RequestButton]?
    /// The request an answer's press was on: its release answers that one,
    /// or nothing if another took the card meanwhile.
    private var pressedRequestID: String?
    /// The heights measured, by width (the inbox measures at two beside a
    /// legacy scroller), until the content changes.
    private var measured: [CGFloat: CGFloat] = [:]

    init(trailing: Trailing) {
        self.trailing = trailing
        super.init(frame: .zero)
        wantsLayer = true
        titleLabel.font = Theme.Font.bodyEmphasized
        titleLabel.textColor = Theme.Color.textPrimary
        titleLabel.lineBreakMode = .byTruncatingTail
        verbLabel.font = Theme.Font.body
        verbLabel.textColor = Theme.Color.textSecondary
        waitedLabel.font = Theme.Font.caption
        waitedLabel.textColor = Theme.Color.textTertiary
        waitedLabel.alignment = .right
        // The card says its task, what the agent wants and how long ago.
        for label in [titleLabel, verbLabel, waitedLabel] {
            label.setAccessibilityElement(false)
            label.cell?.setAccessibilityElement(false)
        }
        for button in [openButton, terminalButton] {
            button.target = self
            button.action = #selector(openTask)
            // A double-click's second press lands on whatever took the
            // place of what its first press answered.
            button.acceptsPress = { $0.clickCount == 1 }
        }
        box.wantsLayer = true
        box.layer?.cornerRadius = Theme.Radius.control
        box.layer?.backgroundColor = Theme.Color.canvas.withAlphaComponent(0.6).cgColor
        box.layer?.borderWidth = 1
        box.layer?.borderColor = Theme.Color.line.cgColor
        box.addSubview(commandLabel)
        noteLabel.font = Theme.Font.caption
        noteLabel.lineBreakMode = .byTruncatingTail
        let views: [NSView] = [iconView, titleLabel, verbLabel, waitedLabel, openButton, box, choicesView, textLabel, noteLabel, terminalButton]
        for view in views {
            addSubview(view)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    func show(_ request: WaitingRequest) {
        guard request != self.request else { return }
        self.request = request
        measured = [:]
        iconView.icon = request.icon
        titleLabel.stringValue = request.taskTitle
        verbLabel.stringValue = request.verb
        waitedLabel.stringValue = request.waited ?? ""
        waitedLabel.isHidden = trailing != .waited || request.waited == nil
        openButton.isHidden = trailing != .openTask
        openButton.setAccessibilityLabel("Open \(request.taskTitle)")
        terminalButton.setAccessibilityLabel("Open \(request.taskTitle) to answer in the terminal")
        setAccessibilityLabel([request.taskTitle, request.verb, request.waited.map { "waiting \($0)" }].compactMap { $0 }.joined(separator: ", "))

        let text = requestText
        var choices: [TurnEndChoice] = [], note: (String, NSColor)?, buttons: [RequestButton] = []
        box.isHidden = true
        switch request.kind {
        case .permission(let approval):
            box.isHidden = false
            commandLabel.setAccessibilityLabel(RequestChoices.permissionRequestLabel(approval))
            if let status = RequestChoices.permissionStatus(approval.display) {
                note = (status, approval.display == .undelivered ? Theme.Color.textSecondary : Theme.Color.textTertiary)
            } else {
                buttons = RequestChoices.permission(approval)
            }
        case .question(let question):
            choices = question.choices
            buttons = [RequestChoices.dismiss(question)] + RequestChoices.turn(question)
        case let .dialog(_, more):
            note = (SidebarDialogLayout.hint(more: more), Theme.Color.textSecondary)
        case .mission(let question):
            buttons = [RequestChoices.missionReply(question)]
        case .terminal:
            note = (SidebarDialogLayout.hint(more: 0), Theme.Color.textSecondary)
        }
        textLabel.attributedStringValue = SidebarWrappedText.wrapping(
            SidebarQuestionText.question(text ?? ""), lineHeight: Metrics.questionLineHeight
        )
        // On the card: off its buttons, the pointer is the card's.
        if case .permission(let approval) = request.kind {
            toolTip = RequestChoices.permissionToolTip(approval)
        } else {
            toolTip = text
        }
        textLabel.isHidden = text == nil
        textLabel.setAccessibilityLabel(text.map { "\(request.asker): \($0)" })
        self.choices = SidebarQuestionText.choices(choices)
        choicesWidth = nil
        choicesView.isHidden = choices.isEmpty
        noteLabel.stringValue = note?.0 ?? ""
        noteLabel.textColor = note?.1
        noteLabel.isHidden = note == nil
        terminalButton.isHidden = trailing != .waited || !request.answersInTerminal
        showButtons(buttons)
        needsLayout = true
    }

    private func showButtons(_ buttons: [RequestButton]) {
        guard buttons != shownButtons else { return }
        shownButtons = buttons
        answerButtons.values.forEach { $0.removeFromSuperview() }
        answerButtons = [:]
        buttonOrder = buttons.map(\.choice)
        for answer in buttons {
            let kind: NiruxButton.Kind = switch answer.role {
            case .primary: .primary
            case .secondary: .secondary
            case .quiet: .quiet
            }
            let button = NiruxButton(title: answer.title, kind: kind, size: .small, target: self, action: #selector(answered(_:)))
            button.setAccessibilityLabel(answer.accessibilityLabel)
            button.toolTip = answer.toolTip
            let choice = answer.choice
            // A single click, on a button its container armed; its release
            // answers the request it pressed.
            button.acceptsPress = { [weak self] event in
                guard let self, event.clickCount == 1, self.canAnswer?(choice) == true else { return false }
                self.pressedRequestID = self.request?.id
                return true
            }
            // Released elsewhere, the press answered nothing: it is over.
            button.pressEnded = { [weak self] in self?.pressedRequestID = nil }
            answerButtons[choice] = button
            addSubview(button)
        }
    }

    @objc private func answered(_ sender: NiruxButton) {
        let pressed = pressedRequestID
        pressedRequestID = nil
        guard let choice = answerButtons.first(where: { $0.value === sender })?.key, canAnswer?(choice) == true else { return }
        // Pressed on one request, released on another in its place.
        if let pressed, pressed != request?.id { return }
        onAnswer?(choice, sender)
    }

    @objc private func openTask() { onOpenTask?() }

    // MARK: - Layout

    /// The card's height at `width`, its content shown: measured once.
    func fittingHeight(width: CGFloat) -> CGFloat {
        if let height = measured[width] { return height }
        let height = place(width: width, apply: false)
        measured[width] = height
        return height
    }

    override func layout() {
        super.layout()
        place(width: bounds.width, apply: true)
    }

    /// Places the content top to bottom (or only measures it) and returns the
    /// height it takes.
    @discardableResult
    private func place(width: CGFloat, apply: Bool) -> CGFloat {
        let inner = width - 2 * Self.padding
        placeHeader(inner: inner, apply: apply)
        var y = placeBody(top: Self.padding + Self.headerHeight + Self.gap, inner: inner, apply: apply)
        y = placeAnswers(top: y, inner: inner, apply: apply)
        return y - Self.gap + Self.padding
    }

    private func set(_ view: NSView, _ frame: NSRect, _ apply: Bool) {
        if apply { view.frame = frame }
    }

    /// The icon, the title, the verb, then the wait or "Open task".
    private func placeHeader(inner: CGFloat, apply: Bool) {
        let padding = Self.padding, header = Self.headerHeight, y = Self.padding
        let icon = iconView.frame.size
        set(iconView, NSRect(x: padding, y: y + (header - icon.height) / 2, width: icon.width, height: icon.height), apply)
        var right = padding + inner
        if !openButton.isHidden {
            let size = openButton.intrinsicContentSize
            set(openButton, NSRect(x: right - size.width, y: y + (header - size.height) / 2, width: size.width, height: size.height), apply)
            right -= size.width + Theme.Space.xs
        } else if !waitedLabel.isHidden {
            let waitedWidth = ceil(waitedLabel.attributedStringValue.size().width) + 4
            set(waitedLabel, NSRect(x: right - waitedWidth, y: y + 2, width: waitedWidth, height: header - 2), apply)
            right -= waitedWidth + Theme.Space.sm
        }
        let titleX = padding + icon.width + Theme.Space.sm
        let verbWidth = ceil(verbLabel.attributedStringValue.size().width) + 4
        let titleRoom = right - titleX - verbWidth - Theme.Space.xs
        let titleWidth = max(0, min(ceil(titleLabel.attributedStringValue.size().width) + 4, titleRoom))
        set(titleLabel, NSRect(x: titleX, y: y + 1, width: titleWidth, height: header - 2), apply)
        let verbX = titleX + titleWidth + Theme.Space.xs
        set(verbLabel, NSRect(x: verbX, y: y + 1, width: min(verbWidth, max(0, right - verbX)), height: header - 2), apply)
    }

    /// The command in its box, the choices, the question; returns where
    /// the answers go.
    private func placeBody(top: CGFloat, inner: CGFloat, apply: Bool) -> CGFloat {
        let padding = Self.padding
        var y = top
        if !box.isHidden, case .permission(let approval)? = request?.kind {
            let metrics = Metrics.self
            let perLine = Int((inner - 2 * metrics.approvalBoxPaddingX - 4) / max(Self.characterWidth, 1))
            let lines = SidebarExpandedMetrics.approvalLines(approval.text, perLine: perLine)
            // Measuring leaves the box as it is.
            if apply, lines != commandLines {
                commandLines = lines
                commandLabel.attributedStringValue = SidebarApprovalBlockRenderer.attributedLines(lines)
                commandLabel.maximumNumberOfLines = lines.count
            }
            let textHeight = CGFloat(lines.count) * metrics.approvalLineHeight
            let boxHeight = textHeight + 2 * metrics.approvalBoxPaddingY
            set(box, NSRect(x: padding, y: y, width: inner, height: boxHeight), apply)
            set(commandLabel, NSRect(
                x: metrics.approvalBoxPaddingX, y: metrics.approvalBoxPaddingY,
                width: inner - 2 * metrics.approvalBoxPaddingX + 4, height: textHeight
            ), apply)
            y += boxHeight + Self.gap
        }
        if !choicesView.isHidden {
            let height = choices.height(width: inner)
            if apply {
                choicesView.frame = NSRect(x: padding, y: y, width: inner, height: height)
                if choicesWidth != inner {
                    // The row's labels, stacked down from the top of an
                    // unflipped view, as the row stacks them.
                    choicesWidth = inner
                    choicesView.subviews = choices.labels(x: 0, width: inner, top: height)
                }
            }
            y += height + Self.gap
        }
        if !textLabel.isHidden, case let text? = requestText {
            let height = SidebarQuestionText.questionHeight(text, width: inner)
            set(textLabel, NSRect(x: padding, y: y, width: inner, height: height), apply)
            y += height + Self.gap
        }
        return y
    }

    /// The question, the dialog's or the prompt's text.
    private var requestText: String? {
        switch request?.kind {
        case .question(let question)?: return question.text
        case .dialog(let question, _)?: return question
        case .mission(let question)?: return question.text
        case .terminal(let prompt)?: return prompt
        case .permission?, nil: return nil
        }
    }

    /// The answers on the right, a quiet one on the left; or the note.
    private func placeAnswers(top y: CGFloat, inner: CGFloat, apply: Bool) -> CGFloat {
        let buttonHeight = NiruxButton.Size.small.height
        // A quiet button's word starts where the text's lines do.
        var right = Self.padding + inner, left = Self.padding - NiruxButton.Size.small.padding
        if !terminalButton.isHidden {
            let width = terminalButton.intrinsicContentSize.width
            set(terminalButton, NSRect(x: right - width, y: y, width: width, height: buttonHeight), apply)
            right -= width + Theme.Space.sm
        }
        for choice in buttonOrder.reversed() {
            guard let button = answerButtons[choice] else { continue }
            let width = button.intrinsicContentSize.width
            if button.kind == .quiet {
                set(button, NSRect(x: left, y: y, width: width, height: buttonHeight), apply)
                left += width + Theme.Space.sm
            } else {
                set(button, NSRect(x: right - width, y: y, width: width, height: buttonHeight), apply)
                right -= width + Theme.Space.xs + 2
            }
        }
        if !noteLabel.isHidden {
            let x = max(left, Self.padding)
            set(noteLabel, NSRect(x: x, y: y + 3, width: max(0, right - x), height: buttonHeight - 4), apply)
        }
        return answerButtons.isEmpty && noteLabel.isHidden ? y : y + buttonHeight + Self.gap
    }

    // MARK: - Clicks

    /// Off the buttons, a click is the card's.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit is NSButton ? hit : self
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
}
