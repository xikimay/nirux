import AppKit

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

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let rect = bounds.integral.insetBy(dx: 0.5, dy: 0.5)
        (isHovered ? (hoverFillColor ?? fillColor) : fillColor).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: isHovered ? (hoverTextColor ?? textColor) : textColor
        ]
        let size = text.size(withAttributes: attrs)
        text.draw(
            at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
            withAttributes: attrs
        )
    }
}
