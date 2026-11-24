import AppKit

/// Cup near the trailing end of the main window's title bar (left of the
/// Claude usage limits) while Nirux
/// keeps the Mac awake (see
/// `KeepAwakeController`); the tooltip says why. The rest of the time it
/// takes no room: the controller's `isHidden` only works for top and
/// bottom accessories (a hidden trailing one keeps its frame and stays
/// drawn), so the view hides and shrinks to nothing itself.
final class KeepAwakeIndicator: NSTitlebarAccessoryViewController {
    static let symbolName = Theme.Symbol.keepAwake
    private static let size = NSSize(width: 30, height: 22)

    private let imageView = NSImageView()

    init() {
        super.init(nibName: nil, bundle: nil)
        layoutAttribute = .trailing
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let container = NSView(frame: NSRect(origin: .zero, size: Self.size))
        container.isHidden = true
        imageView.image = NSImage(systemSymbolName: Self.symbolName, accessibilityDescription: nil)
        imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        imageView.contentTintColor = NSColor.white.withAlphaComponent(0.45)
        imageView.imageScaling = .scaleNone
        imageView.frame = container.bounds
        imageView.autoresizingMask = [.width, .height]
        container.addSubview(imageView)
        container.frame.size.width = 0
        view = container
    }

    func update(isActive: Bool, workingAgentCount: Int, isMergeQueueRunning: Bool = false, isAwaitingChecks: Bool = false) {
        view.isHidden = !isActive
        view.frame.size.width = isActive ? Self.size.width : 0
        relayOutTitleBar()
        let text = Self.toolTip(
            workingAgentCount: workingAgentCount, isMergeQueueRunning: isMergeQueueRunning, isAwaitingChecks: isAwaitingChecks
        )
        view.toolTip = text
        imageView.setAccessibilityLabel(text)
    }

    static func toolTip(workingAgentCount count: Int, isMergeQueueRunning: Bool = false, isAwaitingChecks: Bool = false) -> String {
        let reasons = [
            isMergeQueueRunning ? "a merge queue runs" : nil,
            count == 0 ? nil : count == 1 ? "1 agent works" : "\(count) agents work",
            isAwaitingChecks ? "pull request checks run" : nil
        ].compactMap { $0 }
        guard let last = reasons.last else {
            return "Keeping your Mac awake: no agent is working now, sleep is allowed again in about a minute."
        }
        let listed = reasons.count == 1 ? last : reasons.dropLast().joined(separator: ", ") + " and " + last
        return "Keeping your Mac awake while \(listed)."
    }
}
