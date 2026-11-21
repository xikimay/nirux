import AppKit

/// A waiting task's only column, until it starts (docs/design/task-dependencies.md):
/// what it waits for, the task as the Lead wrote it, and Start Now.
final class WaitingTaskView: NSView {
    /// What the column says.
    struct Facts: Equatable {
        let state: MergeWait.WaitingState
        let repository: String
        let description: String
    }

    var onStart: (() -> Void)?
    private(set) var facts: Facts?

    private let heading = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let task = NSTextField(wrappingLabelWithString: "")
    let startButton = NSButton(title: "Start Now", target: nil, action: nil)

    override init(frame: NSRect) {
        super.init(frame: frame)
        heading.font = Theme.Font.title
        heading.lineBreakMode = .byTruncatingTail
        detail.font = Theme.Font.body
        detail.textColor = Theme.Color.textSecondary
        task.font = Theme.Font.body
        task.textColor = Theme.Color.textPrimary
        task.maximumNumberOfLines = Self.taskMaxLines
        task.lineBreakMode = .byTruncatingTail
        startButton.bezelStyle = .rounded
        startButton.font = Theme.Font.button
        startButton.target = self
        startButton.action = #selector(startClicked)
        startButton.toolTip = "Make its worktree from the repository's base branch, fetched now, and start its agent."
        for view in [heading, detail, task, startButton] as [NSView] { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ facts: Facts) {
        guard facts != self.facts else { return }
        self.facts = facts
        switch facts.state {
        case .waits(let awaited):
            heading.stringValue = "Waits for \(awaited) to merge"
            heading.textColor = Theme.Color.textPrimary
            detail.stringValue = "Then Nirux makes its worktree in \(facts.repository) from its base branch, fetched then, "
                + "and starts its agent with the task below. It has no worktree or agent until then."
        case .starting:
            heading.stringValue = "Starting"
            heading.textColor = Theme.Color.textPrimary
            detail.stringValue = "Nirux is making its worktree in \(facts.repository)."
        case .needsYou(let reason):
            heading.stringValue = "Needs you"
            heading.textColor = Theme.Color.waiting
            detail.stringValue = "\(reason). Start it now, ask the Lead to point it at another task, or close it."
        }
        task.stringValue = facts.description
        task.toolTip = facts.description
        startButton.isEnabled = facts.state != .starting
        setAccessibilityLabel(heading.stringValue)
        needsLayout = true
    }

    @objc private func startClicked() { onStart?() }

    override func draw(_ dirtyRect: NSRect) {
        Theme.Color.canvas.setFill()
        dirtyRect.fill()
    }

    override func layout() {
        super.layout()
        let width = max(1, min(bounds.width - 2 * Self.margin, Self.maxTextWidth))
        let x = (bounds.width - width) / 2
        var y = bounds.height - Self.margin
        for (field, gap) in [(heading, CGFloat(8)), (detail, 16), (task, 20)] {
            let height = ceil(field.sizeThatFits(NSSize(width: width, height: .greatestFiniteMagnitude)).height)
            y -= height
            field.frame = NSRect(x: x, y: y, width: width, height: height)
            y -= gap
        }
        startButton.sizeToFit()
        startButton.frame = NSRect(
            x: x, y: max(Self.margin, y - startButton.frame.height),
            width: startButton.frame.width + 20, height: startButton.frame.height
        )
    }

    override var isFlipped: Bool { false }

    private static let margin: CGFloat = 32
    private static let maxTextWidth: CGFloat = 560
    private static let taskMaxLines = 16
}
