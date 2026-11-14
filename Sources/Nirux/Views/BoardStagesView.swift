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
        /// Its merge queue, as its header says it; nil without one.
        var queue: SectionQueue?
        /// Its header's menu.
        var menu: [SectionMenuItem] = []
    }

    /// A button of the queue, or why it does nothing.
    struct QueueButton: Equatable {
        var title: String
        var isEnabled = true
        var tooltip: String?
    }

    /// What a queue's words say by their colour: green while it works,
    /// red when it stopped on a problem; never amber.
    enum QueueTone: Equatable {
        case normal, working, failed
    }

    /// What a repository's header says of its merge queue, at its right.
    struct SectionQueue: Equatable {
        /// "Merging #52, 2 of 3", "3 pull requests queued"; nil at rest
        /// with nothing queued.
        var status: String?
        var tone = QueueTone.normal
        /// Why this build can't change GitHub, for the DRY RUN badge's
        /// tooltip; nil for a real queue.
        var dryRun: String?
        /// "Start… · 3", or why it can't start.
        var start: QueueButton?
        /// While the queue runs here.
        var stop: QueueButton?
    }

    /// An item of a repository header's menu.
    enum SectionMenuItem: Equatable {
        case boardSettings
        /// Focuses the main checkout's workspace, or opens a shell there.
        case openMainCheckout(path: String)

        var title: String {
            switch self {
            case .boardSettings: return "Board Settings…"
            case .openMainCheckout: return "Open Main Checkout"
            }
        }
    }

    /// A queue that runs, here or in another Nirux, pinned at the Board's
    /// foot: Stop stays in sight while the list scrolls, and nothing above
    /// moves when it comes or goes.
    struct RunningQueue: Equatable {
        /// Its section's id, or the orphan's: a repository the Board no
        /// longer has.
        let id: String
        var title: String
        /// Under the pointer: an orphan's repository, as the table says it.
        var tooltip: String?
        var status: String
        var tone = QueueTone.working
        /// Nil where another Nirux runs it.
        var stop: QueueButton?
    }

    struct Content: Equatable {
        var header: Header
        var order: BoardStages.Order
        var sections: [Section]
        /// The wall clock the lines' times count to.
        var now: TimeInterval
        var runningQueues: [RunningQueue] = []
    }

    /// The order switch was pressed.
    var onOrder: ((BoardStages.Order) -> Void)?
    /// A repository's Start… was pressed: its section's id.
    var onStart: ((String) -> Void)?
    /// Stop was pressed, in a repository's header or on its running
    /// queue's line: its id.
    var onStop: ((String) -> Void)?
    /// An item of a repository header's menu was chosen.
    var onSectionMenu: ((_ section: String, SectionMenuItem) -> Void)?
    /// A line was clicked, or a "Merged today" entry with a task: its id.
    var onOpen: ((String) -> Void)?
    /// A line's Merge station was clicked where that changes the queue's
    /// list: its section's id, and what the click does.
    var onOffer: ((_ section: String, BoardStages.QueueOffer) -> Void)?
    /// The link ending a line's phrase was clicked, or "Clean up" on a
    /// "Merged today" entry: its section's id, its task's line's (which
    /// an entry's has left the list by then), and the link.
    var onLink: ((_ section: String, _ line: String, BoardStages.Link) -> Void)?
    /// An item of a line's menu was chosen: its section's id, the line's,
    /// and the item.
    var onMenu: ((_ section: String, _ line: String, BoardStages.MenuItem) -> Void)?
    /// Open or Clean Up… was chosen on one of a section's other worktrees:
    /// the section's id and the item.
    var onWorktree: ((_ section: String, BoardStages.MenuItem) -> Void)?

    /// Where the pointer is, in the window; nil where the Board doesn't
    /// hear it move: off screen, or in an app that isn't active, whose
    /// windows don't hear the pointer leave. (The tests give their own.)
    lazy var pointerLocation: () -> NSPoint? = { [weak self] in
        guard let window = self?.window, window.isVisible, NSApp.isActive else { return nil }
        return window.mouseLocationOutsideOfEventStream
    }
    /// The line whose Merge station the pointer is on, where a click acts.
    private weak var hoveredLine: BoardStagesLineView?
    /// The pointer is over the Board: nothing on it moves.
    private(set) var isPointerInside = false
    /// The sections as drawn: the content's, or, while the pointer is
    /// over the Board, its lines where they were (`holding`).
    private var shownSections: [Section] = []
    /// Lines drawn where they were though the content has them no more:
    /// inert until the pointer leaves.
    private(set) var departed: Set<String> = []
    /// The order the switch asked for: the user's own click applies at once.
    private var askedOrder: BoardStages.Order?
    /// What is drawn is held for the pointer, not the content as it is.
    private var isHolding: Bool { shownSections != content?.sections || !departed.isEmpty }
    /// The lines are held, or the foot.
    private var isHeld: Bool { isHolding || runningQueueViews.map(\.queue) != content?.runningQueues }
    /// A pointer still that long isn't aiming: the Board settles under it.
    static let stillDelay: TimeInterval = 10
    /// The time the still pointer is counted by. (The tests give their own.)
    var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// Runs `work` after a delay, in seconds. (The tests run it when they say.)
    var after: (TimeInterval, @escaping @MainActor () -> Void) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated(work) }
    }
    /// When the pointer last moved over the Board, or was first seen
    /// there, or pressed, dragged or scrolled.
    private var pointerMovedAt = -TimeInterval.infinity
    private var isAiming: Bool { clock() - pointerMovedAt < Self.stillDelay }
    /// What a click acts on asks it whether what is under the pointer is
    /// what the pointer aimed at.
    let aim = BoardStagesAim()
    /// What is under the pointer changed while it rested: nothing there
    /// lights or acts until it moves (3 pt or more from where it rested).
    var isPointerStale: Bool { aim.isStale }
    /// Where the pointer last moved, as far as a move counts: a hand on
    /// the mouse that shakes it less than 3 pt moves nothing.
    private var movedTo: NSPoint?
    private var isStillCheckPending = false
    /// Settles the Board once the pointer left, after the event that said
    /// so. (The tests run it at once.)
    var settleLater: (@escaping @MainActor () -> Void) -> Void = { work in
        DispatchQueue.main.async { MainActor.assumeIsolated(work) }
    }
    private var pointerArea: NSTrackingArea?

    private(set) var content: Content?
    /// The lines drawn, from the top, for the tests to click through.
    private(set) var lineViews: [BoardStagesLineView] = []
    /// The sections whose pull requests without a task are unfolded, and
    /// those whose "Merged today" shows every pull request. Both start
    /// folded each time the Board opens.
    private(set) var unfolded: Set<String> = []
    /// The sections whose "Other worktrees" are unfolded: folded each time
    /// the Board opens.
    private(set) var unfoldedWorktrees: Set<String> = []
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
    let scrollView = BoardStagesScrollView()
    /// The width the lines were last laid out at: the clip's.
    private var listWidth: CGFloat = 0
    /// The Board resizes its scroll view itself, right before laying the
    /// lines out.
    private var isResizingScrollView = false
    private let documentView = BoardStagesFlippedView()
    /// What the scrolling area holds, from the top.
    private var items: [Item] = []
    private var sectionHeaders: [String: BoardStagesSectionHeaderView] = [:]
    private var foldButtons: [String: NSButton] = [:]
    private var worktreeFolds: [String: NSButton] = [:]
    /// The other worktrees unfolded, from the top.
    private(set) var worktreeViews: [BoardStagesWorktreeView] = []
    private var mergedViews: [String: BoardStagesMergedView] = [:]
    /// The stacks' titles, from the top.
    private var captions: [NSTextField] = []
    /// The running queues' lines, at the Board's foot.
    private(set) var runningQueueViews: [BoardStagesRunningQueueView] = []
    /// Queues ended while the pointer was over the Board: their lines stay,
    /// inert, until it leaves.
    private(set) var departedQueues: Set<String> = []

    private enum Item {
        case sectionHeader(BoardStagesSectionHeaderView)
        case line(BoardStagesLineView)
        case caption(NSTextField)
        case fold(NSButton)
        case worktree(BoardStagesWorktreeView)
        case merged(BoardStagesMergedView)

        var view: NSView {
            switch self {
            case .sectionHeader(let view): return view
            case .line(let view): return view
            case .caption(let view): return view
            case .fold(let view): return view
            case .worktree(let view): return view
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
        scrollView.documentView = documentView
        // Scrolled, the pointer aims at what comes under it.
        scrollView.onScroll = { [weak self] in self?.pointerMoved(to: nil) }
        aim.onUse = { [weak self] in self?.pointerUsed() }
        // The lines move under a still pointer when the list scrolls, and
        // an app that isn't active doesn't hear the pointer leave.
        scrollView.contentView.postsBoundsChangedNotifications = true
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(listScrolled), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        scrollView.contentView.postsFrameChangedNotifications = true
        center.addObserver(self, selector: #selector(clipResized), name: NSView.frameDidChangeNotification, object: scrollView.contentView)
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
        guard content.header != previous?.header || content.order != previous?.order || content.sections != previous?.sections
            || content.runningQueues != previous?.runningQueues else { return showTimes() }
        spaceDot.layer?.backgroundColor = content.header.color.cgColor
        nameLabel.stringValue = content.header.name
        summaryLabel.stringValue = content.header.summary
        leadDot.layer?.backgroundColor = content.header.lead.map { Self.color(of: $0.state).cgColor }
        leadLabel.stringValue = content.header.lead?.text ?? ""
        // Where the Lead's line has no room, its dot says it.
        leadDot.toolTip = content.header.lead?.text
        orderSwitch.selectedSegment = content.order == .sidebar ? 0 : 1
        let aimedBefore = aimed()
        let isOver = pointerIsOver(pointerLocation())
        // A pointer first seen counts as one that moved.
        if isOver, !isPointerInside { pointerMovedAt = clock() }
        // While the pointer is over the Board, a queue's line that ends stays, inert, and one that starts waits:
        // neither the foot nor the list moves.
        if isOver, isAiming, previous != nil {
            let current = Set(content.runningQueues.map(\.id))
            let gone = runningQueueViews.map(\.queue).filter { !current.contains($0.id) }.map { queue in
                RunningQueue(id: queue.id, title: queue.title, tooltip: queue.tooltip, status: queue.status, tone: .normal)
            }
            departedQueues = Set(gone.map(\.id))
            showRunningQueues(runningQueueViews.map(\.queue).compactMap { shown in
                content.runningQueues.first { $0.id == shown.id } ?? gone.first { $0.id == shown.id }
            })
        } else {
            departedQueues = []
            showRunningQueues(content.runningQueues)
        }
        if content.sections != previous?.sections || content.order != previous?.order {
            // Nothing moves under the pointer: what changed is drawn where it
            // was, and settles once the pointer leaves. An order the switch
            // asked for is the user's own click: it applies at once.
            isPointerInside = pointerIsOver(pointerLocation())
            // The order the switch asked for, now shown; a request is good for this change only.
            let isAsked = askedOrder == content.order && content.order != previous?.order
            askedOrder = nil
            if isPointerInside, isAiming, !isAsked, previous != nil {
                (shownSections, departed) = Self.holding(shownSections, in: content.sections)
            } else {
                (shownSections, departed) = (content.sections, [])
            }
            buildItems()
        }
        showTimes()
        layoutContent()
        // Under a pointer that rests, what is under it may have changed: it waits for the pointer to move.
        if isPointerInside, !isAiming {
            layoutSubtreeIfNeeded()
            goStale(ifChangedFrom: aimedBefore)
        }
        if isHeld { settleOnceStill() }
    }

    /// `sections` drawn as `shown` were: each line shown keeps its place,
    /// in its new state, or stays there, departed, when the content has it
    /// no more, its repository's included; what comes waits: a line, a
    /// repository, a merge. "Merged today" keeps its entries, in their
    /// order, in their new state.
    nonisolated static func holding(_ shown: [Section], in sections: [Section]) -> (sections: [Section], departed: Set<String>) {
        var lines: [String: BoardStages.Line] = [:]
        for section in sections {
            for line in (section.lines.units + section.lines.withoutTask).flatMap(\.lines) where lines[line.id] == nil {
                lines[line.id] = line
            }
        }
        var departed = Set<String>()
        func held(_ line: BoardStages.Line) -> BoardStages.Line {
            if let now = lines[line.id] { return now }
            departed.insert(line.id)
            return line
        }
        func held(_ unit: BoardStages.Unit) -> BoardStages.Unit {
            switch unit {
            case .task(let task, let subtasks): return .task(held(task), subtasks: subtasks.map(held))
            case .stack(let title, let stacked): return .stack(title: title, stacked.map(held))
            }
        }
        var worktrees: [String: BoardStages.OtherWorktree] = [:]
        for worktree in sections.flatMap(\.lines.otherWorktrees) where worktrees[worktree.path] == nil {
            worktrees[worktree.path] = worktree
        }
        let current = Dictionary(sections.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let result: [Section] = shown.map { section in
            let shownWorktrees = section.lines.otherWorktrees
            var section = current[section.id].map { now in
                var kept = now
                kept.lines.units = section.lines.units
                kept.lines.withoutTask = section.lines.withoutTask
                kept.lines.merged = keepingOrder(of: section.lines.merged, in: now.lines.merged)
                return kept
            } ?? {
                // A repository gone: its header says nothing it could do.
                var gone = section
                gone.queue = nil
                gone.menu = []
                return gone
            }()
            section.lines.units = section.lines.units.map(held)
            section.lines.withoutTask = section.lines.withoutTask.map(held)
            // An other worktree: as a line, by its path.
            section.lines.otherWorktrees = shownWorktrees.map { worktree in
                if let now = worktrees[worktree.path] { return now }
                departed.insert(worktree.path)
                return worktree
            }
            return section
        }
        return (result, departed)
    }

    /// The entries of `shown` still in `merged`, in their order and their
    /// new state.
    private nonisolated static func keepingOrder(of shown: [BoardStages.Merged], in merged: [BoardStages.Merged]) -> [BoardStages.Merged] {
        let byNumber = Dictionary(merged.map { ($0.number, $0) }, uniquingKeysWith: { first, _ in first })
        return shown.compactMap { byNumber[$0.number] }
    }

    /// Each running queue keeps its line, by its id; one that comes or goes
    /// changes the Board's foot only.
    private func showRunningQueues(_ queues: [RunningQueue]) {
        var kept = Dictionary(runningQueueViews.map { ($0.queue.id, $0) }, uniquingKeysWith: { first, _ in first })
        runningQueueViews = queues.map { queue in
            let view = kept.removeValue(forKey: queue.id) ?? BoardStagesRunningQueueView(queue)
            view.show(queue)
            view.alphaValue = departedQueues.contains(queue.id) ? 0.4 : 1
            view.aim = aim
            view.onStop = { [weak self] in self?.onStop?(queue.id) }
            if view.superview !== self { addSubview(view) }
            return view
        }
        kept.values.forEach { $0.removeFromSuperview() }
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
        let sections = shownSections
        let ids = Set(sections.map(\.id))
        unfolded.formIntersection(ids)
        unfoldedMerged.formIntersection(ids)
        unfoldedWorktrees.formIntersection(ids)
        // What is kept is taken out of these: a view is listed once.
        var keptLines = Dictionary(lineViews.map { ($0.line.id, $0) }, uniquingKeysWith: { first, _ in first })
        var keptHeaders = sectionHeaders
        var keptFolds = foldButtons
        var keptWorktreeFolds = worktreeFolds
        var keptWorktrees = Dictionary(worktreeViews.compactMap { view in view.worktree.map { ($0.path, view) } },
                                       uniquingKeysWith: { first, _ in first })
        var keptMerged = mergedViews
        var keptCaptions = captions[...]
        var items: [Item] = []
        lineViews = []
        sectionHeaders = [:]
        foldButtons = [:]
        worktreeFolds = [:]
        worktreeViews = []
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
            view.aim = aim
            view.onOffer = { [weak self] offer in self?.onOffer?(section, offer) }
            view.onLink = { [weak self, weak view] link in
                guard let self, let view else { return }
                self.onLink?(section, view.line.id, link)
            }
            view.onMenu = { [weak self, weak view] item in
                guard let self, let view else { return }
                self.onMenu?(section, view.line.id, item)
            }
            view.isDeparted = departed.contains(line.id)
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
            header.show(title: section.title, detail: section.detail, status: section.status, queue: section.queue, menu: section.menu)
            header.onStart = { [weak self] in self?.onStart?(id) }
            header.onStop = { [weak self] in self?.onStop?(id) }
            header.onMenu = { [weak self] item in self?.onSectionMenu?(id, item) }
            header.aim = aim
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
            let others = section.lines.otherWorktrees
            if !others.isEmpty {
                let isUnfolded = unfoldedWorktrees.contains(id)
                let fold = keptWorktreeFolds.removeValue(forKey: id) ?? makeFold(section: id, action: #selector(worktreesFoldClicked(_:)))
                fold.attributedTitle = NSAttributedString(
                    string: "\(isUnfolded ? "▾" : "▸") Other worktrees · \(others.count)",
                    attributes: [.font: Theme.Font.caption, .foregroundColor: Theme.Color.textTertiary]
                )
                fold.setAccessibilityLabel("Other worktrees, \(others.count)")
                fold.setAccessibilityExpanded(isUnfolded)
                worktreeFolds[id] = fold
                items.append(.fold(fold))
                for worktree in isUnfolded ? others : [] {
                    let view = keptWorktrees.removeValue(forKey: worktree.path) ?? BoardStagesWorktreeView()
                    view.show(worktree, isDeparted: departed.contains(worktree.path))
                    view.aim = aim
                    view.onMenu = { [weak self] item in self?.onWorktree?(id, item) }
                    worktreeViews.append(view)
                    items.append(.worktree(view))
                }
            }
            if !section.lines.merged.isEmpty {
                let merged = keptMerged.removeValue(forKey: id) ?? BoardStagesMergedView()
                merged.show(section.lines.merged, now: content?.now ?? 0, isUnfolded: unfoldedMerged.contains(id), keepsOrder: isHolding)
                merged.onOpen = { [weak self] line in self?.onOpen?(line) }
                merged.onCleanUp = { [weak self] line in self?.onLink?(id, line, .cleanUp) }
                merged.onUnfold = { [weak self] in self?.unfoldMerged(section: id) }
                merged.aim = aim
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

    private func makeFold(section id: String, action: Selector = #selector(foldClicked(_:))) -> NSButton {
        let fold = NSButton(title: "", target: self, action: action)
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
        /// A running queue's line, at the Board's foot.
        static let queueLineHeight: CGFloat = 30
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

    /// A legacy scroller came or went under lines already laid out (the
    /// Mac's "Show scroll bars" setting changed, or a mouse came): they and
    /// their titles take the width it leaves, at the next layout pass (the
    /// clip resizes while AppKit tiles).
    @objc private func clipResized() {
        if !isResizingScrollView, scrollView.contentSize.width != listWidth { needsLayout = true }
    }

    override func layout() {
        super.layout()
        if scrollView.contentSize.width != listWidth { layoutContent() }
    }

    private func layoutContent() {
        let width = bounds.width
        let pad = Metrics.padding
        layoutHeader(width: width)
        let top = Metrics.headerHeight + Metrics.titlesHeight
        separator.frame = NSRect(x: 0, y: top - 1, width: width, height: 1)
        // The running queues take the foot, as many as there is room for
        // under the header: the lines above them don't move.
        let fitting = min(runningQueueViews.count, Int(max(0, bounds.height - top) / Metrics.queueLineHeight))
        let foot = CGFloat(fitting) * Metrics.queueLineHeight
        let scrollFrame = NSRect(x: 0, y: top, width: width, height: max(0, bounds.height - top - foot))
        isResizingScrollView = true
        scrollView.frame = scrollFrame
        isResizingScrollView = false
        for (index, view) in runningQueueViews.enumerated() {
            view.isHidden = index >= fitting
            let y = bounds.height - foot + CGFloat(index) * Metrics.queueLineHeight
            view.frame = NSRect(x: 0, y: y, width: width, height: Metrics.queueLineHeight)
        }
        // What the clip shows for the lines' height: a legacy scroller sits
        // beside them, as in Finder, and the titles keep over their columns.
        listWidth = scrollView.documentWidth(frameSize: scrollFrame.size) { width in
            (items.reduce(12) { $0 + advance(of: $1, width: width) }, ())
        }.width

        // The columns' titles, each station's over its place on the rails.
        let columns = Columns(width: listWidth)
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

        var y: CGFloat = 0
        for item in items {
            switch item {
            case .sectionHeader(let header):
                header.frame = NSRect(x: 0, y: y, width: listWidth, height: Metrics.sectionHeaderHeight)
            case .line(let line):
                line.frame = NSRect(x: 0, y: y, width: listWidth, height: Metrics.lineHeight)
            case .caption(let caption):
                caption.frame = NSRect(x: pad, y: y + 9, width: max(0, listWidth - 2 * pad), height: 15)
            case .fold(let fold):
                fold.frame = NSRect(x: pad, y: y + 7, width: max(0, listWidth - 2 * pad), height: 18)
            case .worktree(let worktree):
                worktree.frame = NSRect(x: 0, y: y, width: listWidth, height: Metrics.captionHeight)
            case .merged(let merged):
                merged.frame = NSRect(x: 0, y: y + 10, width: listWidth, height: merged.height(for: listWidth))
            }
            y += advance(of: item, width: listWidth)
        }
        documentView.frame = NSRect(x: 0, y: 0, width: listWidth, height: max(scrollView.contentSize.height, y + 12))
        refreshHover()
    }

    /// How far down `item` takes the next one, at `width`.
    private func advance(of item: Item, width: CGFloat) -> CGFloat {
        switch item {
        case .sectionHeader: Metrics.sectionHeaderHeight
        case .line: Metrics.lineHeight
        case .caption, .fold, .worktree: Metrics.captionHeight
        case .merged(let merged): merged.height(for: width) + 10
        }
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

    /// The pointer came over the Board: a move. Over an area inside it
    /// (a button's, a line's), which passed the event on: as any move.
    override func mouseEntered(with event: NSEvent) {
        let isInner = event.type == .mouseEntered && event.trackingArea.map { $0 !== pointerArea } == true
        if !isInner { movedTo = nil }
        pointerMoved(to: event.locationInWindow)
    }
    override func mouseMoved(with event: NSEvent) { pointerMoved(to: event.locationInWindow) }

    /// The pointer moved, or the list scrolled under it (no place): it
    /// aims again, unless it only shook where it rested.
    private func pointerMoved(to location: NSPoint?) {
        if let location, let movedTo, hypot(location.x - movedTo.x, location.y - movedTo.y) < 3 {
            // A hand on the mouse: still resting.
            return hover(at: location)
        }
        pointerMovedAt = clock()
        if let location { movedTo = location }
        setStale(false)
        if let location { hover(at: location) } else { refreshHover() }
    }

    /// A press or a drag: the pointer is in use, though it may not move.
    private func pointerUsed() {
        pointerMovedAt = clock()
    }

    private func setStale(_ isStale: Bool) {
        guard aim.isStale != isStale else { return }
        aim.isStale = isStale
        // Hands, and a lit station, only where a click acts.
        lineViews.forEach { $0.handsChanged() }
        mergedViews.values.forEach { $0.entries.forEach { $0.handsChanged() } }
        refreshHover()
    }

    /// What is under the pointer isn't what it was when it came to rest: nothing there acts until it moves.
    private func goStale(ifChangedFrom before: String?) {
        if let now = aimed(), now != before { setStale(true) }
    }

    /// What a click where the pointer is would act on, in words to compare:
    /// a line's target, an entry's, a repository's queue, a foot line's
    /// Stop; nil where there is nothing.
    private func aimed() -> String? {
        guard !isHiddenOrHasHiddenAncestor, let location = pointerLocation(), pointerIsOver(location) else { return nil }
        let point = convert(location, from: nil)
        if let foot = runningQueueViews.first(where: { !$0.isHidden && $0.frame.contains(point) }) {
            return "queue \(foot.queue.id) \(String(describing: foot.queue.stop))"
        }
        guard scrollView.frame.contains(point) else { return nil }
        func under(_ view: NSView) -> NSPoint? {
            let local = view.convert(location, from: nil)
            return view.bounds.contains(local) && !view.isHiddenOrHasHiddenAncestor ? local : nil
        }
        if let line = lineViews.first(where: { under($0) != nil }), let local = under(line) {
            return "line \(line.line.id) \(line.target(at: local))"
        }
        // A header's words change as its queue goes: only its button counts.
        if let (id, header) = sectionHeaders.first(where: { under($0.value) != nil }), let local = under(header) {
            let button = [header.startButton, header.stopButton].first { !$0.isHidden && $0.frame.contains(local) }
            return "header \(id) \(button.map { "\($0.title) \($0.isEnabled)" } ?? "")"
        }
        if let worktree = worktreeViews.first(where: { under($0) != nil }), let local = under(worktree), let path = worktree.worktree?.path {
            let button = [worktree.openButton, worktree.cleanUpButton].first { !$0.isHidden && $0.frame.contains(local) }
            return "worktree \(path) \(button.map { "\($0.title) \($0.isEnabled)" } ?? "")"
        }
        for entry in mergedViews.values.flatMap(\.entries) {
            if let local = under(entry) { return "merged \(entry.pullRequest.number) \(entry.target(at: local))" }
        }
        return nil
    }
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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshHover()
    }

    /// The pointer is at `location` in the window, or nowhere the Board
    /// hears: the one Merge station under it is lit, among the lines in
    /// sight.
    func hover(at location: NSPoint?) {
        let inside = pointerIsOver(location)
        if inside != isPointerInside {
            isPointerInside = inside
            // The pointer left: the Board settles, once the event that said so is over.
            if inside { (pointerMovedAt, movedTo) = (clock(), location) } else { settleLater { [weak self] in self?.settle() } }
        }
        var line: BoardStagesLineView?
        if !isPointerStale, let location, scrollView.frame.contains(convert(location, from: nil)) {
            line = lineViews.first { $0.actsOnStation(at: $0.convert(location, from: nil)) }
        }
        guard line !== hoveredLine else { return }
        hoveredLine?.isStationHovered = false
        line?.isStationHovered = true
        hoveredLine = line
    }

    /// The pointer is over the part of the Board that shows (none, hidden).
    private func pointerIsOver(_ location: NSPoint?) -> Bool {
        location.map { rectInSight.contains(convert($0, from: nil)) } ?? false
    }

    /// What changed while the pointer was over the Board takes its place.
    private func settle() {
        // Back before the Board settled: it waits for the pointer again.
        guard !isPointerInside else { return isHeld ? settleOnceStill() : () }
        showContent()
    }

    /// Once the pointer has rested `stillDelay` over the Board, what waited
    /// takes its place under it, and nothing there acts until it moves:
    /// someone reading a line that long isn't aiming at it.
    private func settleOnceStill() {
        guard !isStillCheckPending else { return }
        isStillCheckPending = true
        after(max(0, pointerMovedAt + Self.stillDelay - clock())) { [weak self] in
            guard let self else { return }
            self.isStillCheckPending = false
            guard self.isPointerInside, self.isHeld else { return }
            if self.isAiming { return self.settleOnceStill() }
            let before = self.aimed()
            self.showContent()
            self.goStale(ifChangedFrom: before)
        }
    }

    /// The content as it is, where it was held.
    private func showContent() {
        guard let content else { return }
        if runningQueueViews.map(\.queue) != content.runningQueues {
            departedQueues = []
            showRunningQueues(content.runningQueues)
            layoutContent()
        }
        guard content.sections != shownSections || !departed.isEmpty else { return }
        (shownSections, departed) = (content.sections, [])
        rebuild()
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
        askedOrder = asked
        onOrder?(asked)
    }

    @objc private func foldClicked(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        if unfolded.remove(id) == nil { unfolded.insert(id) }
        rebuild()
    }

    @objc private func worktreesFoldClicked(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        if unfoldedWorktrees.remove(id) == nil { unfoldedWorktrees.insert(id) }
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

    /// The fold of a section's other worktrees, when it has some.
    func worktreesFold(section id: String) -> NSButton? { worktreeFolds[id] }

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

/// A repository's header: its name and `owner/name`, its post-merge run's
/// pill, then at its right what its merge queue does, DRY RUN, Start… · N
/// or Stop, and its menu.
@MainActor
final class BoardStagesSectionHeaderView: NSView {
    let titleLabel = NSTextField(labelWithString: "")
    let detailLabel = NSTextField(labelWithString: "")
    let pill = ColumnStatusPill()
    /// What its merge queue does: "Merging #52, 2 of 3".
    let queueLabel = NSTextField(labelWithString: "")
    /// This build can't change GitHub: every queue is a dry run.
    let dryRunBadge = NSTextField(labelWithString: "DRY RUN")
    let startButton = BoardStagesButton(title: "Start…", target: nil, action: nil)
    let stopButton = BoardStagesButton(title: "Stop", target: nil, action: nil)
    /// Start and Stop act only where the pointer aimed. (The Board says.)
    var aim = BoardStagesAim() {
        didSet { [startButton, stopButton].forEach { $0.aim = aim } }
    }
    /// "⋯": the repository's menu.
    let moreButton = NSButton(title: "", target: nil, action: nil)
    var onStart: (() -> Void)?
    var onStop: (() -> Void)?
    var onMenu: ((BoardStagesView.SectionMenuItem) -> Void)?
    /// Shows the menu under "⋯". (The tests give their own.)
    var popUp: (NSMenu, NSPoint, NSView) -> Void = { menu, location, view in
        menu.popUp(positioning: nil, at: location, in: view)
    }
    private(set) var queue: BoardStagesView.SectionQueue?
    private(set) var menuItems: [BoardStagesView.SectionMenuItem] = []

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        titleLabel.font = Theme.Font.bodyEmphasized
        titleLabel.textColor = Theme.Color.textPrimary
        detailLabel.font = Theme.Font.mono
        detailLabel.textColor = Theme.Color.textTertiary
        queueLabel.font = Theme.Font.caption
        for label in [titleLabel, detailLabel, queueLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.allowsExpansionToolTips = true
        }
        // A badge, not a colour: amber is an agent waiting for the user.
        dryRunBadge.font = .systemFont(ofSize: 9, weight: .bold)
        dryRunBadge.textColor = Theme.Color.textSecondary
        dryRunBadge.alignment = .center
        dryRunBadge.wantsLayer = true
        dryRunBadge.layer?.borderWidth = 1
        dryRunBadge.layer?.borderColor = Theme.Color.textTertiary.cgColor
        dryRunBadge.layer?.cornerRadius = 3
        for button in [startButton, stopButton] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = Theme.Font.caption
            button.target = self
        }
        startButton.action = #selector(startClicked)
        stopButton.action = #selector(stopClicked)
        moreButton.isBordered = false
        moreButton.image = NSImage(systemSymbolName: Theme.Symbol.more, accessibilityDescription: nil)
        moreButton.contentTintColor = Theme.Color.textTertiary
        moreButton.target = self
        moreButton.action = #selector(moreClicked)
        moreButton.toolTip = "Repository menu"
        // The Board's text stays still: no breathing dot here.
        pill.animates = false
        [titleLabel, detailLabel, pill, queueLabel, dryRunBadge, startButton, stopButton, moreButton].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(
        title: String, detail: String?, status: ColumnHeaderView.Status?, queue: BoardStagesView.SectionQueue? = nil,
        menu: [BoardStagesView.SectionMenuItem] = []
    ) {
        titleLabel.stringValue = title
        detailLabel.stringValue = detail ?? ""
        if pill.status != status { pill.status = status }
        pill.isHidden = status == nil
        self.queue = queue
        menuItems = menu
        moreButton.setAccessibilityLabel("\(title) menu")
        queueLabel.stringValue = queue?.status ?? ""
        queueLabel.textColor = Self.color(of: queue?.tone ?? .normal)
        dryRunBadge.toolTip = queue?.dryRun
        for (button, state) in [(startButton, queue?.start), (stopButton, queue?.stop)] {
            button.title = state?.title ?? button.title
            button.isEnabled = state?.isEnabled ?? false
            button.toolTip = state?.tooltip
            button.setAccessibilityLabel(state.map { "\($0.title) \(title)" })
        }
        needsLayout = true
    }

    /// The queue's words in their tone's colour.
    static func color(of tone: BoardStagesView.QueueTone) -> NSColor {
        switch tone {
        case .normal: return Theme.Color.textTertiary
        case .working: return Theme.Color.working
        case .failed: return Theme.Color.error
        }
    }

    override func layout() {
        super.layout()
        let pad = BoardStagesView.Metrics.padding
        let baseline = bounds.height - 22
        var right = bounds.width - pad
        // What can be done stays: its menu, Start or Stop.
        moreButton.isHidden = menuItems.isEmpty
        if !moreButton.isHidden {
            moreButton.frame = NSRect(x: right - 20, y: baseline - 2, width: 20, height: 20)
            right = moreButton.frame.minX - 6
        }
        let button = queue?.stop != nil ? stopButton : startButton
        (button === stopButton ? startButton : stopButton).isHidden = true
        button.isHidden = queue?.stop == nil && queue?.start == nil
        if !button.isHidden {
            let width = ceil(button.fittingSize.width)
            button.frame = NSRect(x: right - width, y: baseline - 3, width: width, height: 22)
            // Start and Stop take one place, the wider's: what is left of them doesn't move when one becomes the other.
            right -= max(ceil(startButton.fittingSize.width), ceil(stopButton.fittingSize.width)) + 8
        }
        // Then the name, 80 pt of it at least; then, while there is room, in
        // this order: DRY RUN, the queue's words (whole, or cut down to
        // 60 pt), the run's pill, `owner/name`. Once one doesn't fit, none
        // after it shows.
        var room = right - pad - min(ColumnHeaderView.textWidth(titleLabel), 80)
        var isFull = false
        /// The width given to a part that needs `least` and asks for `most`; nil once there is no room.
        func take(_ least: CGFloat, upTo most: CGFloat, gap: CGFloat) -> CGFloat? {
            guard !isFull, room - gap >= least else {
                isFull = true
                return nil
            }
            let width = min(most, room - gap)
            room -= width + gap
            return width
        }
        let badgeWidth = ColumnHeaderView.textWidth(dryRunBadge) + 8
        dryRunBadge.isHidden = queue?.dryRun == nil || take(badgeWidth, upTo: badgeWidth, gap: 8) == nil
        let words = queueLabel.stringValue.isEmpty ? 0 : ColumnHeaderView.textWidth(queueLabel)
        let wordsWidth = words == 0 ? nil : take(min(words, 60), upTo: words, gap: 10)
        queueLabel.isHidden = wordsWidth == nil
        let pillWidth = min(pill.idealWidth, (bounds.width * 0.4).rounded(.down))
        pill.isHidden = pill.status == nil || take(pillWidth, upTo: pillWidth, gap: 10) == nil
        // What went is still said under the pointer.
        let unsaid = [
            dryRunBadge.isHidden && queue?.dryRun != nil ? "DRY RUN" : nil, queueLabel.isHidden ? queue?.status : nil,
            pill.isHidden ? pill.status?.text : nil
        ].compactMap { $0 }
        toolTip = unsaid.isEmpty ? nil : unsaid.joined(separator: "\n")
        queueLabel.toolTip = queue?.status
        // Right to left: DRY RUN, the pill, the words; the name, then `owner/name`, at the left.
        if !dryRunBadge.isHidden {
            dryRunBadge.frame = NSRect(x: right - badgeWidth, y: baseline + 1, width: badgeWidth, height: 14)
            right = dryRunBadge.frame.minX - 8
        }
        if !pill.isHidden {
            pill.frame = NSRect(x: right - pillWidth, y: baseline - 1, width: pillWidth, height: ColumnStatusPill.height)
            right = pill.frame.minX - 10
        }
        if let wordsWidth {
            queueLabel.frame = NSRect(x: right - wordsWidth, y: baseline + 1, width: wordsWidth, height: 15)
            right = queueLabel.frame.minX - 10
        }
        let titleWidth = min(ColumnHeaderView.textWidth(titleLabel), max(0, right - pad))
        titleLabel.frame = NSRect(x: pad, y: baseline, width: titleWidth, height: 16)
        let detailX = titleLabel.frame.maxX + 10
        detailLabel.frame = NSRect(x: detailX, y: baseline + 1, width: max(0, right - detailX), height: 15)
        detailLabel.isHidden = isFull || detailLabel.frame.width < 30
    }

    // MARK: Clicks

    @objc private func startClicked() { onStart?() }
    @objc private func stopClicked() { onStop?() }
    @objc private func moreClicked() {
        guard let menu = contextMenu() else { return }
        popUp(menu, NSPoint(x: moreButton.frame.minX, y: moreButton.frame.maxY), self)
    }

    /// The repository's menu; the same on a right click.
    override func menu(for event: NSEvent) -> NSMenu? { contextMenu() }

    func contextMenu() -> NSMenu? {
        guard !menuItems.isEmpty else { return nil }
        let menu = NSMenu()
        for item in menuItems {
            let menuItem = NSMenuItem(title: item.title, action: #selector(menuItemChosen(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = item
            menu.addItem(menuItem)
        }
        return menu
    }

    /// Chosen in a menu shown before the header changed: only as it
    /// still offers it.
    @objc private func menuItemChosen(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? BoardStagesView.SectionMenuItem, window != nil, menuItems.contains(item) else { return }
        onMenu?(item)
    }
}

/// A queue that runs, pinned at the Board's foot: its repository, what it
/// does, Stop.
@MainActor
final class BoardStagesRunningQueueView: NSView {
    let titleLabel = NSTextField(labelWithString: "")
    let statusLabel = NSTextField(labelWithString: "")
    let stopButton = BoardStagesButton(title: "Stop", target: nil, action: nil)
    var onStop: (() -> Void)?
    /// Stop acts only where the pointer aimed. (The Board says.)
    var aim = BoardStagesAim() {
        didSet { stopButton.aim = aim }
    }
    private(set) var queue: BoardStagesView.RunningQueue

    override var isFlipped: Bool { true }

    init(_ queue: BoardStagesView.RunningQueue) {
        self.queue = queue
        super.init(frame: .zero)
        titleLabel.font = Theme.Font.bodyEmphasized
        titleLabel.textColor = Theme.Color.textPrimary
        statusLabel.font = Theme.Font.caption
        for label in [titleLabel, statusLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.allowsExpansionToolTips = true
        }
        stopButton.bezelStyle = .rounded
        stopButton.controlSize = .small
        stopButton.font = Theme.Font.caption
        stopButton.target = self
        stopButton.action = #selector(stopClicked)
        [titleLabel, statusLabel, stopButton].forEach(addSubview)
        show(queue)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ queue: BoardStagesView.RunningQueue) {
        self.queue = queue
        titleLabel.stringValue = queue.title
        titleLabel.toolTip = queue.tooltip
        statusLabel.stringValue = queue.status
        statusLabel.textColor = BoardStagesSectionHeaderView.color(of: queue.tone)
        stopButton.isHidden = queue.stop == nil
        stopButton.title = queue.stop?.title ?? "Stop"
        stopButton.isEnabled = queue.stop?.isEnabled ?? false
        stopButton.toolTip = queue.stop?.tooltip
        stopButton.setAccessibilityLabel("\(stopButton.title) \(queue.title)")
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let pad = BoardStagesView.Metrics.padding
        var right = bounds.width - pad
        if !stopButton.isHidden {
            let width = ceil(stopButton.fittingSize.width)
            stopButton.frame = NSRect(x: right - width, y: (bounds.height - 22) / 2, width: width, height: 22)
            right = stopButton.frame.minX - 10
        }
        let titleWidth = min(ColumnHeaderView.textWidth(titleLabel), max(0, ((right - pad) * 0.4).rounded(.down)))
        titleLabel.frame = NSRect(x: pad, y: (bounds.height - 16) / 2, width: titleWidth, height: 16)
        let statusX = titleLabel.frame.maxX + 10
        statusLabel.frame = NSRect(x: statusX, y: (bounds.height - 15) / 2 + 1, width: max(0, right - statusX), height: 15)
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.Color.line.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

    @objc private func stopClicked() { onStop?() }
}

/// The Board's list: a scroll is the pointer at work, though it may not
/// move.
@MainActor
final class BoardStagesScrollView: NSScrollView {
    var onScroll: () -> Void = {}

    override func scrollWheel(with event: NSEvent) {
        // Two fingers laid on the trackpad scroll nothing.
        if event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0 { onScroll() }
        super.scrollWheel(with: event)
    }
}

/// A worktree under "Other worktrees": its branch, its path, then at the
/// right Open and Clean Up…, also on a right click. One the content has no
/// more, held under the pointer, is faded and does nothing.
@MainActor
final class BoardStagesWorktreeView: NSView {
    let titleLabel = NSTextField(labelWithString: "")
    let pathLabel = NSTextField(labelWithString: "")
    let openButton = BoardStagesButton(title: "Open", target: nil, action: nil)
    let cleanUpButton = BoardStagesButton(title: "Clean Up…", target: nil, action: nil)
    var onMenu: ((BoardStages.MenuItem) -> Void)?
    /// Its buttons and its menu act only where the pointer aimed. (The
    /// Board says.)
    var aim = BoardStagesAim() {
        didSet { [openButton, cleanUpButton].forEach { $0.aim = aim } }
    }
    private(set) var worktree: BoardStages.OtherWorktree?
    private(set) var isDeparted = false

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        titleLabel.font = Theme.Font.body
        titleLabel.textColor = Theme.Color.textPrimary
        pathLabel.font = Theme.Font.mono
        pathLabel.textColor = Theme.Color.textTertiary
        titleLabel.lineBreakMode = .byTruncatingTail
        pathLabel.lineBreakMode = .byTruncatingMiddle
        for label in [titleLabel, pathLabel] { label.allowsExpansionToolTips = true }
        for (button, action) in [(openButton, #selector(openClicked)), (cleanUpButton, #selector(cleanUpClicked))] {
            button.isBordered = false
            button.target = self
            button.action = action
        }
        [titleLabel, pathLabel, openButton, cleanUpButton].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ worktree: BoardStages.OtherWorktree, isDeparted: Bool) {
        self.worktree = worktree
        self.isDeparted = isDeparted
        titleLabel.stringValue = worktree.title
        pathLabel.stringValue = (worktree.path as NSString).abbreviatingWithTildeInPath
        pathLabel.toolTip = worktree.path
        let open = worktree.menu.first { if case .openWorktree = $0 { true } else { false } }
        let cleanUp = worktree.menu.first { if case .cleanUp = $0 { true } else { false } }
        openButton.isHidden = open == nil
        cleanUpButton.isHidden = cleanUp == nil
        Self.style(openButton, title: "Open", acts: !isDeparted)
        Self.style(cleanUpButton, title: cleanUp?.blocked == nil ? "Clean Up…" : BoardStages.CleanUp.runningWords,
                   acts: !isDeparted && cleanUp?.blocked == nil)
        cleanUpButton.toolTip = cleanUp?.blocked ?? "Check the worktree, then confirm what goes"
        openButton.setAccessibilityLabel("Open \(worktree.title)")
        cleanUpButton.setAccessibilityLabel("\(cleanUpButton.title) \(worktree.title)")
        alphaValue = isDeparted ? 0.4 : 1
        needsLayout = true
    }

    /// A link's look: the accent colour while it acts.
    private static func style(_ button: NSButton, title: String, acts: Bool) {
        button.isEnabled = acts
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: Theme.Font.caption, .foregroundColor: acts ? Theme.Color.accent : Theme.Color.textTertiary
        ])
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        isDeparted ? nil : super.hitTest(point)
    }

    override func layout() {
        super.layout()
        let pad = BoardStagesView.Metrics.padding
        var right = bounds.width - pad
        for button in [cleanUpButton, openButton] where !button.isHidden {
            let width = ceil(button.fittingSize.width)
            button.frame = NSRect(x: right - width, y: (bounds.height - 18) / 2, width: width, height: 18)
            right = button.frame.minX - 12
        }
        let left = pad + 14
        let titleWidth = min(ColumnHeaderView.textWidth(titleLabel), max(0, ((right - left) * 0.5).rounded(.down)))
        titleLabel.frame = NSRect(x: left, y: (bounds.height - 16) / 2, width: titleWidth, height: 16)
        let pathX = titleLabel.frame.maxX + 10
        pathLabel.frame = NSRect(x: pathX, y: (bounds.height - 15) / 2 + 1, width: max(0, right - pathX), height: 15)
        pathLabel.isHidden = pathLabel.frame.width < 40
    }

    // MARK: Clicks

    @objc private func openClicked() { choose { if case .openWorktree = $0 { true } else { false } } }
    @objc private func cleanUpClicked() { choose { if case .cleanUp = $0 { true } else { false } } }

    /// The item of its menu that `matches`, while it still offers it and acts.
    private func choose(_ matches: (BoardStages.MenuItem) -> Bool) {
        guard !isDeparted, let item = worktree?.menu.first(where: matches), item.blocked == nil else { return }
        onMenu?(item)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        aim.onUse()
        // A worktree that came under a still pointer isn't the one it aimed at.
        return aim.isStale ? nil : contextMenu()
    }

    /// Its items, as the buttons offer them; one held back is there,
    /// disabled, and says why.
    func contextMenu() -> NSMenu? {
        guard !isDeparted, let worktree, !worktree.menu.isEmpty else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in worktree.menu {
            let menuItem = NSMenuItem(title: item.title, action: #selector(menuItemChosen(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = item
            menuItem.isEnabled = item.blocked == nil
            menuItem.toolTip = item.blocked
            menu.addItem(menuItem)
        }
        return menu
    }

    /// Chosen in a menu shown before the worktree changed: only as it
    /// still offers it.
    @objc private func menuItemChosen(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? BoardStages.MenuItem else { return }
        choose { $0 == item }
    }
}
