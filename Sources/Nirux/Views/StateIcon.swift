import AppKit

/// The glass interface's state icons, one family everywhere: the rail, the
/// rows, the inbox, ⌘P and later the Board (docs/design/glass-interface.md).
/// A ring filled by the Board's stations (Code, Reviews, Checks, Merge) in
/// the state's colour, with a glyph saying why. Amber means an agent waits
/// for the user, and nothing else. Nothing shows these yet.
struct StateIcon: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        /// An agent works: a green ring, filled up to its station.
        case working
        /// An agent waits for the user: an amber disc with the reason.
        case needsYou(Reason)
        /// The agent waits for the agent that started it: grey, a question.
        case asking
        /// An agent stopped on an error, or the checks failed: red, "!".
        case error
        /// Waiting on something else than the user (checks that run, the
        /// merge queue, the pull request below in a stack): a dashed ring,
        /// filled up to its station.
        case waiting
        /// Nothing holds the merge: a green ring with a check.
        case readyToMerge
        /// Merged: a violet disc with a check.
        case merged
        /// A blocker is noted: a grey ring, struck through.
        case blocked
        /// A turn ended and the user hasn't looked yet: a grey check.
        case finished
        /// Nothing goes on: a grey ring, filled up to its station.
        case idle
    }

    /// Why an agent waits for the user, drawn in its amber disc.
    enum Reason: Hashable, Sendable {
        /// A permission: a command or a tool to allow.
        case command
        /// A question: at the end of a turn, in a dialog or a message, or a
        /// plan to approve.
        case question

        /// The reason of an attention signal that waits for the user; nil
        /// for one that doesn't (a finished turn, an error).
        init?(_ attention: AgentAttentionReason?) {
            switch attention {
            case .permission(let tool, _)?: self = tool == "ExitPlanMode" ? .question : .command
            case .question?, .askedInReply?, .message?, nil: self = .question
            case .stillWaiting(let dialog, _)?: self.init(dialog)
            case .turnFinished?, .apiError?, .exitedMidTurn?: return nil
            }
        }
    }

    var kind: Kind
    /// How many of the four stations the ring shows, 0 to 4: the station a
    /// task is at counts, so a task at Code shows a quarter.
    private(set) var stage: Int

    init(_ kind: Kind, stage: Int = 0) {
        self.kind = kind
        self.stage = min(4, max(0, stage))
    }

    /// The icon of a task row's mark (`SidebarRowSummary.mark`), with the
    /// reason of its wait and the Board station it is at.
    init(mark: SidebarRowMark, reason: Reason? = nil, station: BoardStages.Station? = nil) {
        let kind: Kind
        switch mark {
        case .needsYou: kind = .needsYou(reason ?? .question)
        case .error: kind = .error
        case .working: kind = .working
        case .asking: kind = .asking
        case .blocked: kind = .blocked
        case .readyToMerge: kind = .readyToMerge
        case .merged: kind = .merged
        case .idle: kind = .idle
        case .finished: kind = .finished
        case .checksRunning: kind = .waiting
        }
        self.init(kind, stage: Self.stage(of: station))
    }

    /// The icon of a Board line (`BoardStages.Line`): its state and the
    /// station it is at.
    init(state: BoardStages.State, station: BoardStages.Station?, reason: Reason? = nil) {
        let kind: Kind
        switch state {
        case .needsYou: kind = .needsYou(reason ?? .question)
        case .failed: kind = .error
        case .working: kind = .working
        case .blocked: kind = .blocked
        case .waiting: kind = .waiting
        case .ready: kind = .readyToMerge
        case .merged: kind = .merged
        case .idle: kind = .idle
        }
        self.init(kind, stage: Self.stage(of: station))
    }

    /// Code fills a quarter, Merge the whole ring; no station, nothing.
    static func stage(of station: BoardStages.Station?) -> Int {
        station.map { $0.rawValue + 1 } ?? 0
    }

    /// It waits for the user to allow a command.
    var waitsOnCommand: Bool { kind == .needsYou(.command) }

    /// The state's colour, from `Theme`: the ring, the disc or the glyph.
    var color: NSColor {
        switch kind {
        case .working: return Theme.Color.working
        case .needsYou: return Theme.Color.waiting
        case .error: return Theme.Color.error
        case .readyToMerge: return Theme.Color.success
        case .merged: return Theme.Color.done
        case .asking, .waiting, .blocked, .finished, .idle: return Theme.Color.idle
        }
    }

    /// Whether a label (a task's initials, on the rail) may take the icon's
    /// centre: not when its glyph says why it stopped, an agent waiting for
    /// the user (amber) or failing (red), which then shows instead.
    var admitsLabel: Bool {
        switch kind {
        case .needsYou, .error: return false
        default: return true
        }
    }

    /// The colour a label in the icon's centre takes: the state's, or the
    /// ink on a disc.
    var labelColor: NSColor {
        if case .merged = kind { return Theme.Color.canvas }
        return color
    }

    /// What VoiceOver says: the state, then the station the ring shows.
    var accessibilityText: String {
        let stations = ["Code", "Reviews", "Checks", "Merge"]
        switch kind {
        case .working where stage > 0, .idle where stage > 0, .waiting where stage > 0:
            return "\(stateText), at \(stations[stage - 1])"
        default:
            return stateText
        }
    }

    private var stateText: String {
        switch kind {
        case .working: return "Working"
        case .needsYou(.command): return "Needs you: a permission"
        case .needsYou(.question): return "Needs you: a question"
        case .asking: return "Asking the agent that started it"
        case .error: return "Failed"
        case .waiting: return "Waiting on checks or the merge queue"
        case .readyToMerge: return "Ready to merge"
        case .merged: return "Merged"
        case .blocked: return "Blocked"
        case .finished: return "Finished its turn"
        case .idle: return "Idle"
        }
    }

    /// The icon as an image of `size` points, for ⌘P, menus and layers. Its
    /// drawing may run off the main thread, as `NSImage` allows.
    func image(size: CGFloat) -> NSImage {
        let icon = self
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            icon.draw(in: context, rect: rect)
            return true
        }
        image.accessibilityDescription = accessibilityText
        return image
    }

    /// Draws the icon centred in `rect` of a context whose y goes down (a
    /// flipped view, a flipped image): the glyphs and the ring's fill
    /// assume it. `labelled`, with room in its centre for a label (see
    /// `admitsLabel`): no glyph, and the station as an arc along the ring.
    func draw(in context: CGContext, rect: CGRect, labelled: Bool = false) {
        let side = min(rect.width, rect.height)
        context.saveGState()
        context.translateBy(x: rect.midX - side / 2, y: rect.midY - side / 2)
        context.scaleBy(x: side / 16, y: side / 16)
        if labelled, admitsLabel { drawFrameOnGrid(context) } else { drawOnGrid(context) }
        context.restoreGState()
    }

    /// The ring or disc in the state's colour without a glyph, the station
    /// along the ring rather than inside it: a label takes the centre.
    private func drawFrameOnGrid(_ context: CGContext) {
        let color = self.color
        let radius = Self.ringRadius
        func ring(alpha: CGFloat = 1, dashed: Bool = false) {
            context.setStrokeColor(color.withAlphaComponent(alpha).cgColor)
            context.setLineWidth(Self.ringWidth)
            context.setLineDash(phase: 0, lengths: dashed ? Self.dash : [])
            context.strokeEllipse(in: CGRect(x: 8 - radius, y: 8 - radius, width: 2 * radius, height: 2 * radius))
            context.setLineDash(phase: 0, lengths: [])
        }
        func arc(_ stage: Int) {
            guard stage > 0 else { return }
            // From 12 o'clock, clockwise on screen: y goes down here.
            let start = -CGFloat.pi / 2
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(Self.ringWidth)
            context.setLineCap(.round)
            context.addArc(center: CGPoint(x: 8, y: 8), radius: radius, startAngle: start,
                           endAngle: start + 2 * .pi * CGFloat(stage) / 4, clockwise: false)
            context.strokePath()
        }
        switch kind {
        case .working:
            ring(alpha: 0.45)
            arc(max(1, stage))
        case .idle where stage > 0:
            ring(alpha: 0.45)
            arc(stage)
        case .waiting:
            ring(dashed: true)
            arc(stage)
        case .merged:
            context.setFillColor(color.cgColor)
            context.fillEllipse(in: CGRect(x: 1, y: 1, width: 14, height: 14))
        case .idle, .asking, .readyToMerge, .finished, .blocked, .needsYou, .error:
            ring()
        }
    }

    private static let ringRadius: CGFloat = 6.25
    private static let ringWidth: CGFloat = 1.5
    private static let glyphWidth: CGFloat = 1.6
    /// Ten dashes around the ring, so that its seam doesn't show.
    private static let dash: [CGFloat] = {
        let period = 2 * CGFloat.pi * ringRadius / 10
        return [period * 0.56, period * 0.44]
    }()

    /// Draws on the 16-unit grid, y going down.
    private func drawOnGrid(_ context: CGContext) {
        let center = CGPoint(x: 8, y: 8)
        let color = self.color
        let ink = Theme.Color.canvas.cgColor
        func ring(alpha: CGFloat = 1, dashed: Bool = false) {
            let radius = Self.ringRadius
            context.setStrokeColor(color.withAlphaComponent(alpha).cgColor)
            context.setLineWidth(Self.ringWidth)
            context.setLineDash(phase: 0, lengths: dashed ? Self.dash : [])
            context.strokeEllipse(in: CGRect(x: 8 - radius, y: 8 - radius, width: 2 * radius, height: 2 * radius))
            context.setLineDash(phase: 0, lengths: [])
        }
        func disc() {
            context.setFillColor(color.cgColor)
            context.fillEllipse(in: CGRect(x: 1, y: 1, width: 14, height: 14))
        }
        func pie(_ stage: Int) {
            guard stage > 0 else { return }
            // From 12 o'clock, clockwise on screen: y goes down here.
            let start = -CGFloat.pi / 2
            context.move(to: center)
            context.addArc(center: center, radius: 3.5, startAngle: start,
                           endAngle: start + 2 * .pi * CGFloat(stage) / 4, clockwise: false)
            context.closePath()
            context.setFillColor(color.cgColor)
            context.fillPath()
        }
        func glyph(_ path: CGPath, _ stroke: CGColor) {
            context.setStrokeColor(stroke)
            context.setLineWidth(Self.glyphWidth)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.addPath(path)
            context.strokePath()
        }
        func dot(_ point: CGPoint, _ fill: CGColor) {
            context.setFillColor(fill)
            context.fillEllipse(in: CGRect(x: point.x - 0.95, y: point.y - 0.95, width: 1.9, height: 1.9))
        }
        switch kind {
        case .working:
            ring(alpha: 0.45)
            pie(max(1, stage))
        case .idle:
            ring()
            pie(stage)
        case .waiting:
            ring(dashed: true)
            pie(stage)
        case .needsYou(.command):
            disc()
            glyph(Glyph.chevron, ink)
        case .needsYou(.question):
            disc()
            glyph(Glyph.question, ink)
            dot(Glyph.questionDot, ink)
        case .asking:
            ring()
            glyph(Glyph.question, color.cgColor)
            dot(Glyph.questionDot, color.cgColor)
        case .error:
            ring()
            glyph(Glyph.bang, color.cgColor)
            dot(Glyph.bangDot, color.cgColor)
        case .readyToMerge, .finished:
            ring()
            glyph(Glyph.check, color.cgColor)
        case .merged:
            disc()
            glyph(Glyph.check, ink)
        case .blocked:
            ring()
            glyph(Glyph.slash, color.cgColor)
        }
    }
}

