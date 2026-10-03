import AppKit

/// A small drawn control of the sidebar: a count chip, a "⋯" menu button,
/// an action block's button. Clicks go through the sidebar's hit areas.
final class SidebarBadgeView: NSView {
    private let text: String
    private let textColor: NSColor
    private let fillColor: NSColor
    private let font: NSFont

    /// Colors drawn while `isHovered` — nil keeps the base colors, so only
    /// badges that opt in (the "⋯" action button) react to hover.
    var hoverTextColor: NSColor?
    var hoverFillColor: NSColor?
    var isHovered = false {
        didSet { if oldValue != isHovered { needsDisplay = true } }
    }
    var cornerRadius = Theme.Radius.control
    var borderColor: NSColor?
    /// An SF Symbol drawn before the text, in the text's color.
    var symbolName: String?
    /// Drawn only while the pointer is over its card (or the badge itself):
    /// the "⋯" of a card that isn't the selected one.
    var hidesUntilHover = false {
        didSet { if oldValue != hidesUntilHover { needsDisplay = true } }
    }
    var isCardHovered = false {
        didSet { if oldValue != isCardHovered { needsDisplay = true } }
    }

    init(text: String, textColor: NSColor, fillColor: NSColor, font: NSFont) {
        self.text = text
        self.textColor = textColor
        self.fillColor = fillColor
        self.font = font
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The width that fits the symbol and the text, padded like a button.
    var fittingWidth: CGFloat { contentWidth + SidebarExpandedMetrics.buttonPaddingX * 2 }

    private var contentWidth: CGFloat {
        let textWidth = text.isEmpty ? 0 : ceil(text.size(withAttributes: [.font: font]).width)
        let symbolWidth: CGFloat = symbolName == nil ? 0 : 12 + (text.isEmpty ? 0 : Theme.Space.xs)
        return textWidth + symbolWidth
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !hidesUntilHover || isCardHovered || isHovered else { return }
        let rect = bounds.integral.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
        (isHovered ? (hoverFillColor ?? fillColor) : fillColor).setFill()
        path.fill()
        if let borderColor {
            borderColor.setStroke()
            path.lineWidth = 1
            path.stroke()
        }

        let color = isHovered ? (hoverTextColor ?? textColor) : textColor
        var x = bounds.midX - contentWidth / 2
        if let symbolName, let image = SidebarRenderer.symbol(symbolName, color: color, pointSize: 10) {
            let size = image.size
            image.draw(in: NSRect(x: x + (12 - size.width) / 2, y: bounds.midY - size.height / 2,
                                  width: size.width, height: size.height))
            x += 12 + (text.isEmpty ? 0 : Theme.Space.xs)
        }
        guard !text.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: x, y: bounds.midY - size.height / 2), withAttributes: attrs)
    }
}
