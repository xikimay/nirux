import AppKit

/// An agent's state as light (see `AgentLight`), on gradient layers that
/// only the window server animates.
///
/// Around a column (`.around`): a ring on the terminal's padding and a
/// faint glow over its first cells, green and breathing while the agent
/// works, amber or red and pulsing while it waits on the user or broke,
/// then one sweep of light when its turn ends. The view lies over the
/// column, as its sibling: the terminal's own layer is never animated.
///
/// On an edge of the viewport: the glow of an agent out of view that waits
/// or broke, a bar of light on the padding. Decoration only: it takes no
/// click and names nobody (M3's pill went with the glass interface's
/// requests, step 3.3: the command bar's count, ⌘J and the rail say who
/// waits).
final class EdgeGlowView: NSView {
    enum Edge {
        case left, right, top, bottom
        /// A column's four edges.
        case around
    }

    /// How far a viewport edge's glow reaches: a bar of light on the
    /// terminal's padding that is gone before the text.
    static let depth: CGFloat = 8
    /// The focused column's light starts inside its focus ring, which
    /// stays as it is.
    static let focusRingWidth: CGFloat = 2
    /// A column's ring: within the terminal's padding
    /// (`TerminalConfigBuilder.padding`), so it covers no text.
    static let ringWidth: CGFloat = 2
    /// How far a column's glow reaches (over the terminal's padding, then
    /// about one cell), and how strong it is at most: text under it keeps
    /// its contrast.
    static let columnGlowDepth = CGFloat(TerminalConfigBuilder.padding) + 10
    static let columnGlowAlpha: CGFloat = 0.08
    static let cornerRadius: CGFloat = 6

    let edge: Edge
    private(set) var light: AgentLight?
    /// The light breathes or pulses; false: it shows steady (the window is
    /// covered, the column out of view, Reduce motion, animations off).
    /// Read off the layers: a movement Core Animation dropped starts again
    /// at the next `show`.
    var isMoving: Bool { movement != nil }
    /// The repeating animation that breathes or pulses: one for the whole
    /// light, on the layer that holds its ring and glows.
    var movement: CAAnimation? { lightLayer.animation(forKey: Self.movementKey) }
    private static let movementKey = "move"
    /// The focused column's light: fainter, and inside its focus ring.
    private(set) var isSoft = false
    /// A sweep is crossing the column.
    var isSweeping: Bool { sweepBand.animation(forKey: Self.sweepKey) != nil }
    private static let sweepKey = "sweep"

    /// Fades the light in and out.
    private let fadeLayer = CALayer()
    /// Holds the ring and the glows, and moves them as one.
    private let lightLayer = CALayer()
    private let ring = CALayer()
    private var glows: [(side: Edge, layer: CAGradientLayer)] = []
    private let sweepHost = CALayer()
    private let sweepBand = CAGradientLayer()
    /// The last `moving` given: whether its fades animate.
    private var animatesChanges = false

