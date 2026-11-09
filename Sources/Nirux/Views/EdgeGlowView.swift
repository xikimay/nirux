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
/// or broke. A pill names it for a few seconds, then leaves the glow alone;
/// the pointer over the glow brings the pill back, and a click on the
/// pill, or on the edge itself, goes to that agent.
final class EdgeGlowView: NSView {
    enum Edge {
        case left, right, top, bottom
        /// A column's four edges.
        case around
    }

    /// The agent out of view an edge's glow stands for.
    struct Target: Equatable {
        let workspaceID: String
        /// `ColumnState.id`.
        let columnID: UUID?
        /// "Cookies needs permission".
        let text: String
    }

    /// How far a viewport edge's glow reaches.
    static let depth: CGFloat = 32
    /// A column's ring: as wide as the terminal's padding, so it covers no
    /// text.
    static let ringWidth: CGFloat = 2
    /// How far a column's glow reaches over its cells, and how strong it
    /// is at most there: text under it keeps its contrast.
    static let columnGlowDepth: CGFloat = 12
    static let columnGlowAlpha: CGFloat = 0.08
    static let cornerRadius: CGFloat = 6
    /// How deep the edge itself takes a click while it glows.
    static let clickBand: CGFloat = 8
    private static let pillMargin: CGFloat = 10

    let edge: Edge
    private(set) var light: AgentLight?
    /// The light breathes or pulses; false: it shows steady (the window is
    /// covered, the column out of view, Reduce motion, animations off).
    /// Read off the layer: a movement Core Animation dropped starts again
    /// at the next `show`.
    var isMoving: Bool { movement != nil }
    /// The repeating animation that breathes or pulses.
    var movement: CAAnimation? { lightLayer.animation(forKey: Self.movementKey) }
    private static let movementKey = "move"
    /// The focused column's light: fainter, over its focus ring.
    private(set) var isSoft = false
    private(set) var target: Target?
    private(set) var isPillShown = false
    /// Sweeps played, for tests.
    private(set) var sweepCount = 0
    var onClick: ((Target) -> Void)?
    /// How long the pill stays once an agent starts waiting out of view.
    var pillDuration: TimeInterval = 4

    /// Fades the light in and out.
    private let fadeLayer = CALayer()
    /// Holds the ring and the glows: what breathes.
    private let lightLayer = CALayer()
    private let ring = CALayer()
    private var glows: [(side: Edge, layer: CAGradientLayer)] = []
    private let sweepHost = CALayer()
    private let sweepBand = CAGradientLayer()
    private let pill = EdgeGlowPill()
    /// Tells a pending pill dismissal whether it still applies.
    private var pillGeneration = 0
    /// The pill's first seconds are still running.
    private var isAnnouncing = false
    private var isHovered = false
    private var hoverArea: NSTrackingArea?

