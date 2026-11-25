import AppKit

/// A column's shadow (`Theme.Elevation.Level.column`, a level higher for
/// the focus), under it in its workspace's strip: the column clips its
/// content to its corners, which would cut a shadow of its own off. Cast
/// along a path, and unmasked under an opaque card, which hides its inside,
/// so that it costs no offscreen pass while terminals redraw over it; cut
/// out of a card that lets it show through. Decoration: it takes no click
/// and no VoiceOver focus.
final class ColumnShadowView: NSView {
    /// How long the shadow takes to pass to its new level as the focus
    /// moves.
    static let liftDuration: CFTimeInterval = 0.22
    static let liftKey = "lift"
    /// How far its cut-out spans past the card: any level's shadow (a card
    /// the pointer holds floats), a lift on its way included.
    static let cutOutReach = max(
        Theme.Elevation.Level.column.reach, Theme.Elevation.Level.focusedColumn.reach, Theme.Elevation.Level.floating.reach
    )

    private let shadowLayer = CALayer()
    /// How high the card lies.
    private(set) var level = Theme.Elevation.Level.column
    private let cutOut = CAShapeLayer()
    /// The card lets what lies under it show through (a translucent
    /// terminal): the shadow then falls only around it.
    var isCardClear = false {
        didSet { if isCardClear != oldValue { updateShadow() } }
    }
    /// How the shadow shows now, a lift on its way included (its
    /// presentation layer); tests say.
    var shownShadow: (CALayer) -> (opacity: Float, radius: CGFloat, offset: CGSize) = { layer in
        let shown = layer.presentation() ?? layer
        return (shown.shadowOpacity, shown.shadowRadius, shown.shadowOffset)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(shadowLayer)
        setAccessibilityElement(false)
        updateShadow()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateShadow()
    }

    /// Lays the card at `level`. `animated`: the shadow passes there from
    /// where it shows now, mid-way included; else it is there at once.
    func show(_ level: Theme.Elevation.Level, animated: Bool) {
        // At once: a lift on its way, even to this level, is cut short.
        if !animated { settle() }
        guard level != self.level else { return }
        let from = shownShadow(shadowLayer)
        self.level = level
        updateShadow()
        guard animated else { return }
        let lift = CAAnimationGroup()
        lift.animations = [
            Self.change("shadowOpacity", from: from.opacity, to: shadowLayer.shadowOpacity),
            Self.change("shadowRadius", from: from.radius, to: shadowLayer.shadowRadius),
            Self.change("shadowOffset", from: NSValue(size: from.offset), to: NSValue(size: shadowLayer.shadowOffset))
        ]
        lift.duration = Self.liftDuration
        shadowLayer.add(lift, forKey: Self.liftKey)
    }

    /// The shadow at its level at once, a lift on its way cut short.
    func settle() {
        if isLifting { shadowLayer.removeAnimation(forKey: Self.liftKey) }
    }

    /// The shape the shadow is cast along, how, and where it may fall
    /// (nil: everywhere), for tests.
    var shadowPath: CGPath? { shadowLayer.shadowPath }
    var shadowOpacity: Float { shadowLayer.shadowOpacity }
    var cutOutPath: CGPath? { shadowLayer.mask == nil ? nil : cutOut.path }
    /// The shadow is passing to a new level, from this opacity.
    var isLifting: Bool { shadowLayer.animation(forKey: Self.liftKey) != nil }
    var liftStartOpacity: Float? {
        let lift = shadowLayer.animation(forKey: Self.liftKey) as? CAAnimationGroup
        return (lift?.animations?.compactMap { $0 as? CABasicAnimation }.first { $0.keyPath == "shadowOpacity" })?.fromValue as? Float
    }

    private static func change(_ keyPath: String, from: Any, to: Any) -> CABasicAnimation {
        let change = CABasicAnimation(keyPath: keyPath)
        change.fromValue = from
        change.toValue = to
        change.duration = liftDuration
        change.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1)
        return change
    }

    private func updateShadow() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        shadowLayer.frame = bounds
        Theme.Elevation.apply(
            level, to: shadowLayer, roundedRect: bounds, radius: Theme.Radius.column,
            cutOut: isCardClear ? cutOut : nil, cutOutReach: Self.cutOutReach
        )
    }
}
