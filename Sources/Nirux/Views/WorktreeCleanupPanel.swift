import AppKit

/// "Clean Up Merged Worktrees…": every worktree a workspace is open in,
/// with the outcome of its checks as they come in. Ready ones are checked
/// (unless an agent is busy), the others disabled with the reason. A sheet
/// on the main window, so the workspaces can't change underneath it. The
/// shell confirms the selection, then cleans up one worktree at a time and
/// reports on each row.
@MainActor
final class WorktreeCleanupPanel: NSObject {
    enum RowResult: Equatable {
        case running
        case done(String)
        case failed(String)
        case skipped(String)
    }

    /// The checked candidates, in list order.
    var onCleanUp: (([WorktreeCleanupCandidate]) -> Void)?
    var onDismiss: (() -> Void)?

    private(set) var candidates: [WorktreeCleanupCandidate] = []
    private(set) var checkedPaths: Set<String> = []
    private var results: [String: RowResult] = [:]
    private(set) var isRunning = false
    private var isFinished = false

    private var panel: NSPanel?
    private weak var parentWindow: NSWindow?
    private var checkboxes: [String: NSButton] = [:]
    private var detailLabels: [String: NSTextField] = [:]
    private var statusLabel: NSTextField?
    private var cleanUpButton: NSButton?
    private var cancelButton: NSButton?

    private static let size = NSSize(width: 720, height: 560)
    private static let rowHeight: CGFloat = 48

    var isVisible: Bool { panel?.isVisible == true }

    func show(attachedTo window: NSWindow, candidates: [WorktreeCleanupCandidate]) {
        self.candidates = candidates
        parentWindow = window
        let panel = buildPanel()
        self.panel = panel
        for candidate in candidates { render(candidate) }
        updateControls()
        window.beginSheet(panel)
    }

    func focus() {
        panel?.makeKeyAndOrderFront(nil)
    }

    func update(path: String, inspection: WorktreeCleanup.Inspection) {
        guard let index = candidates.firstIndex(where: { $0.path == path }) else { return }
        candidates[index].inspection = inspection
        if case .ready(_, preselected: true) = candidates[index].availability, !isRunning, !isFinished {
            checkedPaths.insert(path)
        }
        render(candidates[index])
        updateControls()
    }

    /// Agents and unsaved editors read again right before the confirmation.
    func replace(_ candidate: WorktreeCleanupCandidate) {
        guard let index = candidates.firstIndex(where: { $0.path == candidate.path }) else { return }
        candidates[index] = candidate
        if !Self.isSelectable(candidate) { checkedPaths.remove(candidate.path) }
        render(candidate)
        updateControls()
    }

    func beginRun() {
        isRunning = true
        updateControls()
        for candidate in candidates { render(candidate) }
    }

    func setResult(_ result: RowResult, for path: String) {
        results[path] = result
        if let candidate = candidates.first(where: { $0.path == path }) { render(candidate) }
        updateControls()
    }

    func finishRun() {
        isRunning = false
        isFinished = true
        updateControls()
    }

    func dismiss() {
        guard let panel else { return }
        parentWindow?.endSheet(panel)
        panel.orderOut(nil)
        self.panel = nil
        onDismiss?()
    }

    // MARK: - State

    static func isSelectable(_ candidate: WorktreeCleanupCandidate) -> Bool {
        switch candidate.availability {
        case .ready, .closeOnly: return true
        case .checking, .blocked: return false
        }
    }

    private var selectedCandidates: [WorktreeCleanupCandidate] {
        candidates.filter { checkedPaths.contains($0.path) && Self.isSelectable($0) }
    }

    private func updateControls() {
        let selectedCount = selectedCandidates.count
        cleanUpButton?.title = selectedCount == 0 ? "Clean Up…" : "Clean Up \(selectedCount)…"
        cleanUpButton?.isEnabled = selectedCount > 0 && !isRunning && !isFinished
        cancelButton?.title = isFinished ? "Done" : "Cancel"
        cancelButton?.isEnabled = !isRunning
        statusLabel?.stringValue = statusText()
    }

    private func statusText() -> String {
        if isRunning || isFinished {
            let done = results.values.filter { if case .done = $0 { return true } else { return false } }.count
            let failed = results.values.filter { if case .failed = $0 { return true } else { return false } }.count
            let failures = failed > 0 ? " · \(failed) failed" : ""
            return isRunning ? "Cleaning up… \(done) done\(failures)" : "Finished: \(done) done\(failures)"
        }
        let checking = candidates.filter { $0.inspection == nil }.count
        if checking > 0 { return "Checking \(candidates.count - checking) of \(candidates.count)…" }
        let ready = candidates.filter(Self.isSelectable).count
        return "\(ready) of \(candidates.count) can be cleaned up"
    }

    // MARK: - Rendering

    private func render(_ candidate: WorktreeCleanupCandidate) {
        guard let checkbox = checkboxes[candidate.path], let detail = detailLabels[candidate.path] else { return }
        checkbox.attributedTitle = NSAttributedString(
            string: candidate.title,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: NSColor.white.withAlphaComponent(0.9)
            ]
        )
        checkbox.toolTip = candidate.path
        checkbox.isEnabled = Self.isSelectable(candidate) && !isRunning && !isFinished
        checkbox.state = checkedPaths.contains(candidate.path) && Self.isSelectable(candidate) ? .on : .off

