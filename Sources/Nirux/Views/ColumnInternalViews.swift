import AppKit

/// NSView that accepts file drops and pastes the dropped file paths into
/// the PTY via the `onFileDrop` callback.
final class DropTargetView: NSView {
    var onFileDrop: (([URL]) -> Void)?
    /// False while nothing could take the paths (no shell runs yet).
    var acceptsFileDrops: () -> Bool = { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard acceptsFileDrops(), sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) else {
            return []
        }
        return .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard acceptsFileDrops(),
              let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else {
            return false
        }
        onFileDrop?(urls)
        return true
    }
}

/// Banner shown over the editor when the file on disk changed while the
/// buffer had unsaved edits. Offers an explicit choice instead of silently
/// clobbering external changes on the next save. A warning, never amber
/// (amber means an agent waits for the user): its words after "⚠︎ ", on the
/// look of its neighbour `EditorBranchReviewBanner`.
final class EditorConflictBanner: NSView {
    static let height: CGFloat = 34

    var onCompare: (() -> Void)?
    var onTakeDisk: (() -> Void)?
    var onKeepMine: (() -> Void)?

    private let messageLabel = NSTextField(labelWithString: "")
    /// On while the disk's version shows beside the buffer.
    private lazy var compareButton = makeButton(title: "Compare", action: #selector(compareClicked))
    /// Right to left.
    private lazy var buttons = [
        makeButton(title: "Keep Mine", action: #selector(keepMineClicked)),
        makeButton(title: "Take Disk", action: #selector(takeDiskClicked)),
        compareButton
    ]

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Theme.Color.surface.cgColor
        layer?.cornerRadius = Theme.Radius.card
        layer?.borderWidth = 1
        layer?.borderColor = Theme.Color.line.cgColor

        messageLabel.font = Theme.Font.caption
        messageLabel.textColor = NSColor.niruxWarning
        messageLabel.lineBreakMode = .byTruncatingMiddle
        addSubview(messageLabel)

        compareButton.setButtonType(.pushOnPushOff)
        buttons.forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func makeButton(title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = Theme.Font.caption
        return button
    }

    func configure(fileName: String, isDeleted: Bool, isComparing: Bool) {
        let change = isDeleted ? "was deleted" : "changed"
        messageLabel.stringValue = (isComparing
            ? "\(fileName): on disk on the left, your edits on the right."
            : "\(fileName) \(change) on disk while you have unsaved edits.").asWarning
        compareButton.state = isComparing ? .on : .off
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let pad: CGFloat = 10
        let buttonH: CGFloat = 22
        let gap: CGFloat = 8
        let y = (bounds.height - buttonH) / 2
        var x = bounds.width - pad
        for button in buttons {
            let buttonW = button.intrinsicContentSize.width
            x -= buttonW
            button.frame = NSRect(x: x, y: y, width: buttonW, height: buttonH)
            x -= gap
        }
        messageLabel.frame = NSRect(x: pad, y: (bounds.height - 15) / 2, width: max(60, x - pad), height: 15)
    }

    @objc private func compareClicked() { onCompare?() }
    @objc private func takeDiskClicked() { onTakeDisk?() }
    @objc private func keepMineClicked() { onKeepMine?() }
}

/// Banner above the editor's "Full Branch Diff" tab: the same branch reads
/// better in a Branch Review column (docs/design/branch-review.md, section 1).
/// Native, so that a test can click it. Neutral: nothing waits for the user.
final class EditorBranchReviewBanner: NSView {
    static let height: CGFloat = 34

    var onOpen: (() -> Void)?

    let openButton = NSButton(title: "Open in Branch Review", target: nil, action: nil)
    private let messageLabel = NSTextField(labelWithString: "Read this branch on one page: what and why, its risks, its files.")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Theme.Color.surface.cgColor
        layer?.cornerRadius = Theme.Radius.card
        layer?.borderWidth = 1
        layer?.borderColor = Theme.Color.lineStrong.cgColor

        messageLabel.font = Theme.Font.caption
        messageLabel.textColor = Theme.Color.textSecondary
        messageLabel.lineBreakMode = .byTruncatingTail
        addSubview(messageLabel)

        openButton.target = self
        openButton.action = #selector(openClicked)
        openButton.bezelStyle = .rounded
        openButton.controlSize = .small
        openButton.font = Theme.Font.buttonSmall
        addSubview(openButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let pad: CGFloat = 10
        let buttonSize = openButton.intrinsicContentSize
        openButton.frame = NSRect(
            x: bounds.width - pad - buttonSize.width, y: (bounds.height - buttonSize.height) / 2,
            width: buttonSize.width, height: buttonSize.height
        )
        messageLabel.frame = NSRect(
            x: pad, y: (bounds.height - 15) / 2, width: max(0, openButton.frame.minX - pad * 2), height: 15
        )
    }

    @objc private func openClicked() { onOpen?() }
}

/// Full-surface overlay shown when the Monaco editor fails to load (missing
/// bundled assets, or no `monacoReady` within the watchdog window). Replaces
/// the previous silent blank surface / error tab.
final class EditorLoadFailureOverlay: NSView {
    var onRetry: (() -> Void)?

    private let messageLabel = NSTextField(labelWithString: "")
    private let retryButton = NSButton(title: "Retry", target: nil, action: nil)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Theme.Color.base.cgColor

        messageLabel.font = Theme.Font.bodyMedium
        messageLabel.textColor = NSColor.white.withAlphaComponent(0.55)
        messageLabel.alignment = .center
        addSubview(messageLabel)

        retryButton.bezelStyle = .rounded
        retryButton.font = Theme.Font.button
        retryButton.target = self
        retryButton.action = #selector(retryClicked)
        addSubview(retryButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(message: String, showRetry: Bool) {
        messageLabel.stringValue = message
        retryButton.isHidden = !showRetry
        needsLayout = true
    }

    override func layout() {
        super.layout()
        retryButton.sizeToFit()
        let buttonW = retryButton.frame.width + 16
        retryButton.frame = NSRect(
            x: (bounds.width - buttonW) / 2,
            y: bounds.height / 2 - 34,
            width: buttonW,
            height: 26
        )
        messageLabel.frame = NSRect(
            x: 16,
            y: bounds.height / 2 + 2,
            width: bounds.width - 32,
            height: 18
        )
    }

    @objc private func retryClicked() { onRetry?() }
}

/// Overlay shown over a terminal whose shell process exited. Previously a
/// dead shell left a mute terminal with no explanation and no way back.
/// Restart keeps the terminal surface — scrollback stays visible above.
///
/// Also shown when an agent died mid-turn in a shell that still runs: its
/// button then resumes the agent's conversation, and Dismiss (or typing,
/// which goes to the shell) takes the notice down. And over a restored
/// agent column whose agent hasn't resumed yet: its button, or a click
/// anywhere on it, resumes the agent.
final class ShellExitedOverlay: NSView {
    enum Content: Equatable {
        case shellExited
        case agentExited(processName: String)
        /// `summary`: the session's title and where it was (see
        /// `DeferredAgentLaunch.summary`).
        case notResumed(processName: String, summary: String)
    }

    var onRestart: (() -> Void)?
    var onDismiss: (() -> Void)?
    private(set) var content: Content = .shellExited

    private let label = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: "")
    private let restartButton = NSButton(title: "", target: nil, action: nil)
    private let dismissButton = NSButton(title: "Dismiss", target: nil, action: nil)

    init(content: Content = .shellExited) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.Color.canvas.withAlphaComponent(0.92).cgColor

        label.font = Theme.Font.title
        label.textColor = NSColor.white.withAlphaComponent(0.85)
        label.alignment = .center
        addSubview(label)

        hint.font = Theme.Font.caption
        hint.textColor = NSColor.white.withAlphaComponent(0.45)
        hint.alignment = .center
        hint.lineBreakMode = .byTruncatingTail
        addSubview(hint)

        for (button, action) in [
            (restartButton, #selector(restartClicked)), (dismissButton, #selector(dismissClicked))
        ] {
            button.bezelStyle = .rounded
            button.font = Theme.Font.button
            button.target = self
            button.action = action
            addSubview(button)
        }
        configure(content)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ content: Content) {
        self.content = content
        switch content {
        case .shellExited:
            label.stringValue = "Session ended"
            hint.stringValue = "Press Enter to restart the shell"
            restartButton.title = "Restart Shell"
            dismissButton.isHidden = true
        case .agentExited(let processName):
            label.stringValue = "\(processName) exited mid-turn"
            hint.stringValue = "It stopped without ending its session. Typing goes to the shell."
            restartButton.title = "Resume Session"
            dismissButton.isHidden = false
        case .notResumed(let processName, let summary):
            label.stringValue = "Not resumed yet — click or focus to resume"
            hint.stringValue = "\(processName) · \(summary)"
            restartButton.title = "Resume"
            dismissButton.isHidden = true
        }
        hint.toolTip = hint.stringValue
        needsLayout = true
    }

    /// A click anywhere on a not-resumed notice resumes, as its button does.
    override func mouseDown(with event: NSEvent) {
        if case .notResumed = content {
            onRestart?()
        } else {
            super.mouseDown(with: event)
        }
    }

    override func layout() {
        super.layout()
        // Over a terminal, at the bottom of its card: nothing of it lies in
        // the corners its column clips.
        layer?.roundCardCorners(top: false)
        let midX = bounds.width / 2
        let midY = bounds.height / 2
        restartButton.sizeToFit()
        dismissButton.sizeToFit()
        let restartWidth = restartButton.frame.width + 20
        let dismissWidth = dismissButton.isHidden ? 0 : dismissButton.frame.width + 20
        let gap: CGFloat = dismissButton.isHidden ? 0 : 10
        var x = midX - (restartWidth + gap + dismissWidth) / 2
        if !dismissButton.isHidden {
            // macOS order: the default action last.
            dismissButton.frame = NSRect(x: x, y: midY - 40, width: dismissWidth, height: 26)
            x += dismissWidth + gap
        }
        restartButton.frame = NSRect(x: x, y: midY - 40, width: restartWidth, height: 26)
        label.frame = NSRect(x: 0, y: midY + 18, width: bounds.width, height: 18)
        hint.frame = NSRect(x: 16, y: midY - 4, width: max(0, bounds.width - 32), height: 14)
    }

    @objc private func restartClicked() { onRestart?() }
    @objc private func dismissClicked() { onDismiss?() }
}

/// Draggable divider at a column's right edge — freeform width resize.
/// Lives in the workspace strip (columns clip their own subviews to their
/// bounds), positioned over the inter-column boundary by layoutAndScroll.
/// The owner turns the pointer's way into a width.
final class ColumnResizeHandle: NSView {
    /// What a drag starts from: its column's width, the strip's, and where
    /// the camera was.
    typealias Start = (width: CGFloat, strip: CGFloat, camera: CGFloat)
    /// Drag start → where it starts from; nil: no drag.
    var onDragStart: (() -> Start?)?
    /// Dragging → its start and the pointer's way since, in points
    /// (absolute-set semantics, so a wobbly mouse can't compound errors).
    var onDrag: ((Start, CGFloat) -> Void)?
    /// The drag is over.
    var onDragEnd: (() -> Void)?
    /// Double-click → reset to the default width.
    var onReset: (() -> Void)?

    private var dragStartX: CGFloat = 0
    private var dragStart: Start?
    private let line = NSView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.09).cgColor
        addSubview(line)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        line.frame = NSRect(x: bounds.midX - 1, y: 0, width: 2, height: bounds.height)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            dragStart = nil
            onReset?()
            return
        }
        dragStartX = event.locationInWindow.x
        dragStart = onDragStart?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart else { return }
        onDrag?(dragStart, event.locationInWindow.x - dragStartX)
    }

    override func mouseUp(with event: NSEvent) {
        guard dragStart != nil else { return }
        dragStart = nil
        onDragEnd?()
    }
}
