import AppKit

/// The Board as stages, drawn (docs/design/board-stages.md): the space's
/// header with its Lead and the order switch, the stations' titles, then
/// one section per repository: its lines, a sub-task under its task with
/// an elbow, a stack of pull requests on a numbered rail, the pull
/// requests without a task folded, and "Merged today".
///
/// It only draws what `BoardStages.section` decided, and says what was
/// clicked. Nothing shows it yet: the Board's column still holds the table.
@MainActor
final class BoardStagesView: NSView {
    struct Lead: Equatable {
        var state: BoardStages.State
        /// "Lead · reviewing #438".
        var text: String
    }

    struct Header: Equatable {
        var name: String
        var color: NSColor
        /// "2 repositories · 14 tasks".
        var summary: String
        var lead: Lead?
    }

    /// One repository of the space, or its tasks without one.
    struct Section: Equatable {
        let id: String
        /// "nirux"; "No repository".
        var title: String
        /// `owner/name`, in the machine font; or what the section holds.
        var detail: String?
        /// The post-merge run, or what went wrong reading the repository.
        var status: ColumnHeaderView.Status?
        var lines: BoardStages.Section
    }

    struct Content: Equatable {
        var header: Header
        var order: BoardStages.Order
        var sections: [Section]
        /// The wall clock the lines' times count to.
        var now: TimeInterval
    }

    /// The order switch was pressed.
    var onOrder: ((BoardStages.Order) -> Void)?
    /// A line was clicked, or a "Merged today" entry with a task: its id.
    var onOpen: ((String) -> Void)?

    private(set) var content: Content?
    /// The lines drawn, from the top, for the tests to click through.
    private(set) var lineViews: [BoardStagesLineView] = []
    /// The sections whose pull requests without a task are unfolded. They
    /// start folded each time the Board opens.
    private(set) var unfolded: Set<String> = []

    let spaceDot = NSView()
    let nameLabel = NSTextField(labelWithString: "")
    let summaryLabel = NSTextField(labelWithString: "")
    let leadDot = NSView()
    let leadLabel = NSTextField(labelWithString: "")
    let orderSwitch = NSSegmentedControl(labels: ["Sidebar order", "By progress"], trackingMode: .selectOne, target: nil, action: nil)
    private let columnTitles = ["Task", "Now", "Pull request"].map { NSTextField(labelWithString: $0) }
    private let stationTitles = BoardStages.Station.allCases.map { NSTextField(labelWithString: BoardStagesView.title(of: $0)) }
    private let separator = NSView()
    private let scrollView = NSScrollView()
    private let documentView = FlippedView()
    /// What the scrolling area holds, from the top.
    private var items: [Item] = []

    private enum Item {
        case sectionHeader(BoardStagesSectionHeaderView)
        case line(BoardStagesLineView)
        case caption(NSTextField)
        case fold(NSButton)
        case merged(BoardStagesMergedView)
    }

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Theme.Color.canvas.cgColor
        appearance = Theme.appearance

        for dot in [spaceDot, leadDot] { dot.wantsLayer = true }
        spaceDot.layer?.cornerRadius = 3
        leadDot.layer?.cornerRadius = Metrics.dot / 2
        nameLabel.font = Theme.Font.display
        nameLabel.textColor = Theme.Color.textPrimary
        nameLabel.lineBreakMode = .byTruncatingTail
        for label in [summaryLabel, leadLabel] {
            label.font = Theme.Font.body
            label.textColor = Theme.Color.textTertiary
            label.lineBreakMode = .byTruncatingTail
        }
        orderSwitch.controlSize = .small
        orderSwitch.font = Theme.Font.caption
        orderSwitch.segmentStyle = .rounded
        orderSwitch.target = self
        orderSwitch.action = #selector(orderChosen)
        orderSwitch.setAccessibilityLabel("Order")
        for title in columnTitles + stationTitles {
            title.font = Theme.Font.label
            title.textColor = Theme.Color.textTertiary
        }
        separator.wantsLayer = true
        separator.layer?.backgroundColor = Theme.Color.line.cgColor
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = documentView
        ([spaceDot, nameLabel, summaryLabel, leadDot, leadLabel, orderSwitch, separator, scrollView] + columnTitles + stationTitles)
            .forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Content

