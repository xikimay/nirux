import AppKit

/// Project Memory (⌘P › Project Memory…, the project's menu): what agents
/// know about the workspace's repository, in one list (see
/// ProjectMemory.Knowledge): the project brief's rules apply always, the
/// repository's CLAUDE.md and AGENTS.md are the team's, Claude Code's
/// memory is read when relevant. Filtered by text and scope; on the right,
/// the selected item, its `[[links]]` clickable, its file in small. Return,
/// the button or a double click hands that file to `onOpen`. Read-only:
/// the editor changes the files. The History tab comes later.
@MainActor
final class ProjectMemoryPanel: NSObject {
    static let panelSize = NSSize(width: 900, height: 600)
    static let listWidth: CGFloat = 380
    static let title = "Project Memory"
    static let tabs = ["What agents know", "History"]
    static let openTitle = "Open in Editor"

    static func placeholder(repository: String) -> String { "Filter what agents know about \(repository)…" }

    /// What the panel shows: where Claude Code keeps the memory, whether it
    /// uses it, and every item.
    struct Model: Sendable {
        let repository: String
        let location: ProjectMemory.Location
        let knowledge: ProjectMemory.Knowledge
    }

    private var panel: NSPanel?
    private(set) var searchField: NSTextField?
    private(set) var scopeControl: NSSegmentedControl?
    private(set) var summaryLabel: NSTextField?
    private(set) var noticeLabel: NSTextField?
    private(set) var tableView: NSTableView?
    private(set) var preview: ProjectMemoryPreview?
    private(set) var openButton: NSButton?
    private var scrollView: NSScrollView?
    private(set) var noticeRow: NSView?

    private(set) var model: Model?
    /// Indexes into `model.knowledge.entries`, as listed.
    private(set) var rows: [Int] = []
    /// Gets a file to open, and the line to show.
    private var onOpen: (URL, Int?) -> Void = { _, _ in }

    private var keyMonitor: Any?
    private var clickMonitor: Any?

    var isVisible: Bool { panel?.isVisible == true }

    /// The scopes the control offers after "All": team rules apply always.
    static let scopes: [ProjectMemory.Scope] = [.always, .whenRelevant]

    var selectedEntry: ProjectMemory.Entry? {
        guard let table = tableView, let index = rows[safe: table.selectedRow] else { return nil }
        return model?.knowledge.entries[safe: index]
    }

    /// Shows `model` over `window`, filters cleared, the first item
    /// selected.
    func show(relativeTo window: NSWindow, model: Model, onOpen: @escaping (URL, Int?) -> Void) {
        self.model = model
        self.onOpen = onOpen
        if panel == nil { createPanel() }
        guard let panel, let searchField else { return }
        searchField.stringValue = ""
        searchField.placeholderString = Self.placeholder(repository: model.repository)
        scopeControl?.selectedSegment = 0
        let notice = model.location.notice
        noticeLabel?.stringValue = notice ?? ""
        noticeLabel?.toolTip = notice
        noticeRow?.isHidden = notice == nil
        layoutBody(noticeShown: notice != nil)

        let frame = window.frame
        panel.setFrame(
            NSRect(
                x: frame.origin.x + (frame.width - Self.panelSize.width) / 2,
                y: frame.origin.y + max(frame.height * 0.55 - Self.panelSize.height / 2, 0),
                width: Self.panelSize.width,
                height: Self.panelSize.height
            ),
            display: true
        )
        installMonitors()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
        reload()
    }

    func dismiss() {
        removeMonitors()
        panel?.orderOut(nil)
    }

    // MARK: - Rows

    var scope: ProjectMemory.Scope? {
        let segment = scopeControl?.selectedSegment ?? 0
        return segment > 0 ? Self.scopes[safe: segment - 1] : nil
    }

    private var isFiltered: Bool {
        !(searchField?.stringValue ?? "").trimmingCharacters(in: .whitespaces).isEmpty || scope != nil
    }

