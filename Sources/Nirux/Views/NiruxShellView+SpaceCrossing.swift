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
    /// How long the space chosen gets to draw before it is frozen: its
    /// terminals rested while it was hidden, or never drew since launch.
    static let arrivalDelay: CFTimeInterval = 0.05

    /// `leaving`, what the viewport showed before the switch, recedes; the
    /// space chosen, laid out under it now, comes once it has drawn.
    func crossSpaces(leaving: FrozenView, duration: CFTimeInterval = crossingDuration) {
        endSpaceCrossing()
        guard agentLightsMayMove else { return }
        let generation = spaceCrossingGeneration
        crossingWorkspaceID = activeWorkspace?.id
        crossingPictures = [leaving]
        viewport.addSubview(leaving)
        showLiveViews(false)
        Self.move(leaving, scale: (1, Self.recedeScale), opacity: (1, 0), curve: .easeIn, duration: duration)
        sideEffects.afterCommit(Self.arrivalDelay) { [weak self] in
            guard let self, spaceCrossingGeneration == generation else { return }
            arrive(for: duration - Self.arrivalDelay)
        }
        sideEffects.afterCommit(duration) { [weak self] in
            guard let self, spaceCrossingGeneration == generation else { return }
            endSpaceCrossing()
        }
    }

    /// The workspace on screen, frozen where it lies, comes from the front.
    private func arrive(for duration: CFTimeInterval) {
        guard let container = activeWorkspace?.containerView, let arriving = FrozenView.freeze(container) else { return }
        arriving.frame.origin = container.convert(container.bounds, to: viewport).origin
        crossingPictures.append(arriving)
        viewport.addSubview(arriving)
        Self.move(arriving, scale: (Self.arrivalFromScale, 1), opacity: (0, 1), curve: .easeOut, duration: duration)
    }

    /// A layout that moves something (a user's action) or shows another
    /// workspace (⌘N, a switch, a close, a ⌘P jump) ends a crossing: what
    /// plays under its pictures would go unseen.
    func endSpaceCrossingIfStale(animated: Bool) {
        guard !crossingPictures.isEmpty, animated || activeWorkspace?.id != crossingWorkspaceID else { return }
        endSpaceCrossing()
    }

    /// Movement turned off: a crossing on its way lands at once.
    func stillSpaceCrossing() {
        if !crossingPictures.isEmpty { endSpaceCrossing() }
    }

    /// The live views back, the pictures gone, and no crossing left to end.
    func endSpaceCrossing() {
        spaceCrossingGeneration += 1
        for picture in crossingPictures { picture.removeFromSuperview() }
        crossingPictures = []
        crossingWorkspaceID = nil
        showLiveViews(true)
    }

    /// Every live view of the viewport, shown or hidden under the pictures.
    private func showLiveViews(_ shown: Bool) {
        for view in [verticalStrip, emptySpaceView] as [NSView] { view.alphaValue = shown ? 1 : 0 }
    }

    /// From the first values to the second, about the picture's middle (its
    /// content's anchor); it rests on the second. Its frozen layers move,
    /// not the view's own.
    private static func move(
        _ picture: FrozenView, scale: (CGFloat, CGFloat), opacity: (Float, Float),
        curve: CAMediaTimingFunctionName, duration: CFTimeInterval
    ) {
        let layer = picture.content
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = CATransform3DMakeScale(scale.1, scale.1, 1)
        layer.opacity = opacity.1
        CATransaction.commit()
        let size = CABasicAnimation(keyPath: "transform")
        size.fromValue = NSValue(caTransform3D: CATransform3DMakeScale(scale.0, scale.0, 1))
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = opacity.0
        let group = CAAnimationGroup()
        group.animations = [size, fade]
        group.duration = duration
        group.timingFunction = CAMediaTimingFunction(name: curve)
        layer.add(group, forKey: "crossing")
    }
}
