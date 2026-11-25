import AppKit

/// After an update, what the builds since the one you ran brought: a card
/// over the bottom right of the work, which stays until dismissed and never
/// takes the keyboard (docs/design/changelog.md).
final class WhatsNewCardView: NSView {
    static let width: CGFloat = 340
    /// Lines a kind lists before "+N more".
    static let linesPerKind = 2
    static let fadeDuration: TimeInterval = 0.2
    static let rise: CGFloat = 6

    var onDismiss: (() -> Void)?
    var onSeeAll: (() -> Void)?
    let dismissButton = NiruxButton(title: "Dismiss", kind: .secondary, size: .small)
    let seeAllButton = NiruxButton(title: "See All", kind: .primary, size: .small)
    private let background = CALayer()
    private let stack = NSStackView()

    /// `shipped`: the entries of the builds after `seen` up to the one
    /// running, newest first.
    init(shipped: [Changelog.Entry], seen: Int) {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 0))
        wantsLayer = true
        background.backgroundColor = Theme.Color.raised.cgColor
        background.cornerRadius = Theme.Radius.panel
        background.borderWidth = 1
        background.borderColor = Theme.Color.lineStrong.cgColor
        let shadow = Theme.Elevation.Level.floating
        background.shadowColor = NSColor.black.cgColor
        background.shadowOpacity = shadow.opacity
        background.shadowRadius = shadow.radius
        background.shadowOffset = CGSize(width: 0, height: -shadow.drop)
        layer?.addSublayer(background)

        let visible = shipped.filter { $0.kind != .internal }
        let title = Self.label("What’s new in Nirux", font: Theme.Font.title, color: Theme.Color.textPrimary)
        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Dismiss") ?? NSImage(), target: self, action: #selector(dismiss))
        close.isBordered = false
        close.contentTintColor = Theme.Color.textTertiary
        close.refusesFirstResponder = true
        let header = NSStackView(views: [title, NSView(), close])
        let nightlies = Set(shipped.map(\.build)).count
        let since = Self.label(
            "Since \(Changelog.name(ofBuild: seen)): \(Self.count(nightlies, "nightly", "nightlies")), \(Self.count(visible.count, "change", "changes"))",
            font: Theme.Font.caption, color: Theme.Color.textSecondary
        )
        var rows: [NSView] = [header, since]
        for kind in [Changelog.Kind.new, .better, .fixed] {
            let entries = visible.filter { $0.kind == kind }
            guard !entries.isEmpty else { continue }
            let heading = Self.label(kind.label.uppercased(), font: Theme.Font.label, color: Theme.Color.textTertiary)
            heading.attributedStringValue = NSAttributedString(string: kind.label.uppercased(), attributes: [
                .font: Theme.Font.label, .foregroundColor: Theme.Color.textTertiary, .kern: Theme.Font.labelKern
            ])
            rows.append(heading)
            rows += entries.prefix(Self.linesPerKind).map { Self.label($0.title, font: Theme.Font.body, color: Theme.Color.textPrimary) }
            if entries.count > Self.linesPerKind {
                rows.append(Self.label("+\(entries.count - Self.linesPerKind) more", font: Theme.Font.caption, color: Theme.Color.textSecondary))
            }
        }
        let inside = shipped.count - visible.count
        let note = Self.label(inside > 0 ? "\(inside) under the hood" : "", font: Theme.Font.caption, color: Theme.Color.textTertiary)
        for button in [dismissButton, seeAllButton] {
            button.target = self
            button.refusesFirstResponder = true
        }
        dismissButton.action = #selector(dismiss)
        seeAllButton.action = #selector(seeAll)
        rows.append(NSStackView(views: [note, NSView(), dismissButton, seeAllButton]))

        stack.setViews(rows, in: .top)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Theme.Space.xs
        stack.edgeInsets = NSEdgeInsets(top: Theme.Space.md, left: Theme.Space.lg, bottom: Theme.Space.md, right: Theme.Space.lg)
        for row in rows {
            row.widthAnchor.constraint(equalToConstant: Self.width - Theme.Space.lg * 2).isActive = true
        }
        stack.setCustomSpacing(Theme.Space.sm, after: since)
        stack.setCustomSpacing(Theme.Space.md, after: rows[rows.count - 2])
        addSubview(stack)
        frame.size.height = stack.fittingSize.height
        stack.frame = bounds
        stack.autoresizingMask = [.width, .height]
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("What’s new in Nirux")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The card's text as VoiceOver and the tests read it.
    var text: String {
        stack.arrangedSubviews.flatMap { ($0 as? NSStackView)?.arrangedSubviews ?? [$0] }
            .compactMap { ($0 as? NSTextField)?.stringValue }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    override func layout() {
        super.layout()
        background.frame = bounds
        background.shadowPath = CGPath(roundedRect: bounds, cornerWidth: Theme.Radius.panel, cornerHeight: Theme.Radius.panel, transform: nil)
    }

    @objc private func dismiss() { onDismiss?() }
    @objc private func seeAll() { onSeeAll?() }

    private static func label(_ string: String, font: NSFont, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: string)
        label.font = font
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    private static func count(_ value: Int, _ one: String, _ many: String) -> String {
        "\(value) \(value == 1 ? one : many)"
    }
}