    init(edge: Edge) {
        self.edge = edge
        super.init(frame: .zero)
        wantsLayer = true
        fadeLayer.opacity = 0
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
            ring.borderWidth = Self.ringWidth
            ring.cornerRadius = Self.cornerRadius
            lightLayer.addSublayer(ring)
            sweepHost.masksToBounds = true
            sweepHost.cornerRadius = Self.cornerRadius
            sweepBand.startPoint = CGPoint(x: 0, y: 0.5)
            sweepBand.endPoint = CGPoint(x: 1, y: 0.5)
            let green = Theme.Color.working
            sweepBand.colors = ([0, 0.18, 0] as [CGFloat]).map { green.withAlphaComponent($0).cgColor }
            sweepHost.addSublayer(sweepBand)
            layer?.addSublayer(sweepHost)
        } else {
            pill.alphaValue = 0
            addSubview(pill)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Light

    /// Shows `light`; nil fades it out. `moving`: it breathes or pulses,
    /// and its changes animate; else it shows steady and changes at once.
    /// `target`: the agent a viewport edge stands for.
    func show(_ light: AgentLight?, moving: Bool, soft: Bool = false, target: Target? = nil) {
        animatesChanges = moving
        guard let light else {
            announce(nil)
            guard self.light != nil else { return }
            self.light = nil
            setMoving(false)
            fade(to: 0)
            return
        }
        let appears = self.light == nil
        if light != self.light || soft != isSoft {
            self.light = light
            isSoft = soft
            applyColors()
            // Work that turns into a wait, a wait into an error: the new
            // light's own rhythm.
            setMoving(false)
        }
        if appears { fade(to: 1) }
        setMoving(moving)
        announce(target)
    }

    /// One pass of light across the column: its agent's turn ended.
    func sweep() {
        guard edge == .around, bounds.width > 0 else { return }
        sweepCount += 1
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
        sweepBand.add(pass, forKey: "sweep")
    }

    /// The last `moving` given: whether a change that comes by itself (the
    /// pill leaving) may animate.
    private var animatesChanges = false

    private func applyColors() {
        guard let light else { return }
        let color = light.color
        let ringAlpha: CGFloat
        let glowAlpha: CGFloat
        switch (edge, light) {
        case (.around, .working): (ringAlpha, glowAlpha) = isSoft ? (0.5, 0.05) : (0.7, Self.columnGlowAlpha)
        case (.around, .alert): (ringAlpha, glowAlpha) = (1, Self.columnGlowAlpha)
        default: (ringAlpha, glowAlpha) = (0, 0.5)
        }
        withoutActions {
            ring.borderColor = color.withAlphaComponent(ringAlpha).cgColor
            for glow in glows {
                glow.layer.colors = [color.withAlphaComponent(glowAlpha).cgColor, color.withAlphaComponent(0).cgColor]
            }
            // Steady work shows between the breath's two ends.
            lightLayer.opacity = light == .working ? 0.6 : 1
        }
    }

    private func fade(to opacity: Float) {
        let shown = fadeLayer.presentation()?.opacity ?? fadeLayer.opacity
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

    private func setMoving(_ moving: Bool) {
        guard moving != isMoving else { return }
        guard moving, let light else { return lightLayer.removeAnimation(forKey: Self.movementKey) }
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
        // In phase with every other light, whenever each started.
        move.timeOffset = CACurrentMediaTime().truncatingRemainder(dividingBy: move.duration * 2)
        // A slow fade for hours: no need for 120 frames a second.
        move.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 30, preferred: 15)
        lightLayer.add(move, forKey: Self.movementKey)
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
        withoutActions {
            fadeLayer.frame = bounds
            lightLayer.frame = bounds
            ring.frame = bounds
            sweepHost.frame = bounds
            for glow in glows { glow.layer.frame = strip(glow.side, depth: depth) }
        }
        layoutPill()
    }

    /// The part of the view within `depth` of `side`.
    private func strip(_ side: Edge, depth: CGFloat) -> NSRect {
        switch side {
        case .left: return NSRect(x: 0, y: 0, width: depth, height: bounds.height)
        case .right: return NSRect(x: bounds.width - depth, y: 0, width: depth, height: bounds.height)
        case .top: return NSRect(x: 0, y: bounds.height - depth, width: bounds.width, height: depth)
        case .bottom, .around: return NSRect(x: 0, y: 0, width: bounds.width, height: depth)
        }
    }

    // MARK: - Pill

    /// A new agent to name shows the pill for `pillDuration`; the same one
    /// leaves it as it is.
    private func announce(_ target: Target?) {
        guard target != self.target else { return }
        self.target = target
        updateTrackingAreas()
        setAccessibilityElement(target != nil)
        setAccessibilityRole(.button)
        setAccessibilityLabel(target?.text)
        pillGeneration += 1
        isAnnouncing = false
        guard let target, let light else { return setPillShown(false) }
        pill.configure(text: target.text, edge: edge, color: light.color)
        layoutPill()
        setPillShown(true)
        isAnnouncing = true
        let generation = pillGeneration
        // Then only the glow: the pill never stays over a terminal's text.
        DispatchQueue.main.asyncAfter(deadline: .now() + pillDuration) { [weak self] in
            guard let self, self.pillGeneration == generation else { return }
            self.endAnnouncement()
        }
    }

    /// The pill's first seconds are over: it leaves, unless the pointer is
    /// on the glow.
    func endAnnouncement() {
        guard isAnnouncing else { return }
        isAnnouncing = false
        if !isHovered { setPillShown(false) }
    }

    private func setPillShown(_ shown: Bool) {
        guard shown != isPillShown else { return }
        isPillShown = shown
        let wasVisible = pill.layer?.presentation()?.opacity ?? Float(pill.alphaValue)
        pill.alphaValue = shown ? 1 : 0
        pill.layer?.removeAllAnimations()
        guard animatesChanges, let pillLayer = pill.layer else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = wasVisible
        fade.toValue = shown ? 1 : 0
        fade.duration = shown ? 0.2 : 0.3
        pillLayer.add(fade, forKey: "fade")
        guard shown else { return }
        // It comes in from its edge.
        let slide = CASpringAnimation(keyPath: edge == .left || edge == .right ? "transform.translation.x" : "transform.translation.y")
        slide.fromValue = edge == .left || edge == .bottom ? -Self.pillMargin : Self.pillMargin
        slide.toValue = 0
        slide.damping = 14
        slide.duration = slide.settlingDuration
        pillLayer.add(slide, forKey: "slide")
    }

    private func layoutPill() {
        guard edge != .around else { return }
        let margin = Self.pillMargin
        let width = min(pill.fittingWidth, max(0, bounds.width - margin * 2))
        let height = EdgeGlowPill.height
        let origin: NSPoint
        switch edge {
        case .left: origin = NSPoint(x: margin, y: bounds.midY - height / 2)
        case .right: origin = NSPoint(x: bounds.maxX - margin - width, y: bounds.midY - height / 2)
        case .top: origin = NSPoint(x: bounds.midX - width / 2, y: bounds.maxY - (Self.depth + height) / 2)
        // Above the column dots.
        case .bottom, .around: origin = NSPoint(x: bounds.midX - width / 2, y: 26)
        }
        pill.frame = NSRect(origin: origin, size: NSSize(width: width, height: height)).integral
    }

    /// The pill's frame, for tests.
    var pillFrame: NSRect { pill.frame }
    var pillText: String { pill.text }

    // MARK: - Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        hoverArea = nil
        guard target != nil, edge != .around else {
            isHovered = false
            return
        }
        let area = NSTrackingArea(
            rect: strip(edge, depth: Self.depth), options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self
        )
        addTrackingArea(area)
        hoverArea = area
    }

