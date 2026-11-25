import AppKit

/// Plan limits as hair meters, a row each: the used part filled, red once
/// the limit runs out before its reset (`QuotaLimit.runsOut`), and a tick
/// where time is in its window. Rows are `limits`, top down.
final class QuotaMeterView: NSView {
    static let barHeight: CGFloat = 4
    static let rowGap: CGFloat = 4
    private static let tickWidth: CGFloat = 1.5
    private static let tickOverhang: CGFloat = 1.5

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
            if used > 0 {
                (limit.runsOut ? Theme.Color.error : Theme.Color.textSecondary).setFill()
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
