import AppKit

/// Session History (⌘P › Session History…): every session of the current
/// space, the ones a column holds first, filtered by text, pull request and
/// agent. Under the list, what Return does on the selected row: go to the
/// column that holds it, or resume it, and where (`AgentSessionResume.plan`,
/// read off the main thread). Return, the button or a double click hands
/// the row to `onPick`.
@MainActor
final class SessionHistoryPanel: NSObject {
    typealias PlanResult = Result<AgentSessionResume.Plan, AgentSessionResume.Unavailable>

    static let panelSize = NSSize(width: 720, height: 480)
    static let placeholder = "Filter sessions…"
    static let openTitle = "Open"
    static let endedTitle = "Ended"
    /// Arrowing through rows doesn't run git for each one passed.
    static let planDelay: TimeInterval = 0.15

    /// A section header or a row, as the table lists them.
    enum Item: Equatable {
        case header(String)
        /// An index into `rows`.
        case row(Int)
    }

    private var panel: NSPanel?
    private(set) var searchField: NSTextField?
    private(set) var pullRequestControl: NSSegmentedControl?
    private(set) var agentControl: NSSegmentedControl?
    private(set) var tableView: NSTableView?
    private(set) var actionLabel: NSTextField?
    private(set) var detailLabel: NSTextField?
    private(set) var resumeButton: NSButton?

    private(set) var rows: [SessionHistoryRow] = []
    private(set) var items: [Item] = []
    /// Every row, as the panel opened: the filters pick among them.
    private var allRows: [SessionHistoryRow] = []
    /// Plans read since the panel opened, by session, and the ones being
    /// read. A Resume closes the panel.
    private var plans: [String: PlanResult] = [:]
    private var plansReading: Set<String> = []
    /// Answers for an earlier opening are dropped.
    private var generation = 0
    private var pendingPlan: DispatchWorkItem?

    private var planProvider: (AgentSessionRecord, @escaping @MainActor @Sendable (PlanResult) -> Void) -> Void = { _, _ in }
    private var onPick: (SessionHistoryRow) -> Void = { _ in }

    private var keyMonitor: Any?
    private var clickMonitor: Any?

    var isVisible: Bool { panel?.isVisible == true }

    /// The selected row; nil on none.
    var selectedRow: SessionHistoryRow? {
        guard let table = tableView, case .row(let index)? = items[safe: table.selectedRow] else { return nil }
        return rows[safe: index]
    }

    /// Shows `rows` over `window`, filters cleared. `plan` reads where a
    /// session would resume and answers on the main thread.
    func show(
        relativeTo window: NSWindow,
        rows: [SessionHistoryRow],
        plan: @escaping (AgentSessionRecord, @escaping @MainActor @Sendable (PlanResult) -> Void) -> Void,
        onPick: @escaping (SessionHistoryRow) -> Void
    ) {
        allRows = rows
        planProvider = plan
        self.onPick = onPick
        generation += 1
        plans = [:]
        plansReading = []
        if panel == nil { createPanel() }
        guard let panel, let searchField else { return }
        searchField.stringValue = ""
        pullRequestControl?.selectedSegment = 0
        agentControl?.selectedSegment = 0

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
        reload()
    }

    func dismiss() {
        pendingPlan?.cancel()
        pendingPlan = nil
        removeMonitors()
        panel?.orderOut(nil)
    }

    // MARK: - Rows

    var filter: SessionHistoryFilter {
        let pullRequests: [AgentSessionLedger.Query.PullRequestFilter] = [.any, .with, .without]
        let agents: [AgentHookEvent.Kind?] = [nil, .claude, .codex]
        return SessionHistoryFilter(
            text: searchField?.stringValue ?? "",
            pullRequest: pullRequests[safe: pullRequestControl?.selectedSegment ?? 0] ?? .any,
            agent: agents[safe: agentControl?.selectedSegment ?? 0] ?? nil
        )
    }

    /// Lists what the filters match, the first row selected.
    @objc func reload() {
        rows = SessionHistory.filtered(allRows, by: filter)
        let open = rows.indices.filter { rows[$0].isOpen }
        let ended = rows.indices.filter { !rows[$0].isOpen }
        items = (open.isEmpty ? [] : [.header(Self.openTitle)] + open.map(Item.row))
            + (ended.isEmpty ? [] : [.header(Self.endedTitle)] + ended.map(Item.row))
        tableView?.reloadData()
        if let first = items.firstIndex(where: { if case .row = $0 { return true } else { return false } }) {
            select(item: first)
        } else {
            updateFooter()
        }
    }

