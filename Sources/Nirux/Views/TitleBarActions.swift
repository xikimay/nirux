import AppKit

/// The main window's title bar, at its trailing end: New, Board and Search
/// in one capsule (docs/spaces.md, Interface). Added before the plan usage
/// limits and the keep-awake cup, it keeps the window's edge, and they come
/// and go on its left.
final class TitleBarActions: NSTitlebarAccessoryViewController {
    enum Action: Int, CaseIterable {
        case new, board, search

        var symbolName: String {
            switch self {
            case .new: Theme.Symbol.add
            case .board: Theme.Symbol.projectBoard
            case .search: Theme.Symbol.search
            }
        }

        /// The button's name and its shortcut.
        var title: String {
            switch self {
            case .new: "New…"
            case .board: "Board"
            case .search: "Search"
            }
        }

        var shortcut: NiruxShortcuts {
            switch self {
            case .new: .newWorkspace
            case .board: .board
            case .search: .commandPalette
            }
        }
    }

    static let buttonSize = NSSize(width: 30, height: 22)
    static let capsulePadding: CGFloat = 2
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
            width: Self.buttonSize.width * count + Self.capsulePadding * 2,
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
            let image = NSImage(systemSymbolName: action.symbolName, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .regular))
            let button = NSButton(image: image ?? NSImage(), target: self, action: #selector(pressed(_:)))
            button.tag = action.rawValue
            button.bezelStyle = .accessoryBarAction
            button.showsBorderOnlyWhileMouseInside = true
            button.imagePosition = .imageOnly
            button.contentTintColor = Theme.Color.textSecondary
            button.frame = NSRect(
                x: Self.capsulePadding + Self.buttonSize.width * CGFloat(position), y: Self.capsulePadding,
                width: Self.buttonSize.width, height: Self.buttonSize.height
            )
            button.toolTip = "\(action.title) (\(action.shortcut.chord.display))"
            button.setAccessibilityLabel(action.title)
            capsule.addSubview(button)
            buttons[action] = button
        }
        view = container
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // Level with the traffic lights; the title bar sets the height.
        capsule.frame.origin.y = floor((view.bounds.height - capsule.frame.height) / 2)
    }

    @objc private func pressed(_ sender: NSButton) {
        guard let action = Action(rawValue: sender.tag) else { return }
        onAction?(action)
    }
}