/// Glyph paths on the 16-unit grid, y going down, built once. A path is
/// immutable once built, so sharing it across threads is safe. The stems
/// stop short of their dots, which stay apart at 1x.
private enum Glyph {
    nonisolated(unsafe) static let chevron = path([(6.1, 5.4), (8.8, 8), (6.1, 10.6)])
    nonisolated(unsafe) static let question: CGPath = {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 6.1, y: 6.4))
        path.addCurve(to: CGPoint(x: 9.9, y: 6.2), control1: CGPoint(x: 6.1, y: 4.1), control2: CGPoint(x: 9.7, y: 4.2))
        path.addCurve(to: CGPoint(x: 8, y: 8.9), control1: CGPoint(x: 10.1, y: 7.5), control2: CGPoint(x: 8, y: 7.8))
        path.addLine(to: CGPoint(x: 8, y: 9.0))
        return path
    }()
    static let questionDot = CGPoint(x: 8, y: 11.7)
    nonisolated(unsafe) static let bang = path([(8, 4.7), (8, 8.0)])
    static let bangDot = CGPoint(x: 8, y: 11.1)
    nonisolated(unsafe) static let check = path([(5.2, 8.2), (7, 10), (10.8, 6)])
    nonisolated(unsafe) static let slash = path([(4.4, 11.6), (11.6, 4.4)])

    private static func path(_ points: [(CGFloat, CGFloat)]) -> CGPath {
        let path = CGMutablePath()
        path.addLines(between: points.map { CGPoint(x: $0.0, y: $0.1) })
        return path
    }
}

