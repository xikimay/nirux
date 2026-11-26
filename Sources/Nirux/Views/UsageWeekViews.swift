import AppKit

/// Claude's week in points of its weekly limit (`UsageWeek`): a bar per
/// day, its segments by task in the chart palette's order, the rest in a
/// neutral grey; the legend above, each day's total over its bar, its split
/// in the tooltip.
final class UsageWeekChart: NSView, NSViewToolTipOwner {
    private static let legendHeight: CGFloat = 22
    private static let labelHeight: CGFloat = 16
    private static let gap: CGFloat = 2
    private static let radius = Theme.Radius.chartBar

    private(set) var week: UsageWeek?
    private var dayStarts: [TimeInterval] = []
    private var names: [String: String] = [:]

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ week: UsageWeek?, dayStarts: [TimeInterval], names: [String: String]) {
        guard week != self.week || dayStarts != self.dayStarts || names != self.names else { return }
        self.week = week
        self.dayStarts = dayStarts
        self.names = names
        needsDisplay = true
        updateToolTips()
        setAccessibilityLabel("Claude's weekly limit, day by day: " + zip(dayStarts, week?.days ?? []).map { start, parts in
            "\(Self.dayName(start)) \(Self.percent(parts.reduce(0, +)))"
        }.joined(separator: ", "))
    }

    func name(of task: String) -> String { task.isEmpty ? "Other" : names[task] ?? "Closed task" }

    private func color(at index: Int, of week: UsageWeek) -> NSColor {
        week.tasks[index].isEmpty ? Theme.Color.textTertiary : Theme.Color.chartSeries[index % Theme.Color.chartSeries.count]
    }

    private static func percent(_ points: Double) -> String { "\(Int(points.rounded()))%" }

    private static func dayName(_ start: TimeInterval) -> String {
        Date(timeIntervalSince1970: start).formatted(.dateTime.weekday(.abbreviated).day())
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateToolTips()
    }

    private func columns() -> [NSRect] {
        guard !dayStarts.isEmpty else { return [] }
        let width = bounds.width / CGFloat(dayStarts.count)
        return dayStarts.indices.map { NSRect(x: CGFloat($0) * width, y: 0, width: width, height: bounds.height - Self.legendHeight) }
    }

    private func updateToolTips() {
        removeAllToolTips()
        for column in columns() { addToolTip(column, owner: self, userData: nil) }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        guard let week, let index = columns().firstIndex(where: { $0.contains(point) }), let parts = week.days[safe: index] else { return "" }
        let lines = zip(week.tasks, parts).filter { $0.1 >= 0.5 }.map { "\(name(of: $0.0)): ≈ \(Self.percent($0.1))" }
        return (["\(Self.dayName(dayStarts[index])): ≈ \(Self.percent(parts.reduce(0, +))) of the weekly limit"] + lines).joined(separator: "\n")
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let week else { return }
        drawLegend(week)
        let peak = week.days.map { $0.reduce(0, +) }.max() ?? 0
        let ink: [NSAttributedString.Key: Any] = [.font: Theme.Font.captionDigits, .foregroundColor: Theme.Color.textSecondary]
        let plotHeight = bounds.height - Self.legendHeight - Self.labelHeight * 2
        for (index, (column, parts)) in zip(columns(), week.days).enumerated() {
            let barWidth = min(36, column.width * 0.5)
            let x = column.midX - barWidth / 2
            var y = Self.labelHeight
            let total = parts.reduce(0, +)
            let barHeight = peak > 0 ? plotHeight * CGFloat(total / peak) : 0
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: NSRect(x: x, y: y - Self.radius, width: barWidth, height: barHeight + Self.radius),
                         xRadius: Self.radius, yRadius: Self.radius).addClip()
            for (segment, value) in parts.enumerated() where peak > 0 {
                let height = plotHeight * CGFloat(value / peak)
                if height > Self.gap {
                    color(at: segment, of: week).setFill()
                    NSRect(x: x, y: y, width: barWidth, height: height - Self.gap).fill()
                }
                y += height
            }
            NSGraphicsContext.restoreGraphicsState()
            if total >= 0.5 { Self.center(Self.percent(total), in: NSRect(x: column.minX, y: y, width: column.width, height: Self.labelHeight), ink) }
            let start = dayStarts[index]
            let label = Calendar.current.isDateInToday(Date(timeIntervalSince1970: start)) ? "Today" : Self.dayName(start)
            Self.center(label, in: NSRect(x: column.minX, y: 0, width: column.width, height: Self.labelHeight), ink)
        }
    }

    private func drawLegend(_ week: UsageWeek) {
        let y = bounds.height - Self.legendHeight + 6
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [.font: Theme.Font.caption, .foregroundColor: Theme.Color.textSecondary, .paragraphStyle: paragraph]
        let entries = week.tasks.indices.filter { index in week.days.contains { ($0[safe: index] ?? 0) >= 0.5 } }.map { index in
            (index, NSAttributedString(string: name(of: week.tasks[index]), attributes: attributes))
        }
        let swatch: CGFloat = 12
        let widths = Self.legendWidths(entries.map { swatch + ceil($0.1.size().width) + Theme.Space.md }, fitting: bounds.width)
        var x: CGFloat = 0
        for ((index, text), width) in zip(entries, widths) {
            color(at: index, of: week).setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: y + 2, width: 8, height: 8), xRadius: Theme.Radius.chartSwatch, yRadius: Theme.Radius.chartSwatch).fill()
            text.draw(in: NSRect(x: x + swatch, y: y - 1, width: max(0, width - swatch - Theme.Space.md), height: ceil(text.size().height)))
            x += width
        }
    }

    /// Each legend entry's width: its own when they all fit, else the
    /// widest ones share what the others leave, cut to an even part.
    static func legendWidths(_ widths: [CGFloat], fitting available: CGFloat) -> [CGFloat] {
        var left = available
        var cap = CGFloat.infinity
        for (index, width) in widths.sorted().enumerated() {
            let share = left / CGFloat(widths.count - index)
            if width > share {
                cap = share
                break
            }
            left -= width
        }
        return widths.map { min($0, cap) }
    }

    private static func center(_ string: String, in rect: NSRect, _ attributes: [NSAttributedString.Key: Any]) {
        let text = NSAttributedString(string: string, attributes: attributes)
        let size = text.size()
        text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.minY + (rect.height - size.height) / 2))
    }
}

