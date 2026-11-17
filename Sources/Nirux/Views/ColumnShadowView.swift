import AppKit

/// A column's shadow (`Theme.Elevation.Level.column`), under it in its
/// workspace's strip: the column clips its content to its corners, which
/// would cut a shadow of its own off. Decoration: it takes no click and no
/// VoiceOver focus.
final class ColumnShadowView: NSView {
    private let shadowLayer = ShapeShadowLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // Fading with its column blends its one sublayer on its own: no
        // offscreen pass of the column's size.
        layer?.allowsGroupOpacity = false
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

    /// The shape the shadow is cast along, and how (for tests).
    var shadowPath: CGPath? { shadowLayer.shadowPath }
    var shadowOpacity: Float { shadowLayer.shadowOpacity }
    /// Whether the shape is cut out of the shadow (for tests).
    var cutsOutItsShape: Bool { (shadowLayer.mask as? CAShapeLayer)?.fillRule == .evenOdd }

    private func updateShadow() {
        let radius = max(0, min(Theme.Radius.column, bounds.width / 2, bounds.height / 2))
        let shape = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        shadowLayer.cast(.column, along: shape, frame: bounds)
    }
}
