import AppKit

/// Horizontal tab bar shown above the Monaco surface. Each tab maps 1:1 to
/// a Monaco model on the JS side; closing a tab disposes the model, switching
/// a tab swaps `editor.setModel`. The bar is frame-laid (no NSStackView) so
/// we can size each tab to its filename and keep the rest of the editor
/// column's frame-based layout consistent.
@MainActor
final class EditorTabBar: NSView {
    struct Tab: Equatable {
        let path: String
        var isDirty: Bool
        var title: String?

        var displayName: String { title ?? (path as NSString).lastPathComponent }
    }

    private(set) var tabs: [Tab] = []
    private(set) var activePath: String?

    var onSelect: ((String) -> Void)?
    var onClose: ((String) -> Void)?

    static let tabHeight: CGFloat = 30

    private static let tabMinWidth: CGFloat = 100
    private static let tabMaxWidth: CGFloat = 220
    private static let bgColor = NSColor(red: 0.09, green: 0.09, blue: 0.13, alpha: 1)

    private let scrollView = NSScrollView()
    private let documentView = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Self.bgColor.cgColor

        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.horizontalScrollElasticity = .none
        scrollView.verticalScrollElasticity = .none
        scrollView.documentView = documentView
        addSubview(scrollView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        rebuild()
    }

    func update(tabs: [Tab], activePath: String?) {
        self.tabs = tabs
        self.activePath = activePath
        rebuild()
        scrollActiveIntoView()
    }

    /// `bounds.width` is the visible viewport — used to keep the document
    /// view at least as wide so the empty area still has the tab-bar bg.
    private func rebuild() {
        documentView.subviews.forEach { $0.removeFromSuperview() }

        var x: CGFloat = 0
        let h = bounds.height
        for tab in tabs {
            let item = TabItemView(tab: tab, isActive: tab.path == activePath)
            item.onSelect = { [weak self] in self?.onSelect?(tab.path) }
            item.onClose = { [weak self] in self?.onClose?(tab.path) }
            let w = idealWidth(for: tab.displayName, isDirty: tab.isDirty)
            item.frame = NSRect(x: x, y: 0, width: w, height: h)
            documentView.addSubview(item)
            x += w
        }
        documentView.frame = NSRect(x: 0, y: 0, width: max(x, scrollView.bounds.width), height: h)
    }

    private func idealWidth(for name: String, isDirty: Bool) -> CGFloat {
        let attr = NSAttributedString(
            string: name,
            attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium)]
        )
        let textWidth = attr.size().width
        // dirty dot (8) + horizontal padding (12 left / 8 right) + close button (20)
        let chrome: CGFloat = (isDirty ? 8 : 0) + 12 + 8 + 20
        return min(max(Self.tabMinWidth, ceil(textWidth) + chrome), Self.tabMaxWidth)
    }

    private func scrollActiveIntoView() {
        guard let active = activePath,
              let item = documentView.subviews.compactMap({ $0 as? TabItemView })
                .first(where: { $0.tab.path == active })
        else { return }
        documentView.scrollToVisible(item.frame)
    }

}

// MARK: - Tab item

@MainActor
private final class TabItemView: NSView {
    let tab: EditorTabBar.Tab
    let isActive: Bool
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?

    private let label = NSTextField(labelWithString: "")
    private let dirtyDot = NSView()
    private let closeButton = NSButton()

    private static let activeBg = NSColor(red: 0.13, green: 0.13, blue: 0.18, alpha: 1)
    private static let inactiveBg = NSColor.clear
    private static let activeAccent = NSColor.niruxAccent
    private var accentBar: CALayer?

    init(tab: EditorTabBar.Tab, isActive: Bool) {
        self.tab = tab
        self.isActive = isActive
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = (isActive ? Self.activeBg : Self.inactiveBg).cgColor

        if isActive {
            let bar = CALayer()
            bar.backgroundColor = Self.activeAccent.cgColor
            layer?.addSublayer(bar)
            accentBar = bar
        }

        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = isActive
            ? NSColor.white.withAlphaComponent(0.95)
            : NSColor.white.withAlphaComponent(0.55)
        label.lineBreakMode = .byTruncatingMiddle
        label.stringValue = tab.displayName
        label.toolTip = tab.title ?? tab.path
        addSubview(label)

        dirtyDot.wantsLayer = true
        dirtyDot.layer?.backgroundColor = NSColor(red: 0.95, green: 0.7, blue: 0.3, alpha: 1).cgColor
        dirtyDot.layer?.cornerRadius = 3
        dirtyDot.isHidden = !tab.isDirty
        addSubview(dirtyDot)

        closeButton.bezelStyle = .recessed
        closeButton.isBordered = false
        closeButton.title = "×"
        closeButton.font = .systemFont(ofSize: 14, weight: .regular)
        closeButton.contentTintColor = NSColor.white.withAlphaComponent(0.5)
        closeButton.target = self
        closeButton.action = #selector(closeAction)
        addSubview(closeButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let h = bounds.height
        let dotShown = !dirtyDot.isHidden
        let leftPad: CGFloat = 12
        let dotW: CGFloat = 6
        let dotGap: CGFloat = dotShown ? 8 : 0
        let closeSize: CGFloat = 18
        let rightPad: CGFloat = 6

        dirtyDot.frame = NSRect(x: leftPad, y: (h - dotW) / 2, width: dotW, height: dotW)
        closeButton.frame = NSRect(
            x: bounds.width - closeSize - rightPad,
            y: (h - closeSize) / 2,
            width: closeSize, height: closeSize
        )
        let labelX = leftPad + (dotShown ? dotW + dotGap : 0)
        let labelW = bounds.width - labelX - closeSize - rightPad - 4
        label.frame = NSRect(x: labelX, y: (h - 16) / 2, width: labelW, height: 16)

        accentBar?.frame = CGRect(x: 0, y: h - 2, width: bounds.width, height: 2)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        // Close button has its own action; skip the select if the click landed
        // there so the user doesn't bounce focus to a tab they're closing.
        if closeButton.frame.insetBy(dx: -2, dy: -2).contains(p) {
            super.mouseDown(with: event)
            return
        }
        // Middle-click anywhere on the tab also closes — matches VSCode/Cursor.
        if event.buttonNumber == 2 {
            onClose?()
            return
        }
        onSelect?()
    }

    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2 { onClose?(); return }
        super.otherMouseDown(with: event)
    }

    @objc private func closeAction() { onClose?() }
}
