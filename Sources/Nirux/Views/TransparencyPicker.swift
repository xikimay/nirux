import AppKit

/// Settings › Appearance's four levels as tiles, as macOS's own Appearance
/// pane shows Light and Dark: each a miniature of the window over an
/// invented desktop, the chrome at that level's tint. VoiceOver reads a radio
/// group; with Full Keyboard Access, ← and → pick.
final class TransparencyPicker: NSView {
    static let tileSize = NSSize(width: 96, height: 64)

    private(set) var selection: InterfaceTransparency
    /// The user picked another level: (picked, the one before).
    var onPick: ((InterfaceTransparency, InterfaceTransparency) -> Void)?
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
        let previous = selection
        show(level)
        onPick?(level, previous)
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

        /// The window in miniature over an invented desktop: its backdrop
        /// and the bar at the level's tint, a column of work solid.
        static func miniature(_ level: InterfaceTransparency) -> NSImage {
            let size = TransparencyPicker.tileSize
            return NSImage(size: size, flipped: true) { rect in
                NSGradient(colors: Theme.Color.previewDesktop)?.draw(in: rect, angle: 35)
                let alpha = GlassView.tintAlpha(for: level, role: .chrome)
                Theme.Color.canvas.withAlphaComponent(alpha).setFill()
                rect.fill(using: .sourceOver)
                let sidebarWidth = rect.width * 0.3
                Theme.Color.line.setFill()
                NSRect(x: sidebarWidth, y: 12, width: 1, height: rect.height - 12).fill(using: .sourceOver)
                GlassView.tintColor(for: .chrome).withAlphaComponent(alpha).setFill()
                let bar = NSRect(x: rect.midX - 22, y: 3, width: 44, height: 6)
                NSBezierPath(roundedRect: bar, xRadius: bar.height / 2, yRadius: bar.height / 2).fill()
                Theme.Color.surface.setFill()
                NSRect(x: sidebarWidth + 4, y: 14, width: rect.maxX - sidebarWidth - 7, height: rect.height - 17).fill()
                return true
            }
        }
    }
}

/// Under the tiles: what the level picked shows and, while macOS's Reduce
/// transparency or Increase contrast is on, that Nirux draws opaque. One
/// block, so that the section keeps its gap below when that note hides;
/// `onResize` after the note shows or hides, for the window to fit.
final class TransparencySummary: NSStackView {
    let line = SettingsForm.hint("")
    let forcedOpaque = SettingsForm.hint("")
    var onResize: (() -> Void)?

    init(level: InterfaceTransparency) {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = Theme.Space.sm
        addArrangedSubview(line)
        addArrangedSubview(forcedOpaque)
        show(level)
        updateNote()
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(accessibilityDisplayOptionsChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil
        )
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ level: InterfaceTransparency) {
        line.stringValue = level.summary
    }

    @objc private func accessibilityDisplayOptionsChanged(_ notification: Notification) {
        updateNote()
        onResize?()
    }

    private func updateNote() {
        let workspace = NSWorkspace.shared
        let text = Self.forcedOpaqueText(
            reducesTransparency: workspace.accessibilityDisplayShouldReduceTransparency,
            increasesContrast: workspace.accessibilityDisplayShouldIncreaseContrast
        )
        forcedOpaque.stringValue = text ?? ""
        forcedOpaque.isHidden = text == nil
    }

    static func forcedOpaqueText(reducesTransparency: Bool, increasesContrast: Bool) -> String? {
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
