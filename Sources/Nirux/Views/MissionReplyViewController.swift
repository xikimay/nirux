import AppKit

/// The reply popover of a Mission child's question: who asks, the whole
/// question, why it comes to the user, and a multi-line answer field.
/// ⌘↩ sends, Esc closes; Return makes a new line.
@MainActor
final class MissionReplyViewController: NSViewController, NSPopoverDelegate {
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
    /// Keys typed in the main window are for this popover's field (see
    /// `focusReplyField`). No longer once such a key gave it the keyboard,
    /// or once another window took the keyboard (a panel, a sheet): the
    /// main window getting it back then is the user's doing. Nor once it
    /// starts to close (Esc, a click outside; its delegate is this
    /// controller): keys typed during its fade go where the user went.
    private(set) var claimsMainWindowKeys = true

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
    /// and not the terminal underneath. Opened by a click on the row from
    /// another app, it ends up without it: once that click has brought
    /// Nirux to the front, AppKit gives the keyboard to the main window, the
    /// field still showing a caret. The first key typed there comes here
    /// (`receiveMainWindowKey`).
    func focusReplyField() {
        guard let replyView else { return }
        view.window?.makeKey()
        view.window?.makeFirstResponder(replyView)
    }

    /// A key typed in the main window while the popover lacks the keyboard
    /// (`NiruxShellView.missionReplyLackingKeyboard`): the popover takes the
    /// keyboard and its field gets the key. False when the key goes back to
    /// AppKit instead: a ⌘-chord, now that the popover is the key window
    /// (⌘V through the Edit menu, ⌘↩ to Send).
    func receiveMainWindowKey(_ event: NSEvent) -> Bool {
        focusReplyField()
        // Never nil: the shell only hands keys to a popover on screen.
        guard let window = view.window else { return true }
        if window.isKeyWindow {
            claimsMainWindowKeys = false
            if event.modifierFlags.contains(.command) { return false }
        }
        window.sendEvent(event)
        return true
    }

    /// Esc closes the popover: the answer field passes it up the responder
    /// chain to this controller.
    override func cancelOperation(_ sender: Any?) {
        popover?.performClose(sender)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidBecomeKey(_:)), name: NSWindow.didBecomeKeyNotification, object: nil
        )
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
    }

    /// Only this popover and the main window it hangs from trade the
    /// keyboard while a click brings Nirux to the front.
    @objc private func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window !== view.window, window !== view.window?.parent
        else { return }
        claimsMainWindowKeys = false
    }

    func popoverWillClose(_ notification: Notification) {}

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
