import AppKit

/// Search Everywhere (⌥⌘F): one needle, searched in the scrollback of every
/// terminal of every workspace, in every project. Matches stream in as each
/// terminal is read (GlobalTerminalSearch), grouped by terminal, the newest
/// first. Picking one hands it to `onPick`, which brings its column forward
/// with the find bar open on it.
@MainActor
final class GlobalSearchPanel: NSObject {
    /// One terminal to search, in the order its matches are listed.
    struct Target {
        /// Weak: a column closed while the panel is open, or after, must
        /// go, its shell with it.
        weak var column: ColumnState?
        /// "workspace › column", as the rows show it.
        let place: String
        let read: GlobalTerminalSearch.Reader
    }

    struct Row {
        weak var column: ColumnState?
        let place: String
        let needle: String
        let match: ScrollbackSearch.Match
        /// The terminal's matches when it was read.
        let total: Int
    }

    /// A picked match: its column, still open, and where to find it.
    struct Pick {
        let column: ColumnState
        let needle: String
        let match: ScrollbackSearch.Match
        /// The terminal's matches when it was read.
        let total: Int
    }

    nonisolated static let minNeedleLength = 2
    nonisolated static let maxRows = 500
    nonisolated static let typingDelay: TimeInterval = 0.15
    static let panelSize = NSSize(width: 720, height: 480)
    static let placeholder = "Search every terminal…"

    private var panel: NSPanel?
    private(set) var searchField: NSTextField?
    private(set) var tableView: NSTableView?
    private(set) var statusLabel: NSTextField?

    private(set) var rows: [Row] = []
    private var targets: [Target] = []
    private var progress = Progress()
    private let search = GlobalTerminalSearch()
    private var targetsProvider: () -> [Target] = { [] }
    private var onPick: (Pick) -> Void = { _ in }

    private var keyMonitor: Any?
    private var clickMonitor: Any?
    private var pendingSearch: DispatchWorkItem?

    var isVisible: Bool { panel?.isVisible == true }
    var isSearching: Bool { search.isRunning }

    /// What the status line counts.
    private struct Progress {
        var terminals = 0
        var terminalsWithMatches = 0
        var matches = 0
    }

    /// Shows the panel over `window`. `targets` is asked again on every
    /// search, so terminals opened meanwhile are searched too. Reopening
    /// keeps the last needle, selected, and searches it again.
    func show(relativeTo window: NSWindow, targets: @escaping () -> [Target], onPick: @escaping (Pick) -> Void) {
        targetsProvider = targets
        self.onPick = onPick
        if panel == nil { createPanel() }
        guard let panel, let searchField else { return }

        let frame = window.frame
        panel.setFrame(
            NSRect(
                x: frame.origin.x + (frame.width - Self.panelSize.width) / 2,
                y: frame.origin.y + frame.height * 0.55,
                width: Self.panelSize.width,
                height: Self.panelSize.height
            ),
            display: true
        )
        installMonitors()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
        searchField.currentEditor()?.selectAll(nil)
        runSearch()
    }

    func dismiss() {
        pendingSearch?.cancel()
        pendingSearch = nil
        search.cancel()
        targets = []
        removeMonitors()
        panel?.orderOut(nil)
    }

    // MARK: - Search