    private func select(item index: Int) {
        guard let table = tableView else { return }
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        table.scrollRowToVisible(index)
        updateFooter()
    }

    /// The row `step` rows above or below the selected one, headers skipped.
    private func moveSelection(by step: Int) {
        guard let table = tableView else { return }
        var index = table.selectedRow + step
        while let item = items[safe: index] {
            if case .row = item { return select(item: index) }
            index += step
        }
    }

    // MARK: - Footer

    private func updateFooter() {
        guard let row = selectedRow else {
            actionLabel?.stringValue = rows.isEmpty
                ? allRows.isEmpty ? "No session in this project yet" : "No session matches"
                : ""
            detailLabel?.stringValue = ""
            detailLabel?.toolTip = nil
            resumeButton?.isEnabled = false
            return
        }
        let plan = plans[row.record.key]
        if !row.isOpen, plan == nil { schedulePlan(for: row.record) }
        let outcome = SessionHistory.outcome(of: row, plan: plan) { $0.abbreviatedPath() }
        actionLabel?.stringValue = outcome.isPossible ? "↩ " + outcome.action : outcome.action
        detailLabel?.stringValue = outcome.detail ?? ""
        // A long warning is cut: all of it on hover, and in the question.
        detailLabel?.toolTip = outcome.detail
        // A warning, not a wait on the user: never amber.
        detailLabel?.textColor = outcome.isWarning
            ? .systemOrange
            : outcome.isPossible ? Theme.Color.textSecondary : Theme.Color.error
        resumeButton?.title = row.isOpen ? "Go To" : "Resume"
        resumeButton?.isEnabled = outcome.isPossible
    }