    /// The pointer over the glow brings the pill back.
    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        if target != nil { setPillShown(true) }
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        if !isAnnouncing { setPillShown(false) }
    }

    /// Decoration, but for what goes to the agent: the pill while it
    /// shows, and the edge itself while it glows. Clicks elsewhere reach
    /// the column headers and terminals under the glow.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard target != nil, let superview else { return nil }
        let local = convert(point, from: superview)
        if isPillShown, pill.frame.contains(local) { return self }
        return strip(edge, depth: Self.clickBand).contains(local) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        if let target { onClick?(target) }
    }

    override func accessibilityPerformPress() -> Bool {
        guard let target else { return false }
        onClick?(target)
        return true
    }
}

/// Names the agent an edge's glow stands for, in the glow's color, with an
/// arrow toward it. The glow view takes its clicks.
final class EdgeGlowPill: NSView {
    static let height: CGFloat = 22
    private static let paddingX: CGFloat = 10

    private let label = NSTextField(labelWithString: "")
    var text: String { label.stringValue }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.Color.raised.cgColor
        layer?.cornerRadius = Self.height / 2
        layer?.borderWidth = 1
        label.font = Theme.Font.captionEmphasized
        label.lineBreakMode = .byTruncatingMiddle
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(text: String, edge: EdgeGlowView.Edge, color: NSColor) {
        switch edge {
        case .left: label.stringValue = "← \(text)"
        case .right: label.stringValue = "\(text) →"
        case .top: label.stringValue = "↑ \(text)"
        case .bottom, .around: label.stringValue = "↓ \(text)"
        }
        label.textColor = color
        layer?.borderColor = color.withAlphaComponent(0.6).cgColor
    }

    var fittingWidth: CGFloat {
        ceil(label.cell?.cellSize.width ?? 0) + Self.paddingX * 2
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let height = ceil(label.cell?.cellSize.height ?? 14)
        label.frame = NSRect(
            x: Self.paddingX, y: (newSize.height - height) / 2, width: max(0, newSize.width - Self.paddingX * 2), height: height
        )
    }
}
