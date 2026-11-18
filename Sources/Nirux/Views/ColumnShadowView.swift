import AppKit

/// A column's shadow (`Theme.Elevation.Level.column`, a level higher for
/// the focus), under it in its workspace's strip: the column clips its
/// content to its corners, which would cut a shadow of its own off. Cast
/// along a path and never masked, so that it costs no offscreen pass while
/// terminals redraw over it; the opaque card hides its inside, and it hides
/// while its column comes or goes. Decoration: it takes no click and no
/// VoiceOver focus.
final class ColumnShadowView: NSView {
    /// How long the shadow takes to pass to its new level as the focus
    /// moves.
    static let liftDuration: CFTimeInterval = 0.22
    static let liftKey = "lift"

    private let shadowLayer = CALayer()
    /// How high the card lies.
    private(set) var level = Theme.Elevation.Level.column

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
        guard level != self.level else { return }
        let shown = shadowLayer.presentation() ?? shadowLayer
        let from = (opacity: shown.shadowOpacity, radius: shown.shadowRadius, offset: shown.shadowOffset)
        self.level = level
        updateShadow()
        guard animated else {
            shadowLayer.removeAnimation(forKey: Self.liftKey)
            return
        }
        let lift = CAAnimationGroup()
        lift.animations = [
            Self.change("shadowOpacity", from: from.opacity, to: shadowLayer.shadowOpacity),
            Self.change("shadowRadius", from: from.radius, to: shadowLayer.shadowRadius),
            Self.change("shadowOffset", from: NSValue(size: from.offset), to: NSValue(size: shadowLayer.shadowOffset))
        ]
        lift.duration = Self.liftDuration
        lift.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1)
        shadowLayer.add(lift, forKey: Self.liftKey)
    }

    /// The shape the shadow is cast along, and how (for tests).
    var shadowPath: CGPath? { shadowLayer.shadowPath }
    var shadowOpacity: Float { shadowLayer.shadowOpacity }
    /// The shadow is passing to a new level.
    var isLifting: Bool { shadowLayer.animation(forKey: Self.liftKey) != nil }

    private static func change(_ keyPath: String, from: Any, to: Any) -> CABasicAnimation {
        let change = CABasicAnimation(keyPath: keyPath)
        change.fromValue = from
        change.toValue = to
        return change
    }

    private func updateShadow() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        shadowLayer.frame = bounds
        let radius = max(0, min(Theme.Radius.column, bounds.width / 2, bounds.height / 2))
        let shape = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        Theme.Elevation.apply(level, to: shadowLayer, path: shape)
    }
}