    /// Lists what the filters match, the first item selected.
    @objc func reload() {
        guard let knowledge = model?.knowledge else { return }
        rows = ProjectMemory.entries(in: knowledge, text: searchField?.stringValue ?? "", scope: scope)
        summaryLabel?.stringValue = ProjectMemory.summary(of: knowledge, shown: isFiltered ? rows.count : nil)
        tableView?.reloadData()
        if rows.isEmpty {
            updateSelection()
        } else {
            select(row: 0)
        }
    }

    /// Selects the memory in `fileName` (a `[[link]]`'s), clearing the
    /// filters that hide it; the keyboard goes back to the field.
    func reveal(fileName: String) {
        defer { focusField() }
        guard let knowledge = model?.knowledge,
              let entry = knowledge.entries.firstIndex(where: { knowledge.memory(of: $0)?.fileName == fileName })
        else { return NSSound.beep() }
        if !rows.contains(entry) {
            searchField?.stringValue = ""
            scopeControl?.selectedSegment = 0
            reload()
        }
        if let row = rows.firstIndex(of: entry) { select(row: row) }
    }

    private func select(row: Int) {
        guard let table = tableView else { return }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
        updateSelection()
    }

    private func moveSelection(by step: Int) {
        guard let table = tableView, !rows.isEmpty else { return }
        select(row: min(max(table.selectedRow + step, 0), rows.count - 1))
    }

    // MARK: - Preview

    private func updateSelection() {
        guard let model else { return }
        if let entry = selectedEntry {
            preview?.show(entry, in: model.knowledge, location: model.location)
        } else {
            preview?.showEmpty(Self.emptyText(model: model, filtered: isFiltered))
        }
        openButton?.isEnabled = selectedTarget != nil
    }

    static func emptyText(model: Model, filtered: Bool) -> String {
        guard model.knowledge.entries.isEmpty else { return filtered ? "Nothing matches." : "" }
        return "Agents know nothing about \(model.repository) yet.\n\n"
            + "The project brief’s rules (Edit Project Brief…) apply to every session; "
            + "Claude Code notes what it learns as its sessions work."
    }

    // MARK: - Opening

    /// The file of the selected item, and the line where it starts.
    var selectedTarget: (url: URL, line: Int?)? {
        selectedEntry.flatMap { model?.knowledge.location(of: $0) }
    }

    @objc private func commit() {
        guard let target = selectedTarget else { return NSSound.beep() }
        dismiss()
        onOpen(target.url, target.line)
    }

    @objc private func tableDoubleClicked() {
        guard let table = tableView, rows.indices.contains(table.clickedRow) else { return }
        select(row: table.clickedRow)
        commit()
    }

