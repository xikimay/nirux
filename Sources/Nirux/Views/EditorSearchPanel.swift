import AppKit

/// Workspace-wide text search. Wraps `rg` (preferred) or `grep` and streams
/// matches into a virtualized table. Picking a row opens the file in the
/// active editor column at the matched line.
@MainActor
final class EditorSearchPanel: NSObject {

    struct Result {
        let relativePath: String
        let line: Int
        let column: Int
        let text: String
    }

    private var panel: NSPanel?
    private var searchField: NSTextField?
    private var tableView: NSTableView?

    private var results: [Result] = []
    private var workspaceCwd: String = ""
    private var onPick: ((_ absolutePath: String, _ line: Int) -> Void)?

    private var keyMonitor: Any?
    private var clickMonitor: Any?

    private var currentProcess: Process?
    private var searchDebounce: DispatchWorkItem?

    private static let panelSize = NSSize(width: 720, height: 480)
    private static let maxResults = 500
    private static let minQueryLength = 2

    /// Show the search panel over `window`, scoped to `workspaceCwd`. Calls
    /// `onPick` with absolute path + line number on selection.
    func show(
        relativeTo window: NSWindow,
        workspaceCwd: String,
        onPick: @escaping (String, Int) -> Void
    ) {
        self.workspaceCwd = workspaceCwd
        self.onPick = onPick

        if panel == nil { createPanel() }
        guard let panel, let searchField, let tableView else { return }

        searchField.stringValue = ""
        results = []
        tableView.reloadData()

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
        cancelSearch()
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

        let icon = NSTextField(labelWithString: "🔎")
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
        field.placeholderString = "Search workspace…"
        field.frame = NSRect(x: 42, y: 10, width: Self.panelSize.width - 56, height: 24)
        field.delegate = self
        fieldRow.addSubview(field)

        bg.addSubview(fieldRow)

        let sep = NSView(frame: NSRect(x: 0, y: Self.panelSize.height - 45, width: Self.panelSize.width, height: 1))
        sep.wantsLayer = true
        sep.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        bg.addSubview(sep)

        // Table view
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: Self.panelSize.width, height: Self.panelSize.height - 46))
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autoresizingMask = [.width, .height]

        let table = NSTableView()
        table.headerView = nil
        table.backgroundColor = .clear
        table.gridStyleMask = []
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.rowHeight = 38
        table.rowSizeStyle = .custom
        table.selectionHighlightStyle = .regular
        table.allowsMultipleSelection = false
        table.style = .plain
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(tableClicked)
        table.doubleAction = #selector(tableDoubleClicked)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("result"))
        column.resizingMask = .autoresizingMask
        column.width = Self.panelSize.width
        table.addTableColumn(column)

        scroll.documentView = table
        bg.addSubview(scroll)

        p.contentView = bg
        panel = p
        searchField = field
        tableView = table
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
        case 0x24, 0x4C: // Return / Enter
            commitSelection()
            return nil
        case 0x7E: // Up
            let row = max(0, table.selectedRow - 1)
            if !results.isEmpty {
                table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                table.scrollRowToVisible(row)
            }
            return nil
        case 0x7D: // Down
            let row = min(results.count - 1, table.selectedRow + 1)
            if !results.isEmpty {
                table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                table.scrollRowToVisible(row)
            }
            return nil
        default:
            return event
        }
    }

    private func commitSelection() {
        guard let table = tableView, table.selectedRow >= 0, table.selectedRow < results.count else { return }
        let result = results[table.selectedRow]
        let abs = (workspaceCwd as NSString).appendingPathComponent(result.relativePath)
        dismiss()
        onPick?(abs, result.line)
    }

    @objc private func tableClicked() {}
    @objc private func tableDoubleClicked() { commitSelection() }

    // MARK: - Search

    private func scheduleSearch(query: String) {
        searchDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.runSearch(query: query)
        }
        searchDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    private func cancelSearch() {
        searchDebounce?.cancel()
        searchDebounce = nil
        if let p = currentProcess, p.isRunning {
            p.terminate()
        }
        currentProcess = nil
    }

    private func runSearch(query: String) {
        cancelSearch()
        results = []
        tableView?.reloadData()

        guard query.count >= Self.minQueryLength else { return }

        let process = Process()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe() // discard
        process.currentDirectoryURL = URL(fileURLWithPath: workspaceCwd)

        let usesRipgrepJSON: Bool
        if let rg = Self.findRipgrep() {
            usesRipgrepJSON = true
            process.executableURL = URL(fileURLWithPath: rg)
            process.arguments = [
                "--json", "--smart-case",
                "--max-count", "100",
                "--max-filesize", "2M",
                "--", query, "."
            ]
        } else {
            usesRipgrepJSON = false
            process.executableURL = URL(fileURLWithPath: "/usr/bin/grep")
            process.arguments = [
                "-rIn", "--include=*", "--exclude-dir=.git", "--exclude-dir=node_modules",
                "--exclude-dir=.build", "--exclude-dir=DerivedData",
                "--", query, "."
            ]
        }

        // FileHandle.readabilityHandler is invoked serially on a private
        // dispatch queue; wrap the line buffer in a class so Swift 6 sees a
        // shared reference instead of treating the var capture as a data race.
        let buffer = LineBuffer()
        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { [weak self] reader in
            let chunk = reader.availableData
            if chunk.isEmpty { return }
            buffer.drainLines(adding: chunk) { line in
                let result = usesRipgrepJSON
                    ? Self.parseRipgrepJSONLine(line)
                    : Self.parseLine(line)
                guard let result else { return }
                DispatchQueue.main.async { [weak self] in
                    self?.append(result)
                }
            }
        }

        process.terminationHandler = { _ in
            handle.readabilityHandler = nil
        }

        do {
            try process.run()
            currentProcess = process
        } catch {
            NSLog("[EditorSearchPanel] failed to launch search: %@", error.localizedDescription)
        }
    }

    private func append(_ result: Result) {
        guard results.count < Self.maxResults else { return }
        let wasEmpty = results.isEmpty
        results.append(result)
        tableView?.reloadData()
        if wasEmpty {
            tableView?.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    /// Parses a single rg/grep output line in the format
    /// `path:line:[col:]matched-text`. Returns nil when the line doesn't fit
    /// the expected shape (e.g. context-only output from grep variants).
    /// Nonisolated so it can run on the readabilityHandler's background
    /// queue without bouncing through MainActor.
    nonisolated static func parseLine(_ line: String) -> Result? {
        // Split into max 4 parts — the matched text often contains colons.
        let parts = line.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false)
            .map(String.init)
        guard parts.count >= 3, let lineNum = Int(parts[1]) else { return nil }

        // ripgrep --column emits 4 fields: path, line, column, text.
        if parts.count == 4, let col = Int(parts[2]) {
            return Result(relativePath: normalizeRelativePath(parts[0]), line: lineNum, column: col, text: parts[3])
        }
        // Plain grep -n emits 3 fields: path, line, text. The text may have
        // contained a colon that got captured into the third element here.
        let text = parts[2]
        return Result(relativePath: normalizeRelativePath(parts[0]), line: lineNum, column: 1, text: text)
    }

    /// Parses one ripgrep `--json` JSON Lines message. Only `match` messages
    /// become visible results; begin/end/context/summary messages are ignored.
    nonisolated static func parseRipgrepJSONLine(_ line: String) -> Result? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "match",
              let payload = object["data"] as? [String: Any],
              let pathObject = payload["path"] as? [String: Any],
              let rawPath = pathObject["text"] as? String,
              let linesObject = payload["lines"] as? [String: Any]
        else { return nil }

        let lineNumber: Int
        if let n = payload["line_number"] as? Int {
            lineNumber = n
        } else if let n = payload["line_number"] as? NSNumber {
            lineNumber = n.intValue
        } else {
            return nil
        }

        var column = 1
        if let submatches = payload["submatches"] as? [[String: Any]],
           let first = submatches.first {
            if let start = first["start"] as? Int {
                column = start + 1
            } else if let start = first["start"] as? NSNumber {
                column = start.intValue + 1
            }
        }

        let text = linesObject["text"] as? String ?? ""
        return Result(
            relativePath: normalizeRelativePath(rawPath),
            line: lineNumber,
            column: column,
            text: text
        )
    }

    private nonisolated static func normalizeRelativePath(_ path: String) -> String {
        path.hasPrefix("./") ? String(path.dropFirst(2)) : path
    }

    private static func findRipgrep() -> String? {
        let candidates = [
            "/opt/homebrew/bin/rg",
            "/usr/local/bin/rg",
            "/usr/bin/rg"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

// MARK: - NSTextFieldDelegate

extension EditorSearchPanel: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        scheduleSearch(query: searchField?.stringValue ?? "")
    }
}