    /// Draws `content`. The lines are built again only when more than the
    /// clock changed.
    func show(_ content: Content) {
        guard content != self.content else { return }
        let previous = self.content
        self.content = content
        spaceDot.layer?.backgroundColor = content.header.color.cgColor
        nameLabel.stringValue = content.header.name
        summaryLabel.stringValue = content.header.summary
        leadDot.isHidden = content.header.lead == nil
        leadLabel.isHidden = content.header.lead == nil
        leadDot.layer?.backgroundColor = content.header.lead.map { Self.color(of: $0.state).cgColor }
        leadLabel.stringValue = content.header.lead?.text ?? ""
        orderSwitch.selectedSegment = content.order == .sidebar ? 0 : 1
        if content.sections != previous?.sections {
            buildItems()
        }
        lineViews.forEach { $0.showTime(now: content.now) }
        layoutContent()
    }

    private func buildItems() {
        documentView.subviews.forEach { $0.removeFromSuperview() }
        items = []
        lineViews = []
        for section in content?.sections ?? [] {
            let header = BoardStagesSectionHeaderView(title: section.title, detail: section.detail, status: section.status)
            items.append(.sectionHeader(header))
            section.lines.units.forEach(append)
            let withoutTask = section.lines.withoutTask
            if !withoutTask.isEmpty {
                let isUnfolded = unfolded.contains(section.id)
                let count = withoutTask.reduce(0) { $0 + $1.lines.count }
                let fold = NSButton(title: "", target: self, action: #selector(foldClicked(_:)))
                fold.identifier = NSUserInterfaceItemIdentifier(section.id)
                fold.isBordered = false
                fold.alignment = .left
                fold.attributedTitle = NSAttributedString(
                    string: "\(isUnfolded ? "▾" : "▸") Pull requests without a task · \(count)",
                    attributes: [.font: Theme.Font.caption, .foregroundColor: Theme.Color.textTertiary]
                )
                fold.setAccessibilityLabel("Pull requests without a task, \(count)")
                items.append(.fold(fold))
                if isUnfolded { withoutTask.forEach(append) }
            }
            if !section.lines.merged.isEmpty {
                let merged = BoardStagesMergedView(section.lines.merged, now: content?.now ?? 0)
                merged.onOpen = { [weak self] id in self?.onOpen?(id) }
                items.append(.merged(merged))
            }
        }
        for item in items {
            switch item {
            case .sectionHeader(let view as NSView), .line(let view as NSView), .caption(let view as NSView),
                 .fold(let view as NSView), .merged(let view as NSView):
                documentView.addSubview(view)
            }
        }
    }

    private func append(_ unit: BoardStages.Unit) {
        switch unit {
        case .task(let task, let subtasks):
            add(task, link: subtasks.isEmpty ? .none : .head)
            for (index, subtask) in subtasks.enumerated() {
                add(subtask, link: .subtask(isLast: index == subtasks.count - 1))
            }
        case .stack(let title, let lines):
            let caption = NSTextField(labelWithString: title)
            caption.font = Theme.Font.caption
            caption.textColor = Theme.Color.textTertiary
            caption.lineBreakMode = .byTruncatingTail
            items.append(.caption(caption))
            for (index, line) in lines.enumerated() {
                add(line, link: .stack(number: index + 1, isLast: index == lines.count - 1))
            }
        }
    }

    private func add(_ line: BoardStages.Line, link: BoardStagesLineView.Link) {
        let view = BoardStagesLineView(line, link: link)
        view.onClick = { [weak self] in self?.onOpen?(line.id) }
        lineViews.append(view)
        items.append(.line(view))
    }

    // MARK: - Layout

    /// The sizes of the mockup the user approved.
    enum Metrics {
        static let padding: CGFloat = 18
        static let gap: CGFloat = 14
        static let lineHeight: CGFloat = 34
        static let headerHeight: CGFloat = 44
        static let titlesHeight: CGFloat = 28
        static let sectionHeaderHeight: CGFloat = 42
        static let captionHeight: CGFloat = 28
        static let dot: CGFloat = 8
        static let railWidth: CGFloat = 180
        static let pullRequestWidth: CGFloat = 84
        static let timeWidth: CGFloat = 50
        /// What the title and the phrase keep between them before a
        /// column goes.
        static let minimumText: CGFloat = 300
        /// Where a rail's four stations sit, from its left edge.
        static let stations: [CGFloat] = [10, 63, 116, 169]
        /// A sub-task's or a stack line's inset, and its connector's x.
        static let inset: CGFloat = 26
        static let connectorX: CGFloat = padding + dot / 2
    }

    /// A line's columns for a width: task, rail, phrase, pull request,
    /// time. The task and the phrase share what the others leave (1.05 to
    /// 1.2). On a narrow Board the time goes first, then the pull
    /// request: the title and the phrase are what the line is read for.
    struct Columns: Equatable {
        var task: NSRect
        var rail: NSRect
        var phrase: NSRect
        /// Nil when the Board is too narrow for it.
        var pullRequest: NSRect?
        var time: NSRect?

        init(width: CGFloat, height: CGFloat = Metrics.lineHeight) {
            var flexible = width - Metrics.railWidth - 2 * Metrics.gap - 2 * Metrics.padding
            let showsPullRequest = flexible - Metrics.pullRequestWidth - Metrics.gap >= Metrics.minimumText
            if showsPullRequest { flexible -= Metrics.pullRequestWidth + Metrics.gap }
            let showsTime = showsPullRequest && flexible - Metrics.timeWidth - Metrics.gap >= Metrics.minimumText
            if showsTime { flexible -= Metrics.timeWidth + Metrics.gap }
            flexible = max(0, flexible)
            let taskWidth = (flexible * 1.05 / 2.25).rounded(.down)
            var x = Metrics.padding
            func next(_ width: CGFloat) -> NSRect {
                defer { x += width + Metrics.gap }
                return NSRect(x: x, y: 0, width: width, height: height)
            }
            task = next(taskWidth)
            rail = next(Metrics.railWidth)
            phrase = next(flexible - taskWidth)
            pullRequest = showsPullRequest ? next(Metrics.pullRequestWidth) : nil
            time = showsTime ? next(Metrics.timeWidth) : nil
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutContent()
    }

    private func layoutContent() {
        let width = bounds.width
        let pad = Metrics.padding
        // The space: its colour and name, what it holds; at the right its
        // Lead, then the order switch.
        let midY = Metrics.headerHeight / 2
        spaceDot.frame = NSRect(x: pad, y: midY - 5, width: 10, height: 10)
        let switchWidth = ceil(orderSwitch.fittingSize.width)
        orderSwitch.frame = NSRect(x: width - pad - switchWidth, y: midY - 11, width: switchWidth, height: 22)
        var right = orderSwitch.frame.minX - 12
        if !leadLabel.isHidden {
            let leadWidth = min(leadLabel.fittingWidth, max(0, width * 0.3))
            leadLabel.frame = NSRect(x: right - leadWidth, y: midY - 8, width: leadWidth, height: 16)
            leadDot.frame = NSRect(x: leadLabel.frame.minX - 8 - Metrics.dot, y: midY - Metrics.dot / 2, width: Metrics.dot, height: Metrics.dot)
            right = leadDot.frame.minX - 12
        }
        let nameX = spaceDot.frame.maxX + 8
        let nameWidth = min(nameLabel.fittingWidth, max(0, right - nameX))
        nameLabel.frame = NSRect(x: nameX, y: midY - 10, width: nameWidth, height: 20)
        let summaryX = nameLabel.frame.maxX + 12
        summaryLabel.frame = NSRect(x: summaryX, y: midY - 8, width: max(0, right - summaryX), height: 16)

        // The columns' titles, each station's over its place on the rails.
        let columns = Columns(width: width)
        let titlesY = Metrics.headerHeight + 6
        for (title, frame) in zip(columnTitles, [columns.task, columns.phrase, columns.pullRequest]) {
            title.isHidden = frame == nil
            title.frame = NSRect(x: frame?.minX ?? 0, y: titlesY, width: frame?.width ?? 0, height: 14)
        }
        for (title, x) in zip(stationTitles, Metrics.stations) {
            let titleWidth = title.fittingWidth
            title.frame = NSRect(x: (columns.rail.minX + x - titleWidth / 2).rounded(), y: titlesY, width: titleWidth, height: 14)
        }
        let top = Metrics.headerHeight + Metrics.titlesHeight
        separator.frame = NSRect(x: 0, y: top - 1, width: width, height: 1)
        scrollView.frame = NSRect(x: 0, y: top, width: width, height: max(0, bounds.height - top))

        var y: CGFloat = 0
        for item in items {
            switch item {
            case .sectionHeader(let header):
                header.frame = NSRect(x: 0, y: y, width: width, height: Metrics.sectionHeaderHeight)
                y += Metrics.sectionHeaderHeight
            case .line(let line):
                line.frame = NSRect(x: 0, y: y, width: width, height: Metrics.lineHeight)
                y += Metrics.lineHeight
            case .caption(let caption):
                caption.frame = NSRect(x: pad, y: y + 9, width: max(0, width - 2 * pad), height: 15)
                y += Metrics.captionHeight
            case .fold(let fold):
                fold.frame = NSRect(x: pad, y: y + 7, width: max(0, width - 2 * pad), height: 18)
                y += Metrics.captionHeight
            case .merged(let merged):
                let height = merged.height(for: width)
                merged.frame = NSRect(x: 0, y: y + 10, width: width, height: height)
                y += height + 10
            }
        }
        documentView.frame = NSRect(x: 0, y: 0, width: width, height: max(scrollView.contentSize.height, y + 12))
    }

    // MARK: - Words and colours

    nonisolated static func title(of station: BoardStages.Station) -> String {
        switch station {
        case .code: return "Code"
        case .reviews: return "Reviews"
        case .checks: return "Checks"
        case .merge: return "Merge"
        }
    }

    /// A state's colour, for the line's dot and its current station.
    /// Amber is "needs you" and nothing else.
    static func color(of state: BoardStages.State) -> NSColor {
        switch state {
        case .needsYou: return Theme.Color.waiting
        case .failed: return Theme.Color.error
        case .working: return Theme.Color.working
        case .blocked: return Theme.Color.textDisabled
        case .waiting, .idle: return Theme.Color.textTertiary
        case .ready: return Theme.Color.textSecondary
        case .merged: return Theme.Color.done
        }
    }

    /// "now", "12 min", "3 h", "2 d".
    nonisolated static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 1 { return "now" }
        if minutes < 60 { return "\(minutes) min" }
        return minutes < 24 * 60 ? "\(minutes / 60) h" : "\(minutes / (24 * 60)) d"
    }

    // MARK: - Clicks

    @objc private func orderChosen() {
        onOrder?(orderSwitch.selectedSegment == 0 ? .sidebar : .progress)
    }

    @objc private func foldClicked(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        if unfolded.remove(id) == nil { unfolded.insert(id) }
        buildItems()
        if let now = content?.now { lineViews.forEach { $0.showTime(now: now) } }
        layoutContent()
    }

    /// The fold of a section's pull requests without a task, when it has some.
    func foldButton(section id: String) -> NSButton? {
        for case .fold(let button) in items where button.identifier?.rawValue == id { return button }
        return nil
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

private extension NSControl {
    /// The width its text needs, its cell's insets included (a label's
    /// intrinsic width leaves them out, and truncates).
    var fittingWidth: CGFloat { ceil(fittingSize.width) }
}

// MARK: - A line

/// One line: its dot and title, its rail, its phrase, its pull request and
/// its time. It draws the dot, the rail and what joins it to the lines
/// around it; the words are labels.
@MainActor
final class BoardStagesLineView: NSView {
    /// What joins a line to those around it.
    enum Link: Equatable {
        case none
        /// A task with sub-tasks under it.
        case head
        case subtask(isLast: Bool)
        /// A stack's pull request, by its place in merge order.
        case stack(number: Int, isLast: Bool)

        var isInset: Bool {
            switch self {
            case .none, .head: return false
            case .subtask, .stack: return true
            }
        }
    }

    let line: BoardStages.Line
    let link: Link
    let titleLabel = NSTextField(labelWithString: "")
    /// "no pull request", in place of the rail of a task without a repository.
    let noRailLabel = NSTextField(labelWithString: "no pull request")
    let phraseLabel = NSTextField(labelWithString: "")
    let pullRequestLabel = NSTextField(labelWithString: "")
    let timeLabel = NSTextField(labelWithString: "")
    var onClick: (() -> Void)?

    private typealias Metrics = BoardStagesView.Metrics

    override var isFlipped: Bool { true }

    init(_ line: BoardStages.Line, link: Link) {
        self.line = line
        self.link = link
        super.init(frame: .zero)
        titleLabel.stringValue = line.title
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = Theme.Color.textPrimary
        titleLabel.toolTip = line.title
        phraseLabel.stringValue = line.phrase.text
        phraseLabel.font = Theme.Font.body
        phraseLabel.textColor = Self.phraseColor(of: line.state)
        phraseLabel.toolTip = line.phrase.detail ?? line.phrase.text
        pullRequestLabel.stringValue = line.pullRequest
        pullRequestLabel.font = Theme.Font.mono
        pullRequestLabel.textColor = Theme.Color.textTertiary
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        timeLabel.textColor = Theme.Color.textTertiary
        timeLabel.alignment = .right
        noRailLabel.font = Theme.Font.caption
        noRailLabel.textColor = Theme.Color.textDisabled
        noRailLabel.isHidden = line.rail != nil
        for label in [titleLabel, noRailLabel, phraseLabel, pullRequestLabel, timeLabel] {
            label.lineBreakMode = .byTruncatingTail
            addSubview(label)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(Self.accessibilityLabel(of: line))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// "12 min", counted to `now`; nothing for a line without a clock.
    func showTime(now: TimeInterval) {
        timeLabel.stringValue = line.since.map { BoardStagesView.duration(now - $0) } ?? ""
    }

    /// Amber and red say the phrase needs a look; the rest stays grey.
    static func phraseColor(of state: BoardStages.State) -> NSColor {
        switch state {
        case .needsYou: return Theme.Color.waiting
        case .failed: return Theme.Color.error
        case .working, .blocked, .waiting, .ready, .merged, .idle: return Theme.Color.textTertiary
        }
    }

    /// "Agent loop hint: Ready · reviews done, checks green, #308."
    nonisolated static func accessibilityLabel(of line: BoardStages.Line) -> String {
        let station = line.rail == nil ? nil : "at \(BoardStagesView.title(of: line.station))"
        return ([line.title, station, line.phrase.text, line.pullRequest.isEmpty ? nil : line.pullRequest] as [String?])
            .compactMap { $0 }.joined(separator: ", ")
    }

    // MARK: Layout

    /// Where the dot's centre is: at the line's edge, or inset under a
    /// task or on a stack's rail.
    var dotCenter: NSPoint {
        NSPoint(x: Metrics.connectorX + (link.isInset ? Metrics.inset : 0), y: bounds.midY)
    }

    override func layout() {
        super.layout()
        let columns = BoardStagesView.Columns(width: bounds.width, height: bounds.height)
        let titleX = dotCenter.x + Metrics.dot / 2 + 10
        titleLabel.frame = NSRect(x: titleX, y: 8, width: max(0, columns.task.maxX - titleX), height: 18)
        noRailLabel.frame = NSRect(x: columns.rail.minX, y: 10, width: columns.rail.width, height: 15)
        phraseLabel.frame = NSRect(x: columns.phrase.minX, y: 9, width: columns.phrase.width, height: 16)
        for (label, frame) in [(pullRequestLabel, columns.pullRequest), (timeLabel, columns.time)] {
            label.isHidden = frame == nil
            label.frame = NSRect(x: frame?.minX ?? 0, y: 10, width: frame?.width ?? 0, height: 15)
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        drawConnectors()
        Self.fill(circle: dotCenter, radius: Metrics.dot / 2, BoardStagesView.color(of: line.state))
        if let rail = line.rail {
            let columns = BoardStagesView.Columns(width: bounds.width, height: bounds.height)
            Self.draw(rail, state: line.state, at: NSPoint(x: columns.rail.minX, y: bounds.midY))
        }
    }

    /// The elbow that joins a sub-task to its task, the line a task sends
    /// down to its sub-tasks, a stack's numbered rail.
    private func drawConnectors() {
        let x = Metrics.connectorX
        let midY = bounds.midY
        let path = NSBezierPath()
        path.lineWidth = 1
        switch link {
        case .none:
            return
        case .head:
            path.move(to: NSPoint(x: x, y: midY + Metrics.dot))
            path.line(to: NSPoint(x: x, y: bounds.maxY))
        case .subtask(let isLast):
            // Down from the task, then round the corner to the sub-task.
            path.move(to: NSPoint(x: x, y: 0))
            path.line(to: NSPoint(x: x, y: midY - 6))
            path.curve(to: NSPoint(x: x + 6, y: midY), controlPoint1: NSPoint(x: x, y: midY), controlPoint2: NSPoint(x: x, y: midY))
            path.line(to: NSPoint(x: x + 16, y: midY))
            if !isLast {
                path.move(to: NSPoint(x: x, y: midY - 6))
                path.line(to: NSPoint(x: x, y: bounds.maxY))
            }
        case .stack(let number, let isLast):
            if number > 1 {
                path.move(to: NSPoint(x: x, y: 0))
                path.line(to: NSPoint(x: x, y: midY - 8))
            }
            if !isLast {
                path.move(to: NSPoint(x: x, y: midY + 8))
                path.line(to: NSPoint(x: x, y: bounds.maxY))
            }
        }
        Theme.Color.textDisabled.setStroke()
        path.stroke()
        if case .stack(let number, _) = link {
            Self.draw(number: number, at: NSPoint(x: x, y: midY), radius: 8, ring: Theme.Color.textDisabled, text: Theme.Color.textSecondary)
        }
    }

    /// A rail: its segments, solid up to the current station and dotted
    /// after; a filled dot for a station done, a larger one in the state's
    /// colour for the current one, a hollow one ahead, nothing where
    /// Reviews is skipped; the queue's number on Merge.
    static func draw(_ rail: BoardStages.Rail, state: BoardStages.State, at origin: NSPoint) {
        let stations = Metrics.stations
        let current = rail.marks.firstIndex(of: .current) ?? rail.marks.count
        for index in 0..<(stations.count - 1) {
            let segment = NSBezierPath()
            segment.move(to: NSPoint(x: origin.x + stations[index] + 7, y: origin.y))
            segment.line(to: NSPoint(x: origin.x + stations[index + 1] - 7, y: origin.y))
            segment.lineWidth = 1.5
            segment.lineCapStyle = .round
            if index < current {
                Theme.Color.textTertiary.setStroke()
            } else {
                segment.setLineDash([1, 4], count: 2, phase: 0)
                Theme.Color.textDisabled.setStroke()
            }
            segment.stroke()
        }
        for (index, mark) in rail.marks.enumerated() where index < stations.count {
            let center = NSPoint(x: origin.x + stations[index], y: origin.y)
            let isMerge = index == BoardStages.Station.merge.rawValue
            if isMerge, let order = rail.queueOrder {
                let isCurrent = mark == .current
                draw(number: order, at: center, radius: 7.5, ring: isCurrent ? Theme.Color.textSecondary : Theme.Color.textDisabled,
                     text: isCurrent ? Theme.Color.textPrimary : Theme.Color.textSecondary)
                continue
            }
            switch mark {
            case .done:
                fill(circle: center, radius: 3.5, Theme.Color.textSecondary)
            case .current:
                fill(circle: center, radius: 5, BoardStagesView.color(of: state))
            case .ahead:
                let ring = NSBezierPath(ovalIn: NSRect(x: center.x - 3.5, y: center.y - 3.5, width: 7, height: 7))
                Theme.Color.canvas.setFill()
                ring.fill()
                ring.lineWidth = 1.5
                Theme.Color.textDisabled.setStroke()
                ring.stroke()
            case .skipped:
                break
            }
        }
    }

    private static func fill(circle center: NSPoint, radius: CGFloat, _ color: NSColor) {
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius)).fill()
    }

    /// A number in a ring, on the canvas: a stack's place, the queue's order.
    private static func draw(number: Int, at center: NSPoint, radius: CGFloat, ring: NSColor, text: NSColor) {
        let circle = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius))
        Theme.Color.canvas.setFill()
        circle.fill()
        circle.lineWidth = 1
        ring.setStroke()
        circle.stroke()
        let string = NSAttributedString(string: "\(number)", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold), .foregroundColor: text
        ])
        let size = string.size()
        string.draw(at: NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2))
    }

    // MARK: Clicks

    /// The whole line is one target: its words don't take the mouse.
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func mouseDown(with event: NSEvent) {
        // The click is the mouse going up on the line it went down on.
    }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }
}

