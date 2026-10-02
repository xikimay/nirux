import AppKit

// MARK: - Toast

/// The window's one toast (see ToastView): above the columns, centered on
/// the viewport, over the column dots.
extension NiruxShellView {
    /// Long enough to read it; an error a little longer.
    static func toastDuration(for message: String, tone: ToastView.Tone) -> TimeInterval {
        min(6, 2.5 + Double(message.count) * 0.04) + (tone == .error ? 1 : 0)
    }

    func presentToast(_ message: String, tone: ToastView.Tone, duration: TimeInterval? = nil) {
        toastGeneration += 1
        let generation = toastGeneration
        // A new one, or one fading out, comes in; one on screen changes text.
        let comesIn = toast == nil || toast?.alphaValue == 0
        let toast = toast ?? ToastView()
        self.toast = toast
        toast.show(message, tone: tone)
        // Above whatever was added since.
        addSubview(toast, positioned: .above, relativeTo: nil)
        layoutToast()
        if comesIn { animateToast(toast, appearing: true) }
        NSAccessibility.post(
            element: toast,
            notification: .announcementRequested,
            userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue]
        )
        let delay = duration ?? Self.toastDuration(for: message, tone: tone)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, generation == self.toastGeneration else { return }
            self.dismissToast()
        }
    }

    func dismissToast() {
        guard let toast else { return }
        toastGeneration += 1
        let generation = toastGeneration
        animateToast(toast, appearing: false)
        // Not in the animation's completion: a locked screen holds it back.
        DispatchQueue.main.asyncAfter(deadline: .now() + ToastView.fadeDuration) { [weak self, weak toast] in
            guard let self, generation == self.toastGeneration, let toast, toast === self.toast else { return }
            toast.removeFromSuperview()
            self.toast = nil
        }
    }

    /// Over the column dots and the status bar, centered on the viewport.
    /// `relayout` passes the frames it is moving them to.
    func layoutToast(_ frames: ChromeFrames? = nil) {
        guard let toast else { return }
        let viewportFrame = frames?.viewport ?? viewport.frame
        let bottom = max(
            frames?.statusBar.maxY ?? (statusBar.isHidden ? 0 : statusBar.frame.maxY),
            frames?.indicator.maxY ?? columnIndicator.frame.maxY
        )
        toast.frame = toast.frame(centeredIn: NSRect(x: viewportFrame.minX, y: bottom, width: viewportFrame.width, height: 0))
        toast.needsLayout = true
    }

    /// Sets where it ends at once (alpha 1 or 0), then fades (and rises,
    /// unless Reduce Motion is on) on its layer alone.
    private func animateToast(_ toast: ToastView, appearing: Bool) {
        toast.alphaValue = appearing ? 1 : 0
        guard let layer = toast.layer else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = appearing ? 0 : 1
        fade.toValue = appearing ? 1 : 0
        var animations: [CAAnimation] = [fade]
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let rise = CABasicAnimation(keyPath: "transform.translation.y")
            rise.fromValue = appearing ? -ToastView.rise : 0
            rise.toValue = appearing ? 0 : ToastView.rise
            animations.append(rise)
        }
        let group = CAAnimationGroup()
        group.animations = animations
        group.duration = ToastView.fadeDuration
        group.timingFunction = CAMediaTimingFunction(name: appearing ? .easeOut : .easeIn)
        layer.add(group, forKey: "toast")
    }
}
