import AppKit

/// Depth study P5, the space as a plan (docs/design/glass-interface.md): a
/// row per workspace, every column of it frozen at the plan's scale, its
/// state icon and name at their own size. The chosen card wears a ring; the
/// arrows move it, Return or a click goes there, Escape goes back.
final class SpacePlanView: NSView {
    struct Row {
        let workspaceID: String
        let picture: FrozenView
        /// Each column's card, in the plan.
        let cards: [NSRect]
    }

    /// What a row says beside its picture.
    struct Label {
        let title: String
        let icon: StateIcon
        let initials: String?
        let detail: String?
    }

    static let margin = Theme.Space.xl
    static let rowGap = Theme.Space.xl
    static let labelWidth: CGFloat = 200
    private static let ringWidth: CGFloat = 2

    let spaceID: String
    let workspaceID: String
    private(set) var rows: [Row] = []
    private(set) var chosen = (row: 0, column: 0)
    /// The scale every row's picture is drawn at.
    private(set) var scale: CGFloat = 1
    private let ring = CALayer()
    /// What zooms: the rows' pictures, in a view of their own (its layer's
    /// `sublayerTransform` moves them; AppKit owns the layers).
    let world = NSView()
    /// The names and lines beside the rows, which don't zoom.
    private var labels: [NSView] = []
    /// A picture at the size of the viewport over the zoom: what the work
    /// showed (an opening) or will show (a dive).
    private var overlay: FrozenView?
    /// Going to a workspace: it shows already under the plan.
    var isDiving = false
    /// How far the fingers moved in this pinch.
    private var pinchTotal: CGFloat = 0
    /// Where to go: a workspace and its column; nil goes back.
    var onClose: (_ target: (workspaceID: String, column: Int)?) -> Void = { _ in }

    /// `workspaces` in the order they're listed, the one on screen and its
    /// focused column chosen.
    init(frame: NSRect, spaceID: String, workspaces: [WorkspaceState], labels: [String: Label], onScreen: WorkspaceState) {
        self.spaceID = spaceID
        workspaceID = onScreen.id
        super.init(frame: frame)
        wantsLayer = true
        world.frame = bounds
        world.wantsLayer = true
        addSubview(world)
        let laidOut = workspaces.filter { !$0.columns.isEmpty && !$0.stripSize.equalTo(.zero) }
        let room = NSSize(
            width: bounds.width - Self.labelWidth - Self.margin * 3,
            height: bounds.height - Self.margin * 2 - Self.rowGap * CGFloat(max(0, laidOut.count - 1))
        )
        let widest = laidOut.map(\.stripSize.width).max() ?? 1
        let tallest = laidOut.reduce(0) { $0 + $1.stripSize.height }
        scale = max(0.01, min(1, room.width / widest, room.height / max(tallest, 1)))
        let block = tallest * scale + Self.rowGap * CGFloat(max(0, laidOut.count - 1))
        var top = (bounds.height + block) / 2
        let left = Self.margin * 2 + Self.labelWidth + (room.width - widest * scale) / 2
        for workspace in laidOut {
            guard let picture = workspace.frozenColumns(scale: scale) else { continue }
            let height = workspace.stripSize.height * scale
            picture.frame.origin = NSPoint(x: left, y: top - height)
            world.addSubview(picture)
            let cards = workspace.columnFrames.map { frame in
                NSRect(x: left + frame.minX * scale, y: top - height + frame.minY * scale, width: frame.width * scale, height: frame.height * scale)
            }
            rows.append(Row(workspaceID: workspace.id, picture: picture, cards: cards))
            let label = labels[workspace.id] ?? Label(title: workspace.title, icon: StateIcon(.idle), initials: nil, detail: nil)
            addLabel(label, besideRowAt: top - height / 2)
            if workspace === onScreen { chosen = (rows.count - 1, min(onScreen.focusedIndex, cards.count - 1)) }
            top -= height + Self.rowGap
        }
        ring.borderColor = Theme.Color.accent.cgColor
        ring.borderWidth = Self.ringWidth
        ring.cornerRadius = Theme.Radius.column * scale + Self.ringWidth
        layer?.addSublayer(ring)
        showChoice()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: move(columns: -1)
        case 124: move(columns: 1)
        case 125: move(rows: 1)
        case 126: move(rows: -1)
        case 36, 76: goToChoice()
        case 53: onClose(nil)
        default: super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let card = card(at: convert(event.locationInWindow, from: nil)) else { return }
        chosen = card
        goToChoice()
    }

