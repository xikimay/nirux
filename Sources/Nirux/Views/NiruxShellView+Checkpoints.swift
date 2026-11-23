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
            let list = CheckpointList(store: store, worktree: workspace.cwd) { [weak self, weak workspace] diff, title in
                guard let self, let workspace, workspaces.contains(where: { $0 === workspace }),
                      let editor = editorColumn(in: workspace, cwd: workspace.cwd) else { return }
                editor.showCheckpointDiff(diff, title: title)
                focusEditor(editor, in: workspace)
            }
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

    private let worktree: String
    private let onDiff: (LocalCheckpoints.Diff, String) -> Void
    private let comparison = NSPopUpButton()

    init(store: LocalCheckpoints, worktree: String, onDiff: @escaping (LocalCheckpoints.Diff, String) -> Void) {
        self.worktree = worktree
        self.onDiff = onDiff
        self.store = store
        super.init(frame: NSRect(x: 0, y: 0, width: 550, height: 280))
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

    private static func title(_ checkpoint: LocalCheckpoints.Manifest) -> String {
        let timestamp = checkpoint.createdAt.formatted(date: .abbreviated, time: .standard)
        return checkpoint.label.map { "\($0) · \(timestamp)" } ?? timestamp
    }

    private func render(_ entries: [LocalCheckpoints.Entry]) {
        rows.subviews.forEach { $0.removeFromSuperview() }
        let width = contentSize.width
        rows.frame.size = NSSize(width: width, height: 40 + CGFloat(entries.count) * 82)
        label("Compare with", x: 4, y: 7, width: 96)
        comparison.removeAllItems()
        comparison.addItem(withTitle: "Working Tree")
        for manifest in entries.compactMap(\.manifest) {
            let item = NSMenuItem(title: Self.title(manifest), action: nil, keyEquivalent: "")
            item.representedObject = manifest.id
            comparison.menu?.addItem(item)
        }
        comparison.frame = NSRect(x: 100, y: 1, width: width - 108, height: 28)
        rows.addSubview(comparison)
        for (index, entry) in entries.enumerated() {
            let y = 40 + CGFloat(index) * 82
            guard let checkpoint = entry.manifest else {
                label("Requires Nirux with checkpoint format \(entry.version)", x: 4, y: y, width: width - 8)
                continue
            }
            label(Self.title(checkpoint), x: 4, y: y, width: width - 8).font = .boldSystemFont(ofSize: NSFont.systemFontSize)
            let head = checkpoint.head.map { "HEAD \($0.prefix(8))" } ?? "No HEAD"
            label("\(head) · \(checkpoint.files.count) files · \(Self.size(checkpoint.size))", x: 4, y: y + 22, width: width - 200)
            if checkpoint.isIncomplete {
                let badge = label("Incomplete".asWarning, x: width - 190, y: y + 22, width: 105)
                badge.textColor = .niruxWarning
                let reasons = checkpoint.omissions.map { "\(BranchReview.visible($0.path)) — \($0.reason)" }
                badge.toolTip = ((checkpoint.timedOut ? ["Capture timed out"] : []) + reasons).joined(separator: "\n")
            }
            func button(_ title: String, _ action: Selector, x: CGFloat, width: CGFloat) {
                let button = NSButton(title: title, target: self, action: action)
                button.identifier = NSUserInterfaceItemIdentifier(entry.id.uuidString)
                button.frame = NSRect(x: x, y: y + 42, width: width, height: 28)
                rows.addSubview(button)
            }
            button("View Diff", #selector(viewDiff(_:)), x: 0, width: 92)
            button("Export Copy…", #selector(exportCopy(_:)), x: 96, width: 125)
            button("Delete", #selector(deleteCheckpoint(_:)), x: width - 80, width: 76)
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

    @objc private func viewDiff(_ sender: NSButton) {
        guard let id = sender.identifier.flatMap({ UUID(uuidString: $0.rawValue) }),
              let sheet = window, let parent = sheet.sheetParent else { return }
        let target = comparison.selectedItem?.representedObject as? UUID
        let source = comparison.itemArray.first { $0.representedObject as? UUID == id }?.title ?? "Checkpoint"
        let title = source + " → " + (comparison.titleOfSelectedItem ?? "Working Tree")
        renderMessage("Comparing checkpoints…")
        Task {
            do {
                let diff = try await store.diff(from: id, to: target, worktree: worktree)
                guard sheet.sheetParent === parent else { return }
                parent.endSheet(sheet)
                onDiff(diff, title)
            } catch { renderMessage(error.localizedDescription) }
        }
    }

    @objc private func exportCopy(_ sender: NSButton) {
        guard let id = sender.identifier.flatMap({ UUID(uuidString: $0.rawValue) }), let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.resolvesAliases = false
        panel.prompt = "Export Copy"
        panel.message = "Choose an empty folder for the checkpoint’s stored files."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let destination = panel.url, let self else { return }
            renderMessage("Exporting checkpoint…")
            Task {
                do {
                    try await Task.detached(priority: .userInitiated) { [store, worktree] in
                        try store.exportCopy(id, to: destination, worktree: worktree)
                    }.value
                    renderMessage("Exported checkpoint to " + destination.path)
                } catch { renderMessage(error.localizedDescription) }
            }
        }
    }

    @objc private func deleteCheckpoint(_ sender: NSButton) {
        guard let id = sender.identifier.flatMap({ UUID(uuidString: $0.rawValue) }) else { return }
        reload(deleting: id)
    }
}
