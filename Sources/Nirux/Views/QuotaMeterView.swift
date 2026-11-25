import AppKit

/// A share as a hair bar, in the meters' look.
final class QuotaShareBar: NSView {
    var share: Double = 0 {
        didSet { if share != oldValue { needsDisplay = true } }
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        Theme.Color.lineStrong.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        guard share > 0 else { return }
        Theme.Color.textSecondary.setFill()
        let fill = NSRect(x: 0, y: 0, width: max(bounds.height, bounds.width * min(1, share)), height: bounds.height)
        NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius).fill()
    }
}

/// Plan limits as hair meters, a row each: the used part filled, the
/// projection to its reset hatched, both red once the limit runs out before
/// its reset (`QuotaLimit.runsOut`), and a tick where time is in its window.
/// Rows are `limits`, top down.
final class QuotaMeterView: NSView {
    static let barHeight: CGFloat = 4
    static let rowGap: CGFloat = 4
    private static let tickWidth: CGFloat = 1.5
    private static let tickOverhang: CGFloat = 1.5
    private static let hatchStep: CGFloat = 3
    private static let hatchAlpha: CGFloat = 0.55

    /// Where the forecast takes it by its reset, 0…100.
    static func projected(_ limit: QuotaLimit) -> Double {
        switch limit.forecast {
        case .reached, .runsOut: 100
        case .atReset(let percent): max(limit.latest.usedPercent, Double(percent))
        case .quiet, .unknown: limit.latest.usedPercent
        }
    }

    var limits: [QuotaLimit] = [] {
        didSet { if limits != oldValue { needsDisplay = true } }
    }

    var now: TimeInterval = 0 {
        didSet { if now != oldValue { needsDisplay = true } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        // The words beside it say the same: VoiceOver reads those.
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    static func height(rows: Int) -> CGFloat {
        CGFloat(rows) * (barHeight + rowGap) - rowGap + 2 * tickOverhang
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = Self.barHeight / 2
        var y = (bounds.height - Self.height(rows: limits.count)) / 2 + Self.tickOverhang
        for limit in limits {
            let bar = NSRect(x: 0, y: y, width: bounds.width, height: Self.barHeight)
            Theme.Color.lineStrong.setFill()
            NSBezierPath(roundedRect: bar, xRadius: radius, yRadius: radius).fill()
            let used = min(1, max(0, limit.latest.usedPercent / 100))
            let ink = limit.runsOut ? Theme.Color.error : Theme.Color.textSecondary
            let projected = min(1, Self.projected(limit) / 100)
            if projected > used {
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(roundedRect: bar, xRadius: radius, yRadius: radius).addClip()
                NSRect(x: bar.width * used, y: bar.minY, width: bar.width * (projected - used), height: bar.height).clip()
                ink.withAlphaComponent(Self.hatchAlpha).setStroke()
                let hatch = NSBezierPath()
                var x = bar.width * used - bar.height
                while x < bar.width * projected {
                    hatch.move(to: NSPoint(x: x, y: bar.maxY))
                    hatch.line(to: NSPoint(x: x + bar.height, y: bar.minY))
                    x += Self.hatchStep
                }
                hatch.stroke()
                NSGraphicsContext.restoreGraphicsState()
            }
            if used > 0 {
                ink.setFill()
                let fill = NSRect(x: bar.minX, y: bar.minY, width: max(Self.barHeight, bar.width * used), height: bar.height)
                NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius).fill()
            }
            let elapsed = QuotaPace.elapsed(resetsAt: limit.latest.resetsAt, length: limit.length, now: now)
            let x = min(bar.width - Self.tickWidth, max(0, bar.width * elapsed - Self.tickWidth / 2))
            Theme.Color.textPrimary.setFill()
            NSRect(x: x, y: bar.minY - Self.tickOverhang, width: Self.tickWidth, height: bar.height + 2 * Self.tickOverhang).fill()
            y += Self.barHeight + Self.rowGap
        }
    }
}
