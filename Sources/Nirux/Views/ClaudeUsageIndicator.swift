import AppKit

/// "5h 42% · 7d 18% · Codex 7d 30%" at the trailing end of the main
/// window's title bar: the Claude plan usage limits (see
/// `ClaudeUsageLimits`), then Codex's as its rollouts last reported them
/// (`UsageMonitor`), a warning from 80% of any window like a nearly full
/// context. The tooltip gives each
/// window's reset. While the option is off or nothing is known it takes
/// no room: the controller's `isHidden` only works for top and bottom
/// accessories, so the view hides and shrinks to nothing itself.
/// First of the trailing accessories, it keeps the window's edge, at the
/// right end of the toolbar (`CommandBarToolbar`): the cup, which comes and
/// goes with every turn, appears to its left without moving it.
final class ClaudeUsageIndicator: NSTitlebarAccessoryViewController {
    private static let height: CGFloat = 22
    private static let padding: CGFloat = 6
    private static let normalColor = NSColor.white.withAlphaComponent(0.45)

    let label = NSTextField(labelWithString: "")
    private var claude: ClaudeUsageLimits?
    private var codex: CodexRateLimits?

    init() {
        super.init(nibName: nil, bundle: nil)
        layoutAttribute = .trailing
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 0, height: Self.height))
        container.isHidden = true
        label.font = Theme.Font.captionDigits
        label.textColor = Self.normalColor
        label.lineBreakMode = .byClipping
        container.addSubview(label)
        view = container
    }

    func update(limits: ClaudeUsageLimits?, now: TimeInterval) {
        claude = limits
        render(now: now)
    }

    func update(codex limits: CodexRateLimits?, now: TimeInterval) {
        codex = limits
        render(now: now)
    }

    private func render(now: TimeInterval) {
        defer { relayOutTitleBar() }
        let codexWindows = codex.map { UsageText.codexWindows($0, now: now) } ?? []
        guard claude != nil || !codexWindows.isEmpty else {
            view.isHidden = true
            view.frame.size.width = 0
            view.toolTip = nil
            label.toolTip = nil
            label.stringValue = ""
            return
        }
        let codexText = codexWindows.isEmpty ? nil : "Codex " + codexWindows.map { "\($0.name) \($0.percent)%" }.joined(separator: " · ")
        let text = [claude?.titleText, codexText].compactMap { $0 }.joined(separator: " · ")
        let isNearLimit = claude?.isNearLimit == true || codexWindows.contains { $0.percent >= ClaudeUsageLimits.nearLimitPercent }
        label.stringValue = isNearLimit ? text.asWarning : text
        label.textColor = isNearLimit ? .niruxWarning : Self.normalColor
        let codexLines = codexWindows.map { window in
            "\(window.name) window: \(window.percent)% used"
                + (window.resetsAt.map { ", " + ClaudeUsageLimits.resetText($0, now: now, calendar: .current) } ?? "")
        }
        label.setAccessibilityLabel([
            claude?.accessibilityText, codexLines.isEmpty ? nil : "Codex usage limits: " + codexLines.joined(separator: ", ")
        ].compactMap { $0 }.joined(separator: ". "))
        let tooltip = [
            claude?.tooltip(now: now), codexLines.isEmpty ? nil : (["Codex plan usage limits"] + codexLines).joined(separator: "\n")
        ].compactMap { $0 }.joined(separator: "\n\n")
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