// MARK: - Table data + delegate

extension EditorSearchPanel: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("EditorSearchCell")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: nil) as? SearchResultCellView)
            ?? SearchResultCellView()
        cell.identifier = identifier
        cell.configure(result: results[row])
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        SearchResultRowView()
    }
}

private final class SearchResultCellView: NSTableCellView {
    private let pathLabel = NSTextField(labelWithString: "")
    private let lineLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        pathLabel.font = .systemFont(ofSize: 12, weight: .medium)
        pathLabel.textColor = NSColor.white.withAlphaComponent(0.85)
        pathLabel.lineBreakMode = .byTruncatingMiddle
        addSubview(pathLabel)
        lineLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        lineLabel.textColor = NSColor.white.withAlphaComponent(0.55)
        lineLabel.lineBreakMode = .byTruncatingTail
        addSubview(lineLabel)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        pathLabel.frame = NSRect(x: 16, y: 18, width: bounds.width - 24, height: 16)
        lineLabel.frame = NSRect(x: 16, y: 2, width: bounds.width - 24, height: 14)
    }

    func configure(result: EditorSearchPanel.Result) {
        pathLabel.stringValue = "\(result.relativePath):\(result.line)"
        lineLabel.stringValue = result.text.trimmingCharacters(in: .whitespaces)
    }
}

/// Serial line accumulator for the search subprocess's stdout. The
/// `FileHandle.readabilityHandler` queue invokes us serially, so unchecked
/// Sendable is safe here — we just need a class to satisfy Swift 6's
/// concurrency checker for the captured buffer.
private final class LineBuffer: @unchecked Sendable {
    private var data = Data()

    /// Appends `chunk` and invokes `handler` for every complete line drained
    /// from the buffer. Called on a single background queue per FileHandle.
    func drainLines(adding chunk: Data, _ handler: (String) -> Void) {
        data.append(chunk)
        while let nl = data.firstIndex(of: 0x0A) {
            let lineData = data.prefix(upTo: nl)
            data = Data(data.suffix(from: nl + 1))
            if let line = String(data: lineData, encoding: .utf8) {
                handler(line)
            }
        }
    }
}

private final class SearchResultRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        if selectionHighlightStyle != .none {
            NSColor.niruxAccent.withAlphaComponent(0.18).setFill()
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 2), xRadius: 6, yRadius: 6)
            path.fill()
        }
    }
    override var isEmphasized: Bool { get { true } set {} }
}
