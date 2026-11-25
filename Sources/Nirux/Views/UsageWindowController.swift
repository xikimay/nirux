import AppKit

/// What the Usage window calls tasks and spaces.
struct UsageNames: Equatable {
    struct Task: Equatable {
        var title: String
        var isLead = false
    }

    var tasks: [String: Task] = [:]
    var spaces: [String: String] = [:]
}

/// The Usage window's text: sections of tab-separated rows.
enum UsageReportText {
    struct Section: Equatable {
        var title: String
        var rows: [[String]]
    }

    static let taskRows = 12

    /// The tasks, busiest first, for the table; points of Claude's weekly
    /// limit from `week` over 7 days.
    static func tableRows(_ period: UsageReport.Period, names: UsageNames, week: UsageWeek?, dayTasks: [[String: Double]]) -> [UsageTasksTable.Row] {
        period.tasks.sorted { $0.value.weightedTokens > $1.value.weightedTokens }.prefix(taskRows).map { id, summary in
            let claude = dayTasks.reduce(0.0) { $0 + ($1[id] ?? 0) }
            return UsageTasksTable.Row(
                title: names.tasks[id]?.title ?? "Closed task",
                points: week?.pointsPerToken.flatMap { claude > 0 ? $0 * claude : nil },
                tokens: summary.weightedTokens, peakContext: summary.peakContextTokens, subagents: summary.subagents.count
            )
        }
    }

    static func name(of source: UsageReport.Source) -> String {
        switch source {
        case .claude: "Claude"
        case .subagents: "Claude subagents"
        case .codex: "Codex"
        case .agy: "Antigravity"
        case .nirux: "Nirux’s own runs"
        }
    }

    static func sections(_ period: UsageReport.Period, names: UsageNames) -> [Section] {
        let total = period.total.weightedTokens
        func row(_ label: String, _ tokens: Double, _ extra: [String] = []) -> [String] {
            [label, UsageText.tokens(tokens), UsageText.share(tokens, of: total)] + extra
        }
        let agents = UsageReport.Source.allCases.compactMap { source in
            period.sources[source].map { row(name(of: source), $0.weightedTokens) }
        }
        let leads = period.tasks.filter { names.tasks[$0.key]?.isLead == true }.values.reduce(0) { $0 + $1.weightedTokens }
        let saves = { (tokens: Double, how: String) in tokens >= 1 ? "\(how) saves ≈ \(UsageText.share(tokens, of: total))" : "" }
        let causes = [
            row("Context past \(UsageText.tokens(UsageSummary.heavyContextTokens))", period.total.heavyContextWeightedTokens,
                [saves(period.total.heavyContextExcessWeightedTokens, "Compacting there")]),
            row("Subagents (\(period.total.subagents.count))", period.total.subagentWeightedTokens,
                [period.total.subagents.count > SidebarTaskUsage.subagentSoftCap ? "Past \(SidebarTaskUsage.subagentSoftCap) a session: start tasks" : ""]),
            row("Cold cache rewrites (\(period.total.coldRewrites))", period.total.coldRewriteWeightedTokens,
                [saves(period.total.coldRewriteWeightedTokens, "A fresh start after an idle hour")]),
            row("Leads", leads)
        ].filter { $0[1] != "0" }
        let spaces = period.spaces.sorted { $0.value.weightedTokens > $1.value.weightedTokens }.map { id, summary in
            row(names.spaces[id] ?? "Removed space", summary.weightedTokens)
        }
        return [
            Section(title: "By agent", rows: agents),
            Section(title: "Causes (they overlap)", rows: causes),
            Section(title: "Spaces", rows: spaces)
        ].filter { !$0.rows.isEmpty }
    }

    /// "1.05G tokens · 4,210 responses · 96 sessions".
    static func headline(_ period: UsageReport.Period) -> String {
        let count = { (value: Int, noun: String) in "\(value.formatted()) \(noun)\(value == 1 ? "" : "s")" }
        return "\(UsageText.tokens(period.total.weightedTokens)) tokens · " + count(period.total.calls, "response")
            + " · " + count(period.total.sessions.count, "session")
    }
}

