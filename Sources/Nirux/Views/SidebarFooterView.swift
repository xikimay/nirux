import AppKit

/// The unfolded sidebar's foot (docs/design/glass-interface.md, 3.4): a
/// glass capsule with Tasks, the list the sidebar shows (always the current
/// one, on the selection's glass), the space's Board and the Session History.
/// Buttons, not tabs: Board opens what the rail's Board button opens, History
/// the panel of ⌘P's and the Space menu's "Session History…".
final class SidebarFooterView: NSView {
    static let height: CGFloat = 30
    /// Around the capsule, to the sidebar's edges.
    static let margin: CGFloat = 10
    /// The room it takes from the list.
    static var room: CGFloat { height + 2 * margin }

    var onBoard: (() -> Void)?
    var onHistory: (() -> Void)?

    var level: InterfaceTransparency {
        get { glass.level }
        set { glass.level = newValue }
    }

    private let glass: GlassView
    /// The current list: not a button, nothing to open.
    let tasksPill = NSView()
    private let tasksLabel = NSTextField(labelWithString: "Tasks")
    let boardButton = NiruxButton(title: "Board", kind: .quiet, size: .small)
    let historyButton = NiruxButton(title: "History", kind: .quiet, size: .small)

    init(level: InterfaceTransparency) {
        glass = GlassView(role: .chrome, level: level, cornerRadius: Self.height / 2)
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: Self.height))
        glass.frame = bounds
        glass.autoresizingMask = [.width, .height]
        addSubview(glass)
        // Its rim: at Opaque the chrome's glass is the sidebar's colour.
        wantsLayer = true
        layer?.cornerRadius = Self.height / 2
        layer?.borderWidth = 1
        layer?.borderColor = Theme.Color.line.cgColor

        tasksPill.wantsLayer = true
        tasksPill.layer?.cornerRadius = NiruxButton.Size.small.height / 2
        tasksPill.layer?.backgroundColor = Theme.Color.selectionGlass.cgColor
        tasksLabel.font = NiruxButton.Size.small.font
        tasksLabel.textColor = Theme.Color.textPrimary
        tasksLabel.alignment = .center
        tasksLabel.setAccessibilityElement(false)
        tasksPill.addSubview(tasksLabel)
        tasksPill.setAccessibilityElement(true)
        tasksPill.setAccessibilityRole(.staticText)
        tasksPill.setAccessibilityLabel("Tasks, the list shown")

        boardButton.target = self
        boardButton.action = #selector(boardPressed)
        boardButton.toolTip = "Board (\(NiruxShortcuts.board.chord.display))"
        historyButton.target = self
        historyButton.action = #selector(historyPressed)
        historyButton.toolTip = "Session History"
        for view in [tasksPill, boardButton, historyButton] { glass.contentView.addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        let inset: CGFloat = 3
        let width = (bounds.width - 2 * inset) / 3
        let height = NiruxButton.Size.small.height
        for (index, view) in [tasksPill, boardButton, historyButton].enumerated() {
            view.frame = NSRect(
                x: inset + CGFloat(index) * width, y: (bounds.height - height) / 2, width: width, height: height
            ).integral
        }
        let text = tasksLabel.fittingSize.height
        tasksLabel.frame = NSRect(x: 0, y: (tasksPill.bounds.height - text) / 2, width: tasksPill.bounds.width, height: text)
    }

    @objc private func boardPressed() { onBoard?() }
    @objc private func historyPressed() { onHistory?() }
}
