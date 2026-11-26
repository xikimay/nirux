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

    /// What moves with the card: its view's, light's and shadow's layers.
    var cardLayers: [CALayer] { [view, light, shadow].compactMap { $0?.layer } }

    /// How high the card lies, from its state: over its neighbours while it
    /// arrives, a move lifts it or the pointer holds it, unless it is going.
    func updateDepth() {
        let depth: CGFloat = (isArriving || lifts > 0 || isDragged) && !isClosing ? 1 : 0
        cardLayers.forEach { $0.zPosition = depth }
    }

    /// `step` after `duration`, on time once the change is committed (a
    /// busy turn delays its start), not on the animations' completion,
    /// which a window out of view may never report.
    static func afterCommit(_ duration: CFTimeInterval, _ step: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async {
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
                MainActor.assumeIsolated(step)
            }
        }
    }

    /// `scale` about a card's middle: a view's layer turns about its corner.
    static func scaledAboutMiddle(_ size: NSSize, by scale: CGFloat) -> CGAffineTransform {
        CGAffineTransform(translationX: size.width * (1 - scale) / 2, y: size.height * (1 - scale) / 2)
            .scaledBy(x: scale, y: scale)
    }

    /// The card stops passing, whole and opaque, done arriving: no pass's
    /// end acts on it.
    func endPass() {
        passes += 1
        view.layer?.removeAnimation(forKey: Self.passKey)
        view.alphaValue = 1
        isArriving = false
        updateDepth()
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
        Self.afterCommit(duration) { [weak self] in
            guard let self, self.passes == pass else { return }
            self.view.layer?.removeAnimation(forKey: Self.passKey)
            then()
        }
    }

    /// What the glide and the lift add to where the card lies now: its
    /// translation shown, less the share of a pass's scale about the middle.
    private var shownOffset: CGPoint {
        guard let shown = view.layer?.presentation()?.transform else { return .zero }
        let size = view.frame.size
        return CGPoint(x: shown.m41 - size.width * (1 - shown.m11) / 2, y: shown.m42 - size.height * (1 - shown.m22) / 2)
    }

    /// Where the card shows in its strip, a glide on its way included, and
    /// how wide it is.
    var shownPlace: (x: CGFloat, width: CGFloat) {
        (view.frame.minX + shownOffset.x, view.frame.width)
    }

    /// A neighbour pushed or let go of the card: it glides to its place
    /// from `dx` away, its light and its shadow with it.
    func glide(by dx: CGFloat) {
        for layer in cardLayers {
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
    /// it rises a little on its way, from the height it shows (a held key),
    /// its shadow falling on the other, which dims under it a moment. Not a
    /// card that is going.
    func lift(over passed: ColumnState) {
        guard !isClosing else { return }
        let duration = Self.glideDuration
        let height = shownOffset.y
        lifts += 1
        updateDepth()
        for layer in cardLayers {
            let rise = CAKeyframeAnimation(keyPath: "transform.translation.y")
            rise.values = [height, Self.liftHeight, 0] as [CGFloat]
            rise.isAdditive = true
            rise.duration = duration
            rise.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 0.6, 0.3, 1)
            layer.add(rise, forKey: Self.liftKey)
        }
        passed.dim(for: duration)
        Self.afterCommit(duration) { [weak self] in
            guard let self else { return }
            self.lifts -= 1
            self.updateDepth()
        }
    }

    static let dragKey = "cardDrag"
    /// How much larger a card the pointer holds shows.
    static let dragScale: CGFloat = 1.02
    static let dragScaleDuration: CFTimeInterval = 0.18

    /// Taken by its header, the card rises over its neighbours to
    /// `dragScale` of its size about its middle, its light and shadow with
    /// it, until let go (`settle`). `animated`: from the scale it shows;
    /// else there at once.
    func raise(animated: Bool) {
        isDragged = true
        drags += 1
        updateDepth()
        scaleDrag(to: Self.dragScale, animated: animated)
    }

    /// Let go, the card comes back to its size over its neighbours while it
    /// glides to its place (`glideDuration`), then lies with them, on time;
    /// its scale stays another's that took it meanwhile.
    func settle(animated: Bool) {
        guard isDragged else { return }
        isDragged = false
        drags += 1
        let drag = drags
        lifts += 1
        updateDepth()
        scaleDrag(to: 1, animated: animated)
        Self.afterCommit(animated ? Self.glideDuration : 0) { [weak self] in
            guard let self else { return }
            self.lifts -= 1
            self.updateDepth()
            guard self.drags == drag else { return }
            self.cardLayers.forEach { $0.removeAnimation(forKey: Self.dragKey) }
        }
    }

    /// The card's drag scale passes to `scale` about its middle from the one
    /// it shows (at once when not `animated`), held there.
    private func scaleDrag(to scale: CGFloat, animated: Bool) {
        let size = view.frame.size
        let held = view.layer?.animation(forKey: Self.dragKey) != nil
        let shown = held ? (view.layer?.presentation()?.value(forKeyPath: "transform.scale.x") as? NSNumber).map { CGFloat($0.doubleValue) } ?? 1 : 1
        for layer in cardLayers {
            let scaling = CABasicAnimation(keyPath: "transform")
            scaling.fromValue = CATransform3DMakeAffineTransform(Self.scaledAboutMiddle(size, by: animated ? shown : scale))
            scaling.toValue = CATransform3DMakeAffineTransform(Self.scaledAboutMiddle(size, by: scale))
            scaling.isAdditive = true
            scaling.duration = Self.dragScaleDuration
            scaling.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
            scaling.fillMode = .forwards
            scaling.isRemovedOnCompletion = false
            layer.add(scaling, forKey: Self.dragKey)
        }
    }

    /// A card passes over this one: it dims a moment under one shade, from
    /// how dark it shows, however many pass; the shade goes with the last.
    private func dim(for duration: CFTimeInterval) {
        let shade = passShadeView ?? {
            let shade = PassShadeView(frame: view.bounds)
            view.addSubview(shade)
            passShadeView = shade
            return shade
        }()
        let shown = shade.layer?.presentation()?.opacity ?? 0
        dims += 1
        let dim = CAKeyframeAnimation(keyPath: "opacity")
        dim.values = [shown, Self.passShade, 0] as [Float]
        dim.duration = duration
        shade.layer?.add(dim, forKey: Self.liftKey)
        Self.afterCommit(duration) { [weak self] in
            guard let self else { return }
            self.dims -= 1
            guard self.dims == 0 else { return }
            self.passShadeView?.removeFromSuperview()
            self.passShadeView = nil
        }
    }
}

/// The shade over a card another passes over (`ColumnState.lift`): above
/// its content, its size, transparent at rest. Decoration: it takes no
/// click and no VoiceOver focus.
final class PassShadeView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Theme.Color.base.cgColor
        layer?.opacity = 0
        autoresizingMask = [.width, .height]
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
