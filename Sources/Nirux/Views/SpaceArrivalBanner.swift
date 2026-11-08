import AppKit

/// Says that a workspace opened in the default space because no space
/// claims its folder (docs/spaces.md, "Routing", rule 4), with "Move to…"
/// and "Anchor to…" menus. At the bottom of the viewport, where the toast
/// shows; the toast goes above it. Unlike the toast it takes clicks, and
/// keys don't put it away: the agent it opened may be typed into.
@MainActor
final class SpaceArrivalBanner: NSView {
    private enum Style {
        static let height: CGFloat = 36
    }

    static let duration: TimeInterval = 12

    /// The workspace it is about.
    private(set) var workspaceID = ""
    private(set) var message = ""
    let label = NSTextField(labelWithString: "")
    let moveButton = NSButton(title: "Move to…", target: nil, action: nil)
    let anchorButton = NSButton(title: "Anchor to…", target: nil, action: nil)
    let closeButton = NSButton(title: "", target: nil, action: nil)

    /// Each button's menu, built when it is clicked: spaces may have changed.
    var moveMenu: (() -> NSMenu?)?
    var anchorMenu: (() -> NSMenu?)?
    var onClose: (() -> Void)?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 0, height: Style.height))
        wantsLayer = true
        layer?.cornerRadius = Theme.Radius.card
        layer?.backgroundColor = Theme.Color.raised.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = Theme.Color.lineStrong.cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.5
        layer?.shadowOffset = CGSize(width: 0, height: -8)
        layer?.shadowRadius = 12
        label.font = Theme.Font.body
        label.textColor = Theme.Color.textPrimary
        label.lineBreakMode = .byTruncatingMiddle
        addSubview(label)
        for button in [moveButton, anchorButton] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = Theme.Font.caption
            button.target = self
            addSubview(button)
        }
        moveButton.action = #selector(showMoveMenu(_:))
        anchorButton.action = #selector(showAnchorMenu(_:))
        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        closeButton.contentTintColor = Theme.Color.textSecondary
        closeButton.target = self
        closeButton.action = #selector(close(_:))
        addSubview(closeButton)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ message: String, workspaceID: String, offersMove: Bool) {
        self.message = message
        self.workspaceID = workspaceID
        label.stringValue = message
        setAccessibilityLabel(message)
        moveButton.isHidden = !offersMove
        needsLayout = true
    }

    /// Centered on `area`'s bottom edge plus the toast's gap, never wider
    /// than `area` minus a margin.
    func frame(centeredIn area: NSRect) -> NSRect {
        let buttons = visibleButtons.reduce(0) { $0 + ceil($1.fittingSize.width) + Theme.Space.sm }
        let content = ceil(label.fittingSize.width) + Theme.Space.md + buttons + 16
        let width = min(content + Theme.Space.md * 2, max(0, area.width - Theme.Space.md * 4))
        return NSRect(
            x: (area.midX - width / 2).rounded(), y: area.minY + ToastView.bottomGap,
            width: width, height: Style.height
        )
    }

    private var visibleButtons: [NSButton] { [moveButton, anchorButton].filter { !$0.isHidden } }

    override func layout() {
        super.layout()
        let closeSize: CGFloat = 16
        var right = bounds.width - Theme.Space.sm - closeSize
        closeButton.frame = NSRect(x: right, y: ((bounds.height - closeSize) / 2).rounded(), width: closeSize, height: closeSize)
        right -= Theme.Space.sm
        for button in visibleButtons.reversed() {
            let size = button.fittingSize
            right -= ceil(size.width)
            button.frame = NSRect(x: right, y: ((bounds.height - size.height) / 2).rounded(), width: ceil(size.width), height: size.height)
            right -= Theme.Space.sm
        }
        let labelHeight = label.fittingSize.height
        label.frame = NSRect(
            x: Theme.Space.md, y: ((bounds.height - labelHeight) / 2).rounded(),
            width: max(0, right - Theme.Space.md - Theme.Space.xs), height: labelHeight
        )
        layer?.shadowPath = CGPath(
            roundedRect: bounds, cornerWidth: Theme.Radius.card, cornerHeight: Theme.Radius.card, transform: nil
        )
    }

    @objc private func showMoveMenu(_ sender: NSButton) {
        pop(moveMenu?(), under: sender)
    }

    @objc private func showAnchorMenu(_ sender: NSButton) {
        pop(anchorMenu?(), under: sender)
    }

    @objc private func close(_ sender: Any?) {
        onClose?()
    }

    private func pop(_ menu: NSMenu?, under button: NSButton) {
        guard let menu else { return NSSound.beep() }
        let below = button.isFlipped ? button.bounds.maxY + 4 : -4
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: below), in: button)
    }
}