    override func magnify(with event: NSEvent) {
        pinched(by: event.magnification, began: event.phase.contains(.began), at: convert(event.locationInWindow, from: nil))
    }

    /// Fingers opening go to the card under them, else to the chosen one.
    func pinched(by magnification: CGFloat, began: Bool, at point: NSPoint) {
        if began { pinchTotal = 0 }
        pinchTotal += magnification
        guard pinchTotal >= NiruxShellView.pinchThreshold else { return }
        if let card = card(at: point) { chosen = card }
        goToChoice()
    }

    private func card(at point: NSPoint) -> (row: Int, column: Int)? {
        for (rowIndex, row) in rows.enumerated() {
            if let column = row.cards.firstIndex(where: { $0.contains(point) }) { return (rowIndex, column) }
        }
        return nil
    }

    /// Along the chosen row, as far as its ends.
    func move(columns: Int) {
        guard let row = rows[safe: chosen.row] else { return }
        chosen.column = max(0, min(row.cards.count - 1, chosen.column + columns))
        showChoice()
    }

    /// To the row above or below, on the card nearest the chosen one.
    func move(rows delta: Int) {
        guard let from = rows[safe: chosen.row]?.cards[safe: chosen.column] else { return }
        let target = max(0, min(rows.count - 1, chosen.row + delta))
        let cards = rows[target].cards
        let nearest = cards.indices.min { abs(cards[$0].midX - from.midX) < abs(cards[$1].midX - from.midX) } ?? 0
        chosen = (target, nearest)
        showChoice()
    }

    func goToChoice() {
        guard let row = rows[safe: chosen.row] else { return onClose(nil) }
        onClose((row.workspaceID, chosen.column))
    }

    private func showChoice() {
        guard let card = rows[safe: chosen.row]?.cards[safe: chosen.column] else { return ring.isHidden = true }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.isHidden = false
        ring.frame = card.insetBy(dx: -Self.ringWidth * 2, dy: -Self.ringWidth * 2)
        CATransaction.commit()
    }

    /// The row's state icon, name and status line, at their own size.
    private func addLabel(_ label: Label, besideRowAt midY: CGFloat) {
        let icon = StateIconView(label.icon, size: IconRail.iconSize)
        icon.label = label.initials
        let title = NSTextField(labelWithString: label.title)
        title.font = Theme.Font.listTitle
        title.textColor = Theme.Color.textPrimary
        title.lineBreakMode = .byTruncatingTail
        let detail = NSTextField(labelWithString: label.detail ?? "")
        detail.font = Theme.Font.caption
        if case .needsYou = label.icon.kind { detail.textColor = Theme.Color.waiting } else { detail.textColor = Theme.Color.textSecondary }
        detail.lineBreakMode = .byTruncatingTail
        let textX = Self.margin + icon.frame.width + Theme.Space.sm
        let textWidth = Self.labelWidth - icon.frame.width - Theme.Space.sm
        icon.frame.origin = NSPoint(x: Self.margin, y: midY - icon.frame.height / 2)
        title.frame = NSRect(x: textX, y: midY, width: textWidth, height: title.intrinsicContentSize.height)
        detail.frame = NSRect(x: textX, y: midY - detail.intrinsicContentSize.height, width: textWidth, height: detail.intrinsicContentSize.height)
        for view in [icon, title, detail] as [NSView] {
            addSubview(view)
            labels.append(view)
        }
    }

    // MARK: - Motion (depth study P5's transitions)

    static let openingDuration: CFTimeInterval = 0.56
    static let diveDuration: CFTimeInterval = 0.52
    private static let curve = CAMediaTimingFunction(controlPoints: 0.3, 0.7, 0.2, 1)

