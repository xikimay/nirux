import AppKit

/// A floating panel comes out of the control it belongs to and goes back
/// into it (depth study P7): from part of its size about the point of its
/// edge nearest the control, as the palette unfolds from the bar
/// (`CommandPalette.unfoldStart`), fading as a window: the frost behind
/// it ignores its layers' opacity. Its window's shadow waits until it is
/// whole. Its owner sets the end on time (`RequestPanel`): a fade stalls
/// while the display sleeps.
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
        NSPoint(
            x: min(max(source.midX, frame.minX), frame.maxX) - frame.minX,
            y: min(max(source.midY, frame.minY), frame.maxY) - frame.minY
        )
    }

    /// It comes out of `source` (with none, it fades in): from nothing and
    /// without its shadow, so set before it orders in.
    static func grow(_ panel: NSWindow, from source: NSRect?) {
        panel.hasShadow = false
        panel.alphaValue = 0
        let curve = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1.04)
        if let source {
            move(panel, from: start(of: panel, at: source), to: CATransform3DIdentity, duration: openDuration, curve: curve, holds: false)
        }
        fade(panel, to: 1, duration: openDuration, curve: CAMediaTimingFunction(name: .easeOut))
    }

    /// It goes back into `source` (with none, it fades out).
    static func shrink(_ panel: NSWindow, into source: NSRect?) {
        panel.hasShadow = false
        let curve = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1)
        if let source {
            move(panel, from: CATransform3DIdentity, to: start(of: panel, at: source), duration: closeDuration, curve: curve, holds: true)
        }
        fade(panel, to: 0, duration: closeDuration, curve: curve)
    }

    /// Its opacity, over `duration` (none: at once, ending a fade).
    static func fade(_ panel: NSWindow, to alpha: CGFloat, duration: CFTimeInterval = 0, curve: CAMediaTimingFunction? = nil) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = curve
            panel.animator().alphaValue = alpha
        }
    }

    /// Its content from one transform to another, `holds` the last one
    /// until it orders out.
    private static func move(
        _ panel: NSWindow, from: CATransform3D, to: CATransform3D,
        duration: CFTimeInterval, curve: CAMediaTimingFunction, holds: Bool
    ) {
        guard let layer = panel.contentView?.layer else { return }
        let move = CABasicAnimation(keyPath: "transform")
        move.fromValue = from
        move.toValue = to
        move.duration = duration
        move.timingFunction = curve
        if holds {
            move.fillMode = .forwards
            move.isRemovedOnCompletion = false
        }
        layer.add(move, forKey: key)
    }

    private static func start(of panel: NSWindow, at source: NSRect) -> CATransform3D {
        CATransform3DMakeAffineTransform(CommandPalette.unfoldStart(from: origin(of: source, in: panel.frame), scale: scale))
    }
}