    private func scheduleSearch() {
        pendingSearch?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.runSearch() }
        pendingSearch = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.typingDelay, execute: work)
    }

    private func runSearch() {
        pendingSearch?.cancel()
        pendingSearch = nil
        search.cancel()
        rows = []
        progress = Progress()
        tableView?.reloadData()

        let needle = TerminalSearchSession.sanitized(searchField?.stringValue ?? "")
        guard needle.count >= Self.minNeedleLength else {
            targets = []
            statusLabel?.stringValue = needle.isEmpty ? "" : "Type at least \(Self.minNeedleLength) characters"
            return
        }
        targets = targetsProvider()
        progress.terminals = targets.count
        if !targets.isEmpty {
            search.start(
                needle: needle,
                readers: targets.map(\.read),
                onMatches: { [weak self] index, result in
                    self?.append(result, from: index, needle: needle)
                },
                onDone: { [weak self] in self?.updateStatus() }
            )
        }
        updateStatus()
    }

    private func append(_ result: ScrollbackSearch.Result, from index: Int, needle: String) {
        guard let target = targets[safe: index] else { return }
        progress.terminalsWithMatches += 1
        progress.matches += result.total
        let added = result.matches.prefix(Self.maxRows - rows.count).map {
            Row(column: target.column, place: target.place, needle: needle, match: $0, total: result.total)
        }
        if !added.isEmpty {
            let wasEmpty = rows.isEmpty
            rows += added
            tableView?.reloadData()
            if wasEmpty {
                tableView?.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            }
        }
        updateStatus()
    }

    private func updateStatus() {
        statusLabel?.stringValue = Self.status(
            terminals: progress.terminals,
            terminalsWithMatches: progress.terminalsWithMatches,
            matches: progress.matches,
            shown: rows.count,
            isSearching: search.isRunning
        )
    }

    nonisolated static func status(
        terminals: Int, terminalsWithMatches: Int, matches: Int, shown: Int, isSearching: Bool
    ) -> String {
        if terminals == 0 { return "No terminal to search" }
        if isSearching {
            let searching = "Searching \(counted(terminals, "terminal"))…"
            return matches == 0 ? searching : "\(searching) \(counted(matches, "match", "matches")) so far"
        }
        if matches == 0 { return "No matches in \(counted(terminals, "terminal"))" }
        let found = "\(counted(matches, "match", "matches")) in \(terminalsWithMatches) of \(counted(terminals, "terminal"))"
        return shown < matches ? "\(found) · \(shown) shown" : found
    }

    private nonisolated static func counted(_ count: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(count) \(count == 1 ? singular : plural ?? singular + "s")"
    }

    // MARK: - Picking

    private func commit(row index: Int) {
        guard let row = rows[safe: index] else { return }
        dismiss()
        guard let column = row.column else { return NSSound.beep() }
        onPick(Pick(column: column, needle: row.needle, match: row.match, total: row.total))
    }

    @objc private func tableClicked() {
        guard let table = tableView, table.clickedRow >= 0 else { return }
        commit(row: table.clickedRow)
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
        guard let table = tableView, event.window === panel else { return event }
        // An input method composing in the field keeps its keys.
        if (searchField?.currentEditor() as? NSTextView)?.hasMarkedText() == true { return event }
        switch event.keyCode {
        case 0x35: // Escape
            dismiss()
            return nil
        case 0x24, 0x4C: // Return / Enter
            // The rows still answer the text before the last keystroke:
            // search the new text instead of picking among them.
            if pendingSearch != nil {
                runSearch()
            } else {
                commit(row: table.selectedRow)
            }
            return nil
        case 0x7E, 0x7D: // Up / Down
            guard !rows.isEmpty else { return nil }
            let step = event.keyCode == 0x7E ? -1 : 1
            let row = min(max(table.selectedRow + step, 0), rows.count - 1)
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
            return nil
        default:
            return event
        }
    }

    // MARK: - Panel construction

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
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.becomesKeyOnlyIfNeeded = false

        let background = NSView(frame: NSRect(origin: .zero, size: size))
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.backgroundColor = NSColor(red: 0.11, green: 0.11, blue: 0.15, alpha: 0.98).cgColor
        background.layer?.borderWidth = 1
        background.layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor
        background.layer?.masksToBounds = true

        let fieldRow = NSView(frame: NSRect(x: 0, y: size.height - 44, width: size.width, height: 44))
        fieldRow.wantsLayer = true
        fieldRow.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.03).cgColor
        fieldRow.addSubview(PaletteIconView(.symbol("magnifyingglass"), frame: NSRect(x: 14, y: 10, width: 24, height: 24)))
        let field = NSTextField()
        field.font = .systemFont(ofSize: 15)
        field.textColor = .white
        field.backgroundColor = .clear
        field.isBezeled = false
        field.focusRingType = .none
        field.drawsBackground = false
        field.placeholderString = Self.placeholder
        field.frame = NSRect(x: 42, y: 10, width: size.width - 56, height: 24)
        field.delegate = self
        fieldRow.addSubview(field)
        background.addSubview(fieldRow)

        let separator = NSView(frame: NSRect(x: 0, y: size.height - 45, width: size.width, height: 1))
        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        background.addSubview(separator)

        let status = NSTextField(labelWithString: "")
        status.font = .systemFont(ofSize: 11)
        status.textColor = NSColor.white.withAlphaComponent(0.45)
        status.lineBreakMode = .byTruncatingTail
        status.frame = NSRect(x: 16, y: 6, width: size.width - 32, height: 14)
        background.addSubview(status)

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 26, width: size.width, height: size.height - 46 - 26))
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let table = NSTableView()
        table.headerView = nil
        table.backgroundColor = .clear
        table.gridStyleMask = []
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.rowHeight = 40
        table.rowSizeStyle = .custom
        table.selectionHighlightStyle = .regular
        table.allowsMultipleSelection = false
        table.style = .plain
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(tableClicked)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("match"))
        column.resizingMask = .autoresizingMask
        column.width = size.width
        table.addTableColumn(column)
        scroll.documentView = table
        background.addSubview(scroll)

        panel.contentView = background
        self.panel = panel
        searchField = field
        tableView = table
        statusLabel = status
    }
}

