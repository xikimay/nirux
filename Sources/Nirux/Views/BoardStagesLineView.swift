import AppKit

/// One line: its dot and title, its rail, its phrase, its pull request and
/// its time. It draws the dot, the rail and what joins it to the lines
/// around it; the words are labels. It takes the mouse for its words and
/// shows their tooltips. A click opens its task, but on its Merge station
/// where that changes the queue's list, and on the link ending its phrase
/// (docs/design/board-stages.md, section 7).
@MainActor
final class BoardStagesLineView: NSView, NSViewToolTipOwner {
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

    /// What a press and its release on a line do, by where both land.
    enum Target: Equatable {
        /// Anywhere but on what follows: its task opens.
        case line
        /// Its Merge station, while a click there changes the queue's list.
        case offer(BoardStages.QueueOffer)
        /// The link ending its phrase.
        case link(BoardStages.Link)
    }

    private(set) var line: BoardStages.Line
    private(set) var link: Link
    let titleLabel = NSTextField(labelWithString: "")
    /// "no pull request", in place of the rail of a task without a repository.
    let noRailLabel = NSTextField(labelWithString: "no pull request")
    /// The phrase; with a link, its words before the link.
    let phraseLabel = NSTextField(labelWithString: "")
    /// The link ending the phrase, drawn apart: the words before it are
    /// what gives way.
    let linkLabel = NSTextField(labelWithString: "")
    let pullRequestLabel = NSTextField(labelWithString: "")
    let timeLabel = NSTextField(labelWithString: "")
    var onClick: (() -> Void)?
    var onOffer: ((BoardStages.QueueOffer) -> Void)?
    var onLink: ((BoardStages.Link) -> Void)?
    /// The mouse moved with its button down, or came up, at this place in
    /// the window: no other event says where the pointer is meanwhile.
    var onPointer: ((NSPoint) -> Void)?
    /// What the mouse went down on: its release on the same is a click.
    private var pressed: Target?
    /// The pointer is on the Merge station, as the Board follows it. The
    /// station says what a click does only while one acts.
    var isStationHovered = false {
        didSet { if isStationHovered != oldValue { needsDisplay = true } }
    }
    /// What the words and the stations say under the pointer, by where.
    private var toolTips = BoardStagesToolTips()
    var hints: [(rect: NSRect, text: String)] { toolTips.places }
    /// Where a hand showed at the last layout.
    private var shownHandRects: [NSRect] = []

    private typealias Metrics = BoardStagesView.Metrics

    override var isFlipped: Bool { true }

