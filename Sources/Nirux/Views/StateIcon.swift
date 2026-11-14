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
        /// The checks run: a dashed ring, filled up to its station.
        case checksRunning
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
        /// A question: at the end of a turn, in a dialog or a message.
        case question

        /// The reason of an attention signal that waits for the user; nil
        /// for one that doesn't (a finished turn, an error).
        init?(_ attention: AgentAttentionReason?) {
            switch attention {
            case .permission?: self = .command
            case .question?, .askedInReply?, .message?, nil: self = .question
            case .stillWaiting(let dialog, _)?: self.init(dialog)
            case .turnFinished?, .apiError?, .exitedMidTurn?: return nil
            }
        }
    }

    var kind: Kind
    /// How many of the four stations the ring shows: 0 to 4.
    private(set) var stage: Int

    init(_ kind: Kind, stage: Int = 0) {
        self.kind = kind
        self.stage = min(4, max(0, stage))
    }

    /// The icon of a task row's mark (`SidebarRowSummary.mark`), with the
    /// reason of its wait and how far it went through the Board's stations.
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
        case .checksRunning: kind = .checksRunning
        }
        self.init(kind, stage: Self.stage(of: station))
    }

    /// Code fills a quarter, Merge the whole ring; no station, nothing.
    static func stage(of station: BoardStages.Station?) -> Int {
        station.map { $0.rawValue + 1 } ?? 0
    }

    /// The state's colour, from `Theme`: the ring, the disc or the glyph.
    var color: NSColor {
        switch kind {
        case .working: return Theme.Color.working
        case .needsYou: return Theme.Color.waiting
        case .error: return Theme.Color.error
        case .readyToMerge: return Theme.Color.success
        case .merged: return Theme.Color.done
        case .asking, .checksRunning, .blocked, .finished, .idle: return Theme.Color.idle
        }
    }

    /// What VoiceOver says: the state, then the station the ring shows.
    var accessibilityText: String {
        let stations = ["Code", "Reviews", "Checks", "Merge"]
        switch kind {
        case .working where stage > 0, .idle where stage > 0, .checksRunning where stage > 0:
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
        case .checksRunning: return "Checks running"
        case .readyToMerge: return "Ready to merge"
        case .merged: return "Merged"
        case .blocked: return "Blocked"
        case .finished: return "Finished its turn"
        case .idle: return "Idle"
        }
    }
}

/// Draws a `StateIcon` at any size, on a 16-unit grid scaled to its bounds.
final class StateIconView: NSView {
    var icon: StateIcon {
        didSet {
            guard icon != oldValue else { return }
            needsDisplay = true
            setAccessibilityLabel(icon.accessibilityText)
            NSAccessibility.post(element: self, notification: .titleChanged)
        }
    }

    /// Its natural size, whatever frame a layout gives it.
    private let size: CGFloat

