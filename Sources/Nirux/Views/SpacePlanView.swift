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
    /// The names' column, at most.
    static let maxLabelWidth: CGFloat = 200
    private static let ringWidth: CGFloat = 2

    let spaceID: String
    let workspaceID: String
    private(set) var rows: [Row] = []
    private(set) var chosen = (row: 0, column: 0)
    /// The scale every row's picture is drawn at.
    private(set) var scale: CGFloat = 1
    private let ring = CALayer()
    /// What zooms: the rows' pictures, in a view of their own (its layer's
    /// `sublayerTransform` moves them; AppKit owns the layers). The plan
    /// takes its clicks.
    let world: NSView = Passive()
    /// The names and lines beside the rows, which don't zoom: they fade as
    /// one, in a view whose layer is there from the start.
    let names: NSView = Passive()
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
        for view in [world, names] {
            view.frame = bounds
            view.wantsLayer = true
            addSubview(view)
        }
        let laidOut = workspaces.filter { !$0.columns.isEmpty && !$0.stripSize.equalTo(.zero) }
        let rowLabels = laidOut.map { workspace in
            RowLabel(labels[workspace.id] ?? Label(title: workspace.title, icon: StateIcon(.idle), initials: nil, detail: nil))
        }
        // As wide as the longest name or line needs, so that each sits near its row.
        let labelWidth = min(Self.maxLabelWidth, rowLabels.map(\.width).max() ?? 0)
        let room = NSSize(
            width: bounds.width - labelWidth - Self.margin * 3,
            height: bounds.height - Self.margin * 2 - Self.rowGap * CGFloat(max(0, laidOut.count - 1))
        )
        let widest = laidOut.map(\.stripSize.width).max() ?? 1
        let tallest = laidOut.reduce(0) { $0 + $1.stripSize.height }
        scale = max(0.01, min(1, room.width / widest, room.height / max(tallest, 1)))
        let block = tallest * scale + Self.rowGap * CGFloat(max(0, laidOut.count - 1))
        var top = (bounds.height + block) / 2
        // The names just before the rows, the whole centred.
        let labelLeft = ((bounds.width - labelWidth - Self.margin - widest * scale) / 2).rounded()
        let left = labelLeft + labelWidth + Self.margin
        for (workspace, rowLabel) in zip(laidOut, rowLabels) {
            guard let picture = workspace.frozenColumns(scale: scale) else { continue }
            let height = workspace.stripSize.height * scale
            picture.frame.origin = NSPoint(x: left, y: top - height)
            world.addSubview(picture)
            let cards = workspace.columnFrames.map { frame in
                NSRect(x: left + frame.minX * scale, y: top - height + frame.minY * scale, width: frame.width * scale, height: frame.height * scale)
            }
            rows.append(Row(workspaceID: workspace.id, picture: picture, cards: cards))
            rowLabel.place(left: labelLeft, width: labelWidth, midY: top - height / 2, in: names)
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

    /// Leaves its clicks to the plan.
    private final class Passive: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

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

    /// A row's state icon, name and status line, at their own size.
    @MainActor private struct RowLabel {
        let icon: StateIconView
        let title: NSTextField
        let detail: NSTextField

        init(_ label: Label) {
            icon = StateIconView(label.icon, size: IconRail.iconSize)
            icon.label = label.initials
            title = NSTextField(labelWithString: label.title)
            title.font = Theme.Font.listTitle
            title.textColor = Theme.Color.textPrimary
            title.lineBreakMode = .byTruncatingTail
            detail = NSTextField(labelWithString: label.detail ?? "")
            detail.font = Theme.Font.caption
            // Amber, the state's colour, only while it waits on the user.
            if case .needsYou = label.icon.kind { detail.textColor = label.icon.color } else { detail.textColor = Theme.Color.textSecondary }
            detail.lineBreakMode = .byTruncatingTail
        }

        /// Its icon and its longer line, whole: a truncating label's intrinsic
        /// width cuts its last letters.
        var width: CGFloat {
            icon.frame.width + Theme.Space.sm + ceil(max(title.fittingSize.width, detail.fittingSize.width))
        }

        func place(left: CGFloat, width: CGFloat, midY: CGFloat, in view: NSView) {
            let textX = left + icon.frame.width + Theme.Space.sm
            let textWidth = width - icon.frame.width - Theme.Space.sm
            icon.frame.origin = NSPoint(x: left, y: midY - icon.frame.height / 2)
            title.frame = NSRect(x: textX, y: midY, width: textWidth, height: title.intrinsicContentSize.height)
            detail.frame = NSRect(x: textX, y: midY - detail.intrinsicContentSize.height, width: textWidth, height: detail.intrinsicContentSize.height)
            for subview in [icon, title, detail] as [NSView] { view.addSubview(subview) }
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
        if !ZZ("namesUnfaded") { Self.fade(names, [0, 0, 1], keyTimes: [0, 0.55, 0.95], duration: Self.openingDuration) }
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
        Self.fade(names, [1, 0], keyTimes: [0, 0.3], duration: Self.diveDuration)
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
        names.layer?.removeAnimation(forKey: "planFade")
        names.alphaValue = 1
        showChoice()
    }

    private func showOverlay(_ picture: FrozenView, in rect: NSRect, opacities: [Float], keyTimes: [NSNumber], duration: CFTimeInterval) {
        overlay?.removeFromSuperview()
        picture.show(in: rect)
        world.addSubview(picture)
        overlay = picture
        Self.fade(picture, opacities, keyTimes: keyTimes, duration: duration)
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

    /// `view` through `opacities`, left at the last.
    private static func fade(_ view: NSView, _ opacities: [Float], keyTimes: [NSNumber], duration: CFTimeInterval) {
        view.alphaValue = CGFloat(opacities.last ?? 1)
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = opacities
        fade.keyTimes = keyTimes
        fade.duration = duration
        view.layer?.add(fade, forKey: "planFade")
    }
}
