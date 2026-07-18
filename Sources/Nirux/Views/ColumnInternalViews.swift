import AppKit

/// NSView subclass whose background drags the window (like a title bar).
final class WindowDragView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
}

/// NSView that accepts file drops and pastes the dropped file paths into
/// the PTY via the `onFileDrop` callback.
final class DropTargetView: NSView {
    var onFileDrop: (([URL]) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) else {
            return []
        }
        return .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else {
            return false
        }
        onFileDrop?(urls)
        return true
    }
}

/// Banner shown over the editor when the file on disk changed while the
/// buffer had unsaved edits. Offers an explicit choice instead of silently
/// clobbering external changes on the next save.
final class EditorConflictBanner: NSView {
    static let height: CGFloat = 34

    var onReload: (() -> Void)?
    var onKeep: (() -> Void)?

    private let messageLabel = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(red: 0.35, green: 0.22, blue: 0.08, alpha: 0.98).cgColor
        layer?.cornerRadius = 7
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.systemOrange.withAlphaComponent(0.5).cgColor

        messageLabel.font = .systemFont(ofSize: 11, weight: .medium)
        messageLabel.textColor = NSColor.white.withAlphaComponent(0.9)
        messageLabel.lineBreakMode = .byTruncatingMiddle
        addSubview(messageLabel)

        let reload = makeButton(title: "Reload from Disk", action: #selector(reloadClicked))
        let keep = makeButton(title: "Keep My Changes", action: #selector(keepClicked))
        addSubview(reload)
        addSubview(keep)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func makeButton(title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11, weight: .medium)
        return button
    }

    func configure(fileName: String) {
        messageLabel.stringValue = "\(fileName) changed on disk while you have unsaved edits."
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let pad: CGFloat = 10
        let buttonH: CGFloat = 22
        let buttonW: CGFloat = 118
        let gap: CGFloat = 8
        let y = (bounds.height - buttonH) / 2
        var x = bounds.width - pad
        for subview in subviews where subview is NSButton {
            x -= buttonW
            subview.frame = NSRect(x: x, y: y, width: buttonW, height: buttonH)
            x -= gap
        }
        messageLabel.frame = NSRect(x: pad, y: (bounds.height - 15) / 2, width: max(60, x - pad), height: 15)
    }

    @objc private func reloadClicked() { onReload?() }
    @objc private func keepClicked() { onKeep?() }
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
        layer?.backgroundColor = NSColor(red: 0.10, green: 0.11, blue: 0.15, alpha: 1).cgColor

        messageLabel.font = .systemFont(ofSize: 12, weight: .medium)
        messageLabel.textColor = NSColor.white.withAlphaComponent(0.55)
        messageLabel.alignment = .center
        addSubview(messageLabel)

        retryButton.bezelStyle = .rounded
        retryButton.font = .systemFont(ofSize: 12, weight: .medium)
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