    private func schedulePlan(for record: AgentSessionRecord) {
        pendingPlan?.cancel()
        guard !plansReading.contains(record.key) else { return }
        let generation = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            plansReading.insert(record.key)
            planProvider(record) { [weak self] plan in
                guard let self, self.generation == generation else { return }
                plansReading.remove(record.key)
                plans[record.key] = plan
                if selectedRow?.record.key == record.key { updateFooter() }
            }
        }
        pendingPlan = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.planDelay, execute: work)
    }

    // MARK: - Picking

    @objc private func commit() {
        guard let row = selectedRow, resumeButton?.isEnabled == true else { return NSSound.beep() }
        dismiss()
        onPick(row)
    }

    @objc private func tableDoubleClicked() {
        guard let table = tableView, table.clickedRow >= 0, case .row = items[safe: table.clickedRow] else { return }
        select(item: table.clickedRow)
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
        panel.isReleasedWhenClosed = false

        let background = NSView(frame: NSRect(origin: .zero, size: size))
        background.wantsLayer = true
        background.layer?.cornerRadius = Theme.Radius.panel
        background.layer?.backgroundColor = Theme.Color.base.cgColor
        background.layer?.borderWidth = 1
        background.layer?.borderColor = Theme.Color.lineStrong.cgColor
        background.layer?.masksToBounds = true

        // The field, then the filters, at the top.
        let fieldRow = NSView(frame: NSRect(x: 0, y: size.height - 44, width: size.width, height: 44))
        fieldRow.wantsLayer = true
        fieldRow.layer?.backgroundColor = Theme.Color.fillHover.cgColor
        fieldRow.addSubview(PaletteIconView(
            .symbol(Theme.Symbol.sessionHistory), frame: NSRect(x: 14, y: 10, width: 24, height: 24)
        ))
        let field = NSTextField()
        field.font = .systemFont(ofSize: 15)
        field.textColor = Theme.Color.textPrimary
        field.backgroundColor = .clear
        field.isBezeled = false
        field.focusRingType = .none
        field.drawsBackground = false
        field.placeholderString = Self.placeholder
        field.frame = NSRect(x: 42, y: 10, width: size.width - 56, height: 24)
        field.delegate = self
        fieldRow.addSubview(field)
        background.addSubview(fieldRow)

        let pullRequests = NSSegmentedControl(
            labels: ["All", "With PR", "No PR"], trackingMode: .selectOne, target: self, action: #selector(reload)
        )
        let agents = NSSegmentedControl(
            labels: ["All Agents", "Claude", "Codex"], trackingMode: .selectOne, target: self, action: #selector(reload)
        )
        for (control, x) in [(pullRequests, Theme.Space.lg), (agents, size.width / 2)] {
            // The keyboard stays in the field, whatever is clicked.
            control.refusesFirstResponder = true
            control.selectedSegmentBezelColor = Theme.Color.accent
            control.controlSize = .small
            control.font = Theme.Font.caption
            control.sizeToFit()
            control.frame.origin = NSPoint(x: x, y: size.height - 44 - control.frame.height - Theme.Space.sm)
            background.addSubview(control)
        }
        let filtersBottom = size.height - 44 - pullRequests.frame.height - 2 * Theme.Space.sm

        let separator = NSView(frame: NSRect(x: 0, y: filtersBottom, width: size.width, height: 1))
        separator.wantsLayer = true
        separator.layer?.backgroundColor = Theme.Color.line.cgColor
        background.addSubview(separator)

        // What Return does, at the bottom.
        let footerHeight: CGFloat = 48
        let button = NSButton(title: "Resume", target: self, action: #selector(commit))
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.sizeToFit()
        button.frame.size.width = max(button.frame.width, 96)
        button.frame.origin = NSPoint(
            x: size.width - Theme.Space.lg - button.frame.width, y: (footerHeight - button.frame.height) / 2
        )
        background.addSubview(button)
        let textWidth = button.frame.minX - 2 * Theme.Space.lg
        let action = NSTextField(labelWithString: "")
        action.font = Theme.Font.bodyEmphasized
        action.textColor = Theme.Color.textPrimary
        action.lineBreakMode = .byTruncatingMiddle
        action.frame = NSRect(x: Theme.Space.lg, y: 24, width: textWidth, height: 16)
        background.addSubview(action)
        let detail = NSTextField(labelWithString: "")
        detail.font = Theme.Font.caption
        detail.textColor = Theme.Color.textSecondary
        detail.lineBreakMode = .byTruncatingTail
        detail.frame = NSRect(x: Theme.Space.lg, y: 7, width: textWidth, height: 15)
        background.addSubview(detail)
        let footerLine = NSView(frame: NSRect(x: 0, y: footerHeight, width: size.width, height: 1))
        footerLine.wantsLayer = true
        footerLine.layer?.backgroundColor = Theme.Color.line.cgColor
        background.addSubview(footerLine)

        let scroll = NSScrollView(frame: NSRect(
            x: 0, y: footerHeight + 1, width: size.width, height: filtersBottom - footerHeight - 1
        ))
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let table = NSTableView()
        table.refusesFirstResponder = true
        table.allowsEmptySelection = false
        // A floating header would draw over the rows under it.
        table.floatsGroupRows = false
        table.headerView = nil
        table.backgroundColor = .clear
        table.gridStyleMask = []
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.rowSizeStyle = .custom
        table.selectionHighlightStyle = .regular
        table.allowsMultipleSelection = false
        table.style = .plain
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(tableDoubleClicked)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("session"))
        column.resizingMask = .autoresizingMask
        column.width = size.width
        table.addTableColumn(column)
        scroll.documentView = table
        background.addSubview(scroll)

        panel.contentView = background
        self.panel = panel
        searchField = field
        pullRequestControl = pullRequests
        agentControl = agents
        tableView = table
        actionLabel = action
        detailLabel = detail
        resumeButton = button
    }
}

// MARK: - NSTextFieldDelegate

extension SessionHistoryPanel: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        reload()
    }
}

// MARK: - Table

extension SessionHistoryPanel: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = items[safe: row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .header = items[safe: row] { return 24 }
        return 44
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .row = items[safe: row] { return true }
        return false
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateFooter()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch items[safe: row] {
        case .header(let title):
            let label = NSTextField(labelWithAttributedString: NSAttributedString(string: title.uppercased(), attributes: [
                .font: Theme.Font.label, .kern: Theme.Font.labelKern, .foregroundColor: Theme.Color.textTertiary
            ]))
            let header = NSView()
            label.frame = NSRect(x: Theme.Space.lg, y: 4, width: Self.panelSize.width - 2 * Theme.Space.lg, height: 14)
            header.addSubview(label)
            return header
        case .row(let index):
            guard let row = rows[safe: index] else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("SessionHistoryCell")
            let cell = (tableView.makeView(withIdentifier: identifier, owner: nil) as? SessionHistoryCellView)
                ?? SessionHistoryCellView()
            cell.identifier = identifier
            cell.configure(row, now: Date().timeIntervalSince1970)
            return cell
        case nil:
            return nil
        }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        if case .header = items[safe: row] { return HeaderRowView() }
        return SearchResultRowView()
    }
}