/// The Usage window (⇧⌘U): the plan limits on top, as the title bar's
/// popover shows them; then where the tokens went over the last 24 hours or
/// 7 days: Claude's week day by day in points of its weekly limit (by agent
/// in tokens without its readings), the tasks, the causes and what each
/// remedy saves, the spaces. Read-only; numbers only.
final class UsageWindowController: NSWindowController {
    let period = NSSegmentedControl(labels: ["24 Hours", "7 Days"], trackingMode: .selectOne, target: nil, action: nil)
    let headline = NSTextField(labelWithString: "")
    private let chart = UsageDaysChart()
    let weekChart = UsageWeekChart()
    let tasksTable = UsageTasksTable()
    let limitsStack = NSStackView()
    private var limits: [QuotaLimit] = []
    private var weekReadings: [QuotaReading] = []
    private let scroll = NSTextView.scrollableTextView()
    private var textView: NSTextView { scroll.documentView as! NSTextView }
    private var report: UsageReport?
    private var names = UsageNames()

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true
        )
        window.title = "Token Usage"
        window.appearance = Theme.appearance
        window.isReleasedWhenClosed = false
        // The last column ("394 subagents") still fits.
        window.minSize = NSSize(width: 560, height: 480)
        window.setFrameAutosaveName("NiruxTokenUsage")
        super.init(window: window)

        period.selectedSegment = 1
        period.target = self
        period.action = #selector(periodChanged)
        headline.font = Theme.Font.title
        headline.textColor = Theme.Color.textPrimary
        let note = NSTextField(wrappingLabelWithString: "Counted \(UsageText.unitNote): an output token counts 5, a cache read 0.05; "
            + "Codex and Antigravity at Opus prices. Read from the agents’ transcripts on this Mac, numbers only.")
        note.font = Theme.Font.caption
        note.textColor = Theme.Color.textTertiary
        textView.isEditable = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 4)
        scroll.drawsBackground = false
        limitsStack.orientation = .vertical
        limitsStack.alignment = .leading
        limitsStack.spacing = Theme.Space.md
        let stack = NSStackView(views: [limitsStack, period, headline, chart, weekChart, tasksTable, scroll, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Theme.Space.md
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        window.contentView = content
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            chart.heightAnchor.constraint(equalToConstant: 190),
            weekChart.heightAnchor.constraint(equalToConstant: 190),
            weekChart.widthAnchor.constraint(equalTo: chart.widthAnchor),
            tasksTable.heightAnchor.constraint(equalToConstant: 170),
            tasksTable.widthAnchor.constraint(equalTo: chart.widthAnchor),
            chart.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            scroll.widthAnchor.constraint(equalTo: chart.widthAnchor),
            note.widthAnchor.constraint(equalTo: chart.widthAnchor)
        ])
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// `limits` as the title bar reads them; `weekReadings`: Claude's weekly
    /// limit over the week, which turns its days into points.
    func update(report: UsageReport?, names: UsageNames, limits: [QuotaLimit] = [], weekReadings: [QuotaReading] = []) {
        self.report = report
        self.names = names
        self.limits = limits
        self.weekReadings = weekReadings
        render()
    }

    @objc private func periodChanged() { render() }

    private func render() {
        guard let report else {
            headline.stringValue = "Reading the agents’ transcripts…"
            chart.days = []
            textView.string = ""
            return
        }
        let shown = period.selectedSegment == 0 ? report.day : report.week
        headline.stringValue = UsageReportText.headline(shown)
        let starts = report.days.map(\.start)
        let week = UsageWeek(rise: QuotaCalibration.dailyRise(weekReadings, dayStarts: starts), dayTasks: report.claudeDayTasks)
        weekChart.show(week, dayStarts: starts, names: names.tasks.mapValues(\.title))
        weekChart.isHidden = period.selectedSegment == 0 || week == nil
        chart.isHidden = period.selectedSegment == 0 || week != nil
        chart.days = report.days
        tasksTable.show(UsageReportText.tableRows(shown, names: names, week: period.selectedSegment == 0 ? nil : week, dayTasks: report.claudeDayTasks))
        limitsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let width = (window?.contentLayoutRect.width ?? 640) - 40
        for limit in limits.sorted(by: { ($0.agent == .claude ? 0 : 1, $0.length) < ($1.agent == .claude ? 0 : 1, $1.length) }) {
            limitsStack.addArrangedSubview(QuotaPopoverViewController.limitRow(limit, now: report.generatedAt, calendar: .current, width: width))
        }
        limitsStack.isHidden = limits.isEmpty
        textView.textStorage?.setAttributedString(Self.text(UsageReportText.sections(shown, names: names)))
    }

    private static func text(_ sections: [UsageReportText.Section]) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [260, 310, 350, 415].map { NSTextTab(textAlignment: .left, location: $0) }
        paragraph.lineBreakMode = .byTruncatingTail
        let body: [NSAttributedString.Key: Any] = [
            .font: Theme.Font.captionDigits, .foregroundColor: Theme.Color.textSecondary, .paragraphStyle: paragraph
        ]
        let heading: [NSAttributedString.Key: Any] = [.font: Theme.Font.captionEmphasized, .foregroundColor: Theme.Color.textPrimary]
        let text = NSMutableAttributedString()
        for (index, section) in sections.enumerated() {
            text.append(NSAttributedString(string: (index == 0 ? "" : "\n") + section.title + "\n", attributes: heading))
            for row in section.rows {
                text.append(NSAttributedString(string: row.joined(separator: "\t") + "\n", attributes: body))
            }
        }
        return text
    }
}

