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

    /// What a row shows: a workspace, its strip's size, its columns' frames
    /// and the one focused; the plan goes when one changes.
    struct Listed: Equatable {
        let id: String
        let stripSize: NSSize
        let columnFrames: [NSRect]
        let focusedIndex: Int

        @MainActor init(_ workspace: WorkspaceState) {
            id = workspace.id
            stripSize = workspace.stripSize
            columnFrames = workspace.columnFrames
            focusedIndex = workspace.focusedIndex
        }
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
    let listed: [Listed]
    private(set) var chosen = (row: 0, column: 0)
    /// The scale every row's picture is drawn at.
    private(set) var scale: CGFloat = 1
    private let ring = CALayer()
    /// Where the names start.
    private var labelLeft = SpacePlanView.margin
    /// The pinch on the plan under way.
    private var pinch = PinchGesture()
    /// Where to go: a workspace and its column; nil goes back.
    var onClose: (_ target: (workspaceID: String, column: Int)?) -> Void = { _ in }

    /// `workspaces` as `listing` keeps them, in the order they're listed;
    /// the one on screen and its focused column chosen.
    init(frame: NSRect, spaceID: String, workspaces: [WorkspaceState], labels: [String: Label], onScreen: WorkspaceState) {
        self.spaceID = spaceID
        workspaceID = onScreen.id
        listed = workspaces.map(Listed.init)
        super.init(frame: frame)
        wantsLayer = true
        // Gaps take a quarter of the height at most, so that every row shows.
        let gaps = CGFloat(max(0, workspaces.count - 1))
        let gap = min(Self.rowGap, (bounds.height - Self.margin * 2) / 4 / max(gaps, 1))
        let room = NSSize(
            width: bounds.width - Self.labelWidth - Self.margin * 3,
            height: bounds.height - Self.margin * 2 - gap * gaps
        )
        let widest = workspaces.map(\.stripSize.width).max() ?? 1
        let tallest = workspaces.reduce(0) { $0 + $1.stripSize.height }
        scale = max(0.01, min(1, room.width / widest, room.height / max(tallest, 1)))
        let block = tallest * scale + gap * gaps
        var top = (bounds.height + block) / 2
        // The names just before the rows, the whole centred.
        labelLeft = (bounds.width - Self.labelWidth - Self.margin - widest * scale) / 2
        let left = labelLeft + Self.labelWidth + Self.margin
        for workspace in workspaces {
            guard let picture = workspace.frozenColumns(scale: scale) else { continue }
            let height = workspace.stripSize.height * scale
            picture.frame.origin = NSPoint(x: left, y: top - height)
            addSubview(picture)
            let cards = workspace.columnFrames.map { frame in
                NSRect(x: left + frame.minX * scale, y: top - height + frame.minY * scale, width: frame.width * scale, height: frame.height * scale)
            }
            rows.append(Row(workspaceID: workspace.id, picture: picture, cards: cards))
            let label = labels[workspace.id] ?? Label(title: workspace.title, icon: StateIcon(.idle), initials: nil, detail: nil)
            addLabel(label, besideRowAt: top - height / 2)
            if workspace === onScreen { chosen = (rows.count - 1, min(onScreen.focusedIndex, cards.count - 1)) }
            top -= height + gap
        }
        ring.borderColor = Theme.Color.accent.cgColor
        ring.borderWidth = Self.ringWidth
        // Its corners follow the card's, two ring widths out.
        ring.cornerRadius = Theme.Radius.column * scale + Self.ringWidth * 2
        layer?.addSublayer(ring)
        showChoice()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Of `workspaces`, those a row shows: laid out, not closing.
    static func listing(_ workspaces: [WorkspaceState]) -> [WorkspaceState] {
        workspaces.filter { !$0.isClosing && !$0.columns.isEmpty && !$0.stripSize.equalTo(.zero) }
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
        pinched(by: event.magnification, phase: event.phase, at: convert(event.locationInWindow, from: nil))
    }

    /// Fingers opening go to the card under them, else to the chosen one.
    func pinched(by magnification: CGFloat, phase: NSEvent.Phase, at point: NSPoint) {
        guard ZZ("planPinchEager") || pinch.moved(by: magnification, phase: phase, past: NiruxShellView.pinchThreshold) else { return }
        if !ZZ("cardIgnored"), let card = card(at: point) { chosen = card }
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
        // Amber, the state's colour, only while it waits on the user.
        if case .needsYou = label.icon.kind { detail.textColor = label.icon.color } else { detail.textColor = Theme.Color.textSecondary }
        detail.lineBreakMode = .byTruncatingTail
        let textX = labelLeft + icon.frame.width + Theme.Space.sm
        let textWidth = Self.labelWidth - icon.frame.width - Theme.Space.sm
        icon.frame.origin = NSPoint(x: labelLeft, y: midY - icon.frame.height / 2)
        title.frame = NSRect(x: textX, y: midY, width: textWidth, height: title.intrinsicContentSize.height)
        detail.frame = NSRect(x: textX, y: midY - detail.intrinsicContentSize.height, width: textWidth, height: detail.intrinsicContentSize.height)
        for view in [icon, title, detail] as [NSView] { addSubview(view) }
    }
}

/// One pinch, `.began` to `.ended`: how far its fingers moved, and
/// whether it acted, which it does once.
struct PinchGesture {
    private(set) var total: CGFloat = 0
    private(set) var acted = false

    /// True once a gesture, when its total passes `threshold`: below it
    /// when negative (fingers closing), above it otherwise.
    mutating func moved(by magnification: CGFloat, phase: NSEvent.Phase, past threshold: CGFloat) -> Bool {
        if phase.contains(.began), !ZZ("noBeganReset") { self = PinchGesture() }
        defer { if phase.contains(.ended) || phase.contains(.cancelled) { end() } }
        guard !acted || ZZ("actsTwice") else { return false }
        total += magnification
        guard threshold < 0 ? total <= threshold : total >= threshold else { return false }
        acted = true
        return true
    }

    /// Nothing more for the gesture under way.
    mutating func end() {
        self = PinchGesture(total: 0, acted: true)
    }
}
