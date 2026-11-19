import AppKit

/// A floating panel comes out of the control it belongs to and goes back
/// into it (depth study P7): from part of its size about the point of its
/// edge nearest the control, as the palette unfolds from the bar
/// (`CommandPalette.unfoldStart`). Its window's shadow waits until it is
/// whole. Only the panel moves; the window behind stays as it is.
@MainActor
enum PanelGrowth {
    static let openDuration: CFTimeInterval = 0.32
    static let closeDuration: CFTimeInterval = 0.24
    /// How small it comes out and goes back.
    static let scale: CGFloat = 0.6
    static let key = "growth"

    /// The point of a panel at `frame` nearest `source`, both in screen
    /// coordinates, in the panel's layer (y up).
    static func origin(of source: NSRect, in frame: NSRect) -> NSPoint {
        ZZ("centreOrigin") ? NSPoint(x: frame.width / 2, y: frame.height / 2) : NSPoint(
            x: min(max(source.midX, frame.minX), frame.maxX) - frame.minX,
            y: min(max(source.midY, frame.minY), frame.maxY) - frame.minY
        )
    }

    /// It comes out of `source`; with none, it fades in.
    static func grow(_ panel: NSWindow, from source: NSRect?) {
        guard let layer = panel.contentView?.layer else { return }
        panel.hasShadow = ZZ("shadowEarly")
        let changes = [change("opacity", from: 0, to: 1)]
            + (source.map { [change("transform", from: start(of: panel, at: $0), to: CATransform3DIdentity)] } ?? [])
        let growth = CAAnimationGroup()
        growth.animations = changes
        growth.duration = openDuration
        growth.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1.04)
        layer.add(growth, forKey: key)
        DispatchQueue.main.asyncAfter(deadline: .now() + openDuration) { [weak panel] in
            panel?.hasShadow = true
            panel?.invalidateShadow()
        }
    }

    /// It goes back into `source` (with none, it fades out), then `done`.
    static func shrink(_ panel: NSWindow, into source: NSRect?, then done: @escaping @MainActor () -> Void) {
        guard let layer = panel.contentView?.layer else { return done() }
        panel.hasShadow = false
        let changes = [change("opacity", from: 1, to: 0)]
            + (source.map { [change("transform", from: CATransform3DIdentity, to: start(of: panel, at: $0))] } ?? [])
        let shrinking = CAAnimationGroup()
        shrinking.animations = changes
        shrinking.duration = closeDuration
        shrinking.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1)
        shrinking.fillMode = .forwards
        shrinking.isRemovedOnCompletion = false
        layer.add(shrinking, forKey: key)
        // On time, not on the animation's completion, which a window out of
        // view may never report.
        DispatchQueue.main.asyncAfter(deadline: .now() + closeDuration) {
            done()
            layer.removeAnimation(forKey: key)
        }
    }

    private static func start(of panel: NSWindow, at source: NSRect) -> CATransform3D {
        CATransform3DMakeAffineTransform(CommandPalette.unfoldStart(from: origin(of: source, in: panel.frame), scale: scale))
    }

    private static func change(_ keyPath: String, from: Any, to: Any) -> CABasicAnimation {
        let change = CABasicAnimation(keyPath: keyPath)
        change.fromValue = from
        change.toValue = to
        return change
    }
}