    init(_ icon: StateIcon, size: CGFloat = 14) {
        self.icon = icon
        self.size = size
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(icon.accessibilityText)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: size, height: size) }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let side = min(bounds.width, bounds.height)
        context.saveGState()
        context.translateBy(x: bounds.midX - side / 2, y: bounds.midY - side / 2)
        context.scaleBy(x: side / 16, y: side / 16)
        Self.draw(icon, in: context)
        context.restoreGState()
    }

    private static let ringRadius: CGFloat = 6.25
    private static let ringWidth: CGFloat = 1.5
    private static let glyphWidth: CGFloat = 1.6
    /// Ten dashes around the ring, so that its seam doesn't show.
    private static let dash: [CGFloat] = {
        let period = 2 * CGFloat.pi * ringRadius / 10
        return [period * 0.56, period * 0.44]
    }()

    /// Draws `icon` on the 16-unit grid of a context whose y goes down (the
    /// view is flipped): the glyphs and the ring's fill assume it.
    private static func draw(_ icon: StateIcon, in context: CGContext) {
        let center = CGPoint(x: 8, y: 8)
        let color = icon.color.cgColor
        let ink = Theme.Color.canvas.cgColor
        func ring(alpha: CGFloat = 1, dashed: Bool = false) {
            context.setStrokeColor(icon.color.withAlphaComponent(alpha).cgColor)
            context.setLineWidth(ringWidth)
            context.setLineDash(phase: 0, lengths: dashed ? dash : [])
            context.strokeEllipse(in: CGRect(x: 8 - ringRadius, y: 8 - ringRadius, width: 2 * ringRadius, height: 2 * ringRadius))
            context.setLineDash(phase: 0, lengths: [])
        }
        func disc() {
            context.setFillColor(color)
            context.fillEllipse(in: CGRect(x: 1, y: 1, width: 14, height: 14))
        }
        func pie(_ stage: Int) {
            guard stage > 0 else { return }
            let start = -CGFloat.pi / 2
            context.move(to: center)
            context.addArc(center: center, radius: 3.5, startAngle: start,
                           endAngle: start + 2 * .pi * CGFloat(stage) / 4, clockwise: false)
            context.closePath()
            context.setFillColor(color)
            context.fillPath()
        }
        func glyph(_ path: CGPath, color stroke: CGColor) {
            context.setStrokeColor(stroke)
            context.setLineWidth(glyphWidth)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.addPath(path)
            context.strokePath()
        }
        func dot(_ point: CGPoint, color fill: CGColor) {
            context.setFillColor(fill)
            context.fillEllipse(in: CGRect(x: point.x - 0.95, y: point.y - 0.95, width: 1.9, height: 1.9))
        }
        switch icon.kind {
        case .working:
            ring(alpha: 0.45)
            pie(max(1, icon.stage))
        case .idle:
            ring()
            pie(icon.stage)
        case .checksRunning:
            ring(dashed: true)
            pie(icon.stage)
        case .needsYou(let reason):
            disc()
            switch reason {
            case .command: glyph(Glyph.chevron, color: ink)
            case .question:
                glyph(Glyph.question, color: ink)
                dot(CGPoint(x: 8, y: 11.7), color: ink)
            }
        case .asking:
            ring()
            glyph(Glyph.question, color: color)
            dot(CGPoint(x: 8, y: 11.7), color: color)
        case .error:
            ring()
            glyph(Glyph.bang, color: color)
            dot(CGPoint(x: 8, y: 11.1), color: color)
        case .readyToMerge, .finished:
            ring()
            glyph(Glyph.check, color: color)
        case .merged:
            disc()
            glyph(Glyph.check, color: ink)
        case .blocked:
            ring()
            glyph(Glyph.slash, color: color)
        }
    }

    /// Glyph paths on the 16-unit grid, y going down, built once.
    private enum Glyph {
        @MainActor static let chevron: CGPath = {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 6.1, y: 5.4))
            path.addLine(to: CGPoint(x: 8.8, y: 8))
            path.addLine(to: CGPoint(x: 6.1, y: 10.6))
            return path
        }()
        @MainActor static let question: CGPath = {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 6.1, y: 6.4))
            path.addCurve(to: CGPoint(x: 9.9, y: 6.2), control1: CGPoint(x: 6.1, y: 4.1), control2: CGPoint(x: 9.7, y: 4.2))
            path.addCurve(to: CGPoint(x: 8, y: 9.1), control1: CGPoint(x: 10.1, y: 7.6), control2: CGPoint(x: 8, y: 7.9))
            path.addLine(to: CGPoint(x: 8, y: 9.6))
            return path
        }()
        @MainActor static let bang: CGPath = {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 8, y: 4.9))
            path.addLine(to: CGPoint(x: 8, y: 8.8))
            return path
        }()
        @MainActor static let check: CGPath = {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 5.2, y: 8.2))
            path.addLine(to: CGPoint(x: 7, y: 10))
            path.addLine(to: CGPoint(x: 10.8, y: 6))
            return path
        }()
        @MainActor static let slash: CGPath = {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 4.4, y: 11.6))
            path.addLine(to: CGPoint(x: 11.6, y: 4.4))
            return path
        }()
    }
}
