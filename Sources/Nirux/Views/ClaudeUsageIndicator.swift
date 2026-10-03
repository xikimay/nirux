import AppKit

/// "5h 42% · 7d 18%" at the trailing end of the main window's title bar:
/// the Claude plan usage limits (see `ClaudeUsageLimits`), orange from 80%
/// of either window like a nearly full context. The tooltip gives each
/// window's reset. While the option is off or nothing is known it takes
/// no room: the controller's `isHidden` only works for top and bottom
/// accessories, so the view hides and shrinks to nothing itself.
/// It sits at the very end, left of nothing: the cup, which comes and goes
/// with every turn, appears to its left without moving it.
final class ClaudeUsageIndicator: NSTitlebarAccessoryViewController {
    private static let height: CGFloat = 22
    private static let padding: CGFloat = 6
    private static let normalColor = NSColor.white.withAlphaComponent(0.45)

    let label = NSTextField(labelWithString: "")

    init() {
        super.init(nibName: nil, bundle: nil)
        layoutAttribute = .trailing
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 0, height: Self.height))
        container.isHidden = true
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        label.textColor = Self.normalColor
        label.lineBreakMode = .byClipping
        container.addSubview(label)
        view = container
    }

    func update(limits: ClaudeUsageLimits?, now: TimeInterval) {
        guard let limits else {
            view.isHidden = true
            view.frame.size.width = 0
            view.toolTip = nil
            label.toolTip = nil
            label.stringValue = ""
            return
        }
        label.stringValue = limits.titleText
        label.textColor = limits.isNearLimit ? .niruxNearLimit : Self.normalColor
        label.setAccessibilityLabel(limits.accessibilityText)
        let tooltip = limits.tooltip(now: now)
        view.toolTip = tooltip
        label.toolTip = tooltip
        label.sizeToFit()
        // The title bar sets the height; only the width follows the text.
        view.frame.size.width = label.frame.width + Self.padding * 2
        centerLabel()
        view.isHidden = false
    }

    /// Showing the limits, as opposed to taking no room.
    var isShowing: Bool { !view.isHidden && view.frame.width > 0 }

    override func viewDidLayout() {
        super.viewDidLayout()
        centerLabel()
    }

    /// Level with the traffic lights and the keep-awake cup.
    private func centerLabel() {
        label.frame.origin = NSPoint(x: Self.padding, y: floor((view.bounds.height - label.frame.height) / 2))
    }
}
