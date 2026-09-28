import AppKit

/// The merge queue's confirmation sheet (docs/project-board.md, section 4):
/// what Start read of GitHub, the pull requests that join in their order,
/// with their heads and checks, those left out and why, what may go wrong
/// and what will happen. The user reorders it with ↑ and ↓; Nirux never
/// does. A sheet on the main window: nothing waits in a modal loop, so
/// tests click through it. The shell starts the queue from `onStart`.
@MainActor
final class MergeQueueConfirmationPanel: NSObject {
    /// The confirmation as shown, in the user's order.
    var onStart: ((MergeQueue.Confirmation) -> Void)?
    var onDismiss: (() -> Void)?

    let projectID: String
    private(set) var confirmation: MergeQueue.Confirmation?
    private(set) var isDryRun: Bool
    private var readingText: String
    private var error: String?

    private var panel: NSPanel?
    private weak var parentWindow: NSWindow?
    private var documentView: FlippedView?
    private(set) var startButton: NSButton?
    private(set) var cancelButton: NSButton?
    private(set) var statusLabel: NSTextField?
    /// ↑ and ↓ of each item, in list order.
    private(set) var moveButtons: [(up: NSButton, down: NSButton)] = []
    /// Every line of the sheet's list, top to bottom, for the tests.
    private(set) var lines: [String] = []

    private static let size = NSSize(width: 700, height: 640)
    private static let dryRunColor = NSColor.systemOrange
    private static let refusalColor = NSColor(red: 0.97, green: 0.46, blue: 0.56, alpha: 1)
    private static let primaryText = NSColor.white.withAlphaComponent(0.9)
    private static let secondaryText = NSColor.white.withAlphaComponent(0.5)

    static let dryRunExplanation = "Dry run: this build reads GitHub, then stops before its first change (a branch "
        + "update, a rerun or a merge). Nothing changes on GitHub. Only the installed Nirux runs a real queue."

    init(projectID: String, isDryRun: Bool, numbers: [Int]) {
        self.projectID = projectID
        self.isDryRun = isDryRun
        readingText = "Reading " + numbers.map { "#\($0)" }.joined(separator: ", ") + " on GitHub…"
    }

    var isShown: Bool { panel != nil }

