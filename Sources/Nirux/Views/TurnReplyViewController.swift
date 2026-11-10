import AppKit

/// The Reply… popover of the question a Claude turn ended on: the task,
/// the question as the agent wrote it, and an answer field. ⌘↩ sends, Esc
/// closes; Return makes a new line.
@MainActor
final class TurnReplyViewController: NSViewController {
    static let width: CGFloat = 340

    private let taskTitle: String
    private let question: String
    /// True once the answer went in; false keeps the popover open.
    private let onSend: (String) -> Bool
    private(set) var replyView: MissionReplyTextView?
    weak var popover: NSPopover?

    init(taskTitle: String, question: String, onSend: @escaping (String) -> Bool) {
        self.taskTitle = taskTitle
        self.question = question
        self.onSend = onSend
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Theme.Space.md
        stack.edgeInsets = NSEdgeInsets(top: Theme.Space.lg, left: Theme.Space.lg, bottom: Theme.Space.lg, right: Theme.Space.lg)
        let contentWidth = Self.width - 2 * Theme.Space.lg

        let title = NSTextField(labelWithString: "\(taskTitle) · Claude asks")
        title.font = Theme.Font.title
        title.textColor = Theme.Color.textPrimary
        title.lineBreakMode = .byTruncatingTail
        stack.addArrangedSubview(title)

        let questionLabel = NSTextField(wrappingLabelWithString: question)
        questionLabel.font = Theme.Font.display
        questionLabel.textColor = Theme.Color.textPrimary
        questionLabel.isSelectable = true
        questionLabel.preferredMaxLayoutWidth = contentWidth
        stack.addArrangedSubview(questionLabel)

        stack.addArrangedSubview(replyField(width: contentWidth))
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

    override func cancelOperation(_ sender: Any?) {
        popover?.performClose(sender)
    }

    private func replyField(width: CGFloat) -> NSView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.Color.canvas
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = Theme.Radius.card
        scroll.layer?.borderWidth = 1
        scroll.layer?.borderColor = Theme.Color.accent.cgColor
        scroll.heightAnchor.constraint(equalToConstant: 76).isActive = true
        let text = MissionReplyTextView(frame: NSRect(x: 0, y: 0, width: width, height: 76))
        text.minSize = NSSize(width: 0, height: 76)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.isHorizontallyResizable = false
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.textContainer?.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = true
        text.isRichText = false
        text.allowsUndo = true
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.drawsBackground = false
        text.font = Theme.Font.body
        text.textColor = Theme.Color.textPrimary
        text.insertionPointColor = Theme.Color.textPrimary
        text.textContainerInset = NSSize(width: Theme.Space.xs, height: Theme.Space.sm)
        text.setAccessibilityLabel("Your answer")
        text.onCommandReturn = { [weak self] in self?.send() }
        scroll.documentView = text
        replyView = text
        return scroll
    }

    private func buttonRow() -> NSView {
        let send = NSButton(title: "Send ⌘↩", target: self, action: #selector(sendAction))
        send.bezelStyle = .rounded
        send.bezelColor = Theme.Color.accent
        send.keyEquivalent = "\r"
        send.keyEquivalentModifierMask = .command
        send.toolTip = "Type the answer into Claude's prompt"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [spacer, send])
        row.orientation = .horizontal
        row.alignment = .centerY
        return row
    }

    @objc private func sendAction() { send() }

    func send() {
        guard let replyView else { return }
        _ = onSend(replyView.string)
    }
}
