import AppKit

/// The find bar floating over a terminal column's top-right corner (⌘F):
/// a field, next/previous buttons and a close button. Return goes to the
/// next match, Shift+Return to the previous one, Escape closes the bar.
/// Ghostty searches from the bottom, so "next" moves up through older
/// output, and the up arrow is the next-match button, as in Ghostty.
///
/// libghostty runs the search and highlights the matches in the terminal
/// (see TerminalSearchSession). There is no match counter: libghostty-spm
/// does not forward Ghostty's match totals to its delegate.
@MainActor
final class TerminalFindBar: NSView, NSTextFieldDelegate {
    static let height: CGFloat = 32
    static let preferredWidth: CGFloat = 320

    var onNeedleChange: ((String) -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onClose: (() -> Void)?
    /// Modifiers of the key event being handled (a seam for tests).
    var currentModifierFlags: () -> NSEvent.ModifierFlags = { NSApp.currentEvent?.modifierFlags ?? [] }

    let field = NSTextField()
    private let nextButton = TerminalFindBar.makeButton(
        symbol: "chevron.up", label: "Next Match", toolTip: "Next Match (\u{2318}G)"
    )
    private let previousButton = TerminalFindBar.makeButton(
        symbol: "chevron.down", label: "Previous Match", toolTip: "Previous Match (\u{21E7}\u{2318}G)"
    )
    private let closeButton = TerminalFindBar.makeButton(
        symbol: "xmark", label: "Close Find Bar", toolTip: "Close (Esc)"
    )

    override init(frame: NSRect) {
        super.init(frame: frame)
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
        field.setAccessibilityLabel("Find in Terminal")
        addSubview(field)

        previousButton.target = self
        previousButton.action = #selector(previousClicked)
        nextButton.target = self
        nextButton.action = #selector(nextClicked)
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        for button in [nextButton, previousButton, closeButton] {
            addSubview(button)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// True while the field holds the keyboard focus. The key interceptor
    /// then lets keys reach the field instead of the PTY.
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
        for button in [closeButton, previousButton, nextButton] {
            button.frame = NSRect(x: buttonX, y: (bounds.height - side) / 2, width: side, height: side)
            buttonX -= side + 2
        }
        let fieldMaxX = nextButton.frame.minX - 6
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
