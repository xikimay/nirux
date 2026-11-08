import AppKit

/// The main window's title bar, at its trailing end: New, Board and Search
/// in one capsule (docs/spaces.md, Interface). Added before the plan usage
/// limits and the keep-awake cup, it keeps the window's edge, and they come
/// and go on its left.
final class TitleBarActions: NSTitlebarAccessoryViewController {
    enum Action: CaseIterable {
        case new, board, search

        var symbolName: String {
            switch self {
            case .new: Theme.Symbol.add
            case .board: Theme.Symbol.projectBoard
            case .search: Theme.Symbol.search
            }
        }

        /// The button's name: its VoiceOver label, its tooltip's start.
        var title: String {
            switch self {
            case .new: "New…"
            case .board: "Board"
            case .search: "Search"
            }
        }

        /// The tooltip: the name and the shortcut. In the editor ⌘P is
        /// Monaco's file picker, ⇧⌘P the palette.
        var toolTip: String {
            switch self {
            case .new: "\(title) (\(NiruxShortcuts.newWorkspace.chord.display))"
            case .board: "\(title) (\(NiruxShortcuts.board.chord.display))"
            case .search:
                "\(title) (\(NiruxShortcuts.commandPalette.chord.display), "
                    + "\(NiruxShortcuts.commandPaletteAlternate.chord.display) in the editor)"
            }
        }
    }

    /// Search's identifier: the palette closes on a press on it.
    static let searchButtonID = NSUserInterfaceItemIdentifier("nirux.titlebar.search")
    static let buttonSize = NSSize(width: 30, height: 22)
    static let capsulePadding: CGFloat = 2
    static let buttonGap: CGFloat = 2
    static let trailingMargin = Theme.Space.sm

    var onAction: ((Action) -> Void)?
    private(set) var buttons: [Action: NSButton] = [:]
    private let capsule = NSView()

    init() {
        super.init(nibName: nil, bundle: nil)
        layoutAttribute = .trailing
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let count = CGFloat(Action.allCases.count)
        let capsuleSize = NSSize(
            width: Self.buttonSize.width * count + Self.buttonGap * (count - 1) + Self.capsulePadding * 2,
            height: Self.buttonSize.height + Self.capsulePadding * 2
        )
        let container = NSView(frame: NSRect(x: 0, y: 0, width: capsuleSize.width + Self.trailingMargin, height: capsuleSize.height))
        capsule.frame = NSRect(origin: .zero, size: capsuleSize)
        capsule.wantsLayer = true
        capsule.layer?.cornerRadius = capsuleSize.height / 2
        capsule.layer?.backgroundColor = Theme.Color.fillHover.cgColor
        capsule.layer?.borderWidth = 1
        capsule.layer?.borderColor = Theme.Color.line.cgColor
        container.addSubview(capsule)

        for (position, action) in Action.allCases.enumerated() {
            let button = TitleBarButton(frame: NSRect(
                x: Self.capsulePadding + (Self.buttonSize.width + Self.buttonGap) * CGFloat(position), y: Self.capsulePadding,
                width: Self.buttonSize.width, height: Self.buttonSize.height
            ))
            // VoiceOver reads the cell, and the image's description.
            button.image = NSImage(systemSymbolName: action.symbolName, accessibilityDescription: action.title)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular))
            button.cell?.setAccessibilityLabel(action.title)
            if action == .search { button.identifier = Self.searchButtonID }
            button.target = self
            button.action = #selector(pressed(_:))
            button.toolTip = action.toolTip
            button.setAccessibilityLabel(action.title)
            capsule.addSubview(button)
            buttons[action] = button
        }
        view = container
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // Level with the traffic lights; the title bar sets the height.
        capsule.frame.origin.y = max(0, floor((view.bounds.height - capsule.frame.height) / 2))
    }

    @objc private func pressed(_ sender: NSButton) {
        guard let action = buttons.first(where: { $0.value === sender })?.key else { return }
        onAction?(action)
    }
}

/// A pill-shaped icon button of the capsule, filled from Theme while
/// hovered or pressed (the system's accessory-bar bezel draws a grey
/// rounded rectangle that crosses the capsule's ends). It leaves the
/// keyboard where it was.
private final class TitleBarButton: NSButton {
    private var isHovered = false {
        didSet { applyColors() }
    }
    private var isPressed = false {
        didSet { applyColors() }
    }
    private var hoverArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = ""
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        wantsLayer = true
        layer?.cornerRadius = frameRect.height / 2
        refusesFirstResponder = true
        contentTintColor = Theme.Color.textPrimary
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        super.mouseDown(with: event)
        isPressed = false
    }

    private func applyColors() {
        let fill = isPressed ? Theme.Color.fillPressed : isHovered ? Theme.Color.fillHover : .clear
        layer?.backgroundColor = fill.cgColor
    }
}
