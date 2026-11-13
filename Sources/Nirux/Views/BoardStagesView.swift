import AppKit

/// The Board as stages, drawn (docs/design/board-stages.md, section 5):
/// the space's header with its Lead and the order switch, the stations'
/// titles, then one section per repository: its lines, a sub-task under
/// its task with an elbow, a stack of pull requests on a numbered rail,
/// the pull requests without a task folded, and "Merged today".
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
    /// A line's Merge station was clicked where that changes the queue's
    /// list: its section's id, and what the click does.
    var onOffer: ((_ section: String, BoardStages.QueueOffer) -> Void)?
    /// The link ending a line's phrase was clicked, or "Clean up" on a
    /// "Merged today" entry: its section's id, its task's line's (which
    /// an entry's has left the list by then), and the link.
    var onLink: ((_ section: String, _ line: String, BoardStages.Link) -> Void)?

    /// Where the pointer is, in the window; nil where the Board doesn't
    /// hear it move: off screen, or in an app that isn't active, whose
    /// windows don't hear the pointer leave. (The tests give their own.)
    lazy var pointerLocation: () -> NSPoint? = { [weak self] in
        guard let window = self?.window, window.isVisible, NSApp.isActive else { return nil }
        return window.mouseLocationOutsideOfEventStream
    }
    /// The line whose Merge station the pointer is on, where a click acts.
    private weak var hoveredLine: BoardStagesLineView?
    private var pointerArea: NSTrackingArea?

    private(set) var content: Content?
    /// The lines drawn, from the top, for the tests to click through.
    private(set) var lineViews: [BoardStagesLineView] = []
    /// The sections whose pull requests without a task are unfolded, and
    /// those whose "Merged today" shows every pull request. Both start
    /// folded each time the Board opens.
    private(set) var unfolded: Set<String> = []
    private(set) var unfoldedMerged: Set<String> = []

    let spaceDot = NSView()
    let nameLabel = NSTextField(labelWithString: "")
    let summaryLabel = NSTextField(labelWithString: "")
    let leadDot = NSView()
    let leadLabel = NSTextField(labelWithString: "")
    let orderSwitch = NSSegmentedControl(labels: ["Sidebar order", "By progress"], trackingMode: .selectOne, target: nil, action: nil)
    /// "Task", "Now", "Pull request": over their columns.
    let columnTitles = ["Task", "Now", "Pull request"].map { NSTextField(labelWithString: $0) }
    let stationTitles = BoardStages.Station.allCases.map { NSTextField(labelWithString: BoardStagesView.title(of: $0)) }
    private let separator = NSView()
    let scrollView = NSScrollView()
    private let documentView = BoardStagesFlippedView()
    /// What the scrolling area holds, from the top.
    private var items: [Item] = []
    private var sectionHeaders: [String: BoardStagesSectionHeaderView] = [:]
    private var foldButtons: [String: NSButton] = [:]
    private var mergedViews: [String: BoardStagesMergedView] = [:]
    /// The stacks' titles, from the top.
    private var captions: [NSTextField] = []

    private enum Item {
        case sectionHeader(BoardStagesSectionHeaderView)
        case line(BoardStagesLineView)
        case caption(NSTextField)
        case fold(NSButton)
        case merged(BoardStagesMergedView)

        var view: NSView {
            switch self {
            case .sectionHeader(let view): return view
            case .line(let view): return view
            case .caption(let view): return view
            case .fold(let view): return view
            case .merged(let view): return view
            }
        }
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
        for label in [summaryLabel, leadLabel] {
            label.font = Theme.Font.body
            label.textColor = Theme.Color.textTertiary
        }
        for label in [nameLabel, summaryLabel, leadLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.allowsExpansionToolTips = true
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
        // As the sidebar: a scroller that takes no width, so the lines
        // keep the titles' columns whatever the Mac's setting.
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = documentView
        // The lines move under a still pointer when the list scrolls, and
        // an app that isn't active doesn't hear the pointer leave.
        scrollView.contentView.postsBoundsChangedNotifications = true
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(listScrolled), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        for name in [NSApplication.didResignActiveNotification, NSApplication.didBecomeActiveNotification] {
            center.addObserver(self, selector: #selector(refreshHover), name: name, object: nil)
        }
        ([spaceDot, nameLabel, summaryLabel, leadDot, leadLabel, orderSwitch, separator, scrollView] + columnTitles + stationTitles)
            .forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Content

    /// Draws `content`. A refresh that only moves the clock touches the
    /// times that changed and nothing else; one that changes lines updates
    /// them where they are, so what is listed keeps its view (a press in
    /// flight, the keyboard, a tooltip).
    func show(_ content: Content) {
        guard content != self.content else { return }
        let previous = self.content
        self.content = content
        guard content.header != previous?.header || content.order != previous?.order || content.sections != previous?.sections else {
            return showTimes()
        }
        spaceDot.layer?.backgroundColor = content.header.color.cgColor
        nameLabel.stringValue = content.header.name
        summaryLabel.stringValue = content.header.summary
        leadDot.layer?.backgroundColor = content.header.lead.map { Self.color(of: $0.state).cgColor }
        leadLabel.stringValue = content.header.lead?.text ?? ""
        // Where the Lead's line has no room, its dot says it.
        leadDot.toolTip = content.header.lead?.text
        orderSwitch.selectedSegment = content.order == .sidebar ? 0 : 1
        if content.sections != previous?.sections { buildItems() }
        showTimes()
        layoutContent()
    }

    private func showTimes() {
        guard let now = content?.now else { return }
        lineViews.forEach { $0.showTime(now: now) }
    }

    /// The scrolling area's items for the sections shown. What is still
    /// listed keeps its view from one content to the next: a line by its
    /// id, a repository's header, fold and "Merged today" by its section's,
    /// a stack's title by its place.
    private func buildItems() {
        let sections = content?.sections ?? []
        let ids = Set(sections.map(\.id))
        unfolded.formIntersection(ids)
        unfoldedMerged.formIntersection(ids)
        // What is kept is taken out of these: a view is listed once.
        var keptLines = Dictionary(lineViews.map { ($0.line.id, $0) }, uniquingKeysWith: { first, _ in first })
        var keptHeaders = sectionHeaders
        var keptFolds = foldButtons
        var keptMerged = mergedViews
        var keptCaptions = captions[...]
        var items: [Item] = []
        lineViews = []
        sectionHeaders = [:]
        foldButtons = [:]
        mergedViews = [:]
        captions = []
        // The section being listed.
        var sectionID = ""
        func add(_ line: BoardStages.Line, link: BoardStagesLineView.Link) {
            let view: BoardStagesLineView
            if let kept = keptLines.removeValue(forKey: line.id) {
                kept.update(line, link: link)
                view = kept
            } else {
                let made = BoardStagesLineView(line, link: link)
                made.onClick = { [weak self, weak made] in
                    guard let self, let made else { return }
                    self.onOpen?(made.line.id)
                }
                view = made
            }
            // The line's section may be another one than when its view was made.
            let section = sectionID
            view.onPointer = { [weak self] location in self?.hover(at: location) }
            view.onOffer = { [weak self] offer in self?.onOffer?(section, offer) }
            view.onLink = { [weak self, weak view] link in
                guard let self, let view else { return }
                self.onLink?(section, view.line.id, link)
            }
            lineViews.append(view)
            items.append(.line(view))
        }
        func add(_ unit: BoardStages.Unit) {
            switch unit {
            case .task(let task, let subtasks):
                add(task, link: subtasks.isEmpty ? .none : .head)
                for (index, subtask) in subtasks.enumerated() {
                    add(subtask, link: .subtask(isLast: index == subtasks.count - 1))
                }
            case .stack(let title, let stacked):
                let caption = keptCaptions.popFirst() ?? Self.makeCaption()
                caption.stringValue = title
                captions.append(caption)
                items.append(.caption(caption))
                for (index, line) in stacked.enumerated() {
                    add(line, link: .stack(number: index + 1, isLast: index == stacked.count - 1))
                }
            }
        }
        for section in sections {
            let id = section.id
            sectionID = id
            let header = keptHeaders.removeValue(forKey: id) ?? BoardStagesSectionHeaderView()
            header.show(title: section.title, detail: section.detail, status: section.status)
            sectionHeaders[id] = header
            items.append(.sectionHeader(header))
            section.lines.units.forEach(add)
            let withoutTask = section.lines.withoutTask
            if !withoutTask.isEmpty {
                let isUnfolded = unfolded.contains(id)
                let count = withoutTask.reduce(0) { $0 + $1.lines.count }
                let fold = keptFolds.removeValue(forKey: id) ?? makeFold(section: id)
                fold.attributedTitle = NSAttributedString(
                    string: "\(isUnfolded ? "▾" : "▸") Pull requests without a task · \(count)",
                    attributes: [.font: Theme.Font.caption, .foregroundColor: Theme.Color.textTertiary]
                )
                fold.setAccessibilityLabel("Pull requests without a task, \(count)")
                fold.setAccessibilityExpanded(isUnfolded)
                foldButtons[id] = fold
                items.append(.fold(fold))
                if isUnfolded { withoutTask.forEach(add) }
            }
            if !section.lines.merged.isEmpty {
                let merged = keptMerged.removeValue(forKey: id) ?? BoardStagesMergedView()
                merged.show(section.lines.merged, now: content?.now ?? 0, isUnfolded: unfoldedMerged.contains(id))
                merged.onOpen = { [weak self] line in self?.onOpen?(line) }
                merged.onCleanUp = { [weak self] line in self?.onLink?(id, line, .cleanUp) }
                merged.onUnfold = { [weak self] in self?.unfoldMerged(section: id) }
                mergedViews[id] = merged
                items.append(.merged(merged))
            }
        }
        // In the items' order, as VoiceOver reads them; what stays is moved,
        // not taken out and put back.
        documentView.subviews = items.map(\.view)
        self.items = items
    }

    private static func makeCaption() -> NSTextField {
        let caption = NSTextField(labelWithString: "")
        caption.font = Theme.Font.caption
        caption.textColor = Theme.Color.textTertiary
        caption.lineBreakMode = .byTruncatingTail
        caption.allowsExpansionToolTips = true
        return caption
    }

    private func makeFold(section id: String) -> NSButton {
        let fold = NSButton(title: "", target: self, action: #selector(foldClicked(_:)))
        fold.identifier = NSUserInterfaceItemIdentifier(id)
        fold.isBordered = false
        fold.alignment = .left
        return fold
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
        /// The rail at ease, and tightened on a narrow Board.
        static let railWidth: CGFloat = 180
        static let compactRailWidth: CGFloat = 116
        /// A rail's first station, from its left edge; its last sits
        /// further from its right one: the queue's ring, and its title
        /// clear of the next column's.
        static let firstStation: CGFloat = 10
        static let lastStation: CGFloat = 18
        /// "#1451 · on #1450" whole.
        static let pullRequestWidth: CGFloat = 114
        static let timeWidth: CGFloat = 50
        /// The task's column: two fifths of the Board, between these.
        static let minimumTask: CGFloat = 140
        static let maximumTask: CGFloat = 280
        /// What the phrase keeps before the pull request, then the time,
        /// take their columns; and under what it isn't worth showing.
        static let minimumPhrase: CGFloat = 180
        static let shortestPhrase: CGFloat = 70
        /// The name is whole beside the order switch; a long one keeps
        /// this much.
        static let minimumName: CGFloat = 160
        /// A sub-task's or a stack line's inset, and its connector's x.
        static let inset: CGFloat = 26
        static let connectorX: CGFloat = padding + dot / 2
    }

    /// A line's columns for a width: task, rail, phrase, pull request,
    /// time.
    /// - From where a phrase shows, the task's column and the rail grow
    ///   with the Board, never by a jump: widening a column moves no rail
    ///   back.
    /// - Below about 760 pt the rail tightens, its stations closer, before
    ///   any title is cut further.
    /// - The phrase takes the rest. The pull request, then the time, show
    ///   once the phrase keeps `minimumPhrase` beside them.
    /// - A phrase under `shortestPhrase` says nothing: it goes, and the
    ///   title takes its place (below about 390 pt).
    /// - A Board too narrow for a rail beside a title (about 300 pt) keeps
    ///   each line's dot and title.
    struct Columns: Equatable {
        var task: NSRect
        /// No width when the Board is too narrow for it.
        var rail: NSRect
        /// No width when the Board is too narrow for it.
        var phrase: NSRect
        /// Nil when the Board is too narrow for it.
        var pullRequest: NSRect?
        var time: NSRect?

        init(width: CGFloat, height: CGFloat = Metrics.lineHeight) {
            let inner = max(0, width - 2 * Metrics.padding)
            let eased = (Metrics.compactRailWidth + 0.4 * (width - 600)).rounded(.down)
            let wholeRail = min(Metrics.railWidth, max(Metrics.compactRailWidth, eased))
            let showsRail = inner - wholeRail - Metrics.gap >= Metrics.minimumTask
            let railWidth = showsRail ? wholeRail : 0
            let wanted = min(Metrics.maximumTask, max(Metrics.minimumTask, (inner * 0.4).rounded(.down)))
            var taskWidth = showsRail ? wanted : inner
            var phraseWidth = max(0, inner - taskWidth - railWidth - 2 * Metrics.gap)
            if phraseWidth < Metrics.shortestPhrase {
                phraseWidth = 0
                if showsRail { taskWidth = inner - railWidth - Metrics.gap }
            }
            let showsPullRequest = phraseWidth - Metrics.pullRequestWidth - Metrics.gap >= Metrics.minimumPhrase
            if showsPullRequest { phraseWidth -= Metrics.pullRequestWidth + Metrics.gap }
            let showsTime = showsPullRequest && phraseWidth - Metrics.timeWidth - Metrics.gap >= Metrics.minimumPhrase
            if showsTime { phraseWidth -= Metrics.timeWidth + Metrics.gap }
            var x = Metrics.padding
            func next(_ width: CGFloat) -> NSRect {
                defer { x += width + Metrics.gap }
                return NSRect(x: x, y: 0, width: width, height: height)
            }
            task = next(taskWidth)
            rail = next(railWidth)
            phrase = next(phraseWidth)
            pullRequest = showsPullRequest ? next(Metrics.pullRequestWidth) : nil
            time = showsTime ? next(Metrics.timeWidth) : nil
        }

        /// Where the rail's four stations sit, from the Board's left edge;
        /// none without a rail.
        var stations: [CGFloat] {
            guard rail.width > 0 else { return [] }
            let step = (rail.width - Metrics.firstStation - Metrics.lastStation) / CGFloat(BoardStages.Station.allCases.count - 1)
            return BoardStages.Station.allCases.indices.map { (rail.minX + Metrics.firstStation + CGFloat($0) * step).rounded() }
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutContent()
    }

    private func layoutContent() {
        let width = bounds.width
        let pad = Metrics.padding
        layoutHeader(width: width)

        // The columns' titles, each station's over its place on the rails.
        let columns = Columns(width: width)
        let titlesY = Metrics.headerHeight + 6
        for (title, frame) in zip(columnTitles, [columns.task, columns.phrase, columns.pullRequest]) {
            title.isHidden = (frame?.width ?? 0) < 30
            title.frame = NSRect(x: frame?.minX ?? 0, y: titlesY, width: frame?.width ?? 0, height: 14)
        }
        // On a tightened rail only its two ends are named: the four
        // titles would run into each other.
        let stations = columns.stations
        let isTight = stations.count > 1 && stations[1] - stations[0] < 50
        for (index, title) in stationTitles.enumerated() {
            guard index < stations.count else {
                title.isHidden = true
                continue
            }
            let titleWidth = ColumnHeaderView.textWidth(title)
            title.isHidden = isTight && index != 0 && index != stationTitles.count - 1
            title.frame = NSRect(x: (stations[index] - titleWidth / 2).rounded(), y: titlesY, width: titleWidth, height: 14)
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
        refreshHover()
    }

    /// The space: its colour and name first, then at the right the order
    /// switch, before it the Lead, and what the space holds in what is
    /// left. On a narrow Board they give way in this order: the summary,
    /// the Lead's line, the order switch; the name is the last to (a long
    /// one keeps `minimumName` beside the switch). The Lead's dot keeps
    /// its place: its state is never hidden.
    private func layoutHeader(width: CGFloat) {
        let pad = Metrics.padding
        let midY = Metrics.headerHeight / 2
        spaceDot.frame = NSRect(x: pad, y: midY - 5, width: 10, height: 10)
        let nameX = spaceDot.frame.maxX + 8
        let hasLead = content?.header.lead != nil
        let dotRoom = hasLead ? Metrics.dot + 12 : 0
        var right = width - pad
        let switchWidth = ceil(orderSwitch.fittingSize.width)
        let wholeName = ColumnHeaderView.textWidth(nameLabel)
        orderSwitch.isHidden = right - switchWidth - 12 - dotRoom - nameX < min(wholeName, Metrics.minimumName)
        if !orderSwitch.isHidden {
            orderSwitch.frame = NSRect(x: right - switchWidth, y: midY - 11, width: switchWidth, height: 22)
            right = orderSwitch.frame.minX - 12
        }
        let nameWidth = min(wholeName, max(0, right - dotRoom - nameX))
        nameLabel.frame = NSRect(x: nameX, y: midY - 10, width: nameWidth, height: 20)

        let free = right - nameLabel.frame.maxX - 12
        let wholeLead = ColumnHeaderView.textWidth(leadLabel)
        let leadWidth = min(wholeLead, free - Metrics.dot - 8)
        // Whole, or 60 pt of it at least.
        let showsLeadLine = hasLead && !orderSwitch.isHidden && leadWidth >= min(wholeLead, 60)
        leadLabel.isHidden = !showsLeadLine
        leadDot.isHidden = !hasLead
        if showsLeadLine {
            leadLabel.frame = NSRect(x: right - leadWidth, y: midY - 8, width: leadWidth, height: 16)
            right = leadLabel.frame.minX - 8
        }
        if !leadDot.isHidden {
            leadDot.frame = NSRect(x: right - Metrics.dot, y: midY - Metrics.dot / 2, width: Metrics.dot, height: Metrics.dot)
            right = leadDot.frame.minX - 12
        }
        // What the space holds, where 60 pt are left for it: never beside
        // a Lead's line that is cut, nor beside its dot alone.
        let summaryX = nameLabel.frame.maxX + 12
        summaryLabel.isHidden = orderSwitch.isHidden || right - summaryX < 60
        summaryLabel.frame = NSRect(x: summaryX, y: midY - 8, width: max(0, right - summaryX), height: 16)
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

    /// The Board's time column: "now", "12 min", "3 h", "2 d".
    nonisolated static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 1 { return "now" }
        if minutes < 60 { return "\(minutes) min" }
        return minutes < 24 * 60 ? "\(minutes / 60) h" : "\(minutes / (24 * 60)) d"
    }

    // MARK: - The pointer

    /// One area for the Board, not one a line: a line moves under a
    /// still pointer (a new order, a scroll, a resize), which no event of
    /// its own says. The Merge station under the pointer says what a
    /// click does, where one acts.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if pointerArea == nil {
            let area = NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect], owner: self
            )
            addTrackingArea(area)
            pointerArea = area
        }
        refreshHover()
    }

    override func mouseEntered(with event: NSEvent) { hover(at: event.locationInWindow) }
    override func mouseMoved(with event: NSEvent) { hover(at: event.locationInWindow) }
    /// Whoever's area the pointer left, the Board's or one inside it,
    /// which passed the event on: where it is now says what is lit.
    override func mouseExited(with event: NSEvent) { hover(at: event.locationInWindow) }

    override func viewDidHide() {
        super.viewDidHide()
        refreshHover()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        refreshHover()
    }

    /// The pointer is at `location` in the window, or nowhere the Board
    /// hears: the one Merge station under it is lit, among the lines in
    /// sight.
    func hover(at location: NSPoint?) {
        var line: BoardStagesLineView?
        if let location, scrollView.frame.contains(convert(location, from: nil)) {
            line = lineViews.first { $0.actsOnStation(at: $0.convert(location, from: nil)) }
        }
        guard line !== hoveredLine else { return }
        hoveredLine?.isStationHovered = false
        line?.isStationHovered = true
        hoveredLine = line
    }

    /// The hover, from where the pointer is now; none on a Board that
    /// doesn't show.
    @objc private func refreshHover() {
        hover(at: isHiddenOrHasHiddenAncestor ? nil : pointerLocation())
    }

    /// The lines moved under the pointer, and under their hands.
    @objc private func listScrolled() {
        window?.invalidateCursorRects(for: documentView)
        refreshHover()
    }

    // MARK: - Clicks

    @objc private func orderChosen() {
        let asked: BoardStages.Order = orderSwitch.selectedSegment == 0 ? .sidebar : .progress
        // The switch shows the content's order: it moves once the owner
        // shows the order asked.
        orderSwitch.selectedSegment = content?.order == .progress ? 1 : 0
        onOrder?(asked)
    }

    @objc private func foldClicked(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        if unfolded.remove(id) == nil { unfolded.insert(id) }
        rebuild()
    }

    private func unfoldMerged(section id: String) {
        unfoldedMerged.insert(id)
        rebuild()
    }

    private func rebuild() {
        buildItems()
        showTimes()
        layoutContent()
    }

    /// The fold of a section's pull requests without a task, when it has some.
    func foldButton(section id: String) -> NSButton? { foldButtons[id] }

    /// A section's "Merged today", when it has one.
    func mergedView(section id: String) -> BoardStagesMergedView? { mergedViews[id] }

    /// A section's header, while the section is shown.
    func sectionHeader(section id: String) -> BoardStagesSectionHeaderView? { sectionHeaders[id] }
}

/// The scrolling area: its lines run from the top.
final class BoardStagesFlippedView: NSView {
    override var isFlipped: Bool { true }
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

    init() {
        super.init(frame: .zero)
        titleLabel.font = Theme.Font.bodyEmphasized
        titleLabel.textColor = Theme.Color.textPrimary
        detailLabel.font = Theme.Font.mono
        detailLabel.textColor = Theme.Color.textTertiary
        for label in [titleLabel, detailLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.allowsExpansionToolTips = true
        }
        // The Board's text stays still: no breathing dot here.
        pill.animates = false
        [titleLabel, detailLabel, pill].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(title: String, detail: String?, status: ColumnHeaderView.Status?) {
        titleLabel.stringValue = title
        detailLabel.stringValue = detail ?? ""
        if pill.status != status { pill.status = status }
        pill.isHidden = status == nil
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let pad = BoardStagesView.Metrics.padding
        let baseline = bounds.height - 22
        var right = bounds.width - pad
        if !pill.isHidden {
            let width = min(pill.idealWidth, (bounds.width * 0.4).rounded(.down))
            pill.frame = NSRect(x: right - width, y: baseline - 1, width: width, height: ColumnStatusPill.height)
            right = pill.frame.minX - 10
        }
        let titleWidth = min(ColumnHeaderView.textWidth(titleLabel), max(0, ((right - pad) * 0.6).rounded(.down)))
        titleLabel.frame = NSRect(x: pad, y: baseline, width: titleWidth, height: 16)
        let detailX = titleLabel.frame.maxX + 10
        detailLabel.frame = NSRect(x: detailX, y: baseline + 1, width: max(0, right - detailX), height: 15)
    }
}