// MARK: - A repository's header

/// A section's header: the repository's name, `owner/name`, and its
/// post-merge run's pill at the right.
@MainActor
final class BoardStagesSectionHeaderView: NSView {
    let titleLabel = NSTextField(labelWithString: "")
    let detailLabel = NSTextField(labelWithString: "")
    let pill = ColumnStatusPill()

    override var isFlipped: Bool { true }

    init(title: String, detail: String?, status: ColumnHeaderView.Status?) {
        super.init(frame: .zero)
        titleLabel.stringValue = title
        titleLabel.font = Theme.Font.bodyEmphasized
        titleLabel.textColor = Theme.Color.textPrimary
        detailLabel.stringValue = detail ?? ""
        detailLabel.font = Theme.Font.mono
        detailLabel.textColor = Theme.Color.textTertiary
        for label in [titleLabel, detailLabel] { label.lineBreakMode = .byTruncatingTail }
        pill.status = status
        pill.isHidden = status == nil
        [titleLabel, detailLabel, pill].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let pad = BoardStagesView.Metrics.padding
        let baseline = bounds.height - 22
        var right = bounds.width - pad
        if !pill.isHidden {
            let width = min(pill.idealWidth, bounds.width * 0.4)
            pill.frame = NSRect(x: right - width, y: baseline - 1, width: width, height: ColumnStatusPill.height)
            right = pill.frame.minX - 10
        }
        let titleWidth = min(titleLabel.fittingWidth, max(0, (right - pad) * 0.6))
        titleLabel.frame = NSRect(x: pad, y: baseline, width: titleWidth, height: 16)
        let detailX = titleLabel.frame.maxX + 10
        detailLabel.frame = NSRect(x: detailX, y: baseline + 1, width: max(0, right - detailX), height: 15)
    }
}

