import AppKit

/// A focused file picker that scans the workspace cwd, lists relative paths,
/// and invokes a callback when one is chosen. Uses `NSTableView` so 1000+
/// files render instantly (vs. building one NSView per row up front).
@MainActor
final class FilePickerPanel: NSObject {
    private var panel: NSPanel?
    private var searchField: NSTextField?
    private var scrollView: NSScrollView?
    private var tableView: NSTableView?

    private var allFiles: [String] = []
    private var filtered: [String] = []
    private var workspaceCwd: String = ""
    private var onPick: ((String) -> Void)?

    private var keyMonitor: Any?
    private var clickMonitor: Any?

    private static let panelSize = NSSize(width: 520, height: 380)

    /// Show the picker over `window`, scoped to `workspaceCwd`. Calls `onPick`
    /// with an absolute path on selection.
    func show(
        relativeTo window: NSWindow,
        workspaceCwd: String,
        onPick: @escaping (String) -> Void
    ) {
        self.workspaceCwd = workspaceCwd
        self.onPick = onPick

        if panel == nil { createPanel() }
        guard let panel, let searchField, let tableView else { return }

        // Scan happens on a background queue; show the panel immediately so it
        // feels responsive even on large repos.
        searchField.stringValue = ""
        allFiles = []
        filtered = []
        tableView.reloadData()

        let cwd = workspaceCwd
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let files = WorkspaceFileScanner.scan(cwd: cwd)
            DispatchQueue.main.async {
                guard let self else { return }
                self.allFiles = files
                self.filter(query: "")
            }
        }

        let frame = window.frame
        let x = frame.origin.x + (frame.width - Self.panelSize.width) / 2
        let y = frame.origin.y + frame.height * 0.55
        panel.setFrame(
            NSRect(x: x, y: y, width: Self.panelSize.width, height: Self.panelSize.height),
            display: true
        )

