import AppKit

/// Depth study P4, the crossing (docs/design/glass-interface.md): ⌥⌘← ⌥⌘→
/// pass through depth. The space left recedes into the glass as it fades;
/// the one chosen comes from the front and lands. Both are frozen
/// (`FrozenView`), the live views hidden under them until it lands, so no
/// live terminal scales.
extension NiruxShellView {
    static let crossingDuration: CFTimeInterval = 0.56
    static let recedeScale: CGFloat = 0.92
    static let arrivalFromScale: CGFloat = 1.06

    /// `leaving`, what the viewport showed before the switch, crosses with
    /// the space chosen, laid out under it now.
    func crossSpaces(leaving: FrozenView, duration: CFTimeInterval = crossingDuration) {
        endSpaceCrossing()
        viewport.layoutSubtreeIfNeeded()
        let arriving = FrozenView.freeze(viewport)
        let generation = spaceCrossingGeneration
        crossingPictures = [leaving] + (arriving.map { [$0] } ?? [])
        for picture in crossingPictures { viewport.addSubview(picture) }
        verticalStrip.alphaValue = 0
        Self.move(leaving, scale: (1, Self.recedeScale), opacity: (1, 0), curve: .easeIn, duration: duration)
        if let arriving {
            Self.move(arriving, scale: (Self.arrivalFromScale, 1), opacity: (0, 1), curve: .easeOut, duration: duration)
        }
        sideEffects.afterCommit(duration) { [weak self] in
            guard let self, spaceCrossingGeneration == generation else { return }
            endSpaceCrossing()
        }
    }

    /// The live views back, the pictures gone, and no crossing left to end.
    func endSpaceCrossing() {
        spaceCrossingGeneration += 1
        for picture in crossingPictures { picture.removeFromSuperview() }
        crossingPictures = []
        verticalStrip.alphaValue = 1
    }

    /// From the first values to the second, about the picture's middle; it
    /// rests on the second. Its frozen layers move, not the view's own.
    private static func move(
        _ picture: FrozenView, scale: (CGFloat, CGFloat), opacity: (Float, Float),
        curve: CAMediaTimingFunctionName, duration: CFTimeInterval
    ) {
        let layer = picture.content
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = scaledAboutMiddle(layer, by: scale.1)
        layer.opacity = opacity.1
        CATransaction.commit()
        let size = CABasicAnimation(keyPath: "transform")
        size.fromValue = NSValue(caTransform3D: scaledAboutMiddle(layer, by: scale.0))
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = opacity.0
        let group = CAAnimationGroup()
        group.animations = [size, fade]
        group.duration = duration
        group.timingFunction = CAMediaTimingFunction(name: curve)
        layer.add(group, forKey: "crossing")
    }

    /// `scale` about the layer's middle, wherever its anchor lies.
    static func scaledAboutMiddle(_ layer: CALayer, by scale: CGFloat) -> CATransform3D {
        let dx = (0.5 - layer.anchorPoint.x) * layer.bounds.width
        let dy = (0.5 - layer.anchorPoint.y) * layer.bounds.height
        return CATransform3DTranslate(CATransform3DScale(CATransform3DMakeTranslation(dx, dy, 0), scale, scale, 1), -dx, -dy, 0)
    }
}
