import AppKit

struct SidebarShortcutHint {
    let key: String
    let label: String
}

final class SidebarShortcutHintView: NSView {
    private let hints: [SidebarShortcutHint]

    init(hints: [SidebarShortcutHint]) {
        self.hints = hints
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        var x: CGFloat = 0
        for hint in hints {
            let width = drawItem(hint, x: x)
            x += width + 18
        }
    }

    private func drawItem(_ hint: SidebarShortcutHint, x: CGFloat) -> CGFloat {
        let keyFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold)
        let labelFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
        let keyAttrs: [NSAttributedString.Key: Any] = [
            .font: keyFont,
            .foregroundColor: NSColor.white.withAlphaComponent(0.66)
        ]
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: labelFont,
            .foregroundColor: NSColor.white.withAlphaComponent(0.52)
        ]

        let keySize = hint.key.size(withAttributes: keyAttrs)
        let keyRect = NSRect(x: x, y: 1, width: keySize.width + 12, height: 20)
        NSColor.white.withAlphaComponent(0.07).setFill()
        NSBezierPath(roundedRect: keyRect, xRadius: 5, yRadius: 5).fill()
        NSColor.white.withAlphaComponent(0.13).setStroke()
        NSBezierPath(roundedRect: keyRect.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5).stroke()

        hint.key.draw(
            at: NSPoint(x: keyRect.midX - keySize.width / 2, y: keyRect.midY - keySize.height / 2),
            withAttributes: keyAttrs
        )

        let labelSize = hint.label.size(withAttributes: labelAttrs)
        let labelOrigin = NSPoint(x: keyRect.maxX + 7, y: keyRect.midY - labelSize.height / 2)
        hint.label.draw(at: labelOrigin, withAttributes: labelAttrs)

        return keyRect.width + 7 + labelSize.width
    }
}
