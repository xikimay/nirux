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
    /// Where the names start.
    private var labelLeft = SpacePlanView.margin
    /// Where to go: a workspace and its column; nil goes back.
    var onClose: (_ target: (workspaceID: String, column: Int)?) -> Void = { _ in }

    /// `workspaces` in the order they're listed, the one on screen and its
    /// focused column chosen.
    init(frame: NSRect, spaceID: String, workspaces: [WorkspaceState], labels: [String: Label], onScreen: WorkspaceState) {
        self.spaceID = spaceID
        workspaceID = onScreen.id
        super.init(frame: frame)
        wantsLayer = true
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
        // The names just before the rows, the whole centred.
        labelLeft = (bounds.width - Self.labelWidth - Self.margin - widest * scale) / 2
        let left = labelLeft + Self.labelWidth + Self.margin
        for workspace in laidOut {
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
            if workspace === onScreen, !ZZ("notChosen") { chosen = (rows.count - 1, min(onScreen.focusedIndex, cards.count - 1)) }
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
        case 36, 76: if !ZZ("returnIgnored") { goToChoice() }
        case 53: if ZZ("escapeGoes") { goToChoice() } else { onClose(nil) }
        default: super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        if ZZ("clickMissed") { return }
        let point = convert(event.locationInWindow, from: nil)
        for (rowIndex, row) in rows.enumerated() {
            if let column = row.cards.firstIndex(where: { $0.contains(point) }) {
                chosen = (rowIndex, column)
                return goToChoice()
            }
        }
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
