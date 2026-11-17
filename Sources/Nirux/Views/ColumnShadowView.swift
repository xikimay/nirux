import AppKit

/// A column's shadow (`Theme.Elevation.Level.column`), under it in its
/// workspace's strip: the column clips its content to its corners, which
/// would cut a shadow of its own off. Cast along a path and never masked,
/// so that it costs no offscreen pass while terminals redraw over it; the
/// opaque card hides its inside, and it hides while its column comes or
/// goes. Decoration: it takes no click and no VoiceOver focus.
final class ColumnShadowView: NSView {
    private let shadowLayer = CALayer()

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

    /// The shape the shadow is cast along, and how (for tests).
    var shadowPath: CGPath? { shadowLayer.shadowPath }
    var shadowOpacity: Float { shadowLayer.shadowOpacity }

    private func updateShadow() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        shadowLayer.frame = bounds
        let radius = max(0, min(Theme.Radius.column, bounds.width / 2, bounds.height / 2))
        let shape = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        Theme.Elevation.apply(.column, to: shadowLayer, path: shape)
    }
}
