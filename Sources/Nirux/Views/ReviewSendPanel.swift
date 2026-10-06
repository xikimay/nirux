import AppKit

/// "Send N Comments to Agent" (docs/branch-review.md, section 6.2): the
/// agent column the comments go to, why they can't go now, what the user
/// should know first, and the message itself, exactly as it is pasted:
/// Claude Code folds a long paste into "[Pasted text #1]", so the sheet is
/// where the user reads what goes. A sheet on the review's window, as the
/// merge queue's: nothing waits in a modal loop, so tests click through it.
/// The shell sends from `onSend`, with the column picked.
@MainActor
final class ReviewSendPanel: NSObject {
    /// What the sheet shows.
    struct Content: Equatable {
        /// An agent column inside the reviewed worktree.
        struct Target: Equatable {
            /// The column's: labels may repeat.
            let id: UUID
            let label: String
            /// Why the comments can't go there now; nil when they can.
            var refusal: String?
            /// What to know of this column before sending.
            var warnings: [String] = []
        }

        let title: String
        let subtitle: String
        /// The message, as pasted.
        let message: String
        var targets: [Target]
        /// What to know whatever the column.
        var warnings: [String] = []
        /// What doesn't go, and why.
        var notes: [String] = []
        /// Why nothing can be sent (no comment fits, no agent column).
        var refusal: String?
        /// Whether the message holds a comment to copy.
        var canCopy = true
    }

    /// Send, to the column of this id.
    var onSend: ((UUID) -> Void)?
    /// Cancel while the paste goes: the shell stops it.
    var onCancelSending: (() -> Void)?
    /// The columns read again (the shell's metadata refresh, a few times a
    /// second while agents work): an agent that finished its turn takes
    /// the comments without the sheet opened again.
    var onRefresh: ((ProcessSnapshot) -> Void)?
    var onDismiss: (() -> Void)?

    private(set) var content: Content
    /// The column picked, by id: it stays picked while the columns are
    /// read again, whatever their order or labels; nil once it is gone.
    private(set) var selectedID: UUID?
    /// The user picked it (else the sheet did, and picks again when it
    /// goes).
    private var isPicked = false
    private(set) var isSending = false
    private var error: String?
    /// What the last action did ("Copied…"), until the next.
    private var notice: String?
    /// Where Copy Message puts the message: the general pasteboard, or the
    /// tests' own.
    var pasteboard: NSPasteboard = .general

    private var panel: NSPanel?
    private weak var parentWindow: NSWindow?
    private var documentView: ReviewSendFlippedView?
    private(set) var titleLabel: NSTextField?
    private(set) var subtitleLabel: NSTextField?
    private(set) var targetPopUp: NSPopUpButton?
    private(set) var messageView: NSTextView?
    private(set) var sendButton: NSButton?
    private(set) var copyButton: NSButton?
    private(set) var cancelButton: NSButton?
    private(set) var statusLabel: NSTextField?
    /// Every line above the message, top to bottom, for the tests.
    private(set) var lines: [String] = []

    private static let size = NSSize(width: 720, height: 620)
    private static let warningColor = NSColor.systemOrange

    init(content: Content) {
        self.content = content
        selectedID = (content.targets.first { $0.refusal == nil } ?? content.targets.first)?.id
    }

    /// The index of the column picked in `content.targets`.
    var selectedTarget: Int? { content.targets.firstIndex { $0.id == selectedID } }

    var isShown: Bool { panel != nil }

