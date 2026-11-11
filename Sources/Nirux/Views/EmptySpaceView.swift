import AppKit

/// What the content area shows while the active space has no workspace
/// (docs/design/spaces.md, "Interface"): the space's name and what to do next.
/// Spaces persist, so an empty one stays in the switcher; selecting it
/// shows this view instead of opening a workspace.
///
/// "Add Repository…" shows until the space has a repository or folder
/// (never in General, which has none). "New…" does what ⌘N does; it looks
/// like the default button and Return presses it while the view has the
/// keyboard. It has no key equivalent: a window's default button takes
/// Returns from anywhere, a hidden view must take none. "Start a Lead"
/// shows in every space but General (docs/design/spaces.md, "The Lead").
@MainActor
final class EmptySpaceView: NSView {
    struct Content: Equatable {
        var spaceName: String
        var offersAddRepository: Bool
        var offersLead = false
    }

    let titleLabel = NSTextField(labelWithString: "")
    let detailLabel = NSTextField(labelWithString: "Nothing open yet. Press \(NiruxShortcuts.newWorkspaceDisplay) to start.")
    let addRepositoryButton = NSButton(title: "Add Repository…", target: nil, action: nil)
    let startLeadButton = NSButton(title: "Start a Lead", target: nil, action: nil)
    let newButton = NSButton(title: "New…", target: nil, action: nil)

    var onAddRepository: (() -> Void)?
    var onStartLead: (() -> Void)?
    var onNew: (() -> Void)?

    private(set) var content: Content?

    init() {
        super.init(frame: .zero)
        autoresizingMask = [.width, .height]
        for label in [titleLabel, detailLabel] {
            label.alignment = .center
            label.lineBreakMode = .byTruncatingTail
            addSubview(label)
        }
        titleLabel.font = Theme.Font.display
        titleLabel.textColor = Theme.Color.textPrimary
        // The group carries the name: VoiceOver would read it twice.
        titleLabel.setAccessibilityElement(false)
        detailLabel.font = Theme.Font.body
        detailLabel.textColor = Theme.Color.textSecondary
        for button in [addRepositoryButton, startLeadButton, newButton] {
            button.bezelStyle = .rounded
            button.controlSize = .large
            button.target = self
            addSubview(button)
        }
        addRepositoryButton.action = #selector(addRepository(_:))
        startLeadButton.action = #selector(startLead(_:))
        newButton.action = #selector(new(_:))
        newButton.bezelColor = .controlAccentColor
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ content: Content) {
        guard content != self.content else { return }
        self.content = content
        titleLabel.stringValue = content.spaceName
        setAccessibilityLabel(content.spaceName)
        addRepositoryButton.isHidden = !content.offersAddRepository
        startLeadButton.isHidden = !content.offersLead
        needsLayout = true
    }

    /// The view itself takes the keyboard: a button only can with Full
    /// Keyboard Access on.
    override var acceptsFirstResponder: Bool { true }

    /// Return and Enter press New…, from the view or one of its buttons.
    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard modifiers.isEmpty, event.keyCode == 0x24 || event.keyCode == 0x4C else { return super.keyDown(with: event) }
        newButton.performClick(nil)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    /// The name, the line under it and the buttons, centered as one block.
    override func layout() {
        super.layout()
        let width = max(0, min(bounds.width - Theme.Space.xl * 2, 480))
        let buttons = [addRepositoryButton, startLeadButton, newButton].filter { !$0.isHidden }
        let sizes = buttons.map { button -> NSSize in
            let fitting = button.fittingSize
            return NSSize(width: max(ceil(fitting.width), 96), height: ceil(fitting.height))
        }
        let rowWidth = sizes.reduce(0) { $0 + $1.width } + Theme.Space.sm * CGFloat(max(sizes.count - 1, 0))
        let rowHeight = sizes.map(\.height).max() ?? 0
        let titleHeight = ceil(titleLabel.fittingSize.height)
        let detailHeight = ceil(detailLabel.fittingSize.height)
        let blockHeight = titleHeight + Theme.Space.xs + detailHeight + Theme.Space.lg + rowHeight

        var y = ((bounds.height + blockHeight) / 2).rounded()
        y -= titleHeight
        titleLabel.frame = NSRect(x: ((bounds.width - width) / 2).rounded(), y: y, width: width, height: titleHeight)
        y -= Theme.Space.xs + detailHeight
        detailLabel.frame = NSRect(x: ((bounds.width - width) / 2).rounded(), y: y, width: width, height: detailHeight)
        y -= Theme.Space.lg + rowHeight
        var x = ((bounds.width - rowWidth) / 2).rounded()
        for (button, size) in zip(buttons, sizes) {
            button.frame = NSRect(x: x, y: y + ((rowHeight - size.height) / 2).rounded(), width: size.width, height: size.height)
            x += size.width + Theme.Space.sm
        }
    }

    @objc private func addRepository(_ sender: Any?) {
        onAddRepository?()
    }

    @objc private func startLead(_ sender: Any?) {
        onStartLead?()
    }

    @objc private func new(_ sender: Any?) {
        onNew?()
    }
}