        installMonitors()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
    }

    func dismiss() {
        removeMonitors()
        panel?.orderOut(nil)
    }

    // MARK: - Panel construction

    private func createPanel() {
        let p = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        p.titlebarAppearsTransparent = true
        p.titleVisibility = .hidden
        p.isMovable = false
        p.level = .floating
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.appearance = NSAppearance(named: .darkAqua)
        p.becomesKeyOnlyIfNeeded = false

        let bg = NSView(frame: NSRect(origin: .zero, size: Self.panelSize))
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 12
        bg.layer?.backgroundColor = NSColor(red: 0.11, green: 0.11, blue: 0.15, alpha: 0.98).cgColor
        bg.layer?.borderWidth = 1
        bg.layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor
        bg.layer?.masksToBounds = true

        // Search row
        let fieldRow = NSView(frame: NSRect(x: 0, y: Self.panelSize.height - 44, width: Self.panelSize.width, height: 44))
        fieldRow.wantsLayer = true
        fieldRow.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.03).cgColor

        let icon = NSTextField(labelWithString: "📄")
        icon.font = .systemFont(ofSize: 14)
        icon.frame = NSRect(x: 14, y: 10, width: 24, height: 24)
        fieldRow.addSubview(icon)

        let field = NSTextField()
        field.font = .systemFont(ofSize: 15)
        field.textColor = .white
        field.backgroundColor = .clear
        field.isBezeled = false
        field.focusRingType = .none
        field.drawsBackground = false
        field.placeholderString = "Find file in workspace…"
        field.frame = NSRect(x: 42, y: 10, width: Self.panelSize.width - 56, height: 24)
        field.delegate = self
        fieldRow.addSubview(field)

        bg.addSubview(fieldRow)

        // Separator
        let sep = NSView(frame: NSRect(x: 0, y: Self.panelSize.height - 45, width: Self.panelSize.width, height: 1))
        sep.wantsLayer = true
        sep.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        bg.addSubview(sep)

        // Table view (virtualized list)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: Self.panelSize.width, height: Self.panelSize.height - 46))
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autoresizingMask = [.width, .height]

        let table = NSTableView()
        table.headerView = nil
        table.backgroundColor = .clear
        table.gridStyleMask = []
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.rowHeight = 36
        table.rowSizeStyle = .custom
        table.selectionHighlightStyle = .regular
        table.allowsMultipleSelection = false
        table.style = .plain
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(tableClicked)
        table.doubleAction = #selector(tableDoubleClicked)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("path"))
        column.resizingMask = .autoresizingMask
        column.width = Self.panelSize.width
        table.addTableColumn(column)

        scroll.documentView = table
        bg.addSubview(scroll)

        p.contentView = bg
        panel = p
        searchField = field
        scrollView = scroll
        tableView = table
    }

    // MARK: - Filtering

    private func filter(query: String) {
        let q = query.lowercased()
        if q.isEmpty {
            filtered = allFiles
        } else {
            filtered = allFiles.filter { $0.lowercased().contains(q) }
        }
        tableView?.reloadData()
        if !filtered.isEmpty {
            tableView?.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            tableView?.scrollRowToVisible(0)
        }
    }

    // MARK: - Monitors

    private func installMonitors() {
        removeMonitors()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKey(event)
        }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, let panel = self.panel else { return event }
            if event.window !== panel { self.dismiss() }
            return event
        }
    }

    private func removeMonitors() {
        if let monitor = keyMonitor { NSEvent.removeMonitor(monitor); keyMonitor = nil }
        if let monitor = clickMonitor { NSEvent.removeMonitor(monitor); clickMonitor = nil }
    }

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        guard let table = tableView else { return event }
        switch event.keyCode {
        case 0x35: // Escape
            dismiss()
            return nil
        case 0x24, 0x4C: // Return, numpad Enter
            commitSelection()
            return nil
        case 0x7E: // Up
            let row = max(0, table.selectedRow - 1)
            if !filtered.isEmpty {
                table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                table.scrollRowToVisible(row)
            }
            return nil
        case 0x7D: // Down
            let row = min(filtered.count - 1, table.selectedRow + 1)
            if !filtered.isEmpty {
                table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                table.scrollRowToVisible(row)
            }
            return nil
        default:
            return event
        }
    }

    private func commitSelection() {
        guard let table = tableView, table.selectedRow >= 0, table.selectedRow < filtered.count else { return }
        let rel = filtered[table.selectedRow]
        let abs = (workspaceCwd as NSString).appendingPathComponent(rel)
        dismiss()
        onPick?(abs)
    }

    @objc private func tableClicked() { /* selection handled by NSTableView */ }
    @objc private func tableDoubleClicked() { commitSelection() }
}

// MARK: - NSTextFieldDelegate

extension FilePickerPanel: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        filter(query: searchField?.stringValue ?? "")
    }
}

// MARK: - Table data + delegate

extension FilePickerPanel: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("FilePickerCell")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: nil) as? FilePickerCellView)
            ?? FilePickerCellView()
        cell.identifier = identifier
        cell.configure(relativePath: filtered[row])
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        return FilePickerRowView()
    }
}

/// Single row: name on top, parent dir on bottom (greyed).
private final class FilePickerCellView: NSTableCellView {
    private let nameLabel = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
        nameLabel.textColor = .white
        pathLabel.font = .systemFont(ofSize: 11)
        pathLabel.textColor = .secondaryLabelColor
        addSubview(nameLabel)
        addSubview(pathLabel)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        nameLabel.frame = NSRect(x: 16, y: 16, width: bounds.width - 24, height: 16)
        pathLabel.frame = NSRect(x: 16, y: 2, width: bounds.width - 24, height: 14)
    }

    func configure(relativePath: String) {
        let parts = (relativePath as NSString).pathComponents
        nameLabel.stringValue = parts.last ?? relativePath
        if parts.count > 1 {
            pathLabel.stringValue = parts.dropLast().joined(separator: "/")
        } else {
            pathLabel.stringValue = ""
        }
    }
}

/// Row view that paints the accent highlight on selection.
private final class FilePickerRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        if selectionHighlightStyle != .none {
            NSColor.niruxAccent.withAlphaComponent(0.18).setFill()
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 2), xRadius: 6, yRadius: 6)
            path.fill()
        }
    }
    override var isEmphasized: Bool { get { true } set {} }
}
