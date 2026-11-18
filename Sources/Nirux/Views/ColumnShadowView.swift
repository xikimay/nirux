import AppKit

/// A column's shadow (`Theme.Elevation.Level.column`), under it in its
/// workspace's strip: the column clips its content to its corners, which
/// would cut a shadow of its own off. Cast along a path, and unmasked under
/// an opaque card, which hides its inside, so that it costs no offscreen
/// pass while terminals redraw over it; cut out of a card that lets it show
/// through. Decoration: it takes no click and no VoiceOver focus.
final class ColumnShadowView: NSView {
    private let shadowLayer = CALayer()
    private let cutOut = CAShapeLayer()
    /// The card lets what lies under it show through (a translucent
    /// terminal): the shadow then falls only around it.
    var isCardClear = false {
        didSet { if isCardClear != oldValue { updateShadow() } }
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

    /// The shape the shadow is cast along, how, and where it may fall
    /// (nil: everywhere), for tests.
    var shadowPath: CGPath? { shadowLayer.shadowPath }
    var shadowOpacity: Float { shadowLayer.shadowOpacity }
    var cutOutPath: CGPath? { shadowLayer.mask == nil ? nil : cutOut.path }

    private func updateShadow() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        shadowLayer.frame = bounds
        Theme.Elevation.apply(
            .column, to: shadowLayer, roundedRect: bounds, radius: Theme.Radius.column, cutOut: isCardClear ? cutOut : nil
        )
    }
}
