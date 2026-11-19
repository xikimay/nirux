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
        var padding: CGFloat { self == .regular ? 12 : 8 }
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
    /// How high it rises under the pointer, over a short shadow (`Relief`);
    /// pressed, it is flat again. 0: it stays flat.
    var relief: CGFloat = 0 { didSet { if relief != oldValue { applyLook() } } }
    /// While the cell highlights: during a press with the pointer on the
    /// button, and while its action runs.
    fileprivate var isPressed = false { didSet { if isPressed != oldValue { applyLook() } } }
    private var hoverArea: NSTrackingArea?
    /// Setting the attributed title may set the title again.
    private var isApplyingLook = false
    /// The title's colour as last set: only a new colour or a new title
    /// sets the attributed title again.
    private var titleColor: NSColor?

    override class var cellClass: AnyClass? {
        get { NiruxButtonCell.self }
        set {}
    }

    /// `focusable`: in the key loop under Full Keyboard Access (a sheet's,
    /// Settings' buttons); otherwise a click leaves the keyboard where it
    /// was (the terminal, Monaco).
    init(
        title: String, kind: Kind, size: Size = .regular, focusable: Bool = false,
        target: AnyObject? = nil, action: Selector? = nil
    ) {
        self.kind = kind
        self.size = size
        super.init(frame: NSRect(x: 0, y: 0, width: 0, height: size.height))
        self.title = title
        self.target = target
        self.action = action
        font = size.font
        refusesFirstResponder = !focusable
        if kind == .glass, Self.drawsSystemGlass {
            if #available(macOS 26, *) { bezelStyle = .glass }
            controlSize = size == .small ? .small : .regular
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
            // Every kind greys out the same way, the primary included: a
            // light slab with grey text would read neither as on nor off.
            let resting = kind == .primary ? Self.look(.secondary, hovered: false, pressed: false, enabled: true) : look
            look.fill = resting.fill.withAlphaComponent(resting.fill.alphaComponent / 2)
            look.border = resting.border
            look.text = Theme.Color.textDisabled
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
            titleColor = nil
            applyLook()
        }
    }

    /// Fits the capsule to its title: call it after a title change when the
    /// button is laid out with frames.
    override func sizeToFit() {
        setFrameSize(intrinsicContentSize)
    }

    /// Hidden, itself or with its container: no hover left behind.
    override func viewDidHide() {
        super.viewDidHide()
        isHovered = false
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { isHovered = false }
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

    /// Asked at each press: a press it refuses does nothing, no highlight and
    /// no action (an answer's button that just moved under the pointer, the
    /// second press of a double-click).
    var acceptsPress: ((NSEvent) -> Bool)?
    /// After a press it accepted, once its tracking is over: released on it
    /// (its action already sent) or elsewhere.
    var pressEnded: (() -> Void)?

    /// The tracking loop of a press eats the pointer's exit: after it, the
    /// hover follows where the pointer is.
    override func mouseDown(with event: NSEvent) {
        if let acceptsPress, !acceptsPress(event) { return }
        super.mouseDown(with: event)
        pressEnded?()
        guard let window else { return isHovered = false }
        isHovered = bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layer?.cornerRadius = newSize.height / 2
        // The radius turns clipping on, which would cut its relief's shadow;
        // the fill keeps its corners without it.
        if relief > 0 { layer?.masksToBounds = false }
        if let layer { Relief.reshape(layer, shape: bounds, radius: newSize.height / 2) }
    }

    /// VoiceOver reads the cell, not the control: what the button is called
    /// goes to both.
    override func setAccessibilityLabel(_ label: String?) {
        super.setAccessibilityLabel(label)
        cell?.setAccessibilityLabel(label)
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
        if let layer, relief > 0 || layer.sublayers?.contains(where: { $0.name == Relief.shadowName }) == true {
            layer.masksToBounds = ZZ("clipsShadow")
            let lifted = relief > 0 && isEnabled && isHovered && !isPressed
            Relief.show(lifted ? .lifted(height: relief) : .resting, on: layer, shape: bounds, radius: bounds.height / 2, animated: window != nil)
        }
        layer?.borderColor = look.border?.cgColor
        layer?.borderWidth = look.border == nil ? 0 : 1
        guard look.text != titleColor else { return }
        titleColor = look.text
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: size.font, .foregroundColor: look.text, .paragraphStyle: paragraph,
        ])
    }
}

/// Tells its button when it highlights (AppKit highlights the cell, not the
/// control, during a press, a `performClick` or a key equivalent), and draws
/// the button's own title: AppKit would recolour a disabled one.
private final class NiruxButtonCell: NSButtonCell {
    override func highlight(_ flag: Bool, withFrame cellFrame: NSRect, in controlView: NSView) {
        super.highlight(flag, withFrame: cellFrame, in: controlView)
        (controlView as? NiruxButton)?.isPressed = flag
    }

    override func drawTitle(_ title: NSAttributedString, withFrame frame: NSRect, in controlView: NSView) -> NSRect {
        super.drawTitle((controlView as? NSButton)?.attributedTitle ?? title, withFrame: frame, in: controlView)
    }
}
