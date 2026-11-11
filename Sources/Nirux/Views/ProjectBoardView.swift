import AppKit

/// The Project Board column's content (docs/design/project-board.md, sections 1
/// and 2): the column header (its repository, the last post-merge run or
/// what went wrong, Refresh, and the project and Board Settings in its ⋯
/// menu), the merge queue's line, then one row per branch. A board with
/// several repositories (docs/design/spaces.md, S12) names its space in the header,
/// keeps one queue line per repository under it, always in sight, and
/// groups the rows under a header per repository. Lines under the header
/// say why the board shows less than it could: what went wrong reading
/// GitHub, a repository not set up, with Board Settings… beside it.
/// It only draws: `ProjectBoardController` fills it, the shell runs its
/// buttons and the queue.
@MainActor
final class ProjectBoardView: NSView {
    struct Project: Equatable {
        let id: String
        let name: String
    }

    struct Header: Equatable {
        var projectName: String
        var repository: String?
        /// The header's pill: "nightly 20:27" with how it ended; the
        /// whole summary ("nightly: success 20:27, 60e0ff2") in its tooltip.
        var postMergeRun: ColumnHeaderView.Status?
        /// When the pull requests were read (Refresh's tooltip), or why
        /// they weren't (a red pill in place of the run's, the message in
        /// its tooltip: the rows never move).
        var status: String?
        var statusIsError = false
        /// The red pill's words: "GitHub error", "git error".
        var errorTitle = "GitHub error"
        /// The project menu.
        var projects: [Project] = []
        var projectID: String
        /// The board's project was deleted: the menu says so.
        var projectIsMissing = false
    }

    /// One repository of a board with several: its header, its rows, its
    /// queue.
    struct Section: Equatable {
        let id: String
        /// The anchor's name, "x-front".
        var title: String
        /// `owner/name`; nil while it has none.
        var repository: String?
        /// Its post-merge run, or what went wrong reading it.
        var status: ColumnHeaderView.Status?
        /// Why it shows no pull requests: no repository, a read-only file.
        var note: String?
        var rows: [ProjectBoard.Row]
        var requiredChecks: [String] = []
        var baseBranch: String?
        /// Its merge queue; nil without a repository.
        var queue: ProjectBoard.QueueState?
    }

    /// A queue line of a board with several: a repository's queue, or one
    /// left running on a repository the board no longer has.
    struct QueueLine: Equatable {
        /// Its section's id, or the orphan's.
        let id: String
        var title: String
        var tooltip: String?
        var queue: ProjectBoard.QueueState
    }

    /// A line under the header: what went wrong reading GitHub, or why a
    /// repository isn't set up, with Board Settings….
    struct Notice: Equatable {
        var text: String
        var isError = false
        /// The section whose Board Settings its button opens; nil: no button.
        var settingsSection: String?

        var offersSettings: Bool { settingsSection != nil }
    }

    enum Body: Equatable {
        case message(String)
        case rows([ProjectBoard.Row])
        /// Several repositories, then the workspaces in none of them.
        case sections([Section], others: [ProjectBoard.Row])
    }

    struct Content: Equatable {
        var header: Header
        var body: Body
        /// The configured checks, shown by name.
        var requiredChecks: [String] = []
        /// The configured base branch: another one is named in the PR column.
        var baseBranch: String?
        /// The project's merge queue on a board with one repository (its
        /// rows' cells, and its line unless `queueLines` has some); nil
        /// while the board can't show one (no repository, a deleted project).
        var queue: ProjectBoard.QueueState?
        /// One line per queue, under the header, when the board has several.
        var queueLines: [QueueLine] = []
        /// Above the queue lines.
        var notices: [Notice] = []
        /// A Board Settings… button under the body's message.
        var messageOffersSettings = false
    }

    /// A button of the queue line or of a Queue cell.
    struct QueueButton: Equatable {
        let title: String
        var isEnabled = true
        var tooltip: String?
    }

    enum QueueTone: Equatable {
        case normal, active, success, failure
    }

    /// The header's queue line: what the queue does, Start and Stop.
    struct QueueHeader: Equatable {
        var text: String
        var tone: QueueTone = .normal
        var isDryRun: Bool
        /// Why this build is a dry run, for the badge's tooltip.
        var dryRunReason: String?
        var start: QueueButton?
        var stop: QueueButton?
    }

    /// A row's Queue column: its place or step, or why it can't join, and
    /// the button that adds or removes it.
    struct QueueCell: Equatable {
        var text: String
        var tone: QueueTone = .normal
        /// A second line: what the last queue did with it.
        var detail: String?
        var detailTone: QueueTone = .normal
        var tooltip: String?
        var button: QueueButton?
        var action: Action?
    }

    enum Action: Equatable {
        case focus(workspaceID: String, columnID: UUID?)
        case open(path: String, title: String)
        case cleanUp(path: String)
        case resumeFailed(workspaceID: String, columnID: UUID, failedAt: TimeInterval)
        case resumeExited(workspaceID: String, columnID: UUID)
        /// `section`: the repository's, on a board with several; nil on a
        /// board with one.
        case addToQueue(number: Int, section: String? = nil)
        case removeFromQueue(number: Int, section: String? = nil)
        /// Its base's pull request merged: base it on that one's base.
        case retarget(number: Int, base: String, section: String? = nil)
    }

    /// A button of a row, with what it does.
    final class ActionButton: NSButton {
        var boardAction: Action?
    }

    /// One row as drawn, for the shell's tests to click through.
    struct RowViews {
        fileprivate(set) var row: ProjectBoard.Row
        /// Its section's id; nil on a board with one repository.
        let section: String?
        /// The name, a button when the row has a workspace to focus.
        let name: NSView
        let subtitle: NSTextField
        let agent: NSTextField
        let pullRequest: NSTextField
        let checks: NSTextField
        let queue: NSTextField
        let queueDetail: NSTextField
        let queueButton: ActionButton?
        let actions: [ActionButton]
    }

    /// A queue line's line of a board with several repositories: its
    /// repository's name, then what the board with one shows.
    @MainActor
    final class QueueLineViews {
        let section: String
        let name = NSTextField(labelWithString: "")
        let badge = NSTextField(labelWithString: "DRY RUN")
        let label = NSTextField(labelWithString: "")
        let startButton = NSButton(title: "Start…", target: nil, action: nil)
        let stopButton = NSButton(title: "Stop", target: nil, action: nil)

        init(section: String) {
            self.section = section
        }

        var views: [NSView] { [name, badge, label, startButton, stopButton] }
    }