    // MARK: - Keys and clicks

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
        guard event.window === panel else { return event }
        // An input method composing in the field keeps its keys.
        if (searchField?.currentEditor() as? NSTextView)?.hasMarkedText() == true { return event }
        switch event.keyCode {
        case 0x35: // Escape
            dismiss()
            return nil
        case 0x24, 0x4C: // Return / Enter
            commit()
            return nil
        case 0x7E: // Up
            moveSelection(by: -1)
            return nil
        case 0x7D: // Down
            moveSelection(by: 1)
            return nil
        default:
            // Typed after a click in the preview: the filter gets it, ⌘C
            // still copies the preview's selection.
            if event.modifierFlags.isDisjoint(with: [.command, .control]),
               event.characters?.unicodeScalars.contains(where: { !CharacterSet.controlCharacters.contains($0) }) == true {
                focusField()
            }
            return event
        }
    }

    /// The keyboard back in the field, the caret at its end.
    private func focusField() {
        guard let panel, let searchField else { return }
        if let editor = searchField.currentEditor(), panel.firstResponder === editor { return }
        panel.makeFirstResponder(searchField)
        let end = (searchField.stringValue as NSString).length
        searchField.currentEditor()?.selectedRange = NSRange(location: end, length: 0)
    }

    // MARK: - Panel construction

    private static let tabRowHeight: CGFloat = 40
    private static let fieldRowHeight: CGFloat = 44
    private static let filterRowHeight: CGFloat = 36
    private static let noticeHeight: CGFloat = 30
    private static let footerHeight: CGFloat = 48
    private static var headerHeight: CGFloat { tabRowHeight + fieldRowHeight + filterRowHeight }

    private func createPanel() {
        let size = Self.panelSize
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovable = false
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.appearance = Theme.appearance
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false

        let background = NSView(frame: NSRect(origin: .zero, size: size))
        background.wantsLayer = true
        background.layer?.cornerRadius = Theme.Radius.panel
        background.layer?.backgroundColor = Theme.Color.base.cgColor
        background.layer?.borderWidth = 1
        background.layer?.borderColor = Theme.Color.lineStrong.cgColor
        background.layer?.masksToBounds = true
        addTabRow(to: background)
        addFieldRow(to: background)
        addFilterRow(to: background)
        addNoticeRow(to: background)
        addFooter(to: background)
        addBody(to: background)
        panel.contentView = background
        self.panel = panel
        layoutBody(noticeShown: false)
    }

    /// The panel's name and its tabs: "What agents know", and "History",
    /// greyed until it exists.
    private func addTabRow(to background: NSView) {
        let size = Self.panelSize
        let row = NSView(frame: NSRect(x: 0, y: size.height - Self.tabRowHeight, width: size.width, height: Self.tabRowHeight))
        row.wantsLayer = true
        row.layer?.backgroundColor = Theme.Color.canvas.cgColor
        func label(_ text: String, font: NSFont, color: NSColor, x: CGFloat) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.font = font
            label.textColor = color
            label.sizeToFit()
            label.frame.origin = NSPoint(x: x, y: (Self.tabRowHeight - label.frame.height) / 2)
            row.addSubview(label)
            return label
        }
        let title = label(Self.title, font: Theme.Font.display, color: Theme.Color.textPrimary, x: Theme.Space.lg)
        let current = label(Self.tabs[0], font: Theme.Font.bodyEmphasized, color: Theme.Color.textPrimary, x: title.frame.maxX + Theme.Space.xl)
        let underline = NSView(frame: NSRect(x: current.frame.minX, y: 0, width: current.frame.width, height: 2))
        underline.wantsLayer = true
        underline.layer?.backgroundColor = Theme.Color.accent.cgColor
        row.addSubview(underline)
        let history = label(Self.tabs[1], font: Theme.Font.body, color: Theme.Color.textDisabled, x: current.frame.maxX + Theme.Space.xl)
        let later = label("later", font: Theme.Font.caption, color: Theme.Color.textDisabled, x: history.frame.maxX + Theme.Space.xs)
        for view in [history, later] { view.toolTip = "Coming later: what was said and decided in this project" }
        row.addSubview(Self.line(at: 0))
        background.addSubview(row)
    }

    /// The field, under the tabs.
    private func addFieldRow(to background: NSView) {
        let size = Self.panelSize
        let y = size.height - Self.tabRowHeight - Self.fieldRowHeight
        let row = NSView(frame: NSRect(x: 0, y: y, width: size.width, height: Self.fieldRowHeight))
        row.wantsLayer = true
        row.layer?.backgroundColor = Theme.Color.fillHover.cgColor
        row.addSubview(PaletteIconView(.symbol(Theme.Symbol.projectMemory), frame: NSRect(x: 14, y: 10, width: 24, height: 24)))
        let field = NSTextField()
        field.font = .systemFont(ofSize: 15)
        field.textColor = Theme.Color.textPrimary
        field.backgroundColor = .clear
        field.isBezeled = false
        field.focusRingType = .none
        field.drawsBackground = false
        field.frame = NSRect(x: 42, y: 10, width: size.width - 56, height: 24)
        field.delegate = self
        row.addSubview(field)
        background.addSubview(row)
        searchField = field
    }

    /// The scope filter, and how many items each scope holds.
    private func addFilterRow(to background: NSView) {
        let size = Self.panelSize
        let scopes = NSSegmentedControl(
            labels: ["All"] + Self.scopes.map(\.title), trackingMode: .selectOne, target: self, action: #selector(reload)
        )
        // The keyboard stays in the field, whatever is clicked.
        scopes.refusesFirstResponder = true
        scopes.selectedSegmentBezelColor = Theme.Color.accent
        scopes.controlSize = .small
        scopes.font = Theme.Font.caption
        scopes.sizeToFit()
        let y = size.height - Self.headerHeight
        scopes.frame.origin = NSPoint(x: Theme.Space.lg, y: y + (Self.filterRowHeight - scopes.frame.height) / 2)
        background.addSubview(scopes)
        let summary = NSTextField(labelWithString: "")
        summary.font = Theme.Font.caption
        summary.textColor = Theme.Color.textTertiary
        summary.alignment = .right
        summary.lineBreakMode = .byTruncatingHead
        let summaryX = scopes.frame.maxX + Theme.Space.lg
        summary.frame = NSRect(
            x: summaryX, y: y + (Self.filterRowHeight - 15) / 2, width: size.width - Theme.Space.lg - summaryX, height: 15
        )
        background.addSubview(summary)
        background.addSubview(Self.line(at: y))
        scopeControl = scopes
        summaryLabel = summary
    }

    /// Why Claude Code doesn't use its memory, when it doesn't, or which
    /// setting moved it. A notice, not a wait on the user: never amber.
    private func addNoticeRow(to background: NSView) {
        let size = Self.panelSize
        let row = NSView(frame: NSRect(
            x: 0, y: size.height - Self.headerHeight - Self.noticeHeight, width: size.width, height: Self.noticeHeight
        ))
        row.wantsLayer = true
        row.layer?.backgroundColor = Theme.Color.surface.cgColor
        let icon = NSImageView(frame: NSRect(x: Theme.Space.lg, y: 8, width: 14, height: 14))
        icon.image = NSImage(systemSymbolName: Theme.Symbol.notice, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .regular))
        icon.contentTintColor = Theme.Color.textSecondary
        row.addSubview(icon)
        let notice = NSTextField(labelWithString: "")
        notice.font = Theme.Font.caption
        notice.textColor = Theme.Color.textSecondary
        notice.lineBreakMode = .byTruncatingTail
        notice.frame = NSRect(x: Theme.Space.lg + 22, y: 7, width: size.width - 2 * Theme.Space.lg - 22, height: 15)
        row.addSubview(notice)
        row.isHidden = true
        background.addSubview(row)
        noticeRow = row
        noticeLabel = notice
    }

    /// What Return does, at the bottom.
    private func addFooter(to background: NSView) {
        let size = Self.panelSize
        let button = NSButton(title: Self.openTitle, target: self, action: #selector(commit))
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.sizeToFit()
        button.frame.size.width = max(button.frame.width, 120)
        button.frame.origin = NSPoint(
            x: size.width - Theme.Space.lg - button.frame.width, y: (Self.footerHeight - button.frame.height) / 2
        )
        background.addSubview(button)
        background.addSubview(Self.line(at: Self.footerHeight))
        openButton = button
    }

    /// The list on the left, the item on the right.
    private func addBody(to background: NSView) {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let table = NSTableView()
        table.refusesFirstResponder = true
        table.allowsEmptySelection = false
        table.headerView = nil
        table.backgroundColor = .clear
        table.gridStyleMask = []
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.rowSizeStyle = .custom
        table.rowHeight = 50
        table.selectionHighlightStyle = .regular
        table.allowsMultipleSelection = false
        table.style = .plain
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(tableDoubleClicked)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        column.resizingMask = .autoresizingMask
        column.width = Self.listWidth
        table.addTableColumn(column)
        scroll.documentView = table
        background.addSubview(scroll)

        let preview = ProjectMemoryPreview(frame: .zero)
        preview.onLink = { [weak self] fileName in self?.reveal(fileName: fileName) }
        background.addSubview(preview)
        tableView = table
        scrollView = scroll
        self.preview = preview
    }

    private static func line(at y: CGFloat) -> NSView {
        let line = NSView(frame: NSRect(x: 0, y: y, width: panelSize.width, height: 1))
        line.wantsLayer = true
        line.layer?.backgroundColor = Theme.Color.line.cgColor
        return line
    }

    /// The list and the preview fill what the notice leaves.
    private func layoutBody(noticeShown: Bool) {
        let size = Self.panelSize
        let top = size.height - Self.headerHeight - (noticeShown ? Self.noticeHeight : 0)
        let bottom = Self.footerHeight + 1
        scrollView?.frame = NSRect(x: 0, y: bottom, width: Self.listWidth, height: top - bottom)
        preview?.frame = NSRect(x: Self.listWidth, y: bottom, width: size.width - Self.listWidth, height: top - bottom)
    }
}

