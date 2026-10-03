import AppKit

/// Terminal header chip offering to open a dev server that the terminal
/// printed: "● localhost:5173 ↗  ✕". Clicking the label opens it in a
/// browser column; ✕ dismisses the proposal.
final class LocalServerChipView: NSView, ColumnHeaderAccessory {
    static let height: CGFloat = 20

    /// Called with the URL the chip showed when clicked.
    var onOpen: ((LocalServerURL) -> Void)?
    var onDismiss: ((LocalServerURL) -> Void)?

    private(set) var url: LocalServerURL?
    private let openButton = NSButton(title: "", target: nil, action: nil)
    private let dismissButton = NSButton(title: "✕", target: nil, action: nil)
    private var fullTitle = NSAttributedString()
    private var compactTitle = NSAttributedString()
    private var fullWidth: CGFloat = 0
    private var compactWidth: CGFloat = 0
    /// Which title the button shows (its getter returns a restyled copy,
    /// so comparing titles never matches).
    private var showsCompactTitle: Bool?

    private static let horizontalPadding: CGFloat = 8
    private static let dismissWidth: CGFloat = 16

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Self.height / 2
        layer?.backgroundColor = Theme.Color.accent.withAlphaComponent(0.14).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = Theme.Color.accent.withAlphaComponent(0.35).cgColor
        isHidden = true

        openButton.isBordered = false
        openButton.bezelStyle = .inline
        openButton.target = self
        openButton.action = #selector(openClicked)
        addSubview(openButton)

        dismissButton.isBordered = false
        dismissButton.bezelStyle = .inline
        dismissButton.font = .systemFont(ofSize: 10, weight: .regular)
        dismissButton.contentTintColor = NSColor.white.withAlphaComponent(0.45)
        dismissButton.target = self
        dismissButton.action = #selector(dismissClicked)
        dismissButton.toolTip = "Dismiss"
        dismissButton.setAccessibilityLabel("Dismiss dev server suggestion")
        addSubview(dismissButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Show `url`, or clear the chip with nil. The view stays in the header
    /// either way: removing it could free a button mid-click.
    func configure(url: LocalServerURL?) {
        guard url != self.url else { return }
        self.url = url
        guard let url else {
            isHidden = true
            return
        }
        fullTitle = Self.title(url.displayName)
        compactTitle = Self.title(":\(url.port)")
        fullWidth = Self.width(for: fullTitle)
        compactWidth = Self.width(for: compactTitle)
        showsCompactTitle = nil
        openButton.toolTip = "Open \(url.urlString) in a browser column"
        openButton.setAccessibilityLabel("Open \(url.urlString) in a browser column")
        needsLayout = true
    }

    /// Width the chip takes within `maxWidth`: full label, else the compact
    /// ":5173" one, else zero (the header hides the chip), as without a URL.
    func width(fitting maxWidth: CGFloat) -> CGFloat {
        guard url != nil else { return 0 }
        if fullWidth <= maxWidth { return fullWidth }
        return compactWidth <= maxWidth ? compactWidth : 0
    }

    // The header drags the window; the chip, padding included, must not.
    override var mouseDownCanMoveWindow: Bool { false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let compact = bounds.width < fullWidth
        if compact != showsCompactTitle {
            showsCompactTitle = compact
            openButton.attributedTitle = compact ? compactTitle : fullTitle
        }
        let height = bounds.height
        let dismissX = bounds.width - Self.dismissWidth - Self.horizontalPadding / 2
        dismissButton.frame = NSRect(x: dismissX, y: 0, width: Self.dismissWidth, height: height)
        openButton.frame = NSRect(x: Self.horizontalPadding, y: 0, width: max(0, dismissX - Self.horizontalPadding), height: height)
    }

    // Deferred one turn: both actions remove the proposal, which must not
    // happen inside the button's own mouse-tracking loop. The URL is the
    // one shown at click time, even if a scan swaps it meanwhile.
    @objc private func openClicked() {
        guard let url else { return }
        DispatchQueue.main.async { [weak self] in self?.onOpen?(url) }
    }

    @objc private func dismissClicked() {
        guard let url else { return }
        DispatchQueue.main.async { [weak self] in self?.onDismiss?(url) }
    }

    private static func width(for title: NSAttributedString) -> CGFloat {
        // + 4: NSButton insets its title a little beyond the text width.
        ceil(title.size().width) + 4 + horizontalPadding + dismissWidth + horizontalPadding / 2
    }

    private static func title(_ text: String) -> NSAttributedString {
        let title = NSMutableAttributedString(string: "● ", attributes: [
            .font: NSFont.systemFont(ofSize: 8),
            .foregroundColor: NSColor.systemGreen,
            .baselineOffset: 1
        ])
        title.append(NSAttributedString(string: "\(text) ↗", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: Theme.Color.accent
        ]))
        return title
    }
}
