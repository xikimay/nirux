import AppKit

/// Search Everywhere (⌥⌘F): one needle, searched in the scrollback of every
/// terminal of every workspace, in every project, then in the Claude
/// transcripts of the sessions the history knows (a no-flicker conversation
/// keeps no scrollback, a past one has no terminal). Matches stream in as
/// each terminal or transcript is read (GlobalTerminalSearch), grouped by
/// terminal or session, the newest first. Picking a terminal's match hands
/// it to `onPick`, which brings its column forward with the find bar open on
/// it; picking a session's hands it to `onPickSession`, which resumes it.
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

    /// A session whose Claude transcript is searched after the terminals.
    struct Session {
        let record: AgentSessionRecord
        let spaceID: String
        /// What the rows call it (see `SessionHistory.title`).
        let title: String
        let transcriptPath: String
    }

    struct Row {
        enum Source {
            /// A terminal's match, with the terminal's matches when it was
            /// read.
            case terminal(ScrollbackSearch.Match, total: Int)
            /// A match in a session's transcript.
            case session(Session)
        }

        /// A terminal's column.
        weak var column: ColumnState?
        let place: String
        let needle: String
        let excerpt: String
        /// The match in `excerpt`, in UTF-16 units.
        let highlight: NSRange
        /// "line 12" in a terminal; "you · 2 h ago" in a transcript.
        let detail: String
        let source: Source

        var session: Session? {
            if case .session(let session) = source { return session }
            return nil
        }
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
    /// Terminal rows; transcripts have rows of their own, so that terminals
    /// with a common word don't leave them none.
    nonisolated static let maxRows = 500
    nonisolated static let maxSessionRows = 200
    nonisolated static let typingDelay: TimeInterval = 0.15
    static let panelSize = NSSize(width: 720, height: 480)
    static let placeholder = "Search every terminal and Claude session…"

    private var panel: NSPanel?
    private(set) var searchField: NSTextField?
    private(set) var tableView: NSTableView?
    private(set) var statusLabel: NSTextField?

    private(set) var rows: [Row] = []
    private var targets: [Target] = []
    private var sessions: [Session] = []
    private var progress = Progress()
    private let search = GlobalTerminalSearch()
    private var targetsProvider: () -> [Target] = { [] }
    private var sessionsProvider: () -> [Session] = { [] }
    private var onPick: (Pick) -> Void = { _ in }
    private var onPickSession: (Session) -> Void = { _ in }

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
        var terminalRows = 0
        var terminalsDone = false
        var sessions = 0
        var sessionsWithMatches = 0
        var sessionMatches = 0
        var sessionRows = 0
        /// Set once the transcripts were read.
        var transcripts: GlobalTerminalSearch.TranscriptSummary?
    }

    /// Shows the panel over `window`. `targets` and `sessions` are asked
    /// again on every search, so terminals opened meanwhile are searched
    /// too. Reopening keeps the last needle, selected, and searches it
    /// again.
    func show(
        relativeTo window: NSWindow,
        targets: @escaping () -> [Target],
        sessions: @escaping () -> [Session] = { [] },
        onPick: @escaping (Pick) -> Void,
        onPickSession: @escaping (Session) -> Void = { _ in }
    ) {
        targetsProvider = targets
        sessionsProvider = sessions
        self.onPick = onPick
        self.onPickSession = onPickSession
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
        sessions = []
        // Transcript excerpts are the user's prompts: not kept once closed.
        rows = []
        tableView?.reloadData()
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
            sessions = []
            statusLabel?.stringValue = needle.isEmpty ? "" : "Type at least \(Self.minNeedleLength) characters"
            return
        }
        targets = targetsProvider()
        sessions = sessionsProvider()
        progress.terminals = targets.count
        progress.sessions = sessions.count
        if !targets.isEmpty || !sessions.isEmpty {
            search.start(
                needle: needle,
                readers: targets.map(\.read),
                transcripts: sessions.map(\.transcriptPath),
                onMatches: { [weak self] index, result in
                    self?.append(result, from: index, needle: needle)
                },
                onTerminalsDone: { [weak self] in
                    self?.progress.terminalsDone = true
                    self?.updateStatus()
                },
                onTranscriptMatches: { [weak self] index, result in
                    self?.append(result, fromSession: index, needle: needle)
                },
                onDone: { [weak self] summary in
                    self?.progress.terminalsDone = true
                    self?.progress.transcripts = summary
                    self?.updateStatus()
                }
            )
        }
        updateStatus()
    }

    private func append(_ result: ScrollbackSearch.Result, from index: Int, needle: String) {
        guard let target = targets[safe: index] else { return }
        progress.terminalsWithMatches += 1
        progress.matches += result.total
        let added = result.matches.prefix(Self.maxRows - progress.terminalRows).map {
            Row(
                column: target.column, place: target.place, needle: needle, excerpt: $0.excerpt,
                highlight: $0.highlight, detail: "line \($0.line)", source: .terminal($0, total: result.total)
            )
        }
        progress.terminalRows += added.count
        add(added)
    }

    private func append(_ result: TranscriptSearch.Result, fromSession index: Int, needle: String) {
        guard let session = sessions[safe: index] else { return }
        progress.sessionsWithMatches += 1
        progress.sessionMatches += result.total
        let place = Self.place(of: session, customTitle: result.customTitle, aiTitle: result.aiTitle)
        let now = Date()
        let added = result.matches.prefix(Self.maxSessionRows - progress.sessionRows).map { match in
            let who = match.role == .user ? "you" : "Claude"
            let when = match.timestamp.map { SessionHistory.ago(now.timeIntervalSince($0)) }
            // Its terminal may hold the same lines, with a find bar.
            let running = session.record.isActive ? "running" : nil
            return Row(
                column: nil, place: place, needle: needle, excerpt: match.excerpt, highlight: match.highlight,
                detail: [who, when, running].compactMap { $0 }.joined(separator: " · "), source: .session(session)
            )
        }
        progress.sessionRows += added.count
        add(added)
    }

    /// The session's name, then its title: the one it was given, unless
    /// that is the name (Nirux launches with `--name`), else Claude's own.
    nonisolated static func place(of session: Session, customTitle: String?, aiTitle: String?) -> String {
        let title = [customTitle, aiTitle].compactMap { $0 }.first { $0 != session.title }
        return title.map { "\(session.title) · \($0)" } ?? session.title
    }

    private func add(_ added: [Row]) {
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
        var parts: [String] = []
        if progress.terminals > 0 || progress.sessions == 0 {
            parts.append(Self.status(
                terminals: progress.terminals,
                terminalsWithMatches: progress.terminalsWithMatches,
                matches: progress.matches,
                shown: progress.terminalRows,
                isSearching: search.isRunning && !progress.terminalsDone
            ))
        }
        if progress.sessions > 0, progress.terminalsDone || progress.terminals == 0 {
            parts.append(Self.sessionStatus(
                matches: progress.sessionMatches, withMatches: progress.sessionsWithMatches,
                shown: progress.sessionRows, summary: progress.transcripts
            ))
        }
        statusLabel?.stringValue = parts.joined(separator: " · ")
        // The line may be cut: all of it on hover.
        statusLabel?.toolTip = statusLabel?.stringValue
    }

    /// The transcripts' part of the status line; `summary` is nil while
    /// they are read.
    nonisolated static func sessionStatus(
        matches: Int, withMatches: Int, shown: Int, summary: GlobalTerminalSearch.TranscriptSummary?
    ) -> String {
        guard let summary else {
            let searching = "Searching Claude sessions…"
            return matches == 0 ? searching : "\(searching) \(counted(matches, "match", "matches")) so far"
        }
        if summary.searched == 0 { return "No Claude session to search" }
        var status = matches == 0
            ? "No matches in \(counted(summary.searched, "session"))"
            : "\(counted(matches, "match", "matches")) in \(withMatches) of \(counted(summary.searched, "session"))"
        if shown < matches { status += " · \(shown) shown" }
        let notes = [
            summary.isCut ? "older sessions not searched" : nil,
            summary.partial > 0 ? "\(counted(summary.partial, "long transcript")) read from the end" : nil
        ].compactMap { $0 }
        return notes.isEmpty ? status : status + " (" + notes.joined(separator: "; ") + ")"
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
        switch row.source {
        case .session(let session):
            onPickSession(session)
        case .terminal(let match, let total):
            guard let column = row.column else { return NSSound.beep() }
            onPick(Pick(column: column, needle: row.needle, match: match, total: total))
        }
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
        panel.appearance = Theme.appearance
        panel.becomesKeyOnlyIfNeeded = false

        let background = NSView(frame: NSRect(origin: .zero, size: size))
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.backgroundColor = Theme.Color.base.withAlphaComponent(0.98).cgColor
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

/// Where the match is (a terminal's "workspace › column" and line, or a
/// session's name, who wrote it and when) over the line itself, the match
/// highlighted.
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
        // As wide as "line 12" or "Claude · 5 days ago" needs.
        let lineWidth = min(180, ceil(lineLabel.intrinsicContentSize.width))
        placeLabel.frame = NSRect(x: 16, y: 21, width: bounds.width - 32 - lineWidth, height: 16)
        lineLabel.frame = NSRect(x: bounds.width - 16 - lineWidth, y: 21, width: lineWidth, height: 16)
        excerptLabel.frame = NSRect(x: 16, y: 4, width: bounds.width - 32, height: 15)
    }

    func configure(_ row: GlobalSearchPanel.Row) {
        placeLabel.stringValue = row.place
        lineLabel.stringValue = row.detail
        // A transcript's text is prose; a terminal's, machine text.
        let isProse = row.session != nil
        let font = isProse ? Theme.Font.caption : NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        // The string's paragraph style decides, not the field's.
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let excerpt = NSMutableAttributedString(string: row.excerpt, attributes: [
            .font: font,
            .foregroundColor: NSColor.white.withAlphaComponent(0.6),
            .paragraphStyle: paragraph
        ])
        if NSMaxRange(row.highlight) <= excerpt.length {
            excerpt.addAttributes([
                .font: isProse ? Theme.Font.captionEmphasized : NSFont.monospacedSystemFont(ofSize: 11, weight: .bold),
                .foregroundColor: Theme.Color.accent
            ], range: row.highlight)
        }
        excerptLabel.attributedStringValue = excerpt
        // The detail's width changes with its text.
        needsLayout = true
    }
}
