import AppKit

/// What some nightlies brought, by kind, with two actions: the card over the
/// work after an update (`floats`, on its own background), which opening
/// What's New puts away too, and the status bar's popover before one. It
/// never takes the keyboard (docs/design/changelog.md).
final class WhatsNewCardView: NSView {
    static let width: CGFloat = 340
    static let fadeDuration: TimeInterval = 0.2
    static let rise: CGFloat = 6

    var onSecondary: (() -> Void)?
    var onPrimary: (() -> Void)?
    let secondaryButton: NiruxButton
    let primaryButton: NiruxButton
    private let background = CALayer()
    private let stack = NSStackView()

    /// `shipped`: the entries to list, newest first; `linesPerKind`: how
    /// many a kind lists before "+N more".
    init(shipped: [Changelog.Entry], title: String, subtitle: String, linesPerKind: Int, actions: (secondary: String, primary: String), floats: Bool) {
        secondaryButton = NiruxButton(title: actions.secondary, kind: .secondary, size: .small)
        primaryButton = NiruxButton(title: actions.primary, kind: .primary, size: .small)
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 0))
        wantsLayer = true
        background.isHidden = !floats
        background.backgroundColor = Theme.Color.raised.cgColor
        background.cornerRadius = Theme.Radius.panel
        background.borderWidth = 1
        background.borderColor = Theme.Color.lineStrong.cgColor
        layer?.addSublayer(background)

        let visible = shipped.filter { $0.kind != .internal }
        let heading = Self.label(title, font: Theme.Font.title, color: Theme.Color.textPrimary)
        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: actions.secondary) ?? NSImage(), target: self, action: #selector(secondary))
        close.isBordered = false
        close.contentTintColor = Theme.Color.textTertiary
        close.refusesFirstResponder = true
        close.isHidden = !floats
        let header = NSStackView(views: [heading, NSView(), close])
        let since = Self.label(subtitle, font: Theme.Font.caption, color: Theme.Color.textSecondary)
        var rows: [NSView] = [header, since]
        for kind in [Changelog.Kind.new, .better, .fixed] {
            let entries = visible.filter { $0.kind == kind }
            guard !entries.isEmpty else { continue }
            let group = Self.label(kind.label.uppercased(), font: Theme.Font.label, color: Theme.Color.textTertiary)
            group.attributedStringValue = NSAttributedString(string: kind.label.uppercased(), attributes: [
                .font: Theme.Font.label, .foregroundColor: Theme.Color.textTertiary, .kern: Theme.Font.labelKern
            ])
            rows.append(group)
            rows += entries.prefix(linesPerKind).map { Self.label($0.title, font: Theme.Font.body, color: Theme.Color.textPrimary) }
            if entries.count > linesPerKind {
                rows.append(Self.label("+\(entries.count - linesPerKind) more", font: Theme.Font.caption, color: Theme.Color.textSecondary))
            }
        }
        let inside = shipped.count - visible.count
        let note = Self.label(inside > 0 ? "\(inside) under the hood" : "", font: Theme.Font.caption, color: Theme.Color.textTertiary)
        for button in [secondaryButton, primaryButton] {
            button.target = self
            button.refusesFirstResponder = true
        }
        secondaryButton.action = #selector(secondary)
        primaryButton.action = #selector(primary)
        rows.append(NSStackView(views: [note, NSView(), secondaryButton, primaryButton]))

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
        setAccessibilityLabel(title)
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
        Theme.Elevation.apply(.floating, to: background, roundedRect: background.bounds, radius: Theme.Radius.panel, cutOut: nil)
    }

    @objc private func secondary() { onSecondary?() }
    @objc private func primary() { onPrimary?() }

    private static func label(_ string: String, font: NSFont, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: string)
        label.font = font
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    static func count(_ value: Int, _ one: String, _ many: String) -> String {
        "\(value) \(value == 1 ? one : many)"
    }
}
