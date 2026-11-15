import AppKit

/// A shortcut shown as a key cap: "⌘P".
final class KeyCap: NSView {
    static let height: CGFloat = 18
    private let label: NSTextField

    init(_ text: String) {
        label = NSTextField(labelWithString: text)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Theme.Radius.chip
        layer?.borderWidth = 1
        layer?.borderColor = Theme.Color.lineStrong.cgColor
        label.font = Theme.Font.caption
        label.textColor = Theme.Color.textSecondary
        label.alignment = .center
        // Its host says the shortcut, in words.
        label.setAccessibilityElement(false)
        setAccessibilityElement(false)
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var fittingWidth: CGFloat { ceil(label.attributedStringValue.size().width) + 10 }

    override func layout() {
        super.layout()
        let lineHeight = ceil(label.font?.boundingRectForFont.height ?? 14)
        label.frame = NSRect(x: 0, y: ((bounds.height - lineHeight) / 2).rounded(), width: bounds.width, height: lineHeight)
    }
}
