import AppKit

/// A short line over the columns that fades by itself — "No agent is
/// waiting on you": no beep, no alert, nothing to dismiss. VoiceOver reads
/// it out.
final class TransientHintView: NSView {
    private let label = NSTextField(labelWithString: "")
    private var generation = 0
    /// Between `show` and the start of the fade-out.
    private(set) var isShowing = false

    static let visibleDuration: TimeInterval = 1.6
    private static let fadeOutDuration: TimeInterval = 0.3

    var text: String { label.stringValue }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = Theme.Color.raised.withAlphaComponent(0.96).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = NSColor.white.withAlphaComponent(0.85)
        label.alignment = .center
        addSubview(label)
        alphaValue = 0
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Clicks go through to the columns below.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Shows `text` centered at the top of `area` (in the superview's
    /// coordinates), then fades it out. A new hint replaces the one
    /// showing and starts the time over.
    func show(_ text: String, topCenteredIn area: NSRect) {
        label.stringValue = text
        let size = label.intrinsicContentSize
        let width = ceil(size.width) + 28
        let height = ceil(size.height) + 14
        frame = NSRect(x: area.midX - width / 2, y: area.maxY - 16 - height, width: width, height: height).integral
        label.frame = NSRect(x: 14, y: (frame.height - ceil(size.height)) / 2, width: ceil(size.width), height: ceil(size.height))
        isHidden = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            animator().alphaValue = 1
        }
        NSAccessibility.post(
            element: NSApp.mainWindow ?? self,
            notification: .announcementRequested,
            userInfo: [
                .announcement: text,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue
            ]
        )

        isShowing = true
        generation += 1
        let shown = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.visibleDuration) { [weak self] in
            guard let self, self.generation == shown else { return }
            self.isShowing = false
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.fadeOutDuration
                self.animator().alphaValue = 0
            }
            // Out of VoiceOver's reach once faded.
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.fadeOutDuration) { [weak self] in
                guard let self, self.generation == shown else { return }
                self.isHidden = true
            }
        }
    }
}
