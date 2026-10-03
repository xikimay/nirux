import AppKit

/// Horizontal dot strip at the bottom of the viewport showing columns of the active workspace
final class ColumnIndicatorView: NSView {
    private var columnCount: Int = 0
    private var focusedIndex: Int = 0
    /// What each column asks while the user looks elsewhere.
    private var columnSignals: [AttentionSignal?] = []
    private var pulseLayers: [CALayer] = []

    private static let dotSize: CGFloat = 6
    private static let dotGap: CGFloat = 8
    private static let accentColor: NSColor = Theme.Color.accent
    private static let dimColor = NSColor.white.withAlphaComponent(0.25)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update(columnCount: Int, focusedIndex: Int, columnSignals: [AttentionSignal?] = []) {
        guard columnCount != self.columnCount || focusedIndex != self.focusedIndex
              || columnSignals != self.columnSignals else { return }
        self.columnCount = columnCount
        self.focusedIndex = focusedIndex
        self.columnSignals = columnSignals
        setNeedsDisplay(bounds)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard columnCount > 0, let ctx = NSGraphicsContext.current?.cgContext else { return }

        pulseLayers.forEach { $0.removeFromSuperlayer() }
        pulseLayers.removeAll()

        let ds = Self.dotSize
        let gap = Self.dotGap
        let totalW = CGFloat(columnCount) * ds + CGFloat(columnCount - 1) * gap
        var x = (bounds.width - totalW) / 2
        let y = (bounds.height - ds) / 2

        // Background pill
        let pillPad: CGFloat = 10
        let pillRect = CGRect(x: x - pillPad, y: 1, width: totalW + pillPad * 2, height: bounds.height - 2)
        ctx.setFillColor(Theme.Color.base.withAlphaComponent(0.85).cgColor)
        let path = CGMutablePath()
        path.addRoundedRect(in: pillRect, cornerWidth: (bounds.height - 2) / 2, cornerHeight: (bounds.height - 2) / 2)
        ctx.addPath(path)
        ctx.fillPath()

        // Dots
        for i in 0..<columnCount {
            let isFocused = (i == focusedIndex)
            let signal = isFocused ? nil : columnSignals[safe: i] ?? nil
            // A wait or an error pulses; a finished turn is a brighter dot.
            let isNotif = signal.map { $0 != .finished } ?? false
            let color: NSColor
            if let signal {
                color = SidebarRenderer.color(for: signal)
            } else if isFocused {
                color = Self.accentColor
            } else {
                color = Self.dimColor
            }
            ctx.setFillColor(color.cgColor)
            let dotW = isFocused ? ds + 2 : ds
            let dotY = (bounds.height - dotW) / 2
            ctx.fillEllipse(in: CGRect(x: x - (isFocused ? 1 : 0), y: dotY, width: dotW, height: dotW))

            if isNotif, let rootLayer = layer {
                let glowSize = dotW + 6
                let glow = CALayer()
                glow.frame = CGRect(x: x - 3, y: dotY - 3, width: glowSize, height: glowSize)
                glow.cornerRadius = glowSize / 2
                glow.backgroundColor = NSColor.clear.cgColor
                glow.borderWidth = 1.5
                glow.borderColor = color.cgColor

                let pulse = CABasicAnimation(keyPath: "opacity")
                pulse.fromValue = 1.0
                pulse.toValue = 0.15
                pulse.duration = 0.6
                pulse.autoreverses = true
                pulse.repeatCount = .infinity
                pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                glow.add(pulse, forKey: "pulse")

                rootLayer.addSublayer(glow)
                pulseLayers.append(glow)
            }

            x += ds + gap
        }
    }
}
