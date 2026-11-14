import AppKit

/// The glass interface's one button (docs/design/glass-interface.md): a
/// capsule in two sizes and five kinds. Primary for the one action a view
/// is for, secondary beside it, quiet for what can wait, danger for what
/// can't be undone, glass on glass chrome (macOS 26's own glass bezel; the
/// secondary look on macOS 14 and 15). Never amber: amber is an agent
/// waiting for the user. Nothing uses it yet.
final class NiruxButton: NSButton {
    enum Kind: CaseIterable, Sendable {
        case primary, secondary, quiet, danger, glass
    }

    enum Size: Sendable {
        case regular, small

        var height: CGFloat { self == .regular ? 24 : 20 }
        var padding: CGFloat { self == .regular ? 11 : 8 }
        var font: NSFont { self == .regular ? Theme.Font.button : Theme.Font.buttonSmall }
    }

    /// What a button draws in a state.
    struct Look: Equatable {
        var fill: NSColor
        var text: NSColor
        var border: NSColor?
    }

    let kind: Kind
    let size: Size

    private var isHovered = false { didSet { if isHovered != oldValue { applyLook() } } }
    private var isPressed = false { didSet { if isPressed != oldValue { applyLook() } } }
    private var hoverArea: NSTrackingArea?
    /// Setting the attributed title may set the title again.
    private var isApplyingLook = false

    init(title: String, kind: Kind, size: Size = .regular, target: AnyObject? = nil, action: Selector? = nil) {
        self.kind = kind
        self.size = size
        super.init(frame: NSRect(x: 0, y: 0, width: 0, height: size.height))
        self.title = title
        self.target = target
        self.action = action
        font = size.font
        if kind == .glass, Self.drawsSystemGlass {
            if #available(macOS 26, *) { bezelStyle = .glass }
        } else {
            isBordered = false
            bezelStyle = .regularSquare
            wantsLayer = true
            layer?.cornerCurve = .continuous
        }
        setFrameSize(intrinsicContentSize)
        applyLook()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// macOS 26 draws the glass kind itself.
    static var drawsSystemGlass: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }

    /// The look of `kind` in a state, from `Theme`. The glass kind looks
    /// secondary where the system doesn't draw it.
    static func look(_ kind: Kind, hovered: Bool, pressed: Bool, enabled: Bool) -> Look {
        let step = !enabled ? 0 : pressed ? 2 : hovered ? 1 : 0
        var look: Look
        switch kind {
        case .primary:
            look = Look(fill: Theme.Color.textPrimary.withAlphaComponent([1, 0.9, 0.78][step]), text: Theme.Color.canvas)
        case .secondary, .glass:
            look = Look(
                fill: Theme.Color.textPrimary.withAlphaComponent([0.09, 0.13, 0.17][step]),
                text: Theme.Color.textPrimary, border: Theme.Color.line
            )
        case .quiet:
            look = Look(
                fill: [NSColor.clear, Theme.Color.fillHover, Theme.Color.fillPressed][step],
                text: step == 0 ? Theme.Color.textSecondary : Theme.Color.textPrimary
            )
        case .danger:
            look = Look(fill: Theme.Color.error.withAlphaComponent([0.14, 0.2, 0.26][step]), text: Theme.Color.error)
        }
        if !enabled {
            look.text = Theme.Color.textDisabled
            look.fill = look.fill.withAlphaComponent(look.fill.alphaComponent / 2)
        }
        return look
    }

    override var intrinsicContentSize: NSSize {
        guard kind != .glass || !Self.drawsSystemGlass else { return super.intrinsicContentSize }
        let text = (title as NSString).size(withAttributes: [.font: size.font])
        return NSSize(width: ceil(text.width) + 2 * size.padding, height: size.height)
    }

    override var isEnabled: Bool {
        didSet { applyLook() }
    }

    override var title: String {
        didSet {
            guard !isApplyingLook else { return }
            invalidateIntrinsicContentSize()
            applyLook()
        }
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    /// Darker while the button tracks the mouse: without a border the cell
    /// draws no highlight of its own.
    override func mouseDown(with event: NSEvent) {
        isPressed = true
        super.mouseDown(with: event)
        isPressed = false
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layer?.cornerRadius = newSize.height / 2
    }

    /// The keyboard focus ring follows the capsule.
    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        guard kind != .glass || !Self.drawsSystemGlass else { return super.drawFocusRingMask() }
        let radius = bounds.height / 2
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
    }

    private func applyLook() {
        guard kind != .glass || !Self.drawsSystemGlass, !isApplyingLook else { return }
        isApplyingLook = true
        defer { isApplyingLook = false }
        let look = Self.look(kind, hovered: isHovered, pressed: isPressed, enabled: isEnabled)
        layer?.backgroundColor = look.fill.cgColor
        layer?.borderColor = look.border?.cgColor
        layer?.borderWidth = look.border == nil ? 0 : 1
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: size.font, .foregroundColor: look.text, .paragraphStyle: paragraph,
        ])
    }
}
