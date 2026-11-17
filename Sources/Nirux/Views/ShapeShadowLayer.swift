import AppKit

/// Casts an elevation's shadow (`Theme.Elevation`) around a shape, and only
/// outside it: what lies on the shape, translucent or fading, shows none of
/// it.
final class ShapeShadowLayer: CALayer {
    private let cutOut = CAShapeLayer()

    override init() {
        super.init()
        cutOut.fillRule = .evenOdd
        mask = cutOut
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Casts `level`'s shadow along `shape`, a path in the layer's own
    /// coordinates, the layer laid over `frame`.
    func cast(_ level: Theme.Elevation.Level, along shape: CGPath, frame: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        self.frame = frame
        Theme.Elevation.apply(level, to: self, path: shape)
        // The mask spans the shadow's reach, with the shape cut out.
        let outside = CGMutablePath()
        outside.addRect(bounds.insetBy(dx: -level.reach, dy: -level.reach))
        outside.addPath(shape)
        cutOut.frame = bounds
        cutOut.path = outside
    }
}