    /// A notice's line: its words, and Board Settings… when it offers it.
    @MainActor
    final class NoticeLineViews {
        let label = NSTextField(labelWithString: "")
        let settingsButton = NSButton(title: "Board Settings…", target: nil, action: nil)
        var section: String?
    }

    var onRefresh: (() -> Void)?
    /// Start and Stop of a queue line: the section's id on a board with
    /// several repositories, nil on one.
    var onStartQueue: ((String?) -> Void)?
    var onStopQueue: ((String?) -> Void)?
    var onSelectProject: ((String) -> Void)?
    /// The ⋯ menu's item and the buttons saying Board Settings…: on a
    /// section's repository, or nil for the one the form showed last.
    var onBoardSettings: ((String?) -> Void)?
    var onAction: ((Action) -> Void)?

    private(set) var content: Content?
    /// Each section's "Other worktrees" starts folded, each time the board
    /// opens; "" is the board with one repository.
    private(set) var expandedOtherWorktrees: Set<String> = []
    var isOtherWorktreesExpanded: Bool { expandedOtherWorktrees.contains("") }
    private(set) var rowViews: [RowViews] = []
    /// The first "Other worktrees" toggle (the board with one repository's).
    private(set) var otherWorktreesToggle: NSButton?
    /// The queue lines of a board with several repositories, in its order.
    private(set) var queueLines: [QueueLineViews] = []
    /// The notices' lines, in their order.
    private(set) var noticeLines: [NoticeLineViews] = []
    /// What the rows' area holds, from the top.
    private var bodyItems: [BodyItem] = []

    private enum BodyItem {
        /// An index in `rowViews`.
        case row(Int)
        case toggle(NSButton)
        case title(NSTextField)
        case sectionHeader(NSView)
    }

    /// What a row's cells read besides the row: its section's.
    private struct RowContext: Equatable {
        var section: String?
        var queue: ProjectBoard.QueueState?
        var baseBranch: String?
        var requiredChecks: [String]
    }

    let header = ColumnHeaderView()
    let refreshButton = ColumnHeaderButton(symbol: Theme.Symbol.reload, toolTip: "Refresh")
    /// "DRY RUN" while this build can't change GitHub.
    let dryRunBadge = NSTextField(labelWithString: "DRY RUN")
    let queueLabel = NSTextField(labelWithString: "")
    let startQueueButton = NSButton(title: "Start…", target: nil, action: nil)
    let stopQueueButton = NSButton(title: "Stop", target: nil, action: nil)
    let messageLabel = NSTextField(wrappingLabelWithString: "")
    let messageSettingsButton = NSButton(title: "Board Settings…", target: nil, action: nil)
    private let columnTitles = ["Name", "Agent", "PR", "Checks", "Queue", "Actions"].map { NSTextField(labelWithString: $0) }
    private let separator = NSView()
    private let scrollView = NSScrollView()
    private let documentView = FlippedView()

    private static let rowHeight: CGFloat = 42
    private static let groupHeight: CGFloat = 28
    private static let sectionHeaderHeight: CGFloat = 34
    private static let queueLineHeight: CGFloat = 28
    private static let padding: CGFloat = 12
    /// Name, Agent, PR, Checks, Queue, Actions. Actions keeps its width:
    /// its last buttons hide when they don't fit.
    private static let columnFractions: [CGFloat] = [0.20, 0.14, 0.11, 0.13, 0.15, 0.27]

    private static let primaryText = NSColor.white.withAlphaComponent(0.85)
    private static let secondaryText = NSColor.white.withAlphaComponent(0.45)
    private static let waitingColor = Theme.Color.waiting
    private static let failureColor = Theme.Color.error
    private static let workingColor = Theme.Color.working
    private static let successColor = Theme.Color.success
    /// Checks still running: not a wait on the user, so not `waiting`.
    private static let pendingColor = NSColor.systemOrange
    private static let dryRunColor = NSColor.systemOrange

    nonisolated static let dryRunTooltip = "This build can’t change GitHub: its queue reads GitHub, then stops before its first "
        + "branch update, rerun or merge. Only the notarized release, on the real state, runs a real queue."