        let text: String
        let color: NSColor
        var toolTip: String?
        switch results[candidate.path] {
        case .running?:
            (text, color) = ("Cleaning up…", .niruxAccent)
        case .done(let message)?:
            (text, color) = (message, .systemGreen)
        case .failed(let message)?:
            (text, color, toolTip) = (message.replacingOccurrences(of: "\n", with: " "), .systemRed, message)
        case .skipped(let message)?:
            (text, color) = (message, .systemOrange)
        case nil:
            text = candidate.detail
            switch candidate.availability {
            case .checking:
                color = NSColor.white.withAlphaComponent(0.35)
            case .blocked(let problems):
                color = NSColor.systemOrange.withAlphaComponent(0.9)
                toolTip = problems.joined(separator: "\n")
            case .ready, .closeOnly:
                color = NSColor.white.withAlphaComponent(0.5)
            }
        }
        detail.stringValue = text
        detail.textColor = color
        detail.toolTip = toolTip ?? text
    }

    // MARK: - Construction

    private func buildPanel() -> NSPanel {
        let size = Self.size
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.backgroundColor = NSColor(red: 0.105, green: 0.105, blue: 0.14, alpha: 1)

        let container = NSView(frame: NSRect(origin: .zero, size: size))

        let heading = NSTextField(labelWithString: "Clean Up Merged Worktrees")
        heading.font = .systemFont(ofSize: 16, weight: .semibold)
        heading.textColor = NSColor.white.withAlphaComponent(0.94)
        heading.frame = NSRect(x: 24, y: size.height - 46, width: size.width - 48, height: 22)
        container.addSubview(heading)

        let explanation = NSTextField(wrappingLabelWithString:
            "For each checked worktree whose pull request is merged: deletes its folder and its local branch, "
            + "then closes the workspaces open in it. Remote branches are never touched, and nothing is merged.")
        explanation.font = .systemFont(ofSize: 11.5)
        explanation.textColor = NSColor.white.withAlphaComponent(0.5)
        explanation.frame = NSRect(x: 24, y: size.height - 84, width: size.width - 48, height: 32)
        container.addSubview(explanation)

        let listFrame = NSRect(x: 16, y: 64, width: size.width - 32, height: size.height - 64 - 96)
        let scroll = NSScrollView(frame: listFrame)
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 8
        scroll.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.03).cgColor
        scroll.layer?.borderWidth = 1
        scroll.layer?.borderColor = NSColor.white.withAlphaComponent(0.07).cgColor
        let listHeight = max(listFrame.height, CGFloat(candidates.count) * Self.rowHeight + 8)
        let list = FlippedView(frame: NSRect(x: 0, y: 0, width: listFrame.width, height: listHeight))
        for (index, candidate) in candidates.enumerated() {
            let top = 4 + CGFloat(index) * Self.rowHeight
            let checkbox = NSButton(checkboxWithTitle: candidate.title, target: self, action: #selector(toggle(_:)))
            checkbox.identifier = NSUserInterfaceItemIdentifier(candidate.path)
            checkbox.frame = NSRect(x: 14, y: top + 6, width: listFrame.width - 28, height: 18)
            checkbox.lineBreakMode = .byTruncatingMiddle
            list.addSubview(checkbox)
            let detail = NSTextField(labelWithString: "")
            detail.font = .systemFont(ofSize: 11)
            detail.lineBreakMode = .byTruncatingTail
            detail.frame = NSRect(x: 34, y: top + 25, width: listFrame.width - 48, height: 16)
            list.addSubview(detail)
            checkboxes[candidate.path] = checkbox
            detailLabels[candidate.path] = detail
        }
        if candidates.isEmpty {
            let empty = NSTextField(labelWithString: "No workspace is open in a linked worktree.")
            empty.font = .systemFont(ofSize: 12)
            empty.textColor = NSColor.white.withAlphaComponent(0.45)
            empty.alignment = .center
            empty.frame = NSRect(x: 0, y: listFrame.height / 2 - 10, width: listFrame.width, height: 18)
            list.addSubview(empty)
        }
        scroll.documentView = list
        container.addSubview(scroll)

        let status = NSTextField(labelWithString: "")
        status.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        status.textColor = NSColor.white.withAlphaComponent(0.45)
        status.frame = NSRect(x: 24, y: 24, width: size.width - 300, height: 16)
        container.addSubview(status)

        // Neither button answers Return: the clean-up takes a deliberate
        // click, and its confirmation follows.
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelAction))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        cancel.frame = NSRect(x: size.width - 262, y: 17, width: 96, height: 30)
        container.addSubview(cancel)
        let cleanUp = NSButton(title: "Clean Up…", target: self, action: #selector(cleanUpAction))
        cleanUp.bezelStyle = .rounded
        cleanUp.frame = NSRect(x: size.width - 160, y: 17, width: 136, height: 30)
        container.addSubview(cleanUp)

        panel.contentView = container
        statusLabel = status
        cleanUpButton = cleanUp
        cancelButton = cancel
        return panel
    }

    @objc private func toggle(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue else { return }
        if sender.state == .on { checkedPaths.insert(path) } else { checkedPaths.remove(path) }
        updateControls()
    }

    @objc private func cancelAction() {
        guard !isRunning else { return }
        dismiss()
    }

    @objc private func cleanUpAction() {
        let selected = selectedCandidates
        guard !selected.isEmpty, !isRunning, !isFinished else { return }
        onCleanUp?(selected)
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