// MARK: - NSTextFieldDelegate

extension GlobalSearchPanel: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        scheduleSearch()
    }
}

// MARK: - Table

extension GlobalSearchPanel: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("GlobalSearchCell")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: nil) as? GlobalSearchCellView)
            ?? GlobalSearchCellView()
        cell.identifier = identifier
        if let row = rows[safe: row] { cell.configure(row) }
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        SearchResultRowView()
    }
}

/// Where the match is ("workspace › column", its line) over the line
/// itself, the match highlighted.
private final class GlobalSearchCellView: NSTableCellView {
    private let placeLabel = NSTextField(labelWithString: "")
    private let lineLabel = NSTextField(labelWithString: "")
    private let excerptLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        placeLabel.font = .systemFont(ofSize: 12, weight: .medium)
        placeLabel.textColor = NSColor.white.withAlphaComponent(0.85)
        placeLabel.lineBreakMode = .byTruncatingMiddle
        lineLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        lineLabel.textColor = NSColor.white.withAlphaComponent(0.4)
        lineLabel.alignment = .right
        excerptLabel.lineBreakMode = .byTruncatingTail
        [placeLabel, lineLabel, excerptLabel].forEach(addSubview)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let lineWidth: CGFloat = 90
        placeLabel.frame = NSRect(x: 16, y: 21, width: bounds.width - 32 - lineWidth, height: 16)
        lineLabel.frame = NSRect(x: bounds.width - 16 - lineWidth, y: 21, width: lineWidth, height: 16)
        excerptLabel.frame = NSRect(x: 16, y: 4, width: bounds.width - 32, height: 15)
    }

    func configure(_ row: GlobalSearchPanel.Row) {
        placeLabel.stringValue = row.place
        lineLabel.stringValue = "line \(row.match.line)"
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let excerpt = NSMutableAttributedString(string: row.match.excerpt, attributes: [
            .font: font,
            .foregroundColor: NSColor.white.withAlphaComponent(0.6)
        ])
        if NSMaxRange(row.match.highlight) <= excerpt.length {
            excerpt.addAttributes([
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .bold),
                .foregroundColor: NSColor.niruxAccent
            ], range: row.match.highlight)
        }
        excerptLabel.attributedStringValue = excerpt
    }
}
