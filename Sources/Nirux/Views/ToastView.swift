import AppKit

/// A short message at the bottom of the window: why an action did nothing
/// or failed, where Nirux used to beep. One line, one at a time (the next
/// replaces it); it fades out by itself and never takes a click or the
/// keyboard. Shown through `NSView.showToast`.
final class ToastView: NSView {
    enum Tone: Equatable {
        /// Nothing to do, or nothing happened.
        case info
        /// Something failed.
        case error
    }

    /// The visual system's values (design/visual-system) in one place,
    /// named after its Theme tokens, until they land.
    @MainActor
    private enum Style {
        /// Theme.Color.raised
        static let raised = NSColor(srgbRed: 0x29 / 255, green: 0x29 / 255, blue: 0x33 / 255, alpha: 1)
        /// Theme.Color.lineStrong
        static let lineStrong = NSColor.white.withAlphaComponent(0.12)
        /// Theme.Color.textPrimary
        static let textPrimary = NSColor(srgbRed: 0xEC / 255, green: 0xEC / 255, blue: 0xF1 / 255, alpha: 1)
        /// Theme.Color.textSecondary
        static let textSecondary = NSColor(srgbRed: 0xA0 / 255, green: 0xA0 / 255, blue: 0xAD / 255, alpha: 1)
        /// Theme.Color.error
        static let error = NSColor(srgbRed: 0xF0 / 255, green: 0x65 / 255, blue: 0x6B / 255, alpha: 1)
        /// Theme.Font.body
        static let font = NSFont.systemFont(ofSize: 12)
        static let height: CGFloat = 28
        /// Theme.Space.m
        static let paddingX: CGFloat = 12
        /// Theme.Space.s
        static let iconGap: CGFloat = 8
        static let iconPointSize: CGFloat = 12
    }

    /// Above the column dots at the bottom of the viewport.
    static let bottomGap: CGFloat = 16
    /// In and out: a fade and a small rise (a fade only with Reduce Motion).
    static let fadeDuration: TimeInterval = 0.18
    static let rise: CGFloat = 4

    private(set) var message = ""
    private(set) var tone = Tone.info
    private let label = NSTextField(labelWithString: "")
    private let icon = NSImageView()

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 0, height: Style.height))
        wantsLayer = true
        layer?.cornerRadius = Style.height / 2
        layer?.backgroundColor = Style.raised.cgColor
        layer?.borderWidth = 1
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.5
        layer?.shadowOffset = CGSize(width: 0, height: -8)
        layer?.shadowRadius = 12
        label.font = Style.font
        label.textColor = Style.textPrimary
        label.lineBreakMode = .byTruncatingTail
        label.setAccessibilityElement(false)
        icon.imageScaling = .scaleProportionallyDown
        icon.setAccessibilityElement(false)
        addSubview(icon)
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // Never in the way of the columns under it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ message: String, tone: Tone) {
        self.message = message
        self.tone = tone
        label.stringValue = message
        setAccessibilityValue(message)
        let symbol = tone == .error ? "exclamationmark.triangle.fill" : "info.circle"
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: Style.iconPointSize, weight: .regular))
        icon.contentTintColor = tone == .error ? Style.error : Style.textSecondary
        layer?.borderColor = (tone == .error ? Style.error.withAlphaComponent(0.45) : Style.lineStrong).cgColor
    }

    /// Its frame, centered on `area`'s bottom edge plus `bottomGap`, never
    /// wider than `area` minus a margin.
    func frame(centeredIn area: NSRect) -> NSRect {
        let iconWidth = icon.image?.size.width ?? 0
        let content = iconWidth + Style.iconGap + ceil(label.fittingSize.width)
        let width = min(content + Style.paddingX * 2, max(0, area.width - Style.paddingX * 4))
        return NSRect(
            x: (area.midX - width / 2).rounded(), y: area.minY + Self.bottomGap,
            width: width, height: Style.height
        )
    }

    override func layout() {
        super.layout()
        let iconSize = icon.image?.size ?? .zero
        icon.frame = NSRect(
            x: Style.paddingX, y: ((bounds.height - iconSize.height) / 2).rounded(),
            width: iconSize.width, height: iconSize.height
        )
        let labelHeight = label.fittingSize.height
        let labelX = icon.frame.maxX + Style.iconGap
        label.frame = NSRect(
            x: labelX, y: ((bounds.height - labelHeight) / 2).rounded(),
            width: max(0, bounds.width - labelX - Style.paddingX), height: labelHeight
        )
        let radius = min(bounds.width, bounds.height) / 2
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }
}

extension NSView {
    /// Says why an action did nothing or failed without stopping anyone: a
    /// toast at the bottom of the Nirux window, a beep outside one.
    func showToast(_ message: String, tone: ToastView.Tone = .info) {
        guard let shell = window?.contentView as? NiruxShellView else { return NSSound.beep() }
        shell.presentToast(message, tone: tone)
    }
}
