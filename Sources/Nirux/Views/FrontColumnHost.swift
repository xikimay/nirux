import AppKit

/// What lies over a workspace's row while its front editor column is up
/// (`WorkspaceState.front`): a shade dimming the row, whose click sends
/// the column back, and the column's shadow. It takes no click while the
/// column is down.
@MainActor
final class FrontColumnHost: NSView {
    private let shade = FrontShadeView()
    private let cardShadow = ColumnShadowView(frame: .zero)
    private let pill = FrontPill()
    /// Gets a click on the pill.
    var onPillClick: () -> Void = {}
    private(set) var isShown = false
    private var fades = 0
    static let fadeKey = "frontFade"
    /// Gets a click on the shade, in this view's coordinates.
    var onShadeClick: (NSPoint) -> Void = { _ in }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        shade.wantsLayer = true
        shade.layer?.backgroundColor = Theme.Color.frontShade.cgColor
        shade.onClick = { [weak self] point in
            guard let self else { return }
            self.onShadeClick(self.convert(point, from: self.shade))
        }
        cardShadow.show(.floating, animated: false)
        for view in [shade, cardShadow] {
            view.isHidden = true
            addSubview(view)
        }
        pill.isHidden = true
        pill.onClick = { [weak self] in self?.onPillClick() }
        addSubview(pill)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if isShown { return super.hitTest(point) }
        return !pill.isHidden && pill.frame.contains(convert(point, from: superview)) ? pill : nil
    }

    /// The column's view, above the shade and its shadow.
    func addFront(_ view: NSView) { addSubview(view) }

    /// The shade spans the host; the shadow lies under the column's `frame`.
    func place(front frame: NSRect) {
        shade.frame = bounds
        cardShadow.frame = frame
        placePill()
    }

    /// What the column down holds, shown at the top of the row while the
    /// user types, so as not to come up over them; nil hides it.
    func showPill(_ title: String?) {
        pill.title = title
        pill.isHidden = title == nil
        placePill()
    }

    private func placePill() {
        let size = pill.fittingSize
        pill.frame = NSRect(x: floor((bounds.width - size.width) / 2), y: bounds.height - size.height - Theme.Space.md, width: size.width, height: size.height)
    }

    /// Up, the shade and the shadow show and the shade takes the row's
    /// clicks; down, they fade out, then hide on time.
    func setShown(_ shown: Bool, duration: CFTimeInterval?) {
        isShown = shown
        fades += 1
        let fade = fades
        for view in [shade, cardShadow] {
            let from = view.isHidden ? 0 : view.layer?.presentation()?.opacity ?? Float(view.alphaValue)
            view.layer?.removeAnimation(forKey: Self.fadeKey)
            if shown { view.isHidden = false }
            view.alphaValue = shown ? 1 : 0
            guard let duration, let layer = view.layer else { continue }
            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = from
            animation.toValue = shown ? 1 : 0
            animation.duration = duration
            layer.add(animation, forKey: Self.fadeKey)
        }
        guard !shown else { return }
        guard let duration else { return hideIfStill(fade) }
        ColumnState.afterCommit(duration) { [weak self] in self?.hideIfStill(fade) }
    }

    private func hideIfStill(_ fade: Int) {
        guard fades == fade else { return }
        shade.isHidden = true
        cardShadow.isHidden = true
    }
}

/// "<file> ⌘Y": the front column has something new; a click brings it up.
private final class FrontPill: NSView {
    private let fill = CALayer()
    private let label = NSTextField(labelWithString: "")
    var onClick: () -> Void = {}
    var title: String? {
        didSet {
            label.stringValue = (title ?? "") + "  " + NiruxShortcuts.frontEditor.chord.display
            setAccessibilityLabel(title.map { "Show \($0) in the front editor" })
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        fill.backgroundColor = Theme.Color.accent.cgColor
        layer?.addSublayer(fill)
        label.font = Theme.Font.captionEmphasized
        label.textColor = Theme.Color.canvas
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var fittingSize: NSSize {
        let text = label.fittingSize
        return NSSize(width: ceil(text.width) + Theme.Space.md * 2, height: ceil(text.height) + Theme.Space.sm)
    }

    override func layout() {
        super.layout()
        fill.frame = bounds
        fill.cornerRadius = bounds.height / 2
        let text = label.fittingSize
        label.frame = NSRect(x: Theme.Space.md, y: floor((bounds.height - text.height) / 2), width: bounds.width - Theme.Space.md * 2, height: text.height)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick() }
    override func accessibilityPerformPress() -> Bool {
        onClick()
        return true
    }
}

/// The shade over the row: a click on it goes to the host.
private final class FrontShadeView: NSView {
    var onClick: (NSPoint) -> Void = { _ in }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onClick(convert(event.locationInWindow, from: nil))
    }
}
