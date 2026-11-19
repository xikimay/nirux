import AppKit

/// A card's motion (depth study P8): a pass in or out, its scale and
/// opacity, and a glide to a new place in its strip, its light and shadow
/// with it. Every move of its layer is additive, so a glide, an arrival and
/// a close on one card compose; a pass owns the card until another takes
/// it. Explicit animations: AppKit doesn't animate a view's layer inside an
/// animation group. Its layer's own transform stays whole.
extension ColumnState {
    static let passKey = "cardPass"
    static let glideKey = "cardGlide"
    static let glideDuration: CFTimeInterval = 0.36

    /// `scale` about a card's middle: a view's layer turns about its corner.
    static func scaledAboutMiddle(_ size: NSSize, by scale: CGFloat) -> CGAffineTransform {
        CGAffineTransform(translationX: size.width * (1 - scale) / 2, y: size.height * (1 - scale) / 2)
            .scaledBy(x: scale, y: scale)
    }

    /// The card passes from `from` (nil: where it shows) to `scale` of
    /// its size about its middle and to `alpha`, held until the pass ends,
    /// on time; then `then`, unless another pass took the card meanwhile.
    func pass(
        from: (scale: CGFloat, alpha: CGFloat)? = nil, to scale: CGFloat, alpha: CGFloat,
        duration: CFTimeInterval, curve: CAMediaTimingFunction, then: @escaping @MainActor () -> Void
    ) {
        guard let layer = view.layer else { return then() }
        passes += 1
        let pass = passes
        let shown = layer.presentation()
        let start = from ?? (
            (shown?.value(forKeyPath: "transform.scale.x") as? NSNumber).map { CGFloat($0.doubleValue) } ?? 1,
            CGFloat(shown?.opacity ?? Float(view.alphaValue))
        )
        let size = view.frame.size
        view.alphaValue = alpha
        let scaling = CABasicAnimation(keyPath: "transform")
        scaling.fromValue = CATransform3DMakeAffineTransform(Self.scaledAboutMiddle(size, by: start.scale))
        scaling.toValue = CATransform3DMakeAffineTransform(Self.scaledAboutMiddle(size, by: scale))
        scaling.isAdditive = true
        let fading = CABasicAnimation(keyPath: "opacity")
        fading.fromValue = Float(start.alpha)
        fading.toValue = Float(alpha)
        let group = CAAnimationGroup()
        group.animations = [scaling, fading]
        group.duration = duration
        group.timingFunction = curve
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        layer.add(group, forKey: Self.passKey)
        // On time once the change is committed (a busy turn delays its
        // start), not on the animation's completion, which a window out of
        // view may never report.
        DispatchQueue.main.async {
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.passes == pass else { return }
                    self.view.layer?.removeAnimation(forKey: Self.passKey)
                    then()
                }
            }
        }
    }

    /// Where the card shows in its strip, a glide on its way included, and
    /// how wide it is.
    var shownPlace: (x: CGFloat, width: CGFloat) {
        let gliding = (view.layer?.presentation()?.value(forKeyPath: "transform.translation.x") as? NSNumber)?.doubleValue ?? 0
        return (view.frame.minX + CGFloat(gliding), view.frame.width)
    }

    /// A neighbour pushed or let go of the card: it glides to its place
    /// from `dx` away, its light and its shadow with it.
    func glide(by dx: CGFloat) {
        for layer in [view, light, shadow].compactMap({ $0?.layer }) {
            let glide = CABasicAnimation(keyPath: "transform.translation.x")
            glide.fromValue = dx
            glide.toValue = 0
            glide.isAdditive = true
            glide.duration = Self.glideDuration
            glide.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.9, 0.3, 1)
            layer.add(glide, forKey: Self.glideKey)
        }
    }

    static let liftHeight: CGFloat = 10
    static let liftKey = "lift"
    /// How dark the card passed under gets, half-way.
    static let passShade: Float = 0.35

    /// Moved, the card passes over the one it swaps with, while both glide:
    /// it rises a little on its way, its shadow falling on the other, which
    /// dims under it a moment.
    func lift(over passed: ColumnState) {
        let duration = Self.glideDuration
        let curve = CAMediaTimingFunction(controlPoints: 0.3, 0.6, 0.3, 1)
        let raised = [view, light, shadow].compactMap { $0?.layer }
        lifts += 1
        for layer in raised {
            layer.zPosition = 1
            let rise = CAKeyframeAnimation(keyPath: "transform.translation.y")
            rise.values = [0, Self.liftHeight, 0] as [CGFloat]
            rise.isAdditive = true
            rise.duration = duration
            rise.timingFunction = curve
            layer.add(rise, forKey: Self.liftKey)
        }
        let shade = CALayer()
        if let under = passed.view.layer {
            shade.frame = under.bounds
            shade.backgroundColor = Theme.Color.base.cgColor
            shade.opacity = 0
            under.addSublayer(shade)
            let dim = CAKeyframeAnimation(keyPath: "opacity")
            dim.values = [0, Self.passShade, 0] as [Float]
            dim.duration = duration
            shade.add(dim, forKey: Self.liftKey)
        }
        // On time, not on the animations' completion, which a window out of
        // view may never report.
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            MainActor.assumeIsolated {
                shade.removeFromSuperlayer()
                guard let self else { return }
                self.lifts -= 1
                if self.lifts == 0 { raised.forEach { $0.zPosition = 0 } }
            }
        }
    }
}
