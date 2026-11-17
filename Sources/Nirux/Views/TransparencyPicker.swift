import AppKit

/// Settings › Appearance's four levels as tiles, as macOS's own Appearance
/// pane shows Light and Dark: each a miniature of the window over an
/// invented desktop, the chrome at that level's tint. VoiceOver reads a radio
/// group; with Full Keyboard Access, ← and → pick.
final class TransparencyPicker: NSView {
    static let tileSize = NSSize(width: 96, height: 64)

    private(set) var selection: InterfaceTransparency
    /// The user picked another level.
    var onPick: ((InterfaceTransparency) -> Void)?
    private(set) var tiles: [Tile] = []

    init(selection: InterfaceTransparency) {
        self.selection = selection
        super.init(frame: .zero)
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = Theme.Space.lg
        stack.translatesAutoresizingMaskIntoConstraints = false
        for level in InterfaceTransparency.allCases {
            let tile = Tile(level: level) { [weak self] in self?.pick(level) }
            tiles.append(tile)
            stack.addArrangedSubview(tile)
        }
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        showSelection()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func pick(_ level: InterfaceTransparency) {
        guard level != selection else { return }
        show(level)
        onPick?(level)
    }

    /// Shows `level` picked, without telling (a write that failed puts the
    /// last one back).
    func show(_ level: InterfaceTransparency) {
        selection = level
        showSelection()
    }

    private func showSelection() {
        for tile in tiles { tile.isSelected = tile.level == selection }
    }

    // MARK: Keyboard and VoiceOver

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { NSApp.isFullKeyboardAccessEnabled }

    override func keyDown(with event: NSEvent) {
        let levels = InterfaceTransparency.allCases
        guard let index = levels.firstIndex(of: selection) else { return super.keyDown(with: event) }
        switch event.specialKey {
        case .leftArrow?: if index > 0 { pick(levels[index - 1]) }
        case .rightArrow?: if index < levels.count - 1 { pick(levels[index + 1]) }
        default: super.keyDown(with: event)
        }
    }

    override func drawFocusRingMask() { bounds.fill() }
    override var focusRingMaskBounds: NSRect { bounds }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .radioGroup }
    override func accessibilityLabel() -> String? { "Interface" }
    override func accessibilityChildren() -> [Any]? { tiles }

    /// One level: its miniature and its name.
    final class Tile: NSView {
        let level: InterfaceTransparency
        private let press: () -> Void
        private let preview = NSImageView()
        private let title: NSTextField

        var isSelected = false {
            didSet {
                preview.layer?.borderColor = (isSelected ? Theme.Color.accent : Theme.Color.line).cgColor
                preview.layer?.borderWidth = isSelected ? 2 : 1
                title.textColor = isSelected ? Theme.Color.textPrimary : Theme.Color.textSecondary
            }
        }

        init(level: InterfaceTransparency, press: @escaping () -> Void) {
            self.level = level
            self.press = press
            title = NSTextField(labelWithString: level.title)
            super.init(frame: .zero)
            preview.image = Self.miniature(level)
            preview.wantsLayer = true
            preview.layer?.cornerRadius = Theme.Radius.card
            preview.layer?.masksToBounds = true
            preview.translatesAutoresizingMaskIntoConstraints = false
            preview.setAccessibilityElement(false)
            title.font = Theme.Font.caption
            title.alignment = .center
            title.translatesAutoresizingMaskIntoConstraints = false
            title.setAccessibilityElement(false)
            addSubview(preview)
            addSubview(title)
            NSLayoutConstraint.activate([
                preview.widthAnchor.constraint(equalToConstant: TransparencyPicker.tileSize.width),
                preview.heightAnchor.constraint(equalToConstant: TransparencyPicker.tileSize.height),
                preview.topAnchor.constraint(equalTo: topAnchor),
                preview.leadingAnchor.constraint(equalTo: leadingAnchor),
                preview.trailingAnchor.constraint(equalTo: trailingAnchor),
                title.topAnchor.constraint(equalTo: preview.bottomAnchor, constant: Theme.Space.xs),
                title.centerXAnchor.constraint(equalTo: centerXAnchor),
                title.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { press() }

        override func isAccessibilityElement() -> Bool { true }
        override func accessibilityRole() -> NSAccessibility.Role? { .radioButton }
        override func accessibilityLabel() -> String? { level.title }
        override func accessibilityValue() -> Any? { isSelected ? 1 : 0 }
        override func accessibilityPerformPress() -> Bool {
            press()
            return true
        }

        /// The window in miniature over an invented desktop: the sidebar
        /// and the bar at the level's chrome tint, a column of work, solid.
        static func miniature(_ level: InterfaceTransparency) -> NSImage {
            let size = TransparencyPicker.tileSize
            return NSImage(size: size, flipped: true) { rect in
                NSGradient(colors: [NSColor(hex: 0x3A5F8F), NSColor(hex: 0xC27A4E)])?.draw(in: rect, angle: 35)
                let tint = GlassView.tintColor(for: .chrome).withAlphaComponent(GlassView.tintAlpha(for: level, role: .chrome))
                let bar = NSRect(x: 0, y: 0, width: rect.width, height: 12)
                let sidebar = NSRect(x: 0, y: bar.maxY, width: rect.width * 0.3, height: rect.height - bar.maxY)
                tint.setFill()
                bar.fill(using: .sourceOver)
                sidebar.fill(using: .sourceOver)
                Theme.Color.surface.setFill()
                NSRect(x: sidebar.maxX + 3, y: bar.maxY + 3, width: rect.maxX - sidebar.maxX - 6, height: rect.height - bar.maxY - 6).fill()
                return true
            }
        }
    }
}

/// Says when macOS makes every level opaque (Reduce transparency, Increase
/// contrast), and follows those settings while it shows.
final class ForcedOpaqueNote: NSTextField {
    init() {
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        font = Theme.Font.caption
        textColor = Theme.Color.textSecondary
        update()
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(accessibilityDisplayOptionsChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil
        )
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func accessibilityDisplayOptionsChanged(_ notification: Notification) {
        update()
    }

    private func update() {
        let workspace = NSWorkspace.shared
        let text = Self.text(
            reducesTransparency: workspace.accessibilityDisplayShouldReduceTransparency,
            increasesContrast: workspace.accessibilityDisplayShouldIncreaseContrast
        )
        stringValue = text ?? ""
        isHidden = text == nil
    }

    static func text(reducesTransparency: Bool, increasesContrast: Bool) -> String? {
        let setting = reducesTransparency ? "Reduce transparency" : increasesContrast ? "Increase contrast" : nil
        return setting.map { "\($0) is on in System Settings › Accessibility › Display: Nirux draws opaque." }
    }
}

extension InterfaceTransparency {
    var title: String {
        switch self {
        case .opaque: return "Opaque"
        case .tinted: return "Tinted"
        case .glass: return "Glass"
        case .clear: return "Clear"
        }
    }

    /// What the level shows, under the tiles.
    var summary: String {
        switch self {
        case .opaque: return "Solid chrome: nothing shows through."
        case .tinted: return "The desktop shows faintly through the sidebar and the bar."
        case .glass: return "The desktop shows through the sidebar and the bar."
        case .clear: return "The desktop shows clearly through the sidebar and the bar."
        }
    }
}
