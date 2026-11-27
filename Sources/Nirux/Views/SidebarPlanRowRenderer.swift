import AppKit

/// A feature's fold row, and a line of the plan that isn't a task's (a to-do, a Lead line, a planned session), in
/// the sidebar's document view (docs/design/plan.md).
struct SidebarPlanRowRenderer {
    typealias Metrics = SidebarExpandedMetrics

    enum Row: Equatable {
        /// `forUser`: its unchecked to-dos and tasks asking the user; `waits`: one of those tasks.
        case feature(Plan.Line, isFolded: Bool, forUser: Int, waits: Bool)
        case line(Plan.Line, isNested: Bool)
    }

    static let featureHeight: CGFloat = 28
    static let lineHeight: CGFloat = 22
    static let ringSize: CGFloat = 12

    let row: Row
    let sidebarWidth: CGFloat
    let top: CGFloat
    var onFold: () -> Void = {}

    static func height(of row: Row) -> CGFloat {
        if case .feature = row { return featureHeight }
        return lineHeight
    }

    func render() -> (views: [NSView], hitAreas: [SidebarHitArea], bottomY: CGFloat) {
        switch row {
        case .feature(let feature, let isFolded, let forUser, let waits): renderFeature(feature, isFolded: isFolded, forUser: forUser, waits: waits)
        case .line(let line, let isNested): renderLine(line, isNested: isNested)
        }
    }

    private func renderFeature(_ feature: Plan.Line, isFolded: Bool, forUser: Int, waits: Bool) -> (views: [NSView], hitAreas: [SidebarHitArea], bottomY: CGFloat) {
        let rowY = top - Self.featureHeight
        let frame = NSRect(x: Metrics.workspaceInsetX, y: rowY, width: sidebarWidth - Metrics.workspaceInsetX * 2, height: Self.featureHeight)
        var views: [NSView] = []
        let chevron = NSImageView(image: NSImage(systemSymbolName: isFolded ? "chevron.right" : "chevron.down", accessibilityDescription: nil) ?? NSImage())
        chevron.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        chevron.contentTintColor = Theme.Color.textTertiary
        chevron.frame = NSRect(x: Metrics.markCenterX - 6, y: rowY + (Self.featureHeight - 12) / 2, width: 12, height: 12)
        views.append(chevron)

        var right = frame.maxX - Metrics.cardPaddingX
        let ring = SidebarProgressRing(done: feature.progress.done, total: feature.progress.total)
        ring.frame = NSRect(x: right - Self.ringSize, y: rowY + (Self.featureHeight - Self.ringSize) / 2, width: Self.ringSize, height: Self.ringSize)
        views.append(ring)
        right = ring.frame.minX - Theme.Space.xs
        var trailing = ["\(feature.progress.done)/\(feature.progress.total)"]
        if isFolded, forUser > 0 { trailing.insert("\(forUser) for you", at: 0) }
        // Amber only while an agent in it waits for the user.
        let forUserColor = waits ? Theme.Color.waiting : Theme.Color.textSecondary
        for (index, text) in trailing.reversed().enumerated() {
            let label = Self.label(text, font: Theme.Font.captionDigits, color: index == trailing.count - 1 && isFolded && forUser > 0 ? forUserColor : Theme.Color.textTertiary)
            let width = ceil(label.fittingSize.width)
            label.frame = NSRect(x: right - width, y: rowY + (Self.featureHeight - 14) / 2, width: width, height: 14)
            views.append(label)
            right = label.frame.minX - Theme.Space.sm
        }
        let title = Self.label(feature.title, font: Theme.Font.title, color: Theme.Color.textPrimary)
        title.frame = NSRect(x: Metrics.textX, y: rowY + (Self.featureHeight - 17) / 2, width: max(0, right - Metrics.textX), height: 17)
        views.append(title)

        let toggle = SidebarSectionToggleView(frame: frame)
        toggle.setAccessibilityLabel("\(feature.title), feature, \(feature.progress.done) of \(feature.progress.total) done")
        toggle.toolTip = isFolded ? "Unfold" : "Fold"
        toggle.onPress = onFold
        views.append(toggle)
        return (views, [SidebarHitArea(frame: frame, region: .featureFold(feature.id))], rowY)
    }

