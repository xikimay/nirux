import AppKit

/// The find bar floating over a terminal or browser column's top-right
/// corner (⌘F): a field, a match counter, next/previous buttons and a
/// close button. Return goes to the next match, Shift+Return to the
/// previous one, Escape closes the bar.
///
/// In a terminal, Ghostty searches from the bottom, so "next" moves up
/// through older output, and the up arrow is the next-match button, as in
/// Ghostty. libghostty runs the search and highlights the matches (see
/// TerminalSearchSession). There is no match counter: libghostty-spm does
/// not forward Ghostty's match totals to its delegate. On a page, "next"
/// moves down, and WebKit counts the matches (WebPageFind).
@MainActor
final class FindBar: NSView, NSTextFieldDelegate {
    /// What the bar searches: it sets the way "next" goes and the field's
    /// accessibility label.
    enum Target {
        case terminal, page
    }

    static let height: CGFloat = 32
    static let preferredWidth: CGFloat = 320
    /// The counter hides rather than leave the field narrower.
    static let minimumFieldWidth: CGFloat = 80

    var onNeedleChange: ((String) -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onClose: (() -> Void)?
    /// Modifiers of the key event being handled (a seam for tests).
    var currentModifierFlags: () -> NSEvent.ModifierFlags = { NSApp.currentEvent?.modifierFlags ?? [] }

    let field = NSTextField()
    /// The match counter ("12 matches", "Not found"); nil hides it.
    var status: String? {
        didSet {
            statusLabel.stringValue = status ?? ""
            needsLayout = true
        }
    }
    private let statusLabel = NSTextField(labelWithString: "")
    private let upButton: NSButton
    private let downButton: NSButton
    private let closeButton = FindBar.makeButton(
        symbol: "xmark", label: "Close Find Bar", toolTip: "Close (Esc)"
    )

    init(target: Target) {
        let next = (label: "Next Match", toolTip: "Next Match (\u{2318}G)", action: #selector(nextClicked))
        let previous = (label: "Previous Match", toolTip: "Previous Match (\u{21E7}\u{2318}G)", action: #selector(previousClicked))
        let (up, down) = target == .terminal ? (next, previous) : (previous, next)
        upButton = Self.makeButton(symbol: "chevron.up", label: up.label, toolTip: up.toolTip)
        upButton.action = up.action
        downButton = Self.makeButton(symbol: "chevron.down", label: down.label, toolTip: down.toolTip)
        downButton.action = down.action
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.Color.surface.withAlphaComponent(0.98).cgColor
        layer?.cornerRadius = 7
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 6
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        self.shadow = shadow

        field.placeholderString = "Find"
        field.font = .systemFont(ofSize: 12)
        field.bezelStyle = .roundedBezel
        field.usesSingleLineMode = true
        field.lineBreakMode = .byClipping
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = self
        field.setAccessibilityLabel(target == .terminal ? "Find in Terminal" : "Find in Page")
        addSubview(field)

        statusLabel.font = Theme.Font.caption
        statusLabel.textColor = Theme.Color.textSecondary
        statusLabel.lineBreakMode = .byClipping
        statusLabel.isHidden = true
        addSubview(statusLabel)

        closeButton.action = #selector(closeClicked)
        for button in [upButton, downButton, closeButton] {
            button.target = self
            addSubview(button)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// True while the field holds the keyboard focus. The key interceptor
    /// then lets keys reach the field instead of the PTY or the page.
    var isEditing: Bool {
        guard let editor = field.currentEditor() else { return false }
        return window?.firstResponder === editor
    }

    /// Focus the field; its text is selected so typing replaces it.
    func focusField() {
        window?.makeFirstResponder(field)
    }

    override func layout() {
        super.layout()
        let inset: CGFloat = 5
        let side: CGFloat = 22
        var buttonX = bounds.width - inset - side
        for button in [closeButton, downButton, upButton] {
            button.frame = NSRect(x: buttonX, y: (bounds.height - side) / 2, width: side, height: side)
            buttonX -= side + 2
        }
        var fieldMaxX = upButton.frame.minX - 6
        let statusSize = statusLabel.cell?.cellSize ?? .zero
        let statusWidth = ceil(statusSize.width)
        statusLabel.isHidden = status == nil || fieldMaxX - statusWidth - 4 - inset < Self.minimumFieldWidth
        if !statusLabel.isHidden {
            statusLabel.frame = NSRect(
                x: fieldMaxX - statusWidth, y: (bounds.height - statusSize.height) / 2,
                width: statusWidth, height: statusSize.height
            )
            fieldMaxX = statusLabel.frame.minX - 4
        }
        field.frame = NSRect(
            x: inset,
            y: (bounds.height - side) / 2,
            width: max(0, fieldMaxX - inset),
            height: side
        )
    }

    // The terminal below sets an I-beam cursor; the bar's chrome is not text.
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        onNeedleChange?(field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)),
             #selector(NSResponder.insertLineBreak(_:)),
             #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            if currentModifierFlags().contains(.shift) {
                onPrevious?()
            } else {
                onNext?()
            }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
            return true
        // The bar is not in the window's key-view loop: Tab would hand the
        // focus to an arbitrary view of another column.
        case #selector(NSResponder.insertTab(_:)),
             #selector(NSResponder.insertBacktab(_:)):
            return true
        default:
            return false
        }
    }

    // MARK: - Buttons

    @objc private func previousClicked() { onPrevious?() }
    @objc private func nextClicked() { onNext?() }
    @objc private func closeClicked() { onClose?() }

    private static func makeButton(symbol: String, label: String, toolTip: String) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        let button = NSButton(image: image ?? NSImage(), target: nil, action: nil)
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.contentTintColor = NSColor.white.withAlphaComponent(0.7)
        button.toolTip = toolTip
        button.setAccessibilityLabel(label)
        return button
    }
}