    /// The tooltip, with why this build is a dry run when it is known.
    nonisolated static func dryRunTooltip(reason: String?) -> String {
        dryRunTooltip + (reason.map { "\nThis build: \($0)." } ?? "")
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Theme.Color.canvas.cgColor
        appearance = Theme.appearance

        header.icon = .symbol(Theme.Symbol.projectBoard)
        header.title = "Board"
        refreshButton.target = self
        refreshButton.action = #selector(refreshClicked)
        header.trailingButtons = [refreshButton]
        header.menuProvider = { [weak self] in self?.headerMenu() ?? NSMenu() }
        for (button, action) in [
            (startQueueButton, #selector(startQueueClicked)), (stopQueueButton, #selector(stopQueueClicked)),
            (messageSettingsButton, #selector(settingsClicked))
        ] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11)
            button.target = self
            button.action = action
        }
        for title in columnTitles {
            title.font = .systemFont(ofSize: 10, weight: .semibold)
            title.textColor = Self.secondaryText
        }
        queueLabel.font = .systemFont(ofSize: 11, weight: .medium)
        queueLabel.textColor = Self.secondaryText
        queueLabel.lineBreakMode = .byTruncatingTail
        dryRunBadge.font = .systemFont(ofSize: 9.5, weight: .bold)
        dryRunBadge.textColor = .black
        dryRunBadge.alignment = .center
        dryRunBadge.drawsBackground = true
        dryRunBadge.backgroundColor = Self.dryRunColor
        dryRunBadge.toolTip = Self.dryRunTooltip
        dryRunBadge.isHidden = true
        stopQueueButton.isHidden = true
        startQueueButton.isHidden = true
        queueLabel.isHidden = true
        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        messageLabel.font = .systemFont(ofSize: 12)
        messageLabel.textColor = Self.secondaryText
        messageLabel.alignment = .center

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = documentView

        for view in [
            header, dryRunBadge, queueLabel, startQueueButton, stopQueueButton, separator, scrollView
        ] as [NSView] {
            addSubview(view)
        }
        columnTitles.forEach(addSubview)
        documentView.addSubview(messageLabel)
        messageSettingsButton.isHidden = true
        documentView.addSubview(messageSettingsButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Content

    /// Draws `content`. The rows are built again only when more than their
    /// agents' labels changed: a working agent's time ticks by the second.
    func show(_ content: Content) {
        guard content != self.content else { return }
        let previous = self.content
        self.content = content
        applyHeader(content.header)
        applyQueueHeader(content.queueLines.isEmpty ? content.queue.map(Self.queueHeader) : nil)
        applyQueueLines(content.queueLines)
        applyNotices(content.notices)
        if content.body != previous?.body || content.requiredChecks != previous?.requiredChecks
            || content.baseBranch != previous?.baseBranch || content.queue != previous?.queue {
            if !updateAgentsInPlace(from: previous) { buildBody() }
        }
        layoutContent()
    }

    /// Each row with what its cells read, in board order; nil for a message.
    private static func placedRows(_ content: Content) -> [(context: RowContext, row: ProjectBoard.Row)]? {
        switch content.body {
        case .message:
            return nil
        case .rows(let rows):
            let context = RowContext(
                section: nil, queue: content.queue, baseBranch: content.baseBranch, requiredChecks: content.requiredChecks
            )
            return rows.map { (context, $0) }
        case .sections(let sections, let others):
            return sections.flatMap { section in
                section.rows.map { (Self.context(of: section), $0) }
            } + others.map { (RowContext(section: nil, queue: nil, baseBranch: nil, requiredChecks: []), $0) }
        }
    }

    private static func context(of section: Section) -> RowContext {
        RowContext(section: section.id, queue: section.queue, baseBranch: section.baseBranch, requiredChecks: section.requiredChecks)
    }

    /// What the sections' headers show: the sections without their rows
    /// and queues. Nil without sections.
    private static func sectionHeaders(_ body: Body) -> [Section]? {
        guard case .sections(let sections, _) = body else { return nil }
        return sections.map { section in
            var header = section
            header.rows = []
            header.queue = nil
            return header
        }
    }

    /// When the rows differ only in their agents' states, and those don't
    /// change any button, updates the Agent labels where they are.
    private func updateAgentsInPlace(from previous: Content?) -> Bool {
        guard let previous, let content,
              Self.sectionHeaders(previous.body) == Self.sectionHeaders(content.body),
              let old = Self.placedRows(previous), let new = Self.placedRows(content),
              old.count == new.count
        else { return false }
        // A queue change that leaves every cell as it was (its status, a
        // sheet opening) only touches the queue line.
        let cell = { (placed: (context: RowContext, row: ProjectBoard.Row)) in
            placed.context.queue.flatMap {
                Self.queueCell(for: placed.row, queue: $0, baseBranch: placed.context.baseBranch, section: placed.context.section)
            }
        }
        for (before, after) in zip(old, new) {
            var lhs = before.row
            var rhs = after.row
            lhs.agent.state = .none
            rhs.agent.state = .none
            guard lhs == rhs, before.context.section == after.context.section,
                  before.context.baseBranch == after.context.baseBranch,
                  before.context.requiredChecks == after.context.requiredChecks,
                  Self.actionSignature(before.row) == Self.actionSignature(after.row),
                  cell(before) == cell(after)
            else { return false }
        }
        for index in rowViews.indices {
            let shown = rowViews[index]
            guard let position = old.firstIndex(where: { $0.row == shown.row && $0.context.section == shown.section }) else {
                return false
            }
            let row = new[position].row
            rowViews[index].row = row
            rowViews[index].agent.stringValue = row.agent.state.label
            rowViews[index].agent.textColor = Self.color(for: row.agent.state)
            rowViews[index].agent.toolTip = row.agent.state.detail
        }
        return true
    }

    private static func actionSignature(_ row: ProjectBoard.Row) -> [String] {
        actions(for: row).map { "\($0.title)|\(String(describing: $0.action))|\($0.tooltip ?? "")" }
            + [String(describing: focusAction(for: row))]
    }

    /// The column header: the repository (or the project, without one),
    /// the post-merge run or what went wrong, Refresh with when the board
    /// last read GitHub.
    private func applyHeader(_ content: Header) {
        let projectName = content.projectIsMissing ? "Deleted space" : content.projectName
        header.context = content.repository ?? projectName
        header.titleToolTip = "Board · \(projectName)"
        if content.statusIsError, let message = content.status {
            header.status = ColumnHeaderView.Status(
                content.errorTitle, tone: .error, symbol: Theme.Symbol.agentError, toolTip: message
            )
        } else {
            header.status = content.postMergeRun
        }
        refreshButton.toolTip = ["Refresh", content.statusIsError ? nil : content.status].compactMap { $0 }
            .joined(separator: " · ")
    }

    /// The ⋯ menu: the board's project, Board Settings, then the column's
    /// items. Built as it opens: a read landing meanwhile can't change it.
    private func headerMenu() -> NSMenu {
        let menu = NSMenu()
        let projectItem = menu.addItem(withTitle: "Space", action: nil, keyEquivalent: "")
        projectItem.submenu = projectMenu()
        menu.addItem(withTitle: "Board Settings…", action: #selector(settingsClicked), keyEquivalent: "").target = self
        menu.addItem(.separator())
        ColumnHeaderView.columnMenuItems().forEach(menu.addItem)
        return menu
    }

    /// The projects, the board's own checked; a deleted one first, checked.
    func projectMenu() -> NSMenu {
        let menu = NSMenu(title: "Space")
        guard let content = content?.header else { return menu }
        if content.projectIsMissing {
            let deleted = menu.addItem(withTitle: "Deleted space", action: nil, keyEquivalent: "")
            deleted.state = .on
        }
        for project in content.projects {
            let item = menu.addItem(withTitle: project.name, action: #selector(projectChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = project.id
            item.state = !content.projectIsMissing && project.id == content.projectID ? .on : .off
        }
        return menu
    }

    private func buildBody() {
        for view in documentView.subviews where view !== messageLabel && view !== messageSettingsButton {
            view.removeFromSuperview()
        }
        rowViews = []
        bodyItems = []
        otherWorktreesToggle = nil
        guard let content else { return }
        switch content.body {
        case .message:
            return
        case .rows(let rows):
            addRows(rows, context: RowContext(
                section: nil, queue: content.queue, baseBranch: content.baseBranch, requiredChecks: content.requiredChecks
            ))
        case .sections(let sections, let others):
            for section in sections {
                let header = SectionHeaderView(section)
                documentView.addSubview(header)
                bodyItems.append(.sectionHeader(header))
                addRows(section.rows, context: Self.context(of: section))
            }
            addRows(others, context: RowContext(section: nil, queue: nil, baseBranch: nil, requiredChecks: []))
        }
    }

    /// The main working tree and the active rows, the folded "Other
    /// worktrees", then the workspaces outside the repository.
    private func addRows(_ rows: [ProjectBoard.Row], context: RowContext) {
        for row in rows where row.group == .main || row.group == .active { appendRow(row, context: context) }
        let others = rows.filter { $0.group == .otherWorktree }
        if !others.isEmpty {
            let key = context.section ?? ""
            let isExpanded = expandedOtherWorktrees.contains(key)
            let toggle = NSButton(title: "", target: self, action: #selector(toggleOtherWorktrees(_:)))
            toggle.identifier = NSUserInterfaceItemIdentifier(key)
            toggle.isBordered = false
            toggle.alignment = .left
            toggle.attributedTitle = NSAttributedString(
                string: "\(isExpanded ? "▾" : "▸") Other worktrees (\(others.count))",
                attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: Self.secondaryText]
            )
            documentView.addSubview(toggle)
            bodyItems.append(.toggle(toggle))
            if otherWorktreesToggle == nil { otherWorktreesToggle = toggle }
            if isExpanded { others.forEach { appendRow($0, context: context) } }
        }
        let foreign = rows.filter { $0.group == .otherRepository }
        if !foreign.isEmpty {
            let title = NSTextField(labelWithString: "Other workspaces")
            title.font = .systemFont(ofSize: 11, weight: .semibold)
            title.textColor = Self.secondaryText
            documentView.addSubview(title)
            bodyItems.append(.title(title))
            foreign.forEach { appendRow($0, context: context) }
        }
    }

    private func appendRow(_ row: ProjectBoard.Row, context: RowContext) {
        rowViews.append(makeRow(row, context: context))
        bodyItems.append(.row(rowViews.count - 1))
    }

    private func makeRow(_ row: ProjectBoard.Row, context: RowContext) -> RowViews {
        let name: NSView
        let title = NSMutableAttributedString(string: row.name, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: Self.primaryText
        ])
        if row.workspaces.count > 1 {
            title.append(NSAttributedString(string: " +\(row.workspaces.count - 1)", attributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: Self.secondaryText
            ]))
        }
        if let focus = Self.focusAction(for: row) {
            let button = ActionButton(title: "", target: self, action: #selector(actionClicked(_:)))
            button.isBordered = false
            button.alignment = .left
            button.attributedTitle = title
            button.boardAction = focus
            button.toolTip = "Focus \(row.workspaces.map(\.title).joined(separator: ", "))"
            (button.cell as? NSButtonCell)?.lineBreakMode = .byTruncatingTail
            name = button
        } else {
            let label = NSTextField(labelWithAttributedString: title)
            label.lineBreakMode = .byTruncatingTail
            name = label
        }
        let subtitle = label(Self.subtitle(for: row), color: Self.secondaryText, size: 10)
        subtitle.toolTip = row.worktreePath ?? row.folder
        let agent = label(row.agent.state.label, color: Self.color(for: row.agent.state), size: 11)
        agent.toolTip = row.agent.state.detail
        let pullRequest = label("", color: Self.primaryText, size: 11)
        let checks = label("", color: Self.secondaryText, size: 11)
        if row.group != .otherRepository, let pr = row.pullRequest {
            pullRequest.stringValue = ProjectBoard.pullRequestText(pr, baseBranch: context.baseBranch, stack: row.stack)
            pullRequest.textColor = pr.isConflicting ? Self.failureColor : (pr.isOpen ? Self.primaryText : Self.secondaryText)
            pullRequest.toolTip = row.stack.map { "\($0.tooltip)\n\(pr.url)" } ?? pr.url
            if pr.isOpen {
                let summary = ProjectBoard.checkSummary(pr.checks, required: context.requiredChecks)
                checks.stringValue = summary.text
                checks.textColor = Self.color(for: summary.worst)
                checks.toolTip = pr.checks.map { "\($0.qualifiedName ?? $0.name): \(ProjectBoard.glyph($0.result))" }
                    .joined(separator: "\n")
            }
        }
        let queue = label("", color: Self.secondaryText, size: 11)
        let queueDetail = label("", color: Self.secondaryText, size: 10)
        var queueButton: ActionButton?
        if let cell = context.queue.flatMap({
            Self.queueCell(for: row, queue: $0, baseBranch: context.baseBranch, section: context.section)
        }) {
            queue.stringValue = cell.text
            queue.textColor = Self.color(for: cell.tone)
            queue.toolTip = cell.tooltip ?? cell.text
            queueDetail.stringValue = cell.detail ?? ""
            queueDetail.textColor = Self.color(for: cell.detailTone)
            queueDetail.toolTip = cell.tooltip
            if let button = cell.button {
                let control = ActionButton(title: button.title, target: self, action: #selector(actionClicked(_:)))
                control.bezelStyle = .rounded
                control.controlSize = .small
                control.font = .systemFont(ofSize: 10, weight: .medium)
                control.boardAction = cell.action
                control.isEnabled = button.isEnabled && cell.action != nil
                control.toolTip = button.tooltip
                control.setAccessibilityLabel(button.tooltip ?? button.title)
                queueButton = control
            }
        }
        let actions = Self.actions(for: row).map { item -> ActionButton in
            let button = ActionButton(title: item.title, target: self, action: #selector(actionClicked(_:)))
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: 10, weight: .medium)
            button.boardAction = item.action
            button.isEnabled = item.action != nil
            button.toolTip = item.tooltip
            return button
        }
        let container = FlippedView()
        for view in [name, subtitle, agent, pullRequest, checks, queue, queueDetail] + (queueButton.map { [$0] } ?? []) + actions {
            container.addSubview(view)
        }
        documentView.addSubview(container)
        return RowViews(
            row: row, section: context.section, name: name, subtitle: subtitle, agent: agent, pullRequest: pullRequest, checks: checks, queue: queue,
            queueDetail: queueDetail, queueButton: queueButton, actions: actions
        )
    }

    private func label(_ text: String, color: NSColor, size: CGFloat) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size)
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    // MARK: - Row contents

    /// "feat/login · ~/Projects/app.feat-login".
    nonisolated static func subtitle(for row: ProjectBoard.Row) -> String {
        var parts: [String] = []
        if row.group == .main { parts.append("main checkout") }
        if let branch = row.branch, row.name != branch { parts.append(branch) }
        if let path = row.worktreePath ?? row.folder { parts.append(path.abbreviatedPath(maxComponents: 2)) }
        if row.folderIsGone { parts.append("folder is gone") }
        // A detached worktree may hold the branch mid-rebase: not "no local worktree".
        if row.worktreePath == nil, row.folder == nil { parts.append("not checked out") }
        if !row.workspaces.isEmpty, row.workspaces.allSatisfy(\.isInactive) { parts.append("archived") }
        return parts.joined(separator: " · ")
    }

    /// Focus goes to the row's most urgent agent column, else its first workspace.
    nonisolated static func focusAction(for row: ProjectBoard.Row) -> Action? {
        if let workspaceID = row.agent.workspaceID, row.agent.state != .none {
            return .focus(workspaceID: workspaceID, columnID: row.agent.columnID)
        }
        return row.workspaces.first.map { .focus(workspaceID: $0.id, columnID: nil) }
    }

    /// The row's buttons, most urgent first: those that don't fit a narrow
    /// column are left out from the end. A nil action is shown disabled,
    /// with why.
    nonisolated static func actions(for row: ProjectBoard.Row) -> [(title: String, action: Action?, tooltip: String?)] {
        var actions: [(title: String, action: Action?, tooltip: String?)] = []
        if let workspaceID = row.agent.workspaceID, let columnID = row.agent.columnID {
            switch row.agent.state {
            case .stoppedOnError(_, let resume):
                let action = resume == .offered ? row.agent.failedAt.map {
                    Action.resumeFailed(workspaceID: workspaceID, columnID: columnID, failedAt: $0)
                } : nil
                actions.append(("Resume", action, resume.status ?? "Send “continue” to the agent"))
            case .exitedMidTurn(let processName) where processName == "claude":
                actions.append(("Resume", .resumeExited(workspaceID: workspaceID, columnID: columnID),
                                "Reopen the conversation that ended mid-turn"))
            default:
                break
            }
        }
        if let focus = focusAction(for: row) { actions.append(("Focus", focus, nil)) }
        if row.workspaces.isEmpty, let path = row.worktreePath {
            actions.append(("Open", .open(path: path, title: row.branch ?? (path as NSString).lastPathComponent), nil))
        }
        if row.canCleanUp, let path = row.worktreePath ?? row.folder {
            actions.append(("Clean Up…", .cleanUp(path: path), "Check the worktree, then confirm what goes"))
        }
        return actions
    }

    private static func color(for state: ProjectBoard.AgentState) -> NSColor {
        switch state {
        case .none, .idle: return secondaryText
        case .working: return workingColor
        case .waiting, .waitingLong: return waitingColor
        case .stoppedOnError, .exitedMidTurn: return failureColor
        }
    }

    // MARK: - The merge queue

    /// While a queue runs (here or in another Nirux): the pull request's
    /// place and step. Otherwise: queued, with Remove; Add to Queue; or
    /// why it can't join. A stop of the last queue shows after it.
    nonisolated static func queueCell(
        for row: ProjectBoard.Row, queue: ProjectBoard.QueueState, baseBranch: String?, section: String? = nil
    ) -> QueueCell? {
        guard row.group != .otherRepository, let pullRequest = row.pullRequest, pullRequest.isFromConfiguredRepository
        else { return nil }
        let number = pullRequest.number
        let entryIndex = queue.entries.firstIndex { $0.number == number }
        let entry = entryIndex.map { queue.entries[$0] }
        if queue.isLocked, let entry, let entryIndex {
            let step = ProjectBoard.queueStepLabel(entry.step, workflow: queue.workflow)
            var cell = QueueCell(text: step)
            switch entry.step {
            case .done: cell.tone = .success
            case .stopped(let reason):
                cell.tone = reason.isProblem ? .failure : .normal
                cell.tooltip = reason.message
            case .waiting: cell.text = "\(entryIndex + 1) of \(queue.entries.count) · \(step)"
            default:
                cell.text = "\(entryIndex + 1) of \(queue.entries.count) · \(step)"
                cell.tone = .active
            }
            return cell
        }
        // The sheet shows the list as it was when it opened.
        let isFrozen = queue.isLocked || queue.isConfirming
        let locked = queue.run == .elsewhere
            ? "Another Nirux runs this repository’s queue: wait until it ends."
            : queue.isLocked ? "The queue is running: change the list once it stops."
            : "The confirmation sheet is open: change the list once it closes."
        // What the last queue did with it, under its place in the next one.
        var last: String?
        var lastReason: String?
        var lastIsFailure = false
        if !queue.isLocked, let entry {
            switch entry.step {
            case .done: return QueueCell(text: "merged ✓", tone: .success)
            case .stopped(let reason):
                last = ProjectBoard.queueStopLabel(reason, workflow: queue.workflow)
                lastReason = reason.message
                lastIsFailure = reason.isProblem
            default: break
            }
        }
        if let position = queue.selection.firstIndex(of: number) {
            var cell = QueueCell(text: "queued · \(position + 1)", detail: last.map { "last: \($0)" },
                                 detailTone: lastIsFailure ? .failure : .normal)
            cell.tooltip = lastReason.map { "Last queue: \($0)" }
            // ✕: the column is narrow, and its place must stay readable.
            cell.button = QueueButton(title: "✕", isEnabled: !isFrozen,
                                      tooltip: isFrozen ? locked : "Remove #\(number) from the queue")
            cell.action = .removeFromQueue(number: number, section: section)
            return cell
        }
        guard pullRequest.isOpen else { return nil }
        if let refusal = ProjectBoard.queueRefusal(row, baseBranch: baseBranch) {
            if let merged = row.stack?.mergedBase {
                return retargetCell(number: number, merged: merged, refusal: refusal, queue: queue, section: section)
            }
            return QueueCell(text: refusal, detail: last.map { "last: \($0)" }, detailTone: lastIsFailure ? .failure : .normal,
                             tooltip: lastReason.map { "Can’t join the queue: \(refusal). Last queue: \($0)" }
                                ?? "Can’t join the queue: \(refusal)")
        }
        var cell = QueueCell(text: "", detail: last.map { "last: \($0)" }, detailTone: lastIsFailure ? .failure : .normal,
                             tooltip: lastReason.map { "Last queue: \($0)" })
        cell.button = QueueButton(title: "Add to Queue", isEnabled: !isFrozen,
                                  tooltip: isFrozen ? locked : "Propose #\(number) at the next Start")
        cell.action = .addToQueue(number: number, section: section)
        return cell
    }

    /// A pull request based on a merged branch can't join until it is
    /// based on that branch's base (docs/design/pr-stacks.md): the button says
    /// so, under why it can't join yet. A dry run doesn't change GitHub.
    private nonisolated static func retargetCell(
        number: Int, merged: ProjectBoard.MergedBase, refusal: String, queue: ProjectBoard.QueueState, section: String?
    ) -> QueueCell {
        var cell = QueueCell(text: "", detail: refusal, tooltip: "Can’t join the queue: \(refusal)")
        cell.button = QueueButton(
            title: "Retarget to \(merged.onto)", isEnabled: !queue.isDryRun,
            tooltip: queue.isDryRun
                ? "Dry run: this build doesn’t change GitHub." + (queue.dryRunReason.map { "\nThis build: \($0)." } ?? "")
                : "#\(merged.number) is merged: base #\(number) on \(merged.onto), as GitHub does when a merged branch is deleted"
        )
        cell.action = .retarget(number: number, base: merged.onto, section: section)
        return cell
    }

    /// The post-merge run as the header's pill: "nightly 09:42", a green
    /// check once it passed, red when it failed, grey while it runs; the
    /// whole summary in its tooltip.
    nonisolated static func runStatus(
        _ run: ProjectBoard.WorkflowRun?, workflow: String, now: Date, timeZone: TimeZone = .current
    ) -> ColumnHeaderView.Status {
        let label = (workflow as NSString).deletingPathExtension
        let summary = ProjectBoard.runSummary(run, workflow: workflow, now: now, timeZone: timeZone)
        guard let run else { return ColumnHeaderView.Status("\(label): no run yet", tone: .neutral, toolTip: summary) }
        let completed = run.status == "completed"
        let date = completed ? (run.updatedAt ?? run.createdAt) : (run.createdAt ?? run.updatedAt)
        let time = date.map { ProjectBoard.clockTime($0, now: now, timeZone: timeZone) }
        let text = { (outcome: String?) in [label, outcome, time].compactMap { $0 }.joined(separator: " ") }
        guard completed else {
            return ColumnHeaderView.Status(text(nil), tone: .neutral, symbol: Theme.Symbol.checksRunning, toolTip: summary)
        }
        switch run.conclusion {
        case "success":
            return ColumnHeaderView.Status(
                text(nil), tone: .neutral, symbol: Theme.Symbol.checksPassed, symbolTone: .success, toolTip: summary
            )
        case "failure", "timed_out", "startup_failure":
            return ColumnHeaderView.Status(text(nil), tone: .error, symbol: Theme.Symbol.checksFailed, toolTip: summary)
        default:
            // Cancelled, skipped…: said in words, without a color.
            return ColumnHeaderView.Status(text(run.conclusion ?? "completed"), tone: .neutral, toolTip: summary)
        }
    }

    /// The header's queue line.
    nonisolated static func queueHeader(_ queue: ProjectBoard.QueueState) -> QueueHeader {
        var header = QueueHeader(text: "", isDryRun: queue.isDryRun, dryRunReason: queue.dryRunReason)
        let count = queue.selection.count
        let queued = "\(count) pull request\(count == 1 ? "" : "s") queued"
        switch queue.run {
        case .running(let isStopping):
            header.text = "Queue: " + (queue.status ?? "running")
            header.tone = .active
            header.stop = QueueButton(title: isStopping ? "Stopping…" : "Stop", isEnabled: !isStopping,
                                      tooltip: "Stop before the next command; a call already sent to GitHub finishes")
            return header
        case .elsewhere:
            header.text = "Queue: running in another Nirux, read-only here" + (queue.status.map { " · \($0)" } ?? "")
            header.tone = .active
            header.start = QueueButton(title: startTitle(queue), isEnabled: false,
                                       tooltip: "Another Nirux runs this repository’s queue: Start once it ends there.")
            return header
        case .ended:
            header.text = "Queue: " + (queue.status ?? "ended") + (count > 0 ? " · \(queued)" : "")
            header.tone = queue.statusIsFailure ? .failure : .normal
        case .none:
            header.text = count > 0 ? "Queue: \(queued)" : "Queue: add pull requests with Add to Queue, then Start"
        }
        var start = QueueButton(title: startTitle(queue))
        if !queue.startProblems.isEmpty {
            start.isEnabled = false
            start.tooltip = queue.startProblems.joined(separator: "\n")
        } else if count == 0 {
            start.isEnabled = false
            start.tooltip = "Add pull requests to the queue first."
        } else if queue.isConfirming {
            start.isEnabled = false
            start.tooltip = "The confirmation sheet is open."
        } else {
            start.tooltip = "Read the queued pull requests on GitHub, then confirm what the queue will do"
        }
        header.start = start
        return header
    }

    private nonisolated static func startTitle(_ queue: ProjectBoard.QueueState) -> String {
        queue.isDryRun ? "Start Dry Run…" : "Start…"
    }

    private func applyQueueHeader(_ header: QueueHeader?) {
        queueLabel.isHidden = header == nil
        apply(header, label: queueLabel, badge: dryRunBadge, start: startQueueButton, stop: stopQueueButton)
    }

    private func apply(_ header: QueueHeader?, label: NSTextField, badge: NSTextField, start: NSButton, stop: NSButton) {
        badge.isHidden = header?.isDryRun != true
        badge.toolTip = Self.dryRunTooltip(reason: header?.dryRunReason)
        label.stringValue = header?.text ?? ""
        label.toolTip = header?.text
        label.textColor = Self.color(for: header?.tone ?? .normal)
        for (button, state) in [(start, header?.start), (stop, header?.stop)] {
            button.isHidden = state == nil
            button.title = state?.title ?? button.title
            button.isEnabled = state?.isEnabled ?? false
            button.toolTip = state?.tooltip
        }
    }

    /// One line per queue, named, on a board with several.
    private func applyQueueLines(_ lines: [QueueLine]) {
        if queueLines.map(\.section) != lines.map(\.id) {
            queueLines.forEach { $0.views.forEach { $0.removeFromSuperview() } }
            queueLines = lines.map(makeQueueLine)
        }
        for (views, line) in zip(queueLines, lines) {
            views.name.stringValue = line.title
            views.name.toolTip = line.tooltip ?? line.title
            apply(Self.queueHeader(line.queue), label: views.label, badge: views.badge,
                  start: views.startButton, stop: views.stopButton)
            // Start and Stop name the repository for VoiceOver.
            views.startButton.setAccessibilityLabel("\(views.startButton.title) \(line.title)")
            views.stopButton.setAccessibilityLabel("\(views.stopButton.title) \(line.title)")
        }
    }

    /// One line per notice, in red for an error.
    private func applyNotices(_ notices: [Notice]) {
        if noticeLines.count != notices.count {
            noticeLines.forEach { [$0.label, $0.settingsButton].forEach { $0.removeFromSuperview() } }
            noticeLines = notices.map { _ in makeNoticeLine() }
        }
        for (views, notice) in zip(noticeLines, notices) {
            views.label.stringValue = notice.text
            views.label.toolTip = notice.text
            views.label.textColor = notice.isError ? Self.failureColor : Self.secondaryText
            views.settingsButton.isHidden = !notice.offersSettings
            views.section = notice.settingsSection
        }
    }

    private func makeNoticeLine() -> NoticeLineViews {
        let line = NoticeLineViews()
        line.label.font = .systemFont(ofSize: 11)
        line.label.lineBreakMode = .byTruncatingTail
        line.settingsButton.bezelStyle = .rounded
        line.settingsButton.controlSize = .small
        line.settingsButton.font = .systemFont(ofSize: 11)
        line.settingsButton.target = self
        line.settingsButton.action = #selector(noticeSettingsClicked(_:))
        [line.label, line.settingsButton].forEach(addSubview)
        return line
    }

    private func makeQueueLine(_ shown: QueueLine) -> QueueLineViews {
        let line = QueueLineViews(section: shown.id)
        line.name.font = .systemFont(ofSize: 11, weight: .semibold)
        line.name.textColor = Self.primaryText
        line.name.lineBreakMode = .byTruncatingTail
        line.label.font = queueLabel.font
        line.label.lineBreakMode = .byTruncatingTail
        line.badge.font = dryRunBadge.font
        line.badge.textColor = .black
        line.badge.alignment = .center
        line.badge.drawsBackground = true
        line.badge.backgroundColor = Self.dryRunColor
        for (button, action) in [
            (line.startButton, #selector(lineStartClicked(_:))), (line.stopButton, #selector(lineStopClicked(_:)))
        ] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11)
            button.target = self
            button.action = action
        }
        line.views.forEach(addSubview)
        return line
    }

    /// Its name (on a board with several repositories), DRY RUN, the
    /// queue's status, then Start or Stop at the right, in a 24 pt line
    /// from `y`.
    private func layoutQueueLine(
        name: NSTextField?, badge: NSTextField, label: NSTextField, buttons: [NSButton], width: CGFloat, y: CGFloat
    ) {
        let pad = Self.padding
        var right = width - pad
        for button in buttons where !button.isHidden {
            let buttonWidth = ceil(button.intrinsicContentSize.width) + 8
            button.frame = NSRect(x: right - buttonWidth, y: y, width: buttonWidth, height: 24)
            right = button.frame.minX - 6
        }
        var x = pad
        if let name {
            let nameWidth = min(ceil(name.intrinsicContentSize.width), max(60, width * 0.22))
            name.frame = NSRect(x: x, y: y + 4, width: nameWidth, height: 16)
            x = name.frame.maxX + 8
        }
        if !badge.isHidden {
            badge.frame = NSRect(x: x, y: y + 4, width: 58, height: 15)
            x = badge.frame.maxX + 8
        }
        label.frame = NSRect(x: x, y: y + 4, width: max(0, right - x - 8), height: 16)
    }

    private static func color(for tone: QueueTone) -> NSColor {
        switch tone {
        case .normal: return secondaryText
        case .active: return primaryText
        case .success: return successColor
        case .failure: return failureColor
        }
    }

    private static func color(for result: ProjectBoard.CheckResult?) -> NSColor {
        switch result {
        case .failure?: return failureColor
        case .pending?: return pendingColor
        case .success?: return successColor
        case .neutral?, .skipped?, nil: return secondaryText
        }
    }

    // MARK: - Layout

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutContent()
    }

    /// The header, the queue's line when the board has one (one per
    /// repository on a board with several), the column titles; the rows
    /// scroll below.
    private func layoutContent() {
        let width = bounds.width
        header.frame = NSRect(x: 0, y: 0, width: width, height: ColumnHeaderView.height)
        var y = ColumnHeaderView.height
        for line in noticeLines {
            var right = width - Self.padding
            if !line.settingsButton.isHidden {
                let buttonWidth = ceil(line.settingsButton.intrinsicContentSize.width) + 8
                line.settingsButton.frame = NSRect(x: right - buttonWidth, y: y + 4, width: buttonWidth, height: 24)
                right = line.settingsButton.frame.minX - 8
            }
            line.label.frame = NSRect(x: Self.padding, y: y + 8, width: max(0, right - Self.padding), height: 16)
            y += 32
        }
        if !queueLabel.isHidden {
            layoutQueueLine(name: nil, badge: dryRunBadge, label: queueLabel, buttons: [stopQueueButton, startQueueButton],
                            width: width, y: y + 4)
            y += 32
        }
        for line in queueLines {
            layoutQueueLine(name: line.name, badge: line.badge, label: line.label,
                            buttons: [line.stopButton, line.startButton], width: width, y: y + 2)
            y += Self.queueLineHeight
        }
        if !queueLines.isEmpty { y += 4 }

        let columns = columnFrames(width: width)
        for (title, frame) in zip(columnTitles, columns) {
            title.frame = NSRect(x: frame.minX, y: y + 10, width: frame.width, height: 14)
        }
        y += 30
        separator.frame = NSRect(x: 0, y: y - 1, width: width, height: 1)
        scrollView.frame = NSRect(x: 0, y: y, width: width, height: max(0, bounds.height - y))
        layoutBody(width: width, columns: columns)
    }

    /// Each column's x and width.
    private func columnFrames(width: CGFloat) -> [(minX: CGFloat, width: CGFloat)] {
        let usable = max(0, width - 2 * Self.padding)
        var x = Self.padding
        return Self.columnFractions.map { fraction in
            defer { x += usable * fraction }
            return (x, usable * fraction - 6)
        }
    }

    private func layoutBody(width: CGFloat, columns: [(minX: CGFloat, width: CGFloat)]) {
        let visibleHeight = scrollView.contentSize.height
        if case .message(let text)? = content?.body {
            messageLabel.isHidden = false
            messageLabel.stringValue = text
            let height = messageLabel.sizeThatFits(NSSize(width: width - 48, height: .greatestFiniteMagnitude)).height
            messageLabel.frame = NSRect(x: 24, y: 32, width: max(0, width - 48), height: height)
            var bottom = messageLabel.frame.maxY
            messageSettingsButton.isHidden = content?.messageOffersSettings != true
            if !messageSettingsButton.isHidden {
                let buttonWidth = ceil(messageSettingsButton.intrinsicContentSize.width) + 8
                messageSettingsButton.frame = NSRect(x: (width - buttonWidth) / 2, y: bottom + 12, width: buttonWidth, height: 24)
                bottom = messageSettingsButton.frame.maxY
            }
            documentView.frame = NSRect(x: 0, y: 0, width: width, height: max(visibleHeight, bottom + 32))
            return
        }
        messageLabel.isHidden = true
        messageSettingsButton.isHidden = true
        var y: CGFloat = 4
        for item in bodyItems {
            switch item {
            case .row(let index):
                layoutRow(rowViews[index], y: y, width: width, columns: columns)
                y += Self.rowHeight
            case .toggle(let toggle):
                toggle.frame = NSRect(x: Self.padding + 2, y: y + 6, width: 240, height: 18)
                y += Self.groupHeight
            case .title(let title):
                title.frame = NSRect(x: Self.padding, y: y + 8, width: 240, height: 16)
                y += Self.groupHeight
            case .sectionHeader(let header):
                header.frame = NSRect(x: 0, y: y, width: width, height: Self.sectionHeaderHeight)
                y += Self.sectionHeaderHeight
            }
        }
        documentView.frame = NSRect(x: 0, y: 0, width: width, height: max(visibleHeight, y + 8))
    }

    private func layoutRow(_ views: RowViews, y: CGFloat, width: CGFloat, columns: [(minX: CGFloat, width: CGFloat)]) {
        guard let container = views.name.superview else { return }
        container.frame = NSRect(x: 0, y: y, width: width, height: Self.rowHeight)
        // A button draws its title at its edge, a label 2 points in.
        let nameX = views.name is NSButton ? columns[0].minX + 2 : columns[0].minX
        views.name.frame = NSRect(x: nameX, y: 4, width: columns[0].width - 2, height: 18)
        views.subtitle.frame = NSRect(x: columns[0].minX, y: 22, width: columns[0].width, height: 14)
        views.agent.frame = NSRect(x: columns[1].minX, y: 13, width: columns[1].width, height: 16)
        views.pullRequest.frame = NSRect(x: columns[2].minX, y: 13, width: columns[2].width, height: 16)
        views.checks.frame = NSRect(x: columns[3].minX, y: 13, width: columns[3].width, height: 16)
        // The place (or the button alone) on the first line, the last
        // queue's word under it, like the name and its subtitle.
        let hasDetail = !views.queueDetail.stringValue.isEmpty
        var queueTextWidth = columns[4].width
        if let button = views.queueButton {
            let buttonWidth = min(ceil(button.intrinsicContentSize.width), columns[4].width)
            let isAlone = views.queue.stringValue.isEmpty
            button.frame = NSRect(
                x: isAlone ? columns[4].minX : columns[4].minX + columns[4].width - buttonWidth,
                y: isAlone && hasDetail ? 2 : 11, width: buttonWidth, height: 20
            )
            queueTextWidth = isAlone ? 0 : max(0, columns[4].width - buttonWidth - 4)
        }
        views.queue.frame = NSRect(x: columns[4].minX, y: hasDetail ? 4 : 13, width: queueTextWidth, height: hasDetail ? 18 : 16)
        let detailWidth = views.queue.stringValue.isEmpty ? columns[4].width : queueTextWidth
        views.queueDetail.frame = NSRect(x: columns[4].minX, y: 22, width: hasDetail ? detailWidth : 0, height: 14)
        var x = columns[5].minX
        let limit = width - Self.padding
        for button in views.actions {
            let buttonWidth = ceil(button.intrinsicContentSize.width)
            button.isHidden = x + buttonWidth > limit
            button.frame = NSRect(x: x, y: 11, width: buttonWidth, height: 20)
            x += buttonWidth + 4
        }
    }

    // MARK: - Buttons

    @objc private func refreshClicked() { onRefresh?() }

    @objc private func startQueueClicked() { onStartQueue?(nil) }

    @objc private func stopQueueClicked() { onStopQueue?(nil) }

    @objc private func lineStartClicked(_ sender: NSButton) {
        guard let line = queueLines.first(where: { $0.startButton === sender }) else { return }
        onStartQueue?(line.section)
    }

    @objc private func lineStopClicked(_ sender: NSButton) {
        guard let line = queueLines.first(where: { $0.stopButton === sender }) else { return }
        onStopQueue?(line.section)
    }

    @objc private func settingsClicked() { onBoardSettings?(nil) }

    @objc private func noticeSettingsClicked(_ sender: NSButton) {
        guard let line = noticeLines.first(where: { $0.settingsButton === sender }) else { return }
        onBoardSettings?(line.section)
    }

    @objc private func projectChosen(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        onSelectProject?(id)
    }

    @objc private func actionClicked(_ sender: ActionButton) {
        guard let action = sender.boardAction else { return }
        onAction?(action)
    }

    @objc private func toggleOtherWorktrees(_ sender: NSButton) {
        let key = sender.identifier?.rawValue ?? ""
        if expandedOtherWorktrees.remove(key) == nil { expandedOtherWorktrees.insert(key) }
        buildBody()
        layoutContent()
    }

    /// Picks the project as the menu would.
    func chooseProject(id: String) {
        guard let item = projectMenu().items.first(where: { $0.representedObject as? String == id }) else { return }
        projectChosen(item)
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// A repository's header on a board with several: its name, `owner/name`
/// (or why it has none), and its post-merge run's pill at the right.
@MainActor
final class SectionHeaderView: NSView {
    let section: ProjectBoardView.Section
    let titleLabel = NSTextField(labelWithString: "")
    let detailLabel = NSTextField(labelWithString: "")
    let pill = ColumnStatusPill()

    init(_ section: ProjectBoardView.Section) {
        self.section = section
        super.init(frame: .zero)
        titleLabel.stringValue = section.title
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = NSColor.white.withAlphaComponent(0.85)
        titleLabel.lineBreakMode = .byTruncatingTail
        // Its repository, and why it has no saved one: read-only, say.
        detailLabel.stringValue = [section.repository, section.note].compactMap { $0 }.joined(separator: " · ")
        detailLabel.toolTip = section.note ?? section.repository
        detailLabel.font = section.note != nil ? .systemFont(ofSize: 11) : .monospacedSystemFont(ofSize: 11, weight: .regular)
        detailLabel.textColor = NSColor.white.withAlphaComponent(0.45)
        detailLabel.lineBreakMode = .byTruncatingTail
        pill.status = section.status
        pill.isHidden = section.status == nil
        [titleLabel, detailLabel, pill].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let pad: CGFloat = 12
        var right = bounds.width - pad
        if !pill.isHidden {
            let width = min(pill.idealWidth, bounds.width * 0.4)
            pill.frame = NSRect(x: right - width, y: 12, width: width, height: ColumnStatusPill.height)
            right = pill.frame.minX - 8
        }
        let titleWidth = min(ceil(titleLabel.intrinsicContentSize.width), max(0, (right - pad) * 0.5))
        titleLabel.frame = NSRect(x: pad, y: 13, width: titleWidth, height: 16)
        let detailX = titleLabel.frame.maxX + 8
        detailLabel.frame = NSRect(x: detailX, y: 14, width: max(0, right - detailX), height: 15)
    }
}