    private func renderLine(_ line: Plan.Line, isNested: Bool) -> (views: [NSView], hitAreas: [SidebarHitArea], bottomY: CGFloat) {
        let rowY = top - Self.lineHeight
        let indent = isNested ? Metrics.nestIndent : 0
        var views: [NSView] = []
        let mark = SidebarPlanMark(kind: line.kind, isChecked: line.isChecked)
        mark.frame = NSRect(x: Metrics.markCenterX - 6 + indent, y: rowY + (Self.lineHeight - 12) / 2, width: 12, height: 12)
        views.append(mark)
        var right = sidebarWidth - Metrics.workspaceInsetX - Metrics.cardPaddingX
        if let chip = chip(for: line, isNested: isNested) {
            let width = ceil(chip.fittingWidth)
            chip.frame = NSRect(x: right - width, y: rowY + (Self.lineHeight - 16) / 2, width: width, height: 16)
            views.append(chip)
            right = chip.frame.minX - Theme.Space.xs
        }
        let title = Self.label(line.title, font: Theme.Font.body, color: line.isChecked ? Theme.Color.textTertiary : Theme.Color.textPrimary)
        if line.isChecked {
            title.attributedStringValue = NSAttributedString(string: line.title, attributes: [
                .font: Theme.Font.body, .foregroundColor: Theme.Color.textTertiary,
                .strikethroughStyle: NSUnderlineStyle.single.rawValue
            ])
        }
        let x = Metrics.textX + indent
        title.frame = NSRect(x: x, y: rowY + (Self.lineHeight - 15) / 2, width: max(0, right - x), height: 15)
        title.toolTip = Self.origin(of: line)
        views.append(title)
        return (views, [], rowY)
    }

    private func chip(for line: Plan.Line, isNested: Bool) -> SidebarBadgeView? {
        let (text, color): (String, NSColor)
        switch line.kind {
        case .todo where !line.isChecked: (text, color) = ("you", Theme.Color.textSecondary)
        case .lead where isNested: (text, color) = ("Lead", Theme.Color.accent)
        case .session where line.isPlanned: (text, color) = ("Planned", Theme.Color.textTertiary)
        default: return nil
        }
        let chip = SidebarBadgeView(text: text, textColor: color, fillColor: Theme.Color.tint(color, 0.16), font: Theme.Font.caption)
        chip.cornerRadius = Theme.Radius.card
        return chip
    }

    /// "Added by the Lead · 10:31 · Slack: a mention at 08:12".
    static func origin(of line: Plan.Line) -> String {
        let who = [Plan.Author.user: "you", .lead: "the Lead", .agent: "the agent", .nirux: "Nirux"][line.origin.by] ?? line.origin.by.rawValue
        let time = DateFormatter.localizedString(from: Date(timeIntervalSince1970: line.origin.at), dateStyle: .none, timeStyle: .short)
        let source = line.origin.source.map { [$0.name, $0.why].compactMap { $0 }.joined(separator: ": ") }
        return (["Added by \(who)", time] + (source.map { [$0] } ?? [])).joined(separator: " · ")
    }

    private static func label(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        return label
    }
}

/// A feature's done lines over all of them.
final class SidebarProgressRing: NSView {
    let done: Int
    let total: Int

    init(done: Int, total: Int) {
        self.done = done
        self.total = total
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let track = NSBezierPath(ovalIn: rect)
        track.lineWidth = 2
        Theme.Color.lineStrong.setStroke()
        track.stroke()
        guard total > 0, done > 0 else { return }
        let arc = NSBezierPath()
        let center = NSPoint(x: rect.midX, y: rect.midY)
        arc.appendArc(withCenter: center, radius: rect.width / 2, startAngle: 90, endAngle: 90 - 360 * CGFloat(done) / CGFloat(total), clockwise: true)
        arc.lineWidth = 2
        arc.lineCapStyle = .round
        Theme.Color.done.setStroke()
        arc.stroke()
    }
}

/// A plan line's mark where a task row has its state: a box for a to-do, ✦ for the Lead's, a dashed ring for a
/// planned session.
final class SidebarPlanMark: NSView {
    let kind: Plan.Line.Kind
    let isChecked: Bool

    init(kind: Plan.Line.Kind, isChecked: Bool) {
        self.kind = kind
        self.isChecked = isChecked
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1.5, dy: 1.5)
        switch kind {
        case .lead:
            let star = NSAttributedString(string: "✦", attributes: [.font: Theme.Font.caption, .foregroundColor: Theme.Color.accent])
            let size = star.size()
            star.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
        case .session:
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
            ring.lineWidth = 1.5
            ring.setLineDash([2, 2], count: 2, phase: 0)
            Theme.Color.textTertiary.setStroke()
            ring.stroke()
        default:
            let box = NSBezierPath(roundedRect: rect, xRadius: Theme.Radius.box, yRadius: Theme.Radius.box)
            if isChecked {
                Theme.Color.done.setFill()
                box.fill()
            } else {
                box.lineWidth = 1.5
                Theme.Color.textTertiary.setStroke()
                box.stroke()
            }
        }
    }
}