// MARK: - Merged today

/// The line closing a section: "MERGED TODAY", then each pull request
/// merged since midnight, the newest first, wrapping as the width asks.
@MainActor
final class BoardStagesMergedView: NSView {
    let caption = NSTextField(labelWithString: "")
    /// One per pull request: a button while its task is open here, else
    /// a label.
    private(set) var entries: [NSControl] = []
    var onOpen: ((String) -> Void)?
    private let merged: [BoardStages.Merged]

    override var isFlipped: Bool { true }

    init(_ merged: [BoardStages.Merged], now: TimeInterval) {
        self.merged = merged
        super.init(frame: .zero)
        caption.attributedStringValue = NSAttributedString(string: "MERGED TODAY", attributes: [
            .font: Theme.Font.label, .foregroundColor: Theme.Color.textTertiary, .kern: Theme.Font.labelKern
        ])
        addSubview(caption)
        for (index, pullRequest) in merged.enumerated() {
            let time = ProjectBoard.clockTime(Date(timeIntervalSince1970: pullRequest.mergedAt), now: Date(timeIntervalSince1970: now))
            // Amber while an agent of its task needs the user, never hidden.
            let title = NSMutableAttributedString(string: "● ", attributes: [
                .font: NSFont.systemFont(ofSize: 8), .baselineOffset: 1.5,
                .foregroundColor: pullRequest.needsYou ? Theme.Color.waiting : Theme.Color.done
            ])
            title.append(NSAttributedString(string: pullRequest.title, attributes: [
                .font: Theme.Font.body, .foregroundColor: Theme.Color.textSecondary
            ]))
            title.append(NSAttributedString(string: "  #\(pullRequest.number) · \(time)", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: Theme.Color.textTertiary
            ]))
            let entry: NSControl
            if pullRequest.lineID != nil {
                let button = NSButton(title: "", target: self, action: #selector(entryClicked(_:)))
                button.isBordered = false
                button.alignment = .left
                button.attributedTitle = title
                (button.cell as? NSButtonCell)?.lineBreakMode = .byTruncatingTail
                entry = button
            } else {
                let label = NSTextField(labelWithAttributedString: title)
                label.lineBreakMode = .byTruncatingTail
                entry = label
            }
            entry.tag = index
            entry.setAccessibilityLabel("\(pullRequest.title), #\(pullRequest.number), merged at \(time)")
            entries.append(entry)
            addSubview(entry)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Lays the entries out for `width` and says how tall that is.
    func height(for width: CGFloat) -> CGFloat {
        let pad = BoardStagesView.Metrics.padding
        caption.frame = NSRect(x: pad, y: 14, width: caption.fittingWidth, height: 13)
        var x = caption.frame.maxX + 18
        var y: CGFloat = 12
        for entry in entries {
            let entryWidth = min(entry.fittingWidth, max(0, width - 2 * pad))
            if x + entryWidth > width - pad, x > pad {
                x = pad
                y += 22
            }
            entry.frame = NSRect(x: x, y: y, width: entryWidth, height: 18)
            x += entryWidth + 18
        }
        return y + 24
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.Color.line.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

    @objc private func entryClicked(_ sender: NSButton) {
        guard let id = merged[safe: sender.tag]?.lineID else { return }
        onOpen?(id)
    }
}
