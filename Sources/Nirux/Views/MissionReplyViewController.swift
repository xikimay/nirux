import AppKit

/// The reply popover of a Mission child's question: who asks, what blocks
/// it, the whole question, what it recommends (Accept sends that) or, for
/// an access question, what it needs, why it comes to the user, and a
/// multi-line answer field. ⌘↩ sends, Esc closes; Return makes a new line.
@MainActor
final class MissionReplyViewController: NSViewController {
    static let width: CGFloat = 340

    private let childTitle: String
    private let question: SidebarMissionQuestion
    /// True once the answer went out; false keeps the popover open.
    private let onSend: (String) -> Bool
    /// Sends the recommendation; nil when there is none to accept.
    private let onAccept: (() -> Bool)?
    private let onOpenTask: () -> Void
    private(set) var replyView: MissionReplyTextView?
    private(set) var sendButton: NSButton?
    private(set) var acceptButton: NSButton?
    /// The popover showing this controller.
    weak var popover: NSPopover?

    init(
        childTitle: String,
        question: SidebarMissionQuestion,
        onSend: @escaping (String) -> Bool,
        onAccept: (() -> Bool)? = nil,
        onOpenTask: @escaping () -> Void
    ) {
        self.childTitle = childTitle
        self.question = question
        self.onSend = onSend
        self.onAccept = onAccept
        self.onOpenTask = onOpenTask
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Theme.Space.md
        stack.edgeInsets = NSEdgeInsets(
            top: Theme.Space.lg, left: Theme.Space.lg, bottom: Theme.Space.lg, right: Theme.Space.lg
        )
        let contentWidth = Self.width - 2 * Theme.Space.lg

        stack.addArrangedSubview(header())

        if let kind = question.kindTitle {
            let kindLabel = NSTextField(labelWithString: kind.uppercased())
            kindLabel.font = Theme.Font.caption
            kindLabel.textColor = Theme.Color.textTertiary
            stack.addArrangedSubview(kindLabel)
            stack.setCustomSpacing(Theme.Space.xs, after: kindLabel)
        }

        let questionLabel = Self.wrappingLabel(question.text, font: Theme.Font.display, color: Theme.Color.textPrimary)
        questionLabel.isSelectable = true
        questionLabel.preferredMaxLayoutWidth = contentWidth
        stack.addArrangedSubview(questionLabel)

        if let recommendation = question.recommendation {
            stack.addArrangedSubview(recommendationBox(recommendation, width: contentWidth))
        }

        let explanation = Self.wrappingLabel(question.explanation, font: Theme.Font.body, color: Theme.Color.textSecondary)
        explanation.preferredMaxLayoutWidth = contentWidth
        stack.addArrangedSubview(explanation)

        let field = replyField()
        stack.addArrangedSubview(field)
        stack.addArrangedSubview(buttonRow())

        for view in stack.arrangedSubviews {
            view.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        }
        stack.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
        view = stack
    }

    /// The popover's window takes the keyboard, so typing reaches the field
    /// and not the terminal underneath.
    func focusReplyField() {
        guard let replyView else { return }
        view.window?.makeKey()
        view.window?.makeFirstResponder(replyView)
    }

    /// Esc closes the popover: the answer field passes it up the responder
    /// chain to this controller.
    override func cancelOperation(_ sender: Any?) {
        popover?.performClose(sender)
    }

    // MARK: - Parts

    /// A child's question as its row shows it: asking its parent, or
    /// waiting on the user once handed to them.
    static func icon(handedOff: Bool) -> StateIcon {
        StateIcon(handedOff ? .needsYou(.question) : .asking)
    }