/// The Usage window's tasks: each one's points of Claude's weekly limit
/// (when the readings calibrate them), its tokens, peak context and
/// subagents.
final class UsageTasksTable: NSScrollView, NSTableViewDataSource, NSTableViewDelegate {
    struct Row: Equatable {
        var title: String
        var points: Double?
        var tokens: Double
        var peakContext: Int
        var subagents: Int
    }

    private static let columns: [(id: String, title: String, width: CGFloat)] = [
        ("task", "Task", 230), ("points", "≈ Week", 70), ("tokens", "Tokens", 70), ("peak", "Peak context", 90), ("subagents", "Subagents", 70)
    ]

    let table = NSTableView()
    private(set) var rows: [Row] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        for column in Self.columns {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.id))
            tableColumn.title = column.title
            tableColumn.width = column.width
            table.addTableColumn(tableColumn)
        }
        table.dataSource = self
        table.delegate = self
        table.backgroundColor = .clear
        table.usesAlternatingRowBackgroundColors = false
        table.style = .plain
        documentView = table
        drawsBackground = false
        hasVerticalScroller = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ rows: [Row]) {
        guard rows != self.rows else { return }
        self.rows = rows
        table.reloadData()
    }

    /// A cell's words, for tests and VoiceOver alike.
    func text(row: Int, column: String) -> String {
        guard let item = rows[safe: row] else { return "" }
        switch column {
        case "task": return item.title
        case "points": return item.points.map { "≈ \(max(1, Int($0.rounded())))%" } ?? "—"
        case "tokens": return UsageText.tokens(item.tokens)
        case "peak": return item.peakContext > 0 ? UsageText.tokens(item.peakContext) : ""
        default: return item.subagents > 0 ? "\(item.subagents)" : ""
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier.rawValue else { return nil }
        let label = NSTextField(labelWithString: text(row: row, column: id))
        label.font = id == "task" ? Theme.Font.caption : Theme.Font.captionDigits
        label.textColor = id == "task" ? Theme.Color.textPrimary : Theme.Color.textSecondary
        label.lineBreakMode = .byTruncatingTail
        label.alignment = id == "task" ? .left : .right
        if id == "points" { label.toolTip = "Its share of Claude’s week, estimated from the weekly limit’s readings" }
        return label
    }
}
