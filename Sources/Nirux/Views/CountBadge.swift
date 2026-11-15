import AppKit

/// How many agents wait for the user: an amber disc with the count. Amber,
/// because that is all it says.
final class CountBadge: NSView {
    static let height: CGFloat = 18
    private let label = NSTextField(labelWithString: "")

    var count = 0 {
        didSet { label.stringValue = "\(count)" }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Theme.Color.waiting.cgColor
        label.font = Theme.Font.captionEmphasized
        label.textColor = Theme.Color.canvas
        label.alignment = .center
        // Its host says how many wait, in words.
        label.setAccessibilityElement(false)
        setAccessibilityElement(false)
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var fittingWidth: CGFloat { max(Self.height, ceil(label.attributedStringValue.size().width) + 10) }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        let lineHeight = ceil(label.font?.boundingRectForFont.height ?? 14)
        label.frame = NSRect(x: 0, y: ((bounds.height - lineHeight) / 2).rounded(), width: bounds.width, height: lineHeight)
    }
}
