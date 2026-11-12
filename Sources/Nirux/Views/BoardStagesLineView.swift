import AppKit

/// One line: its dot and title, its rail, its phrase, its pull request and
/// its time. It draws the dot, the rail and what joins it to the lines
/// around it; the words are labels. The whole line is one target: it takes
/// the mouse for its words, and shows their tooltips.
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

    private(set) var line: BoardStages.Line
    private(set) var link: Link
    let titleLabel = NSTextField(labelWithString: "")
    /// "no pull request", in place of the rail of a task without a repository.
    let noRailLabel = NSTextField(labelWithString: "no pull request")
    let phraseLabel = NSTextField(labelWithString: "")
    let pullRequestLabel = NSTextField(labelWithString: "")
    let timeLabel = NSTextField(labelWithString: "")
    var onClick: (() -> Void)?
    /// The mouse went down on the line: its release there is a click.
    private var isPressed = false

    private typealias Metrics = BoardStagesView.Metrics

    override var isFlipped: Bool { true }

    init(_ line: BoardStages.Line, link: Link) {
        self.line = line
        self.link = link
        super.init(frame: .zero)
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = Theme.Color.textPrimary
        phraseLabel.font = Theme.Font.body
        pullRequestLabel.font = Theme.Font.mono
        pullRequestLabel.textColor = Theme.Color.textTertiary
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        timeLabel.textColor = Theme.Color.textTertiary
        timeLabel.alignment = .right
        noRailLabel.font = Theme.Font.caption
        noRailLabel.textColor = Theme.Color.textDisabled
        for label in [titleLabel, noRailLabel, phraseLabel, pullRequestLabel, timeLabel] {
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
        phraseLabel.stringValue = line.phrase.text
        phraseLabel.textColor = Self.phraseColor(of: line.state)
        pullRequestLabel.stringValue = line.pullRequest
        setAccessibilityLabel(Self.accessibilityLabel(of: line, link: link))
    }

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
        phraseLabel.frame = NSRect(x: columns.phrase.minX, y: 9, width: columns.phrase.width, height: 16)
        phraseLabel.isHidden = columns.phrase.width == 0
        for (label, frame) in [(pullRequestLabel, columns.pullRequest), (timeLabel, columns.time)] {
            label.isHidden = frame == nil
            label.frame = NSRect(x: frame?.minX ?? 0, y: 10, width: frame?.width ?? 0, height: 15)
        }
        removeAllToolTips()
        for label in told where toolTipText(of: label) != nil {
            addToolTip(label.frame, owner: self, userData: nil)
        }
    }

    // MARK: Tooltips

    /// The words that can say more under the pointer.
    private var told: [NSTextField] { [titleLabel, phraseLabel, pullRequestLabel] }

    /// A text that is cut, whole; and with the phrase what it can't hold:
    /// why the checks look flaky, why the queue stopped. (A column the
    /// Board has no room for has no width: the pointer is never on it.)
    private func toolTipText(of label: NSTextField) -> String? {
        let whole = ColumnHeaderView.textWidth(label) > label.frame.width ? label.stringValue : nil
        guard label === phraseLabel, let detail = line.phrase.detail else { return whole }
        return whole.map { "\($0)\n\(detail)" } ?? detail
    }

    /// What the pointer shows at `point`, if anything.
    func toolTipText(at point: NSPoint) -> String? {
        told.first { $0.frame.contains(point) }.flatMap(toolTipText(of:))
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
            Self.draw(rail, state: line.state, stations: columns.stations, y: bounds.midY)
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
    /// Merge is the current station.
    static func draw(_ rail: BoardStages.Rail, state: BoardStages.State, stations: [CGFloat], y: CGFloat) {
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

    /// A number in a ring, on the canvas: a stack's place, the queue's
    /// order. Two digits are set smaller, to stay inside.
    private static func draw(number: Int, at center: NSPoint, radius: CGFloat, ring: NSColor, text: NSColor) {
        let circle = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius))
        Theme.Color.canvas.setFill()
        circle.fill()
        circle.lineWidth = 1
        ring.setStroke()
        circle.stroke()
        let string = NSAttributedString(string: "\(number)", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: number < 10 ? 9 : 7.5, weight: .semibold), .foregroundColor: text
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
        isPressed = event.clickCount == 1
    }

    override func mouseUp(with event: NSEvent) {
        defer { isPressed = false }
        if isPressed, bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }
}