    init(_ line: BoardStages.Line, link: Link) {
        self.line = line
        self.link = link
        super.init(frame: .zero)
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = Theme.Color.textPrimary
        phraseLabel.font = Theme.Font.body
        linkLabel.font = Theme.Font.body
        linkLabel.textColor = Theme.Color.accent
        pullRequestLabel.font = Theme.Font.mono
        pullRequestLabel.textColor = Theme.Color.textTertiary
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        timeLabel.textColor = Theme.Color.textTertiary
        timeLabel.alignment = .right
        noRailLabel.font = Theme.Font.caption
        noRailLabel.textColor = Theme.Color.textDisabled
        for label in [titleLabel, noRailLabel, phraseLabel, linkLabel, pullRequestLabel, timeLabel] {
            label.lineBreakMode = .byTruncatingTail
            // The line itself is what VoiceOver reads.
            label.setAccessibilityElement(false)
            addSubview(label)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Shows another state of the line, or another place among its own,
    /// in the same view.
    func update(_ line: BoardStages.Line, link: Link) {
        guard line != self.line || link != self.link else { return }
        self.line = line
        self.link = link
        apply()
        needsLayout = true
        needsDisplay = true
    }

    private func apply() {
        titleLabel.stringValue = line.title
        phraseLabel.stringValue = line.phrase.wordsBeforeLink ?? line.phrase.text
        linkLabel.stringValue = shownLink?.title ?? ""
        phraseLabel.textColor = Self.phraseColor(of: line.state)
        pullRequestLabel.stringValue = line.pullRequest
        setAccessibilityLabel(Self.accessibilityLabel(of: line, link: link))
        // What the Merge station says where it refuses: VoiceOver has no pointer to put on it.
        setAccessibilityHelp(line.offer?.blocked)
    }

    /// The link drawn apart: the phrase's, when the phrase ends with it.
    private var shownLink: BoardStages.Link? { line.phrase.wordsBeforeLink == nil ? nil : line.phrase.link }

    /// What a click on the Merge station does; nil where it does nothing
    /// more than anywhere on the line.
    private var actingOffer: BoardStages.QueueOffer? { line.offer.flatMap { $0.blocked == nil ? $0 : nil } }

    /// "12 min", counted to `now`; nothing for a line without a clock.
    func showTime(now: TimeInterval) {
        let time = line.since.map { BoardStagesView.duration(now - $0) } ?? ""
        if timeLabel.stringValue != time { timeLabel.stringValue = time }
    }

    /// Amber and red say the phrase needs a look; the rest stays grey.
    static func phraseColor(of state: BoardStages.State) -> NSColor {
        switch state {
        case .needsYou: return Theme.Color.waiting
        case .failed: return Theme.Color.error
        case .working, .blocked, .waiting, .ready, .merged, .idle: return Theme.Color.textTertiary
        }
    }

    /// "Agent loop hint, at Merge, Ready · reviews done, checks green,
    /// #308, queue place 2".
    nonisolated static func accessibilityLabel(of line: BoardStages.Line, link: Link = .none) -> String {
        var parts = [line.title]
        switch link {
        case .subtask: parts.append("sub-task")
        case .stack(let number, _): parts.append("stack place \(number)")
        case .none, .head: break
        }
        if line.rail != nil { parts.append("at \(BoardStagesView.title(of: line.station))") }
        parts.append(line.phrase.text)
        if !line.pullRequest.isEmpty { parts.append(line.pullRequest) }
        if let order = line.rail?.queueOrder { parts.append("queue place \(order)") }
        return parts.joined(separator: ", ")
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
        noRailLabel.isHidden = line.rail != nil || columns.rail.width == 0
        // The link keeps its width right after the words before it, which
        // give way first. (Two labels' own margins are a space between them.)
        let column = columns.phrase.width
        var linkWidth: CGFloat = 0
        var wordsWidth = column
        if shownLink != nil {
            let whole = ColumnHeaderView.textWidth(phraseLabel)
            let link = ColumnHeaderView.textWidth(linkLabel)
            // A link too long for the column is cut, and leaves its words
            // half of it where that is worth reading.
            let room = link <= column ? column - link : (column >= Self.widthToShare ? column / 2 : 0)
            wordsWidth = min(whole, room)
            // A letter or two and an ellipsis say nothing: the words go,
            // and the link's tooltip has them.
            if wordsWidth < min(whole, Self.fewestWords) { wordsWidth = 0 }
            linkWidth = min(link, column - wordsWidth)
        }
        phraseLabel.frame = NSRect(x: columns.phrase.minX, y: 9, width: wordsWidth, height: 16)
        phraseLabel.isHidden = wordsWidth == 0
        linkLabel.frame = NSRect(x: phraseLabel.frame.maxX, y: 9, width: linkWidth, height: 16)
        linkLabel.isHidden = linkWidth == 0
        for (label, frame) in [(pullRequestLabel, columns.pullRequest), (timeLabel, columns.time)] {
            label.isHidden = frame == nil
            label.frame = NSRect(x: frame?.minX ?? 0, y: 10, width: frame?.width ?? 0, height: 15)
        }
        layoutHints(stations: columns.stations)
        if handRects != shownHandRects {
            shownHandRects = handRects
            window?.invalidateCursorRects(for: self)
        }
    }

    /// Under this, the words before a link aren't worth their place.
    private static let fewestWords: CGFloat = 30
    /// From this, a phrase's column holds some of both its words and a
    /// link too long for it.
    private static let widthToShare: CGFloat = 120

    // MARK: Targets

    /// A station under the pointer or the mouse: 22 pt wide, the line's
    /// height, around its place on the rail.
    private func stationRect(at x: CGFloat) -> NSRect {
        NSRect(x: x - 11, y: 0, width: 22, height: bounds.height)
    }

    /// Where the Merge station is; nil on a Board too narrow for a rail.
    private var mergeStationRect: NSRect? {
        BoardStagesView.Columns(width: bounds.width, height: bounds.height).stations.last.map(stationRect(at:))
    }

    /// The link, the line's height, over its words and no further: what
    /// is beside it is the phrase's. (No width where it has no room.)
    private var linkRect: NSRect? {
        guard shownLink != nil else { return nil }
        return NSRect(x: linkLabel.frame.minX, y: 0, width: linkLabel.frame.width, height: bounds.height)
    }

    /// A click at `point` changes the queue's list: on the Merge station,
    /// while one acts there.
    func actsOnStation(at point: NSPoint) -> Bool {
        actingOffer != nil && mergeStationRect?.contains(point) == true
    }

    /// What a click at `point` does.
    func target(at point: NSPoint) -> Target {
        if let offer = actingOffer, actsOnStation(at: point) { return .offer(offer) }
        if let link = shownLink, linkRect?.contains(point) == true { return .link(link) }
        return .line
    }

    /// Where a hand shows: what a click does something of its own on, as
    /// far as it is in sight (a cursor's place isn't clipped by what
    /// scrolls the line).
    var handRects: [NSRect] {
        [actingOffer == nil ? nil : mergeStationRect, linkRect].compactMap { $0?.intersection(rectInSight) }.filter { !$0.isEmpty }
    }

    // MARK: Tooltips

    /// What each place says under the pointer. A text that is cut, whole;
    /// then what the line can't hold: where the task's work is, why the
    /// checks look flaky or the queue stopped, what the link does, the
    /// pull request's stack and address, and each station's own. (A
    /// column the Board has no room for has no width: the pointer is
    /// never on it.)
    private func layoutHints(stations: [CGFloat]) {
        var hints: [(rect: NSRect, text: String)] = []
        func add(_ rect: NSRect?, _ parts: [String?]) {
            if let rect { hints.append((rect, parts.compactMap { $0 }.joined(separator: "\n"))) }
        }
        func whole(_ label: NSTextField, _ text: String) -> String? {
            ColumnHeaderView.textWidth(label) > label.frame.width ? text : nil
        }
        add(titleLabel.frame, [whole(titleLabel, line.title), line.tooltips.title])
        // The phrase whole where any of it is cut: on its words, and on
        // its link, which may be all that is left of it.
        let phrase = whole(phraseLabel, line.phrase.text) ?? (shownLink == nil ? nil : whole(linkLabel, line.phrase.text))
        if !phraseLabel.isHidden { add(phraseLabel.frame, [phrase, line.phrase.detail]) }
        if let link = shownLink { add(linkRect, [phrase, link.hint]) }
        if !pullRequestLabel.isHidden {
            add(pullRequestLabel.frame, [whole(pullRequestLabel, line.pullRequest), line.tooltips.pullRequest])
        }
        if line.rail != nil {
            for (station, x) in zip(BoardStages.Station.allCases, stations) {
                add(stationRect(at: x), [line.tooltips.stations[station]])
            }
        }
        toolTips.show(hints, on: self)
    }

    /// What the pointer shows at `point`, if anything.
    func toolTipText(at point: NSPoint) -> String? {
        toolTips.text(at: point)
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        toolTipText(at: point) ?? ""
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        drawConnectors()
        Self.fill(circle: dotCenter, radius: Metrics.dot / 2, BoardStagesView.color(of: line.state))
        if let rail = line.rail {
            let columns = BoardStagesView.Columns(width: bounds.width, height: bounds.height)
            Self.draw(rail, state: line.state, stations: columns.stations, y: bounds.midY, hovered: isStationHovered ? actingOffer?.change : nil)
        }
    }

    /// The elbow that joins a sub-task to its task, the line a task sends
    /// down to its sub-tasks, a stack's numbered rail. Half a point off
    /// the dots' centre, so a 1 pt stroke fills whole pixels.
    private func drawConnectors() {
        let x = Metrics.connectorX - 0.5
        let midY = bounds.midY - 0.5
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

    /// A rail on `y`, its stations at `stations`: its segments, solid up
    /// to the current station and dotted after; a filled dot for a station
    /// done, a larger one in the state's colour for the current one, a
    /// hollow one ahead, nothing where there is no Reviews station. The
    /// queue's number sits in a ring on Merge, in the state's colour when
    /// Merge is the current station. Under the pointer, the Merge station
    /// says what a click does: a plus joins the queue's list, a minus
    /// leaves it, in a ring that keeps the state's colour when the line
    /// is at Merge (amber is never hidden), and is bright otherwise.
    static func draw(
        _ rail: BoardStages.Rail, state: BoardStages.State, stations: [CGFloat], y: CGFloat,
        hovered: BoardStages.QueueOffer.Change? = nil
    ) {
        let current = rail.marks.firstIndex(of: .current) ?? rail.marks.count
        for index in stations.indices.dropLast() {
            // A quarter point down: a 1.5 pt stroke fills three whole
            // pixels on a Retina display.
            let segment = NSBezierPath()
            segment.move(to: NSPoint(x: stations[index] + 7, y: y + 0.25))
            segment.line(to: NSPoint(x: stations[index + 1] - 7, y: y + 0.25))
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
            let center = NSPoint(x: stations[index], y: y)
            if index == BoardStages.Station.merge.rawValue, let hovered {
                draw(sign: hovered, at: center, ring: mark == .current ? BoardStagesView.color(of: state) : Theme.Color.textPrimary)
                continue
            }
            if index == BoardStages.Station.merge.rawValue, let order = rail.queueOrder {
                let isCurrent = mark == .current
                draw(number: order, at: center, radius: 7.5,
                     ring: isCurrent ? BoardStagesView.color(of: state) : Theme.Color.textDisabled,
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

    /// A ring on the canvas, for what sits in it.
    private static func drawRing(at center: NSPoint, radius: CGFloat, _ color: NSColor) {
        let circle = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius))
        Theme.Color.canvas.setFill()
        circle.fill()
        circle.lineWidth = 1
        color.setStroke()
        circle.stroke()
    }

    /// What a click on the Merge station does, in a ring: a plus joins
    /// the queue's list, a minus leaves it. Drawn, not set in type: the
    /// sign sits on the station's centre, its 2 pt strokes on whole pixels.
    private static func draw(sign: BoardStages.QueueOffer.Change, at center: NSPoint, ring: NSColor) {
        drawRing(at: center, radius: 7.5, ring)
        let strokes = NSBezierPath()
        strokes.move(to: NSPoint(x: center.x - 4, y: center.y))
        strokes.line(to: NSPoint(x: center.x + 4, y: center.y))
        if sign == .add {
            strokes.move(to: NSPoint(x: center.x, y: center.y - 4))
            strokes.line(to: NSPoint(x: center.x, y: center.y + 4))
        }
        strokes.lineWidth = 2
        Theme.Color.textPrimary.setStroke()
        strokes.stroke()
    }

    /// A number in a ring, on the canvas: a stack's place, the queue's
    /// order. Two digits are set smaller, to stay inside.
    private static func draw(number: Int, at center: NSPoint, radius: CGFloat, ring: NSColor, text: NSColor) {
        drawRing(at: center, radius: radius, ring)
        let string = NSAttributedString(string: "\(number)", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: number < 10 ? 9 : 7.5, weight: .semibold), .foregroundColor: text
        ])
        let size = string.size()
        string.draw(at: NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2))
    }

    // MARK: Clicks

    /// The line takes the mouse for all it holds: its words don't.
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func mouseDown(with event: NSEvent) {
        let target = target(at: convert(event.locationInWindow, from: nil))
        // The station takes the list's change back at a second click; a
        // double click opens a task, or follows a link, once.
        if case .offer = target {
            pressed = target
        } else {
            pressed = event.clickCount == 1 ? target : nil
        }
    }

    override func mouseDragged(with event: NSEvent) {
        onPointer?(event.locationInWindow)
    }

    /// The click is the mouse going up on what it went down on, as that
    /// still is, and where the line is in sight: a station that stopped
    /// offering what was pressed, or a release elsewhere, does nothing.
    override func mouseUp(with event: NSEvent) {
        defer {
            pressed = nil
            onPointer?(event.locationInWindow)
        }
        let point = convert(event.locationInWindow, from: nil)
        guard let pressed, rectInSight.contains(point), target(at: point) == pressed else { return }
        switch pressed {
        case .line: onClick?()
        case .offer(let offer): onOffer?(offer)
        case .link(let link): onLink?(link)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }

    /// What the mouse reaches on the Merge station and the link, by name,
    /// and as a click: only while the line still offers it.
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        var actions: [NSAccessibilityCustomAction] = []
        if let offer = actingOffer {
            actions.append(NSAccessibilityCustomAction(name: offer.title) { [weak self] in
                guard let self, self.actingOffer == offer, let onOffer = self.onOffer else { return false }
                onOffer(offer)
                return true
            })
        }
        if let link = shownLink {
            actions.append(NSAccessibilityCustomAction(name: link.title) { [weak self] in
                guard let self, self.shownLink == link, let onLink = self.onLink else { return false }
                onLink(link)
                return true
            })
        }
        return actions.isEmpty ? nil : actions
    }

    // MARK: Under the pointer

    override func resetCursorRects() {
        for rect in handRects { addCursorRect(rect, cursor: .pointingHand) }
    }
}

/// What a view says under the pointer, by place. Its words are asked for
/// when shown, and a place that stays keeps its registration with AppKit:
/// a tooltip being read stays up while its words change, or another place
/// comes, goes or moves.
@MainActor
struct BoardStagesToolTips {
    private(set) var places: [(rect: NSRect, text: String)] = []
    private var registered: [(rect: NSRect, tag: NSView.ToolTipTag)] = []

    /// The places `view` answers for from now on: those with some width,
    /// and something to say.
    mutating func show(_ places: [(rect: NSRect, text: String)], on view: NSView & NSViewToolTipOwner) {
        self.places = places.filter { $0.rect.width > 0 && !$0.text.isEmpty }
        let rects = self.places.map(\.rect)
        for gone in registered where !rects.contains(gone.rect) { view.removeToolTip(gone.tag) }
        registered = rects.map { rect in
            registered.first { $0.rect == rect } ?? (rect, view.addToolTip(rect, owner: view, userData: nil))
        }
    }

    func text(at point: NSPoint) -> String? {
        places.first { $0.rect.contains(point) }?.text
    }
}

extension NSView {
    /// The part of the view in sight: what the views it is in show of it.
    /// (`visibleRect` alone isn't held to the view's own bounds in a
    /// window that was never shown.)
    var rectInSight: NSRect { bounds.intersection(visibleRect) }
}
