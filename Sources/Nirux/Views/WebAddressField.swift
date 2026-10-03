import AppKit

/// The browser header's address. At rest it reads the URL without its
/// scheme, the host dimmed before the path ("localhost:5173/" then
/// "checkout"); while it has the keyboard it holds the whole URL to edit.
@MainActor
final class AddressField: NSTextField {
    /// The page's URL. Shown at once, even while the user edits (a
    /// navigation replaces what they typed, as before).
    var url = "" {
        didSet { if url != oldValue { showURL() } }
    }

    convenience init() {
        self.init(frame: .zero)
        font = Theme.Font.mono
        textColor = Theme.Color.textPrimary
        isBezeled = false
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        isEditable = true
        cell?.wraps = false
        cell?.isScrollable = true
        cell?.usesSingleLineMode = true
        setAccessibilityLabel("Address")
    }

    /// Like a browser's address bar, the first click selects the whole URL:
    /// placing the caret where the shorter address was clicked would land
    /// it elsewhere in the whole one. Later clicks reach the field editor.
    override func mouseDown(with event: NSEvent) {
        guard currentEditor() == nil, window?.makeFirstResponder(self) == true else {
            return super.mouseDown(with: event)
        }
        currentEditor()?.selectAll(nil)
    }

    override func becomeFirstResponder() -> Bool {
        // The field editor starts from the whole URL, plain.
        showPlainURL()
        return super.becomeFirstResponder()
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        // Return navigated (the action set `url`); Escape or a click
        // elsewhere puts the page's URL back.
        showURL()
    }

    private func showURL() {
        if currentEditor() != nil {
            showPlainURL()
        } else {
            attributedStringValue = Self.display(url)
        }
    }

    /// An attributed value leaves its first run's color on the field.
    private func showPlainURL() {
        font = Theme.Font.mono
        textColor = Theme.Color.textPrimary
        stringValue = url
    }

    /// What the field reads at rest: an http(s) URL's host and the slash
    /// after it dimmed, its path, query and fragment in primary text. A
    /// bare host, or another scheme, reads whole in primary text.
    static func displayParts(_ url: String) -> (dimmed: String, primary: String) {
        let lowered = url.lowercased()
        guard let scheme = ["https://", "http://"].first(where: { lowered.hasPrefix($0) }) else { return ("", url) }
        let rest = String(url.dropFirst(scheme.count))
        guard let slash = rest.firstIndex(of: "/") else { return ("", rest) }
        let path = String(rest[rest.index(after: slash)...])
        guard !path.isEmpty else { return ("", rest) }
        return (String(rest[...slash]), path)
    }

    static func display(_ url: String) -> NSAttributedString {
        let parts = displayParts(url)
        let text = NSMutableAttributedString(string: parts.dimmed, attributes: [
            .font: Theme.Font.mono, .foregroundColor: Theme.Color.textTertiary
        ])
        text.append(NSAttributedString(string: parts.primary, attributes: [
            .font: Theme.Font.mono, .foregroundColor: Theme.Color.textPrimary
        ]))
        return text
    }
}

/// The address field's frame in the header: a sunken control, the field
/// centered in it. A click on its margin edits the address too.
@MainActor
final class AddressBox: NSView {
    var field: NSTextField? {
        didSet {
            oldValue?.removeFromSuperview()
            if let field { addSubview(field) }
            needsLayout = true
        }
    }

    private static let inset = Theme.Space.sm - 2
    private static let fieldHeight: CGFloat = 16

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Theme.Color.canvas.cgColor
        layer?.cornerRadius = Theme.Radius.control
        layer?.borderWidth = 1
        layer?.borderColor = Theme.Color.line.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { false }

    override func layout() {
        super.layout()
        field?.frame = NSRect(
            x: Self.inset, y: ((bounds.height - Self.fieldHeight) / 2).rounded(),
            width: max(0, bounds.width - Self.inset * 2), height: Self.fieldHeight
        )
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func mouseDown(with event: NSEvent) {
        guard let field else { return super.mouseDown(with: event) }
        window?.makeFirstResponder(field)
    }
}