    func show(attachedTo window: NSWindow?) {
        let panel = buildPanel()
        self.panel = panel
        parentWindow = window
        render()
        if let window {
            window.beginSheet(panel)
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    /// The columns and what they say, read again (Send checks once more).
    /// The column picked stays picked; once it is gone, none is if the
    /// user picked it (the comments mustn't go elsewhere unasked), else the
    /// first that takes the comments is. What the sheet said of the last
    /// action stays.
    func update(_ content: Content) {
        guard content != self.content else { return }
        self.content = content
        if !isPicked, selectedTarget == nil {
            selectedID = (content.targets.first { $0.refusal == nil } ?? content.targets.first)?.id
        }
        render()
    }

    /// Send was refused, or the paste failed: the sheet stays, with why.
    func showError(_ message: String) {
        error = message
        notice = nil
        isSending = false
        render()
    }

    /// The paste is under way: Cancel stops it, nothing else can be
    /// clicked.
    func showSending() {
        isSending = true
        error = nil
        notice = nil
        render()
    }

    func dismiss() {
        guard let panel else { return }
        if let parentWindow, panel.sheetParent === parentWindow {
            parentWindow.endSheet(panel)
        }
        panel.orderOut(nil)
        self.panel = nil
        onDismiss?()
    }

    // MARK: - Actions

    @objc private func cancelAction() {
        guard !isSending else {
            onCancelSending?()
            return
        }
        dismiss()
    }

    @objc private func sendAction() {
        guard canSend, let selectedID else { return }
        error = nil
        notice = nil
        onSend?(selectedID)
    }

    @objc private func copyAction() {
        guard content.canCopy else { return }
        pasteboard.clearContents()
        pasteboard.setString(content.message, forType: .string)
        error = nil
        notice = "Copied: paste it into the agent’s prompt yourself."
        render()
    }

    @objc private func targetChanged(_ sender: NSPopUpButton) {
        selectedID = content.targets[safe: sender.indexOfSelectedItem]?.id
        isPicked = true
        error = nil
        notice = nil
        render()
    }

    var canSend: Bool {
        !isSending && content.refusal == nil && selectedTarget.flatMap { content.targets[$0].refusal == nil ? true : nil } == true
    }

    // MARK: - Rendering

    private func render() {
        guard let documentView, let scroll = documentView.enclosingScrollView else { return }
        documentView.subviews.forEach { $0.removeFromSuperview() }
        lines = []
        let width = scroll.contentSize.width
        var y: CGFloat = 10

        func add(_ text: String, color: NSColor, font: NSFont = Theme.Font.body, gap: CGFloat = 4) {
            let label = NSTextField(wrappingLabelWithString: text)
            label.font = font
            label.textColor = color
            label.isSelectable = true
            let labelWidth = max(40, width - 2 * Theme.Space.md)
            let height = ceil(label.sizeThatFits(NSSize(width: labelWidth, height: .greatestFiniteMagnitude)).height)
            label.frame = NSRect(x: Theme.Space.md, y: y, width: labelWidth, height: height)
            documentView.addSubview(label)
            lines.append(text)
            y += height + gap
        }

        let target = selectedTarget.map { content.targets[$0] }
        let gone = target == nil && !content.targets.isEmpty
            ? "The column picked closed, or no longer runs an agent: pick another." : nil
        for refusal in [content.refusal, target?.refusal, gone].compactMap({ $0 }) {
            add(refusal, color: Theme.Color.error, font: Theme.Font.bodyEmphasized)
        }
        for warning in (target?.warnings ?? []) + content.warnings {
            add("⚠︎ " + warning, color: Self.warningColor)
        }
        for note in content.notes {
            add(note, color: Theme.Color.textSecondary)
        }
        if lines.isEmpty {
            add("Pasted into the agent’s prompt, without Return: read it there, and submit it.",
                color: Theme.Color.textSecondary)
        }
        documentView.setFrameSize(NSSize(width: width, height: max(scroll.contentSize.height, y + 6)))
        documentView.scroll(.zero)

        // Menu items of their own: the pop-up's titles would merge labels
        // that repeat.
        if let popUp = targetPopUp, let menu = popUp.menu {
            menu.removeAllItems()
            for target in content.targets { menu.addItem(NSMenuItem(title: target.label, action: nil, keyEquivalent: "")) }
            if content.targets.isEmpty { menu.addItem(NSMenuItem(title: "No agent column", action: nil, keyEquivalent: "")) }
            if let selectedTarget {
                popUp.selectItem(at: selectedTarget)
            } else if !content.targets.isEmpty {
                popUp.select(nil)
            }
            popUp.isEnabled = (content.targets.count > 1 || (selectedTarget == nil && !content.targets.isEmpty)) && !isSending
        }
        titleLabel?.stringValue = content.title
        subtitleLabel?.stringValue = content.subtitle
        if messageView?.string != content.message { messageView?.string = content.message }
        sendButton?.isEnabled = canSend
        sendButton?.title = isSending ? "Sending…" : "Send"
        copyButton?.isEnabled = !isSending && content.canCopy
        cancelButton?.isEnabled = true
        statusLabel?.textColor = error == nil ? Theme.Color.textSecondary : Theme.Color.error
        statusLabel?.stringValue = error ?? notice ?? ""
        statusLabel?.toolTip = error ?? notice
    }

    // MARK: - Construction

    private func buildPanel() -> NSPanel {
        let size = Self.size
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.appearance = Theme.appearance
        panel.backgroundColor = Theme.Color.base

        let container = NSView(frame: NSRect(origin: .zero, size: size))
        let inset = Theme.Space.xl
        let heading = NSTextField(labelWithString: content.title)
        heading.font = Theme.Font.display
        heading.textColor = Theme.Color.textPrimary
        heading.frame = NSRect(x: inset, y: size.height - 46, width: size.width - 2 * inset, height: 22)
        container.addSubview(heading)
        let subheading = NSTextField(labelWithString: content.subtitle)
        subheading.font = Theme.Font.mono
        subheading.textColor = Theme.Color.textSecondary
        subheading.lineBreakMode = .byTruncatingMiddle
        subheading.frame = NSRect(x: inset, y: size.height - 68, width: size.width - 2 * inset, height: 16)
        container.addSubview(subheading)

        let to = NSTextField(labelWithString: "To")
        to.font = Theme.Font.caption
        to.textColor = Theme.Color.textSecondary
        to.frame = NSRect(x: inset, y: size.height - 102, width: 24, height: 16)
        container.addSubview(to)
        let popUp = NSPopUpButton(frame: NSRect(x: inset + 28, y: size.height - 108, width: size.width - 2 * inset - 28, height: 26))
        popUp.target = self
        popUp.action = #selector(targetChanged(_:))
        popUp.setAccessibilityLabel("Agent column")
        container.addSubview(popUp)

        // What to know: refusals, warnings, what stays.
        let notesFrame = NSRect(x: Theme.Space.lg, y: size.height - 210, width: size.width - 2 * Theme.Space.lg, height: 92)
        let notesScroll = NSScrollView(frame: notesFrame)
        notesScroll.hasVerticalScroller = true
        notesScroll.autohidesScrollers = true
        notesScroll.drawsBackground = false
        let document = ReviewSendFlippedView(frame: NSRect(origin: .zero, size: notesFrame.size))
        notesScroll.documentView = document
        container.addSubview(notesScroll)

        // The message, as pasted.
        let messageFrame = NSRect(x: Theme.Space.lg, y: 64, width: size.width - 2 * Theme.Space.lg, height: size.height - 64 - 222)
        let messageScroll = NSScrollView(frame: messageFrame)
        messageScroll.hasVerticalScroller = true
        messageScroll.hasHorizontalScroller = false
        messageScroll.drawsBackground = true
        messageScroll.backgroundColor = Theme.Color.surface
        messageScroll.wantsLayer = true
        messageScroll.layer?.cornerRadius = Theme.Radius.card
        messageScroll.layer?.borderWidth = 1
        messageScroll.layer?.borderColor = Theme.Color.line.cgColor
        let text = NSTextView(frame: NSRect(origin: .zero, size: messageFrame.size))
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        text.drawsBackground = false
        text.font = Theme.Font.mono
        text.textColor = Theme.Color.textPrimary
        text.textContainerInset = NSSize(width: Theme.Space.sm, height: Theme.Space.sm)
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.string = content.message
        text.setAccessibilityLabel("Message to the agent")
        messageScroll.documentView = text
        container.addSubview(messageScroll)

        let status = NSTextField(labelWithString: "")
        status.font = Theme.Font.caption
        status.textColor = Theme.Color.error
        status.lineBreakMode = .byTruncatingTail
        status.frame = NSRect(x: inset, y: 24, width: size.width - inset - 380, height: 16)
        container.addSubview(status)

        // Send doesn't answer Return: the comments go on a deliberate click.
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelAction))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        cancel.frame = NSRect(x: size.width - 362, y: 17, width: 96, height: 30)
        container.addSubview(cancel)
        let copy = NSButton(title: "Copy Message", target: self, action: #selector(copyAction))
        copy.bezelStyle = .rounded
        copy.frame = NSRect(x: size.width - 262, y: 17, width: 130, height: 30)
        container.addSubview(copy)
        let send = NSButton(title: "Send", target: self, action: #selector(sendAction))
        send.bezelStyle = .rounded
        send.frame = NSRect(x: size.width - 126, y: 17, width: 102, height: 30)
        container.addSubview(send)

        panel.contentView = container
        documentView = document
        titleLabel = heading
        subtitleLabel = subheading
        targetPopUp = popUp
        messageView = text
        statusLabel = status
        cancelButton = cancel
        copyButton = copy
        sendButton = send
        return panel
    }
}

private final class ReviewSendFlippedView: NSView {
    override var isFlipped: Bool { true }
}