// MARK: - NSTextFieldDelegate

extension ProjectMemoryPanel: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        reload()
    }
}

// MARK: - Table

extension ProjectMemoryPanel: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateSelection()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let entry = rows[safe: row].flatMap({ model?.knowledge.entries[safe: $0] }) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("ProjectMemoryCell")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: nil) as? ProjectMemoryCellView)
            ?? ProjectMemoryCellView()
        cell.identifier = identifier
        cell.configure(entry)
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        SearchResultRowView()
    }
}

/// The item's title, its scope in a chip on the right (a lock for the
/// team's); below, what follows the title, or that its file is gone.
final class ProjectMemoryCellView: NSTableCellView {
    let titleLabel = NSTextField(labelWithString: "")
    let detailLabel = NSTextField(labelWithString: "")
    let chipLabel = NSTextField(labelWithString: "")
    private let chip = NSView()
    private let lock = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        titleLabel.font = Theme.Font.title
        titleLabel.textColor = Theme.Color.textPrimary
        titleLabel.lineBreakMode = .byTruncatingTail
        detailLabel.font = Theme.Font.caption
        detailLabel.lineBreakMode = .byTruncatingTail
        chip.wantsLayer = true
        chip.layer?.cornerRadius = Theme.Radius.chip
        chip.layer?.backgroundColor = Theme.Color.fillPressed.cgColor
        chipLabel.font = Theme.Font.caption
        chipLabel.alignment = .center
        lock.image = NSImage(systemSymbolName: Theme.Symbol.locked, accessibilityDescription: "Team")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .regular))
        lock.contentTintColor = Theme.Color.textSecondary
        chip.addSubview(lock)
        chip.addSubview(chipLabel)
        [titleLabel, detailLabel, chip].forEach(addSubview)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let inset = Theme.Space.lg
        let lockWidth: CGFloat = lock.isHidden ? 0 : 12
        let labelWidth = ceil(chipLabel.intrinsicContentSize.width)
        let chipWidth = labelWidth + lockWidth + 2 * Theme.Space.sm
        // A title alone sits in the middle of its row.
        let titleY: CGFloat = detailLabel.stringValue.isEmpty ? floor((bounds.height - 17) / 2) : 25
        chip.frame = NSRect(x: bounds.width - inset - chipWidth, y: titleY + 1, width: chipWidth, height: 16)
        lock.frame = NSRect(x: Theme.Space.sm - 1, y: 2, width: 12, height: 12)
        chipLabel.frame = NSRect(x: Theme.Space.sm + lockWidth, y: 1, width: labelWidth, height: 14)
        titleLabel.frame = NSRect(x: inset, y: titleY, width: chip.frame.minX - inset - Theme.Space.sm, height: 17)
        detailLabel.frame = NSRect(x: inset, y: 7, width: bounds.width - 2 * inset, height: 15)
    }

    func configure(_ entry: ProjectMemory.Entry) {
        titleLabel.stringValue = entry.title
        detailLabel.stringValue = entry.detail
        let isGone: Bool
        if case .missingFile = entry.source { isGone = true } else { isGone = false }
        detailLabel.textColor = isGone ? Theme.Color.error : Theme.Color.textSecondary
        chipLabel.stringValue = entry.scope.title.lowercased()
        chipLabel.textColor = entry.scope == .whenRelevant ? Theme.Color.textSecondary : Theme.Color.textPrimary
        lock.isHidden = entry.scope != .team
        needsLayout = true
    }
}
