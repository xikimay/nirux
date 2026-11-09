import AppKit

/// The reply popover of a Mission child's question: who asks, the whole
/// question, why it comes to the user, and a multi-line answer field.
/// ⌘↩ sends, Esc closes; Return makes a new line.
@MainActor
final class MissionReplyViewController: NSViewController {
    static let width: CGFloat = 340

    private let childTitle: String
    private let question: SidebarMissionQuestion
    /// True once the answer went out; false keeps the popover open.
    private let onSend: (String) -> Bool
    private let onOpenTask: () -> Void
    private(set) var replyView: MissionReplyTextView?
    private(set) var sendButton: NSButton?
    /// The popover showing this controller.
    weak var popover: NSPopover?

    init(
        childTitle: String,
        question: SidebarMissionQuestion,
        onSend: @escaping (String) -> Bool,
        onOpenTask: @escaping () -> Void
    ) {
        self.childTitle = childTitle
        self.question = question
        self.onSend = onSend
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

        let questionLabel = Self.wrappingLabel(question.text, font: Theme.Font.display, color: Theme.Color.textPrimary)
        questionLabel.isSelectable = true
        questionLabel.preferredMaxLayoutWidth = contentWidth
        stack.addArrangedSubview(questionLabel)

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
    /// and not the terminal underneath. AppKit ignores `makeKey` while a
    /// click brings Nirux to the front, so a click on the row from another
    /// app leaves the keyboard with the main window, the field still
    /// showing a caret: the first key typed asks again (see
    /// `NiruxShellView.takeKeyboardForMissionReply`).
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

    /// A dot (amber once the question waits on the user), the child's
    /// title, and who it asks.
    private func header() -> NSView {
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.layer?.backgroundColor = (question.handOff == nil ? Theme.Color.textTertiary : Theme.Color.waiting).cgColor
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([dot.widthAnchor.constraint(equalToConstant: 8), dot.heightAnchor.constraint(equalToConstant: 8)])

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

        let row = NSStackView(views: [dot, title, asks])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Theme.Space.sm
        return row
    }

    private func replyField() -> NSView {
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
        let text = MissionReplyTextView(frame: NSRect(x: 0, y: 0, width: Self.width - 2 * Theme.Space.lg, height: 76))
        text.minSize = NSSize(width: 0, height: 76)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.isHorizontallyResizable = false
        text.textContainer?.containerSize = NSSize(width: text.frame.width, height: CGFloat.greatestFiniteMagnitude)
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
        text.onCommandReturn = { [weak self] in self?.send() }
        scroll.documentView = text
        replyView = text
        return scroll
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

    @objc private func openTaskAction() { onOpenTask() }

    func send() {
        guard let replyView else { return }
        _ = onSend(replyView.string)
    }
}

/// The answer field: ⌘↩ sends instead of making a new line.
final class MissionReplyTextView: NSTextView {
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
