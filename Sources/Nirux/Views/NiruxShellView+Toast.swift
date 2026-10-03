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
        // A new one, one fading out or the same message again comes in;
        // another message on screen just replaces the text.
        let comesIn = toast == nil || toast?.alphaValue == 0 || toast?.message == message
        let toast = toast ?? ToastView()
        self.toast = toast
        toast.show(message, tone: tone)
        // Above whatever was added since.
        addSubview(toast, positioned: .above, relativeTo: nil)
        layoutToast()
        if comesIn { animateToast(toast, appearing: true) }
        toastShownAt = ProcessInfo.processInfo.systemUptime
        let priority: NSAccessibilityPriorityLevel = tone == .error ? .high : .medium
        NSAccessibility.post(
            element: window ?? toast,
            notification: .announcementRequested,
            userInfo: [.announcement: message, .priority: priority.rawValue]
        )
        let delay = duration ?? Self.toastDuration(for: message, tone: tone)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, generation == self.toastGeneration else { return }
            self.dismissToast()
        }
    }

    /// The next key or click in the window puts it away (NiruxApp's
    /// interceptors, which see the keys a terminal consumes): it sits over
    /// the bottom of the columns, an agent's prompt. Not in its first half
    /// second: one that came unasked (a diff that ended, a list read off
    /// the main thread) would vanish under a key already on its way.
    func dismissToastOnInput() {
        guard ProcessInfo.processInfo.systemUptime - toastShownAt > Self.toastInputGrace else { return }
        dismissToast()
    }

    static let toastInputGrace: TimeInterval = 0.5

    /// Fades it out, unless it already is.
    func dismissToast() {
        guard let toast, toast.alphaValue > 0 else { return }
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