    /// The child's state icon (the asking ring while its parent has the
    /// question, amber once it waits on the user), its title, and who it
    /// asks.
    private func header() -> NSView {
        let icon = StateIconView(Self.icon(handedOff: question.handOff != nil))
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: icon.frame.width), icon.heightAnchor.constraint(equalToConstant: icon.frame.height)
        ])

        let title = NSTextField(labelWithString: childTitle)
        title.font = Theme.Font.title
        title.textColor = Theme.Color.textPrimary
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let asks = NSTextField(labelWithString: "asks \(question.parentTitle)")
        asks.font = Theme.Font.body
        asks.textColor = Theme.Color.textSecondary
        asks.lineBreakMode = .byTruncatingTail
        asks.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)

        let row = NSStackView(views: [icon, title, asks])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Theme.Space.sm
        return row
    }

    /// The recommendation under its heading, in a box; Accept at its foot
    /// when the user may send it as the answer.
    private func recommendationBox(_ text: String, width: CGFloat) -> NSView {
        let inset = Theme.Space.md
        let heading = NSTextField(labelWithString: question.recommendationTitle)
        heading.font = Theme.Font.caption
        heading.textColor = Theme.Color.textTertiary
        let body = Self.wrappingLabel(text, font: Theme.Font.body, color: Theme.Color.textPrimary)
        body.isSelectable = true
        body.preferredMaxLayoutWidth = width - 2 * inset
        let box = NSStackView(views: [heading, body])
        box.orientation = .vertical
        box.alignment = .leading
        box.spacing = Theme.Space.xs
        box.edgeInsets = NSEdgeInsets(top: inset, left: inset, bottom: inset, right: inset)
        box.wantsLayer = true
        box.layer?.backgroundColor = Theme.Color.canvas.cgColor
        box.layer?.borderColor = Theme.Color.line.cgColor
        box.layer?.borderWidth = 1
        box.layer?.cornerRadius = Theme.Radius.card
        box.setAccessibilityElement(true)
        box.setAccessibilityRole(.group)
        box.setAccessibilityLabel(question.recommendationTitle)
        if onAccept != nil {
            let accept = NSButton(title: "Accept", target: self, action: #selector(acceptAction))
            accept.bezelStyle = .rounded
            accept.toolTip = "Send the recommendation as your answer"
            accept.setAccessibilityLabel("Accept the recommendation: \(text)")
            acceptButton = accept
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let row = NSStackView(views: [spacer, accept])
            row.orientation = .horizontal
            box.addArrangedSubview(row)
            row.widthAnchor.constraint(equalToConstant: width - 2 * inset).isActive = true
        }
        return box
    }

    private func replyField() -> NSView {
        let field = MissionReplyTextView.field(width: Self.width - 2 * Theme.Space.lg) { [weak self] in self?.send() }
        field.text.delegate = self
        replyView = field.text
        return field.scroll
    }

    private func buttonRow() -> NSView {
        let open = NSButton(title: "Open Task", target: self, action: #selector(openTaskAction))
        open.isBordered = false
        open.attributedTitle = NSAttributedString(string: "Open Task", attributes: [
            .font: Theme.Font.body, .foregroundColor: Theme.Color.accent
        ])
        open.toolTip = "Show the workspace that asks"

        let send = NSButton(title: "Send ⌘↩", target: self, action: #selector(sendAction))
        send.bezelStyle = .rounded
        send.bezelColor = Theme.Color.accent
        send.keyEquivalent = "\r"
        send.keyEquivalentModifierMask = .command
        send.toolTip = "Send the answer to the agent that asks"
        sendButton = send

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [open, spacer, send])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Theme.Space.sm
        return row
    }

    private static func wrappingLabel(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = font
        label.textColor = color
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        return label
    }

    // MARK: - Actions

    @objc private func sendAction() { send() }

    /// Once: a second click would find the question answered. Not while the
    /// field holds an answer, which Accept would throw away.
    @objc private func acceptAction() {
        acceptButton?.isEnabled = false
        if onAccept?() != true { updateAcceptButton() }
    }

    private func updateAcceptButton() {
        let drafted = !(replyView?.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        acceptButton?.isEnabled = !drafted
        acceptButton?.toolTip = drafted ? "Clear your answer to send the recommendation instead" : "Send the recommendation as your answer"
    }

    @objc private func openTaskAction() { onOpenTask() }

    func send() {
        guard let replyView else { return }
        _ = onSend(replyView.string)
    }
}

extension MissionReplyViewController: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        updateAcceptButton()
    }
}

/// The answer field: ⌘↩ sends instead of making a new line.
final class MissionReplyTextView: NSTextView {
    /// The answer field of a reply popover (a Mission question's, a turn's
    /// question's): plain text in a bordered scroll view, ⌘↩ sending.
    static func field(width: CGFloat, onCommandReturn: (() -> Void)? = nil) -> (scroll: NSScrollView, text: MissionReplyTextView) {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.Color.canvas
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = Theme.Radius.card
        scroll.layer?.borderWidth = 1
        scroll.layer?.borderColor = Theme.Color.accent.cgColor
        scroll.heightAnchor.constraint(equalToConstant: 76).isActive = true

        // Sized like a scrollable text view: without a large maxSize it can't
        // grow past its first frame, and text below it would be clipped.
        let text = MissionReplyTextView(frame: NSRect(x: 0, y: 0, width: width, height: 76))
        text.minSize = NSSize(width: 0, height: 76)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.isHorizontallyResizable = false
        text.textContainer?.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        text.isRichText = false
        text.allowsUndo = true
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.drawsBackground = false
        text.font = Theme.Font.body
        text.textColor = Theme.Color.textPrimary
        text.insertionPointColor = Theme.Color.textPrimary
        text.textContainerInset = NSSize(width: Theme.Space.xs, height: Theme.Space.sm)
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.setAccessibilityLabel("Your answer")
        text.onCommandReturn = onCommandReturn
        scroll.documentView = text
        return (scroll, text)
    }

    var onCommandReturn: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .command, event.keyCode == 36 || event.keyCode == 76 {
            onCommandReturn?()
            return
        }
        super.keyDown(with: event)
    }
}