/// A section header draws no group background.
private final class HeaderRowView: NSTableRowView {
    override func drawBackground(in dirtyRect: NSRect) {}
}

/// The session's agent and title, when it was last active on the right;
/// below, its state and column when one holds it, its branch, pull request
/// and folder.
private final class SessionHistoryCellView: NSTableCellView {
    private var icon: PaletteIconView?
    private let titleLabel = NSTextField(labelWithString: "")
    private let timeLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        titleLabel.font = Theme.Font.title
        titleLabel.textColor = Theme.Color.textPrimary
        titleLabel.lineBreakMode = .byTruncatingTail
        timeLabel.font = Theme.Font.caption
        timeLabel.textColor = Theme.Color.textTertiary
        timeLabel.alignment = .right
        detailLabel.maximumNumberOfLines = 1
        detailLabel.cell?.wraps = false
        [titleLabel, timeLabel, detailLabel].forEach(addSubview)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let textX: CGFloat = 46
        let timeWidth: CGFloat = 90
        icon?.frame = NSRect(x: Theme.Space.lg, y: (bounds.height - 20) / 2, width: 20, height: 20)
        titleLabel.frame = NSRect(x: textX, y: 22, width: bounds.width - textX - timeWidth - 2 * Theme.Space.lg, height: 17)
        timeLabel.frame = NSRect(x: bounds.width - Theme.Space.lg - timeWidth, y: 22, width: timeWidth, height: 16)
        detailLabel.frame = NSRect(x: textX, y: 5, width: bounds.width - textX - Theme.Space.lg, height: 15)
    }

    func configure(_ row: SessionHistoryRow, now: TimeInterval) {
        icon?.removeFromSuperview()
        let agentIcon = PaletteIconView(.agent(row.record.agent.rawValue), frame: .zero)
        addSubview(agentIcon)
        icon = agentIcon
        titleLabel.stringValue = SessionHistory.title(of: row.record)
        timeLabel.stringValue = SessionHistory.ago(now - row.record.lastActivityAt)

        let detail = NSMutableAttributedString()
        // The string's paragraph style decides, not the field's: the middle
        // goes, the folder at the end stays.
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Theme.Font.caption, .foregroundColor: Theme.Color.textSecondary, .paragraphStyle: paragraph
        ]
        func append(_ text: String, color: NSColor = Theme.Color.textSecondary) {
            if detail.length > 0 { detail.append(NSAttributedString(string: " · ", attributes: attributes)) }
            detail.append(NSAttributedString(string: text, attributes: attributes.merging([.foregroundColor: color]) { $1 }))
        }
        var details = SessionHistory.details(of: row.record, displayPath: { $0.abbreviatedPath() })
        if let held = row.held {
            let state = Self.state(of: held, live: row.liveState, now: now)
            append(state.text, color: state.color)
            if let place = row.place {
                append(place)
                // The column's header already names its folder.
                details.removeAll { $0 == SessionHistory.folder(of: row.record).map { $0.abbreviatedPath() } }
            }
        }
        for part in details {
            let isMerged = row.record.pullRequest.map { SessionHistory.pullRequestLabel($0) == part && $0.state == "MERGED" }
            append(part, color: isMerged == true ? Theme.Color.done : Theme.Color.textSecondary)
        }
        detailLabel.attributedStringValue = detail
        needsLayout = true
    }

    /// The column's live state, as ⌘P shows it, in one color per state:
    /// amber only for an agent that waits on the user.
    private static func state(
        of held: HeldAgentSession, live: QuickSwitchAgentState?, now: TimeInterval
    ) -> (text: String, color: NSColor) {
        switch held.state {
        case .restored: return ("not resumed yet", Theme.Color.textTertiary)
        case .exited: return ("exited mid-turn", Theme.Color.error)
        case .running:
            guard let live else { return ("running", Theme.Color.textSecondary) }
            let color: NSColor
            switch live {
            case .working: color = Theme.Color.working
            case .waiting: color = Theme.Color.waiting
            case .failed: color = Theme.Color.error
            }
            return (live.label(now: now), color)
        }
    }
}