    /// Where a row's workspace shows, its camera at `cameraX` across
    /// `width`, in the plan.
    func shownRect(row: Int, cameraX: CGFloat, width: CGFloat) -> NSRect? {
        guard let picture = rows[safe: row]?.picture.frame else { return nil }
        return NSRect(x: picture.minX + cameraX * scale, y: picture.minY, width: width * scale, height: picture.height)
    }

    /// The world zoomed until `rect` fills the plan.
    func zoom(into rect: NSRect) -> CATransform3D {
        let factor = bounds.width / rect.width
        return CATransform3DConcat(CATransform3DMakeScale(factor, factor, 1), CATransform3DMakeTranslation(-rect.minX * factor, -rect.minY * factor, 0))
    }

    /// The work recedes into the plan: the world comes from `rect` filling
    /// it to its place, `shown` (the viewport frozen at its size) fading
    /// into its row's picture; the names come after.
    func playOpening(from shown: FrozenView, at rect: NSRect) {
        if !ZZ("noOverlay") { showOverlay(shown, in: rect, opacities: [1, 1, 0], keyTimes: [0, 0.35, 0.8], duration: Self.openingDuration) }
        zoomWorld(from: ZZ("notFromWork") ? CATransform3DIdentity : zoom(into: rect), to: CATransform3DIdentity, duration: Self.openingDuration)
        for label in labels { Self.fade(label, to: 1, from: 0, duration: 0.22, delay: 0.32) }
        ring.isHidden = true
    }

    /// Into `rect`, where the chosen workspace now shows: the world zooms
    /// until it fills the plan, `arriving` (that workspace frozen at its
    /// size) fading in over it; the names go first.
    func playDive(into rect: NSRect, arriving: FrozenView) {
        isDiving = true
        ring.isHidden = true
        showOverlay(arriving, in: rect, opacities: [0, 0, 1], keyTimes: [0, 0.5, 0.9], duration: Self.diveDuration)
        zoomWorld(from: CATransform3DIdentity, to: zoom(into: rect), duration: Self.diveDuration)
        for label in labels { Self.fade(label, to: 0, from: 1, duration: 0.16, delay: 0) }
    }

    /// An opening at its end, at once: the world in place, the overlay
    /// gone, the names and the ring shown.
    func finishOpening() {
        guard !isDiving else { return }
        overlay?.removeFromSuperview()
        overlay = nil
        if !ZZ("staysZoomed") {
            world.layer?.removeAnimation(forKey: "planZoom")
            world.layer?.sublayerTransform = CATransform3DIdentity
        }
        for label in labels {
            label.layer?.removeAnimation(forKey: "planFade")
            label.alphaValue = 1
        }
        showChoice()
    }

    private func showOverlay(_ picture: FrozenView, in rect: NSRect, opacities: [Float], keyTimes: [NSNumber], duration: CFTimeInterval) {
        overlay?.removeFromSuperview()
        picture.show(in: rect)
        world.addSubview(picture)
        overlay = picture
        picture.alphaValue = CGFloat(opacities.last ?? 1)
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = opacities
        fade.keyTimes = keyTimes
        fade.duration = duration
        picture.layer?.add(fade, forKey: "planFade")
    }

    private func zoomWorld(from start: CATransform3D, to end: CATransform3D, duration: CFTimeInterval) {
        guard let layer = world.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.sublayerTransform = end
        CATransaction.commit()
        let zoom = CABasicAnimation(keyPath: "sublayerTransform")
        zoom.fromValue = NSValue(caTransform3D: start)
        zoom.duration = duration
        zoom.timingFunction = Self.curve
        layer.add(zoom, forKey: "planZoom")
    }

    private static func fade(_ view: NSView, to end: CGFloat, from start: CGFloat, duration: CFTimeInterval, delay: CFTimeInterval) {
        view.alphaValue = end
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = start
        fade.toValue = end
        fade.duration = duration
        if delay > 0 {
            fade.beginTime = CACurrentMediaTime() + delay
            fade.fillMode = .backwards
        }
        view.layer?.add(fade, forKey: "planFade")
    }
}
