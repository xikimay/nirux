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
/// or broke, a bar of light on the padding. A pill names the agent for a
/// few seconds, then leaves the glow alone; the pointer resting on the
/// glow brings the pill back, and a click on the pill goes to that agent.
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

    /// How far a viewport edge's glow reaches: a bar of light on the
    /// terminal's padding that is gone before the text.
    static let depth: CGFloat = 8
    /// The top edge's view is this tall: room for its pill under the
    /// column headers, whose buttons it must not cover.
    static let topHeight: CGFloat = ColumnHeaderView.height + pillGap + EdgeGlowPill.height + pillGap
    /// Between the glow, or the headers, and the pill: the pill never
    /// comes up under the pointer that brought it.
    static let pillGap: CGFloat = 6
    /// The focused column's light starts inside its focus ring, which
    /// stays as it is.
    static let focusRingWidth: CGFloat = 2
    /// A column's ring: as wide as the terminal's padding
    /// (`TerminalConfigBuilder.padding`), so it covers no text.
    static let ringWidth: CGFloat = 2
    /// How far a column's glow reaches over its cells, and how strong it
    /// is at most there: text under it keeps its contrast.
    static let columnGlowDepth: CGFloat = 12
    static let columnGlowAlpha: CGFloat = 0.08
    static let cornerRadius: CGFloat = 6
    private static let pillMargin: CGFloat = 10

    let edge: Edge
    private(set) var light: AgentLight?
    /// The light breathes or pulses; false: it shows steady (the window is
    /// covered, the column out of view, Reduce motion, animations off).
    /// Read off the layers: a movement Core Animation dropped starts again
    /// at the next `show`.
    var isMoving: Bool { movement != nil }
    /// The repeating animation that breathes or pulses.
    var movement: CAAnimation? { glows.first?.layer.animation(forKey: Self.movementKey) }
    private static let movementKey = "move"
    /// The focused column's light: fainter, and inside its focus ring.
    private(set) var isSoft = false
    private(set) var target: Target?
    private(set) var isPillShown = false
    /// A sweep is crossing the column.
    var isSweeping: Bool { sweepBand.animation(forKey: Self.sweepKey) != nil }
    private static let sweepKey = "sweep"
    var onClick: ((Target) -> Void)?
    /// How long the pill stays once an agent starts waiting out of view.
    var pillDuration: TimeInterval = 4
    /// How long the pointer rests on the glow before the pill comes back:
    /// a pointer crossing the edge brings nothing up.
    var hoverDwell: TimeInterval = 0.3
    /// How long the pill stays once the pointer left the glow: time to
    /// reach it.
    var pillLinger: TimeInterval = 1.2

    /// Fades the light in and out.
    private let fadeLayer = CALayer()
    /// Holds the ring and the glows.
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
    /// The pointer is on the glow, or on the pill it brought back.
    private var pointerOnGlow = false
    private var pointerOnPill = false
    private var isHovered: Bool { pointerOnGlow || pointerOnPill }
    private var glowArea: NSTrackingArea?
    private var pillArea: NSTrackingArea?
    /// Tells a pending dwell or linger whether the pointer moved since.
    private var hoverGeneration = 0
    /// The last `moving` given: whether a change that comes by itself (the
    /// pill leaving) may animate.
    private var animatesChanges = false

    init(edge: Edge) {
        self.edge = edge
        super.init(frame: .zero)
        wantsLayer = true
        fadeLayer.opacity = 0
        // Thin layers each blended on their own: no column-sized offscreen
        // pass for a ring and four strips.
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
    /// `target`: the agent a viewport edge stands for; `announcing` shows
    /// its pill for `pillDuration`, once per call.
    func show(
        _ light: AgentLight?, moving: Bool, soft: Bool = false, target: Target? = nil, announcing: Bool = false
    ) {
        animatesChanges = moving
        guard let light else {
            setTarget(nil, announcing: false)
            guard self.light != nil else { return }
            // From the level it shows now, mid-breath or steady: stopping
            // the movement must not flash before the fade.
            let level = (glows.first?.layer.presentation()?.opacity ?? 1) * lightLayer.opacity
            self.light = nil
            setMoving(false)
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
        setTarget(target, announcing: announcing)
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
                    // Full on the 2 pt of padding, faint over the first
                    // cell, then nothing.
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

    /// The ring and each glow move on their own: what changes on screen is
    /// their thin strips, not the column they frame.
    private func setMoving(_ moving: Bool) {
        guard moving != isMoving else { return }
        let layers = glows.map { $0.layer as CALayer } + (edge == .around ? [ring] : [])
        if moving, let light {
            let move = CABasicAnimation.lightMovement(for: light)
            layers.forEach { $0.add(move, forKey: Self.movementKey) }
        } else {
            layers.forEach { $0.removeAnimation(forKey: Self.movementKey) }
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
        layoutPill()
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
    /// How it is drawn, for tests: the layers that move, the level a
    /// steady light shows at, and whether its layers blend as one group.
    var movingLayerCount: Int {
        (glows.map { $0.layer as CALayer } + [ring]).filter { $0.animation(forKey: Self.movementKey) != nil }.count
    }
    var steadyLevel: Float { lightLayer.opacity }
    var blendsAsAGroup: Bool { fadeLayer.allowsGroupOpacity || lightLayer.allowsGroupOpacity }

    // MARK: - Pill

    /// The agent the glow stands for. `announcing` shows its pill for
    /// `pillDuration`; without it a new agent's pill waits for the pointer.
    private func setTarget(_ target: Target?, announcing: Bool) {
        if target != self.target {
            self.target = target
            pillGeneration += 1
            isAnnouncing = false
            setAccessibilityElement(target != nil)
            setAccessibilityRole(.button)
            setAccessibilityLabel(target?.text)
            if let target, let light {
                pill.configure(text: target.text, edge: edge, color: light.color)
                layoutPill()
            }
            updateTrackingAreas()
            if target == nil || !(announcing || isHovered) { setPillShown(false) }
        }
        guard target != nil, announcing else { return }
        setPillShown(true)
        isAnnouncing = true
        pillGeneration += 1
        let generation = pillGeneration
        // Then only the glow: the pill never stays over a terminal's text.
        DispatchQueue.main.asyncAfter(deadline: .now() + pillDuration) { [weak self] in
            guard let self, self.pillGeneration == generation else { return }
            self.endAnnouncement()
        }
    }

    /// The pill's first seconds are over: it leaves, unless the pointer is
    /// on the glow or on it.
    func endAnnouncement() {
        guard isAnnouncing else { return }
        isAnnouncing = false
        dropStaleHover()
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
        // Past the glow, so not under the pointer that rests on it.
        let margin = Self.depth + Self.pillGap
        let width = min(pill.fittingWidth, max(0, bounds.width - margin * 2))
        let height = EdgeGlowPill.height
        let origin: NSPoint
        switch edge {
        case .left: origin = NSPoint(x: margin, y: bounds.midY - height / 2)
        case .right: origin = NSPoint(x: bounds.maxX - margin - width, y: bounds.midY - height / 2)
        // Under the column headers.
        case .top:
            origin = NSPoint(x: bounds.midX - width / 2, y: bounds.maxY - ColumnHeaderView.height - Self.pillGap - height)
        // Above the column dots.
        case .bottom, .around: origin = NSPoint(x: bounds.midX - width / 2, y: 26)
        }
        pill.frame = NSRect(origin: origin, size: NSSize(width: width, height: height)).integral
    }

    var pillFrame: NSRect { pill.frame }
    var pillText: String { pill.text }

    // MARK: - Pointer

    /// Where the pointer's rest brings the pill back: the glow itself.
    var hoverStrip: NSRect { strip(edge, depth: Self.depth) }

    enum HoverZone { case glow, pill }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        [glowArea, pillArea].compactMap { $0 }.forEach(removeTrackingArea)
        (glowArea, pillArea) = (nil, nil)
        guard target != nil, edge != .around else {
            (pointerOnGlow, pointerOnPill) = (false, false)
            return
        }
        let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeInKeyWindow]
        let glow = NSTrackingArea(rect: hoverStrip, options: options, owner: self)
        let onPill = NSTrackingArea(rect: pill.frame, options: options, owner: self)
        addTrackingArea(glow)
        addTrackingArea(onPill)
        (glowArea, pillArea) = (glow, onPill)
        dropStaleHover()
    }

    override func mouseEntered(with event: NSEvent) {
        pointerEntered(event.trackingArea === pillArea ? .pill : .glow)
    }

    /// Also when the window stops being the key one: the pointer is gone
    /// as far as the pill goes.
    override func mouseExited(with event: NSEvent) {
        pointerExited(event.trackingArea === pillArea ? .pill : .glow)
    }

    /// The pointer resting on the glow brings the pill back; on the pill
    /// it keeps it.
    func pointerEntered(_ zone: HoverZone) {
        hoverGeneration += 1
        switch zone {
        case .pill:
            pointerOnPill = isPillShown
        case .glow:
            pointerOnGlow = true
            guard target != nil, !isPillShown else { return }
            after(hoverDwell) { glow in
                if glow.pointerOnGlow, glow.target != nil { glow.setPillShown(true) }
            }
        }
    }

    /// Off the glow, the pill stays long enough to be reached; off the
    /// pill, it leaves.
    func pointerExited(_ zone: HoverZone) {
        hoverGeneration += 1
        switch zone {
        case .glow: pointerOnGlow = false
        case .pill: pointerOnPill = false
        }
        guard isPillShown, !isHovered, !isAnnouncing else { return }
        after(zone == .glow ? pillLinger : 0) { glow in
            if !glow.isHovered, !glow.isAnnouncing { glow.setPillShown(false) }
        }
    }

    /// Runs `change` after `delay`, unless the pointer moved in or out
    /// meanwhile; at once without a delay.
    private func after(_ delay: TimeInterval, _ change: @escaping (EdgeGlowView) -> Void) {
        guard delay > 0 else { return change(self) }
        let generation = hoverGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.hoverGeneration == generation else { return }
            change(self)
        }
    }

    /// A tracking area replaced after the pointer left sends no exit: a
    /// hover the pointer is no longer in must not keep the pill.
    private func dropStaleHover() {
        guard isHovered, let window else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if pointerOnGlow, !hoverStrip.contains(point) { pointerExited(.glow) }
        if pointerOnPill, !pill.frame.contains(point) { pointerExited(.pill) }
    }

    /// Decoration, but for the pill while it shows: a click on it goes to
    /// the agent. Everything else under the glow keeps its clicks: the
    /// column headers, the terminals' first and last cells, the resize
    /// handle at the viewport's edge.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard target != nil, isPillShown, let superview else { return nil }
        return pill.frame.contains(convert(point, from: superview)) ? self : nil
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
        // A slow fade for hours: no need for 120 frames a second.
        move.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 30, preferred: 15)
        return move
    }
}

/// Names the agent an edge's glow stands for, in the glow's color, with an
/// arrow toward it. The glow view takes its clicks and speaks for it.
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
        // The glow view is the button VoiceOver reads, shown or not.
        label.setAccessibilityElement(false)
        label.cell?.setAccessibilityElement(false)
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
