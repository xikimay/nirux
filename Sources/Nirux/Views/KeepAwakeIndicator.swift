import AppKit

/// Cup at the trailing end of the main window's title bar while Nirux keeps
/// the Mac awake (see `KeepAwakeController`); the tooltip says why.
final class KeepAwakeIndicator: NSTitlebarAccessoryViewController {
    static let symbolName = "cup.and.saucer.fill"
    private static let size = NSSize(width: 30, height: 22)

    private let imageView = NSImageView()

    init() {
        super.init(nibName: nil, bundle: nil)
        layoutAttribute = .trailing
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let container = NSView(frame: NSRect(origin: .zero, size: Self.size))
        imageView.image = NSImage(systemSymbolName: Self.symbolName, accessibilityDescription: nil)
        imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        imageView.contentTintColor = NSColor.white.withAlphaComponent(0.45)
        imageView.imageScaling = .scaleNone
        imageView.frame = container.bounds
        imageView.autoresizingMask = [.width, .height]
        container.addSubview(imageView)
        view = container
    }

    func update(isActive: Bool, workingAgentCount: Int) {
        isHidden = !isActive
        let text = Self.toolTip(workingAgentCount: workingAgentCount)
        view.toolTip = text
        imageView.setAccessibilityLabel(text)
    }

    static func toolTip(workingAgentCount count: Int) -> String {
        switch count {
        case 0: "Keeping your Mac awake: no agent is working now, sleep is allowed again in about a minute."
        case 1: "Keeping your Mac awake while 1 agent works."
        default: "Keeping your Mac awake while \(count) agents work."
        }
    }
}