/// Draws a `StateIcon` at any size. Silent for VoiceOver by default: a row
/// or a line says its state in words; a host showing the icon alone (the
/// rail) makes it an accessibility element.
final class StateIconView: NSView {
    var icon: StateIcon {
        didSet {
            guard icon != oldValue else { return }
            needsDisplay = true
            setAccessibilityLabel(icon.accessibilityText)
            if isAccessibilityElement() { NSAccessibility.post(element: self, notification: .titleChanged) }
        }
    }

    /// A few letters in the ring's centre (the rail's task initials), shown
    /// while the icon has no glyph to show (`StateIcon.admitsLabel`).
    var label: String? {
        didSet { if label != oldValue { needsDisplay = true } }
    }

    /// The label drawn now: none while the glyph shows.
    var shownLabel: String? { icon.admitsLabel ? label : nil }

    /// Its natural size, whatever frame a layout gives it.
    private let size: CGFloat

    init(_ icon: StateIcon, size: CGFloat = 14) {
        self.icon = icon
        self.size = size
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        setAccessibilityElement(false)
        setAccessibilityRole(.image)
        setAccessibilityLabel(icon.accessibilityText)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: size, height: size) }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let label = shownLabel
        icon.draw(in: context, rect: bounds, labelled: label != nil)
        guard let label else { return }
        // Inside the ring: shrunk to fit a longer one ("CR2", "W12").
        let side = min(bounds.width, bounds.height)
        let room = side * 0.6
        var font = NSFont.systemFont(ofSize: side * 0.4, weight: .semibold)
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: icon.labelColor]
        var size = (label as NSString).size(withAttributes: attributes)
        if size.width > room {
            font = NSFont.systemFont(ofSize: font.pointSize * room / size.width, weight: .semibold)
            attributes[.font] = font
            size = (label as NSString).size(withAttributes: attributes)
        }
        (label as NSString).draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attributes)
    }
}