    init(edge: Edge) {
        self.edge = edge
        super.init(frame: .zero)
        wantsLayer = true
        fadeLayer.opacity = 0
        // The ring and the strips are each blended on their own, at their
        // holders' opacity: no column-sized offscreen pass for them.
        fadeLayer.allowsGroupOpacity = false
        lightLayer.allowsGroupOpacity = false
        fadeLayer.addSublayer(lightLayer)
        layer?.addSublayer(fadeLayer)
        for side in edge == .around ? [Edge.left, .right, .top, .bottom] : [edge] {
            let glow = CAGradientLayer()
            // From the edge inward.
            switch side {
            case .left: (glow.startPoint, glow.endPoint) = (CGPoint(x: 0, y: 0.5), CGPoint(x: 1, y: 0.5))
            case .right: (glow.startPoint, glow.endPoint) = (CGPoint(x: 1, y: 0.5), CGPoint(x: 0, y: 0.5))
            case .top: (glow.startPoint, glow.endPoint) = (CGPoint(x: 0.5, y: 1), CGPoint(x: 0.5, y: 0))
            case .bottom, .around: (glow.startPoint, glow.endPoint) = (CGPoint(x: 0.5, y: 0), CGPoint(x: 0.5, y: 1))
            }
            lightLayer.addSublayer(glow)
            glows.append((side, glow))
        }
        if edge == .around {
            lightLayer.addSublayer(ring)
            sweepHost.masksToBounds = true
            sweepHost.cornerRadius = Self.cornerRadius
            sweepBand.startPoint = CGPoint(x: 0, y: 0.5)
            sweepBand.endPoint = CGPoint(x: 1, y: 0.5)
            let green = Theme.Color.working
            sweepBand.colors = ([0, 0.18, 0] as [CGFloat]).map { green.withAlphaComponent($0).cgColor }
            sweepHost.addSublayer(sweepBand)
            layer?.addSublayer(sweepHost)
        }
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Light

    /// Shows `light`; nil fades it out. `moving`: it breathes or pulses,
    /// and its changes animate; else it shows steady and changes at once.
    func show(_ light: AgentLight?, moving: Bool, soft: Bool = false) {
        animatesChanges = moving
        guard let light else {
            guard self.light != nil else { return }
            // From the level it shows now, mid-breath or steady: stopping
            // the movement must not flash before the fade.
            let level = lightLayer.presentation()?.opacity ?? lightLayer.opacity
            self.light = nil
            setMoving(false)
            // The level is in the fade now, steady light or not.
            applySteadyLevel()
            fade(to: 0, from: level)
            return
        }
        let appears = self.light == nil
        if light != self.light || soft != isSoft {
            self.light = light
            if soft != isSoft {
                isSoft = soft
                layoutLayers()
            }
            applyColors()
            // Work that turns into a wait, a wait into an error: the new
            // light's own rhythm.
            setMoving(false)
        }
        if appears { fade(to: 1) }
        setMoving(moving)
    }

    /// One pass of light across the column: its agent's turn ended.
    func sweep() {
        guard edge == .around, bounds.width > 0 else { return }
        let width = max(140, bounds.width * 0.5)
        withoutActions {
            // Rests out of sight: a pass that never runs shows nothing.
            sweepBand.frame = CGRect(x: -width, y: 0, width: width, height: bounds.height)
        }
        let pass = CABasicAnimation(keyPath: "position.x")
        pass.fromValue = -width / 2
        pass.toValue = bounds.width + width / 2
        pass.duration = 1.1
        pass.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
        sweepBand.add(pass, forKey: Self.sweepKey)
    }

    private func applyColors() {
        guard let light else { return }
        let color = light.color
        let ringAlpha: CGFloat
        let glowAlpha: CGFloat
        switch (edge, light) {
        case (.around, .working): (ringAlpha, glowAlpha) = (isSoft ? 0.45 : 0.7, Self.columnGlowAlpha)
        case (.around, .alert): (ringAlpha, glowAlpha) = (isSoft ? 0.8 : 1, Self.columnGlowAlpha)
        default: (ringAlpha, glowAlpha) = (0, 0.9)
        }
        withoutActions {
            ring.borderColor = color.withAlphaComponent(ringAlpha).cgColor
            for glow in glows {
                if edge == .around {
                    glow.layer.colors = [color.withAlphaComponent(glowAlpha).cgColor, color.withAlphaComponent(0).cgColor]
                } else {
                    // Full at the edge, fading over the padding, gone
                    // before the text.
                    glow.layer.colors = [glowAlpha, glowAlpha, 0.1, 0].map { color.withAlphaComponent($0).cgColor }
                    glow.layer.locations = [0, 0.25, 0.4, 1]
                }
            }
        }
        applySteadyLevel()
    }

    /// Steady work shows between the breath's two ends; a moving light
    /// takes its level from its animation.
    private func applySteadyLevel() {
        withoutActions { lightLayer.opacity = light == .working && !isMoving ? 0.6 : 1 }
    }

    private func fade(to opacity: Float, from level: Float = 1) {
        let shown = (fadeLayer.presentation()?.opacity ?? fadeLayer.opacity) * level
        withoutActions { fadeLayer.opacity = opacity }
        fadeLayer.removeAnimation(forKey: "fade")
        guard animatesChanges else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = shown
        fade.toValue = opacity
        fade.duration = 0.3
        fade.timingFunction = CAMediaTimingFunction(name: opacity > 0 ? .easeIn : .easeOut)
        fadeLayer.add(fade, forKey: "fade")
    }

    /// One animation moves the whole light, whatever it is made of: what
    /// changes on screen is its thin strips, not the column they frame.
    private func setMoving(_ moving: Bool) {
        guard moving != isMoving else { return }
        if moving, let light {
            lightLayer.add(CABasicAnimation.lightMovement(for: light), forKey: Self.movementKey)
        } else {
            lightLayer.removeAnimation(forKey: Self.movementKey)
        }
        applySteadyLevel()
    }

    private func withoutActions(_ change: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        change()
        CATransaction.commit()
    }

    // MARK: - Layout

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutLayers()
    }

