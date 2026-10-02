import AppKit

/// "AWS SSO expired" at the trailing end of the main window's title bar,
/// while a session needs a login (see `AWSSSOMonitor`). A click shows the
/// command and copies it on request: Nirux types nothing.
final class AWSSSOIndicator: NSTitlebarAccessoryViewController {
    static let title = "AWS SSO expired"
    private static let color = NSColor(red: 0.95, green: 0.7, blue: 0.3, alpha: 1)
    private static let size = NSSize(width: 118, height: 22)

    private let button = NSButton(title: title, target: nil, action: nil)
    /// Names of the expired sessions, sorted.
    private var sessions: [String] = []

    init() {
        super.init(nibName: nil, bundle: nil)
        layoutAttribute = .trailing
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let container = NSView(frame: NSRect(origin: .zero, size: Self.size))
        button.bezelStyle = .inline
        button.isBordered = false
        button.attributedTitle = NSAttributedString(string: Self.title, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: Self.color
        ])
        button.target = self
        button.action = #selector(showMenu)
        button.frame = container.bounds
        button.autoresizingMask = [.width, .height]
        container.addSubview(button)
        view = container
    }

    func update(expiredSessions: [String]) {
        sessions = expiredSessions.sorted()
        isHidden = sessions.isEmpty
        let text = "Log in again before an agent's next aws call fails: \(sessions.joined(separator: ", "))"
        view.toolTip = text
        button.setAccessibilityLabel(text)
    }

    /// Each command shows as a disabled item (no action), then its Copy.
    func menu() -> NSMenu {
        let menu = NSMenu()
        for session in sessions {
            let command = AWSSSOStatus.loginCommand(session: session)
            menu.addItem(NSMenuItem(title: command, action: nil, keyEquivalent: ""))
            menu.addClosureItem(title: "Copy Command") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            }
        }
        return menu
    }

    @objc private func showMenu() {
        menu().popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 4), in: button)
    }

}
