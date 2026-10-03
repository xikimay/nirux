import AppKit

/// Directional edge glow that pulses when an agent off-screen waits on the
/// user (amber) or broke (red)
final class EdgeGlowView: NSView {
    enum Edge { case left, right, top, bottom }

    private let edge: Edge
    private var glowVisible = false
    private var color = Theme.Color.waiting

    init(edge: Edge) {
        self.edge = edge
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        alphaValue = 0
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Decoration only: clicks reach the column headers and edges it
    /// glows over.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Glows in the signal's color; nil fades it out.
    func show(_ signal: AttentionSignal?) {
        if let signal {
            let color = SidebarRenderer.color(for: signal)
            if color != self.color {
                self.color = color
                setNeedsDisplay(bounds)
            }
        }
        setVisible(signal != nil)
    }

    func setVisible(_ visible: Bool) {
        guard visible != glowVisible else { return }
        glowVisible = visible
        if visible {
            isHidden = false
            setNeedsDisplay(bounds)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                animator().alphaValue = 1
            }
            startPulse()
        } else {
            layer?.removeAnimation(forKey: "edgePulse")
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.3
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                if self?.glowVisible == false { self?.isHidden = true }
            })
        }
    }

    private func startPulse() {
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.35
        pulse.duration = 0.8
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer?.add(pulse, forKey: "edgePulse")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let colors: [CGColor] = [
            color.withAlphaComponent(0.5).cgColor,
            color.withAlphaComponent(0).cgColor
        ]
        let locations: [CGFloat] = [0, 1]
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                        colors: colors as CFArray,
                                        locations: locations) else { return }

        let startPt: CGPoint
        let endPt: CGPoint
        switch edge {
        case .left:
            startPt = CGPoint(x: bounds.minX, y: bounds.midY)
            endPt = CGPoint(x: bounds.maxX, y: bounds.midY)
        case .right:
            startPt = CGPoint(x: bounds.maxX, y: bounds.midY)
            endPt = CGPoint(x: bounds.minX, y: bounds.midY)
        case .top:
            startPt = CGPoint(x: bounds.midX, y: bounds.maxY)
            endPt = CGPoint(x: bounds.midX, y: bounds.minY)
        case .bottom:
            startPt = CGPoint(x: bounds.midX, y: bounds.minY)
            endPt = CGPoint(x: bounds.midX, y: bounds.maxY)
        }
        ctx.drawLinearGradient(gradient, start: startPt, end: endPt, options: [])
    }

    override func layout() {
        super.layout()
        setNeedsDisplay(bounds)
    }
}
