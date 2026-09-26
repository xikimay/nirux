import AppKit

/// Terminal title-bar chip offering to open a dev server that the terminal
/// printed: "● localhost:5173 ↗  ✕". Clicking the label opens it in a
/// browser column; ✕ dismisses the proposal.
final class LocalServerChipView: NSView {
    static let height: CGFloat = 20

    var onOpen: (() -> Void)?
    var onDismiss: (() -> Void)?

    private(set) var url: LocalServerURL?
    private let openButton = NSButton(title: "", target: nil, action: nil)
    private let dismissButton = NSButton(title: "✕", target: nil, action: nil)
    private var fullTitle = NSAttributedString()
    private var compactTitle = NSAttributedString()

    private static let horizontalPadding: CGFloat = 8
    private static let dismissWidth: CGFloat = 16

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Self.height / 2
        layer?.backgroundColor = NSColor.niruxAccent.withAlphaComponent(0.14).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.niruxAccent.withAlphaComponent(0.35).cgColor

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

    func configure(url: LocalServerURL) {
        guard url != self.url else { return }
        self.url = url
        fullTitle = Self.title(url.displayName)
        compactTitle = Self.title(":\(url.port)")
        openButton.attributedTitle = fullTitle
        openButton.toolTip = "Open \(url.urlString) in a browser column"
        openButton.setAccessibilityLabel("Open \(url.urlString) in a browser column")
        needsLayout = true
    }

    /// Width the chip takes within `maxWidth`, switching to the compact
    /// ":5173" label when the full host doesn't fit. Zero when even that
    /// doesn't fit — the caller hides the chip.
    func fittingWidth(maxWidth: CGFloat) -> CGFloat {
        for title in [fullTitle, compactTitle] {
            let width = Self.width(for: title)
            if width <= maxWidth {
                if openButton.attributedTitle != title { openButton.attributedTitle = title }
                return width
            }
        }
        return 0
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func layout() {
        super.layout()
        let height = bounds.height
        let dismissX = bounds.width - Self.dismissWidth - Self.horizontalPadding / 2
        dismissButton.frame = NSRect(x: dismissX, y: 0, width: Self.dismissWidth, height: height)
        openButton.frame = NSRect(x: Self.horizontalPadding, y: 0, width: max(0, dismissX - Self.horizontalPadding), height: height)
    }

    // Deferred one turn: both actions remove this chip from the title bar,
    // which must not happen inside the button's own mouse-tracking loop.
    @objc private func openClicked() {
        DispatchQueue.main.async { [weak self] in self?.onOpen?() }
    }

    @objc private func dismissClicked() {
        DispatchQueue.main.async { [weak self] in self?.onDismiss?() }
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
            .foregroundColor: NSColor(red: 0.72, green: 0.80, blue: 1.0, alpha: 0.95)
        ]))
        return title
    }
}
