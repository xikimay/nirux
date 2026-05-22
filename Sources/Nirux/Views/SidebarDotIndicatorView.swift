import AppKit

final class SidebarDotIndicatorView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }

    var items: [SidebarDotIndicatorItem] {
        didSet {
            toolTip = tooltipText
            needsDisplay = true
        }
    }
    var onSelect: ((SidebarDotIndicatorAction) -> Void)?

    private let tooltipText: String

    init(frame: NSRect, items: [SidebarDotIndicatorItem], tooltip: String) {
        self.items = items
        tooltipText = tooltip
        super.init(frame: frame)
        wantsLayer = true
        toolTip = tooltip
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        for (idx, rect) in dotRects().enumerated() where rect.insetBy(dx: -4, dy: -4).contains(point) {
            onSelect?(items[idx].action)
            return
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let pill = bounds.insetBy(dx: 0, dy: 1)
        ctx.setFillColor(NSColor(red: 0.08, green: 0.08, blue: 0.105, alpha: 0.88).cgColor)
        let path = CGMutablePath()
        path.addRoundedRect(in: pill, cornerWidth: pill.height / 2, cornerHeight: pill.height / 2)
        ctx.addPath(path)
        ctx.fillPath()

        for (idx, rect) in dotRects().enumerated() {
            let item = items[idx]
            let color = NSColor.niruxColor(hex: item.colorHex) ?? .niruxAccent
            if item.label != nil {
                drawActionBackground(in: rect, context: ctx)
            } else {
                ctx.setFillColor((item.isActive ? color : color.withAlphaComponent(0.45)).cgColor)
                ctx.fillEllipse(in: rect)
            }

            if item.hasAttention {
                ctx.setStrokeColor(NSColor.systemOrange.cgColor)
                ctx.setLineWidth(1.5)
                ctx.strokeEllipse(in: rect.insetBy(dx: -3, dy: -3))
            }

            drawLabelIfNeeded(item.label, in: rect, context: ctx)
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    static func preferredWidth(itemCount: Int) -> CGFloat {
        guard itemCount > 0 else { return 0 }
        let dotCount = max(itemCount - 1, 0)
        let dotsWidth = CGFloat(dotCount) * 8
        let actionWidth: CGFloat = 18
        let gaps = CGFloat(max(itemCount - 1, 0)) * 10
        return dotsWidth + actionWidth + gaps + 20
    }

    private func drawActionBackground(in rect: CGRect, context ctx: CGContext) {
        let actionRect = rect.insetBy(dx: 1, dy: 1)
        let actionPath = CGMutablePath()
        actionPath.addRoundedRect(
            in: actionRect,
            cornerWidth: actionRect.height / 2,
            cornerHeight: actionRect.height / 2
        )
        ctx.setFillColor(NSColor.niruxAccent.cgColor)
        ctx.addPath(actionPath)
        ctx.fillPath()
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.28).cgColor)
        ctx.setLineWidth(1)
        ctx.addPath(actionPath)
        ctx.strokePath()
    }

    private func drawLabelIfNeeded(_ label: String?, in rect: CGRect, context ctx: CGContext) {
        if label == "+" {
            let plusSize: CGFloat = 7
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.98).cgColor)
            ctx.setLineWidth(1.8)
            ctx.setLineCap(.round)
            ctx.move(to: CGPoint(x: rect.midX - plusSize / 2, y: rect.midY))
            ctx.addLine(to: CGPoint(x: rect.midX + plusSize / 2, y: rect.midY))
            ctx.move(to: CGPoint(x: rect.midX, y: rect.midY - plusSize / 2))
            ctx.addLine(to: CGPoint(x: rect.midX, y: rect.midY + plusSize / 2))
            ctx.strokePath()
        } else if let label {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: NSColor.white.withAlphaComponent(0.98)
            ]
            let size = label.size(withAttributes: attrs)
            label.draw(
                at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
                withAttributes: attrs
            )
        }
    }

    private func dotRects() -> [CGRect] {
        guard !items.isEmpty else { return [] }
        let normalSize: CGFloat = 8
        let activeSize: CGFloat = 10
        let actionSize: CGFloat = 18
        let gap: CGFloat = 10
        let widths = items.map { item in item.label != nil ? actionSize : (item.isActive ? activeSize : normalSize) }
        let totalW = widths.reduce(0, +) + CGFloat(max(items.count - 1, 0)) * gap
        var x = (bounds.width - totalW) / 2
        return items.map { item in
            let size = item.label != nil ? actionSize : (item.isActive ? activeSize : normalSize)
            defer { x += size + gap }
            return CGRect(x: x, y: (bounds.height - size) / 2, width: size, height: size)
        }
    }
}

private extension NSColor {
    static func niruxColor(hex: String) -> NSColor? {
        var raw = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("#") { raw.removeFirst() }
        guard raw.count == 6, let value = UInt32(raw, radix: 16) else { return nil }
        return NSColor(
            red: CGFloat((value >> 16) & 0xFF) / 255.0,
            green: CGFloat((value >> 8) & 0xFF) / 255.0,
            blue: CGFloat(value & 0xFF) / 255.0,
            alpha: 1
        )
    }
}