    private func layoutLayers() {
        let depth = edge == .around ? Self.columnGlowDepth : Self.depth
        // The focused column's light: a hairline and its glow inside the
        // focus ring, which stays blue all along.
        let inset = isSoft ? Self.focusRingWidth : 0
        withoutActions {
            fadeLayer.frame = bounds
            lightLayer.frame = bounds
            ring.frame = bounds.insetBy(dx: inset, dy: inset)
            ring.borderWidth = isSoft ? 1 : Self.ringWidth
            ring.cornerRadius = Self.cornerRadius - inset
            sweepHost.frame = bounds
            for glow in glows { glow.layer.frame = strip(glow.side, depth: depth, inset: inset) }
        }
    }

    /// The part of the view within `depth` of `side`, `inset` from every
    /// edge.
    private func strip(_ side: Edge, depth: CGFloat, inset: CGFloat = 0) -> NSRect {
        let area = bounds.insetBy(dx: inset, dy: inset)
        switch side {
        case .left: return NSRect(x: area.minX, y: area.minY, width: depth, height: area.height)
        case .right: return NSRect(x: area.maxX - depth, y: area.minY, width: depth, height: area.height)
        case .top: return NSRect(x: area.minX, y: area.maxY - depth, width: area.width, height: depth)
        case .bottom, .around: return NSRect(x: area.minX, y: area.minY, width: area.width, height: depth)
        }
    }

    /// Where the light is drawn, for tests: the ring, and each glow.
    var ringFrame: NSRect { ring.frame }
    var glowFrames: [NSRect] { glows.map(\.layer.frame) }
    /// How it is drawn, for tests: the repeating animations a moving light
    /// runs, the level a steady light shows at, and whether its layers
    /// blend as one group.
    var movingLayerCount: Int {
        ([lightLayer, fadeLayer, ring] + glows.map { $0.layer as CALayer }).filter { layer in
            layer.animationKeys()?.contains { layer.animation(forKey: $0)?.repeatCount == .infinity } ?? false
        }.count
    }
    var steadyLevel: Float { lightLayer.opacity }
    var blendsAsAGroup: Bool { fadeLayer.allowsGroupOpacity || lightLayer.allowsGroupOpacity }

    /// Decoration: the column headers, the terminals' first and last
    /// cells and the resize handle at the viewport's edge keep their
    /// clicks.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

extension CABasicAnimation {
    /// A light's movement: work breathes slowly, a wait or an error pulses
    /// faster. In phase with every other light of its kind, whenever each
    /// started: a column's ring, its header's dot and its row's dot breathe
    /// together, and a rebuilt view carries on where the old one was.
    @MainActor
    static func lightMovement(for light: AgentLight) -> CABasicAnimation {
        let move = CABasicAnimation(keyPath: "opacity")
        move.fromValue = 1.0
        switch light {
        case .working:
            move.toValue = 0.35
            move.duration = 1.3
        case .alert:
            move.toValue = 0.4
            move.duration = 0.85
        }
        move.autoreverses = true
        move.repeatCount = .infinity
        move.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        move.timeOffset = CACurrentMediaTime().truncatingRemainder(dividingBy: move.duration * 2)
        // A slow fade for hours: no need for more frames than the
        // sidebar's dots ever asked for.
        move.preferredFrameRateRange = CAFrameRateRange(minimum: 8, maximum: 15, preferred: 12)
        return move
    }
}