    /// Shows the sheet, reading until `update` brings what was read.
    func show(attachedTo window: NSWindow?, repository: String, baseBranch: String) {
        let panel = buildPanel(repository: repository, baseBranch: baseBranch)
        self.panel = panel
        parentWindow = window
        render()
        if let window {
            window.beginSheet(panel)
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    func focus() {
        panel?.makeKeyAndOrderFront(nil)
    }

    func update(_ confirmation: MergeQueue.Confirmation) {
        self.confirmation = confirmation
        isDryRun = confirmation.isDryRun
        error = nil
        render()
    }

    /// Start was refused: the sheet stays, with why.
    func showError(_ message: String) {
        error = message
        render()
    }

    func dismiss() {
        guard let panel else { return }
        if let parentWindow, panel.sheetParent === parentWindow {
            parentWindow.endSheet(panel)
        }
        panel.orderOut(nil)
        self.panel = nil
        onDismiss?()
    }

    // MARK: - Actions

    @objc private func moveUp(_ sender: NSButton) { move(sender.tag, by: -1) }

    @objc private func moveDown(_ sender: NSButton) { move(sender.tag, by: 1) }

    private func move(_ index: Int, by offset: Int) {
        guard var confirmation else { return }
        confirmation.move(index, by: offset)
        self.confirmation = confirmation
        render()
    }

    @objc private func cancelAction() {
        dismiss()
    }

    @objc private func startAction() {
        guard let confirmation, confirmation.canStart else { return }
        onStart?(confirmation)
    }

    // MARK: - Rendering

    private func render() {
        guard let documentView, let scroll = documentView.enclosingScrollView else { return }
        documentView.subviews.forEach { $0.removeFromSuperview() }
        moveButtons = []
        lines = []
        let width = scroll.contentSize.width
        var y: CGFloat = 12

        func add(_ text: String, color: NSColor, font: NSFont = .systemFont(ofSize: 12), indent: CGFloat = 16,
                 trailing: CGFloat = 16, gap: CGFloat = 4) {
            let label = NSTextField(wrappingLabelWithString: text)
            label.font = font
            label.textColor = color
            label.isSelectable = true
            let labelWidth = max(40, width - indent - trailing)
            let height = ceil(label.sizeThatFits(NSSize(width: labelWidth, height: .greatestFiniteMagnitude)).height)
            label.frame = NSRect(x: indent, y: y, width: labelWidth, height: height)
            documentView.addSubview(label)
            lines.append(text)
            y += height + gap
        }
        func heading(_ text: String) {
            y += 8
            add(text, color: Self.secondaryText, font: .systemFont(ofSize: 11, weight: .semibold), gap: 6)
        }

        if isDryRun {
            add(Self.dryRunExplanation, color: Self.dryRunColor, font: .systemFont(ofSize: 12, weight: .semibold), gap: 8)
        }
        guard let confirmation else {
            add(readingText, color: Self.secondaryText)
            finishLayout(y: y)
            return
        }
        for refusal in confirmation.refusals {
            add(refusal, color: Self.refusalColor, font: .systemFont(ofSize: 12, weight: .medium))
        }
        for warning in confirmation.warnings {
            add("⚠︎ " + warning, color: Self.dryRunColor)
        }
        if !confirmation.items.isEmpty {
            heading("MERGES, IN THIS ORDER")
            for (index, item) in confirmation.items.enumerated() {
                let top = y
                let title = "\(index + 1). #\(item.entry.number)" + (item.title.map { "  \($0)" } ?? "")
                add(title, color: Self.primaryText, font: .systemFont(ofSize: 12.5, weight: .semibold), trailing: 90, gap: 2)
                add("\(item.entry.branch) · head \(WorktreeCleanup.short(item.entry.head)) · \(item.checks)",
                    color: Self.secondaryText, font: .monospacedSystemFont(ofSize: 11, weight: .regular), indent: 34,
                    trailing: 90, gap: 2)
                for note in item.notes {
                    add(note, color: Self.secondaryText, font: .systemFont(ofSize: 11), indent: 34, trailing: 90, gap: 2)
                }
                for warning in item.warnings {
                    add("⚠︎ " + warning, color: Self.dryRunColor, font: .systemFont(ofSize: 11), indent: 34, trailing: 90,
                        gap: 2)
                }
                let up = moveButton("↑", index: index, action: #selector(moveUp(_:)), enabled: index > 0)
                let down = moveButton("↓", index: index, action: #selector(moveDown(_:)),
                                      enabled: index < confirmation.items.count - 1)
                up.frame = NSRect(x: width - 82, y: top, width: 32, height: 22)
                down.frame = NSRect(x: width - 46, y: top, width: 32, height: 22)
                up.toolTip = "Merge #\(item.entry.number) earlier"
                down.toolTip = "Merge #\(item.entry.number) later"
                moveButtons.append((up, down))
                y = max(y, top + 26) + 8
            }
        }
        if !confirmation.excluded.isEmpty {
            heading("LEFT OUT")
            for left in confirmation.excluded {
                add("#\(left.number)" + (left.title.map { "  \($0)" } ?? "") + " — " + left.reason, color: Self.secondaryText)
            }
        }
        if confirmation.canStart {
            heading("WHAT HAPPENS")
            for line in confirmation.plan { add(line, color: Self.secondaryText, font: .systemFont(ofSize: 11.5)) }
        }
        finishLayout(y: y)
    }

    private func finishLayout(y: CGFloat) {
        guard let documentView, let scroll = documentView.enclosingScrollView else { return }
        documentView.setFrameSize(NSSize(width: scroll.contentSize.width, height: max(scroll.contentSize.height, y + 12)))
        let canStart = confirmation?.canStart == true
        startButton?.isEnabled = canStart
        startButton?.title = isDryRun ? "Start Dry Run" : "Start Queue"
        statusLabel?.stringValue = error ?? ""
        statusLabel?.toolTip = error
    }

    private func moveButton(_ title: String, index: Int, action: Selector, enabled: Bool) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.tag = index
        button.isEnabled = enabled
        documentView?.addSubview(button)
        return button
    }

    // MARK: - Construction

    private func buildPanel(repository: String, baseBranch: String) -> NSPanel {
        let size = Self.size
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.backgroundColor = NSColor(red: 0.105, green: 0.105, blue: 0.14, alpha: 1)

        let container = NSView(frame: NSRect(origin: .zero, size: size))
        let heading = NSTextField(labelWithString: isDryRun ? "Dry Run of the Merge Queue" : "Start the Merge Queue")
        heading.font = .systemFont(ofSize: 16, weight: .semibold)
        heading.textColor = isDryRun ? Self.dryRunColor : NSColor.white.withAlphaComponent(0.94)
        heading.frame = NSRect(x: 24, y: size.height - 46, width: size.width - 48, height: 22)
        container.addSubview(heading)
        let subheading = NSTextField(labelWithString: "\(repository) · into \(baseBranch)")
        subheading.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        subheading.textColor = Self.secondaryText
        subheading.frame = NSRect(x: 24, y: size.height - 68, width: size.width - 48, height: 16)
        container.addSubview(subheading)

        let listFrame = NSRect(x: 16, y: 64, width: size.width - 32, height: size.height - 64 - 84)
        let scroll = NSScrollView(frame: listFrame)
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 8
        scroll.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.03).cgColor
        scroll.layer?.borderWidth = 1
        scroll.layer?.borderColor = NSColor.white.withAlphaComponent(0.07).cgColor
        let document = FlippedView(frame: NSRect(origin: .zero, size: listFrame.size))
        scroll.documentView = document
        container.addSubview(scroll)

        let status = NSTextField(labelWithString: "")
        status.font = .systemFont(ofSize: 11)
        status.textColor = Self.refusalColor
        status.lineBreakMode = .byTruncatingTail
        status.frame = NSRect(x: 24, y: 24, width: size.width - 24 - 290, height: 16)
        container.addSubview(status)

        // Neither button answers Return: a queue that merges starts on a
        // deliberate click.
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelAction))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        cancel.frame = NSRect(x: size.width - 262, y: 17, width: 96, height: 30)
        container.addSubview(cancel)
        let start = NSButton(title: "Start Queue", target: self, action: #selector(startAction))
        start.bezelStyle = .rounded
        start.isEnabled = false
        start.frame = NSRect(x: size.width - 160, y: 17, width: 136, height: 30)
        container.addSubview(start)

        panel.contentView = container
        documentView = document
        statusLabel = status
        cancelButton = cancel
        startButton = start
        return panel
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