/// The week day by day: a bar per day, its segments by source, in the
/// validated categorical order (dark steps), 2 pt apart; the legend above,
/// each day's total over its bar, its split in the tooltip.
final class UsageDaysChart: NSView, NSViewToolTipOwner {
    static let colors = Dictionary(uniqueKeysWithValues: zip(UsageReport.Source.allCases, Theme.Color.chartSeries))
    private static let legendHeight: CGFloat = 22
    private static let labelHeight: CGFloat = 16
    private static let gap: CGFloat = 2
    private static let radius = Theme.Radius.chartBar

    var days: [UsageReport.Day] = [] {
        didSet {
            guard days != oldValue else { return }
            needsDisplay = true
            updateToolTips()
            setAccessibilityLabel("Tokens per day: " + days.map { Self.dayName($0.start) + " " + UsageText.tokens(Self.total($0)) }
                .joined(separator: ", "))
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateToolTips()
    }

    private static func total(_ day: UsageReport.Day) -> Double { day.sources.values.reduce(0, +) }

    private static func dayName(_ start: TimeInterval) -> String {
        Date(timeIntervalSince1970: start).formatted(.dateTime.weekday(.abbreviated).day())
    }

    /// Each day's column, full height: the hover target is wider than its bar.
    private func columns() -> [NSRect] {
        guard !days.isEmpty else { return [] }
        let width = bounds.width / CGFloat(days.count)
        return days.indices.map { NSRect(x: CGFloat($0) * width, y: 0, width: width, height: bounds.height - Self.legendHeight) }
    }

    private func updateToolTips() {
        removeAllToolTips()
        for column in columns() { addToolTip(column, owner: self, userData: nil) }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        guard let index = columns().firstIndex(where: { $0.contains(point) }) else { return "" }
        let day = days[index]
        let parts = UsageReport.Source.allCases.compactMap { source in
            day.sources[source].map { "\(UsageReportText.name(of: source)): \(UsageText.tokens($0))" }
        }
        return ([Self.dayName(day.start) + ": " + UsageText.tokens(Self.total(day))] + parts).joined(separator: "\n")
    }

    override func draw(_ dirtyRect: NSRect) {
        drawLegend()
        let peak = days.map(Self.total).max() ?? 0
        let labelFont = Theme.Font.captionDigits
        let ink: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: Theme.Color.textSecondary]
        let plotHeight = bounds.height - Self.legendHeight - Self.labelHeight * 2
        for (column, day) in zip(columns(), days) {
            let barWidth = min(36, column.width * 0.5)
            let x = column.midX - barWidth / 2
            var y = Self.labelHeight
            let total = Self.total(day)
            let barHeight = peak > 0 ? plotHeight * CGFloat(total / peak) : 0
            NSGraphicsContext.saveGraphicsState()
            // Rounded at the top only: the bar stands on its baseline.
            NSBezierPath(
                roundedRect: NSRect(x: x, y: y - Self.radius, width: barWidth, height: barHeight + Self.radius),
                xRadius: Self.radius, yRadius: Self.radius
            ).addClip()
            for source in UsageReport.Source.allCases {
                guard let value = day.sources[source], peak > 0 else { continue }
                let height = plotHeight * CGFloat(value / peak)
                if height > Self.gap {
                    Self.colors[source]?.setFill()
                    NSRect(x: x, y: y, width: barWidth, height: height - Self.gap).fill()
                }
                y += height
            }
            NSGraphicsContext.restoreGraphicsState()
            if total > 0 {
                Self.center(UsageText.tokens(total), in: NSRect(x: column.minX, y: y, width: column.width, height: Self.labelHeight), ink)
            }
            let name = Calendar.current.isDateInToday(Date(timeIntervalSince1970: day.start)) ? "Today" : Self.dayName(day.start)
            Self.center(name, in: NSRect(x: column.minX, y: 0, width: column.width, height: Self.labelHeight), ink)
        }
    }

    private func drawLegend() {
        let font = Theme.Font.caption
        var x: CGFloat = 0
        let y = bounds.height - Self.legendHeight + 6
        let sources = UsageReport.Source.allCases.filter { source in days.contains { $0.sources[source] != nil } }
        for source in sources {
            Self.colors[source]?.setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: y + 2, width: 8, height: 8), xRadius: Theme.Radius.chartSwatch, yRadius: Theme.Radius.chartSwatch).fill()
            let text = NSAttributedString(string: UsageReportText.name(of: source), attributes: [
                .font: font, .foregroundColor: Theme.Color.textSecondary
            ])
            text.draw(at: NSPoint(x: x + 12, y: y - 1))
            x += 12 + ceil(text.size().width) + Theme.Space.md
        }
    }

    private static func center(_ string: String, in rect: NSRect, _ attributes: [NSAttributedString.Key: Any]) {
        let text = NSAttributedString(string: string, attributes: attributes)
        let size = text.size()
        text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.minY + (rect.height - size.height) / 2))
    }
}
