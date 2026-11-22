import AppKit

extension NiruxShellView {
    func requestCheckpoint(in workspace: WorkspaceState?) {
        guard let workspace, let window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = "Save checkpoint for “\(workspace.title)”?"
        alert.informativeText = "Save the working copies of changed tracked files and record deletions."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "Label (optional)"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        let (id, cwd, directory) = (workspace.id, workspace.cwd, Persistence.stateDirectory)
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let label = field.stringValue
            Task {
                do {
                    let saved = try await Task.detached(priority: .userInitiated) {
                        try LocalCheckpoints(stateDirectory: directory, workspaceID: id).save(worktree: cwd, label: label)
                    }.value
                    if saved.isIncomplete {
                        let skipped = saved.omissions.count
                        let detail = saved.timedOut ? "capture timed out, \(skipped) known files skipped" : "\(skipped) files skipped"
                        self?.showToast("Saved incomplete checkpoint (\(detail))")
                    } else {
                        self?.showToast("Saved checkpoint (\(saved.files.count) files, \(CheckpointList.size(saved.size)))")
                    }
                } catch { self?.showToast(error.localizedDescription, tone: .error) }
            }
        }
    }

    func showCheckpoints(in workspace: WorkspaceState?) {
        guard let workspace, let window, window.attachedSheet == nil else { return }
        do {
            let store = try LocalCheckpoints(stateDirectory: Persistence.stateDirectory, workspaceID: workspace.id)
            let list = CheckpointList(store: store)
            let alert = NSAlert()
            alert.messageText = "Checkpoints for “\(workspace.title)”"
            alert.accessoryView = list
            alert.addButton(withTitle: "Done")
            alert.beginSheetModal(for: window)
            list.reload()
        } catch { showToast(error.localizedDescription, tone: .error) }
    }
}

private final class CheckpointList: NSScrollView {
    private final class Rows: NSView { override var isFlipped: Bool { true } }
    private let rows = Rows()
    private let store: LocalCheckpoints

    init(store: LocalCheckpoints) {
        self.store = store
        super.init(frame: NSRect(x: 0, y: 0, width: 500, height: 240))
        hasVerticalScroller = true
        documentView = rows
    }

    required init?(coder: NSCoder) { fatalError() }

    static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    func reload(deleting id: UUID? = nil) {
        renderMessage(id == nil ? "Loading checkpoints…" : "Deleting checkpoint…")
        Task {
            do {
                let entries = try await Task.detached(priority: .userInitiated) { [store] in
                    if let id { try store.delete(id) }
                    return try store.list()
                }.value
                if entries.isEmpty { renderMessage("No saved checkpoints") } else { render(entries) }
            } catch { renderMessage(error.localizedDescription) }
        }
    }

    private func renderMessage(_ message: String) {
        rows.subviews.forEach { $0.removeFromSuperview() }
        rows.frame.size = contentSize
        let field = NSTextField(wrappingLabelWithString: message)
        field.frame = rows.bounds.insetBy(dx: 4, dy: 4)
        rows.addSubview(field)
    }

    private func render(_ entries: [LocalCheckpoints.Entry]) {
        rows.subviews.forEach { $0.removeFromSuperview() }
        let width = contentSize.width
        rows.frame.size = NSSize(width: width, height: CGFloat(entries.count) * 58)
        for (index, entry) in entries.enumerated() {
            let y = CGFloat(index) * 58
            guard let checkpoint = entry.manifest else {
                label("Requires Nirux with checkpoint format \(entry.version)", x: 4, y: y, width: width - 8)
                continue
            }
            let timestamp = checkpoint.createdAt.formatted(date: .abbreviated, time: .standard)
            let title = checkpoint.label.map { "\($0) · \(timestamp)" } ?? timestamp
            label(title, x: 4, y: y, width: width - 90).font = .boldSystemFont(ofSize: NSFont.systemFontSize)
            let head = checkpoint.head.map { "HEAD \($0.prefix(8))" } ?? "No HEAD"
            label("\(head) · \(checkpoint.files.count) files · \(Self.size(checkpoint.size))", x: 4, y: y + 22, width: width - 180)
            if checkpoint.isIncomplete {
                let badge = label("Incomplete", x: width - 170, y: y + 22, width: 85)
                badge.textColor = .systemOrange
                let reasons = checkpoint.omissions.map { "\(BranchReview.visible($0.path)) — \($0.reason)" }
                badge.toolTip = ((checkpoint.timedOut ? ["Capture timed out"] : []) + reasons).joined(separator: "\n")
            }
            let button = NSButton(title: "Delete", target: self, action: #selector(deleteCheckpoint(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(entry.id.uuidString)
            button.frame = NSRect(x: width - 80, y: y + 5, width: 76, height: 28)
            rows.addSubview(button)
        }
    }

    @discardableResult
    private func label(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.frame = NSRect(x: x, y: y, width: width, height: 19)
        field.lineBreakMode = .byTruncatingTail
        field.toolTip = text
        rows.addSubview(field)
        return field
    }

    @objc private func deleteCheckpoint(_ sender: NSButton) {
        guard let id = sender.identifier.flatMap({ UUID(uuidString: $0.rawValue) }) else { return }
        reload(deleting: id)
    }
}
