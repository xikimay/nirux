import AppKit

/// A control in relief (depth study P9): under the pointer it rises a
/// little over a short shadow; pressed, it sinks. Its view's layer moves,
/// and a layer of its own casts the shadow, only outside the control's
/// shape, so a translucent fill doesn't darken. The view's layer must not
/// clip, which would cut the shadow off.
@MainActor
enum Relief {
    enum State: Equatable {
        case resting
        /// Under the pointer, risen `height` points.
        case lifted(height: CGFloat)
        case pressed
    }

    static let shadowName = "nirux.relief"
    static let key = "relief"
    static let pressedScale: CGFloat = 0.93
    static let duration: CFTimeInterval = 0.16

    /// `host`, a view's layer, in `state`, its shape `shape` (corners
    /// `radius`) in the host's coordinates. `animated`: from where it
    /// shows.
    static func show(_ state: State, on host: CALayer, shape: CGRect, radius: CGFloat, animated: Bool) {
        let shadow = host.sublayers?.first { $0.name == shadowName } ?? {
            let shadow = CALayer()
            shadow.name = shadowName
            shadow.opacity = 0
            host.insertSublayer(shadow, at: 0)
            return shadow
        }()
        reshape(shadow, in: host, shape: shape, radius: radius)
        let transform = CATransform3DMakeAffineTransform(self.transform(state, size: host.bounds.size, flipped: host.superlayer?.contentsAreFlipped() ?? false))
        let opacity: Float = state == .resting || state == .pressed ? 0 : 1
        // Already there: nothing starts again.
        guard !CATransform3DEqualToTransform(host.transform, transform) || shadow.opacity != opacity else { return }
        let shownTransform = host.presentation()?.transform ?? host.transform
        let shownOpacity = shadow.presentation()?.opacity ?? shadow.opacity
        host.transform = transform
        shadow.opacity = opacity
        guard animated else {
            host.removeAnimation(forKey: key)
            shadow.removeAnimation(forKey: key)
            return
        }
        let curve = CAMediaTimingFunction(name: .easeInEaseOut)
        let duration = state == .pressed ? 0.12 : Self.duration
        for (layer, keyPath, from, to) in [(host, "transform", shownTransform as Any, transform as Any), (shadow, "opacity", shownOpacity as Any, opacity as Any)] {
            let change = CABasicAnimation(keyPath: keyPath)
            change.fromValue = from
            change.toValue = to
            change.duration = duration
            change.timingFunction = curve
            layer.add(change, forKey: key)
        }
    }

    /// The shadow follows the control's new shape (a layout), if it has one.
    static func reshape(_ host: CALayer, shape: CGRect, radius: CGFloat) {
        guard let shadow = host.sublayers?.first(where: { $0.name == shadowName }) else { return }
        reshape(shadow, in: host, shape: shape, radius: radius)
    }

    private static func reshape(_ shadow: CALayer, in host: CALayer, shape: CGRect, radius: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shadow.frame = host.bounds
        Theme.Elevation.apply(
            .control, to: shadow, roundedRect: shape, radius: radius, cutOut: shadow.mask as? CAShapeLayer ?? CAShapeLayer()
        )
        CATransaction.commit()
    }

    /// Where `state` puts a layer of `size` in its superlayer: up whichever
    /// way the superlayer counts y; pressed, smaller about its middle and a
    /// little down.
    static func transform(_ state: State, size: NSSize, flipped: Bool) -> CGAffineTransform {
        let up: CGFloat = flipped ? -1 : 1
        switch state {
        case .resting:
            return .identity
        case .lifted(let height):
            return CGAffineTransform(translationX: 0, y: up * height)
        case .pressed:
            let scale = pressedScale
            return CGAffineTransform(translationX: size.width * (1 - scale) / 2, y: size.height * (1 - scale) / 2 - up * 0.5)
                .scaledBy(x: scale, y: scale)
        }
    }
}
