import AppKit

/// The Project Board column's content (docs/project-board.md, sections 1
/// and 2): the column header (its repository, the last post-merge run or
/// what went wrong, Refresh, and the project and Board Settings in its ⋯
/// menu), the merge queue's line, then one row per branch.
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

    enum Body: Equatable {
        case message(String)
        case rows([ProjectBoard.Row])
    }

    struct Content: Equatable {
        var header: Header
        var body: Body
        /// The configured checks, shown by name.
        var requiredChecks: [String] = []
        /// The configured base branch: another one is named in the PR column.
        var baseBranch: String?
        /// The project's merge queue; nil while the board can't show one
        /// (no repository, a deleted project).
        var queue: ProjectBoard.QueueState?
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
        case addToQueue(number: Int)
        case removeFromQueue(number: Int)
        /// Its base's pull request merged: base it on that one's base.
        case retarget(number: Int, base: String)
    }

    /// A button of a row, with what it does.
    final class ActionButton: NSButton {
        var boardAction: Action?
    }

    /// One row as drawn, for the shell's tests to click through.
    struct RowViews {
        fileprivate(set) var row: ProjectBoard.Row
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

    var onRefresh: (() -> Void)?
    var onStartQueue: (() -> Void)?
    var onStopQueue: (() -> Void)?
    var onSelectProject: ((String) -> Void)?
    var onBoardSettings: (() -> Void)?
    var onAction: ((Action) -> Void)?

    private(set) var content: Content?
    /// "Other worktrees" starts folded, each time the board opens.
    private(set) var isOtherWorktreesExpanded = false
    private(set) var rowViews: [RowViews] = []
    private(set) var otherWorktreesToggle: NSButton?
    private var otherRepositoriesTitle: NSTextField?

    let header = ColumnHeaderView()
    let refreshButton = ColumnHeaderButton(symbol: Theme.Symbol.reload, toolTip: "Refresh")
    /// "DRY RUN" while this build can't change GitHub.
    let dryRunBadge = NSTextField(labelWithString: "DRY RUN")
    let queueLabel = NSTextField(labelWithString: "")
    let startQueueButton = NSButton(title: "Start…", target: nil, action: nil)
    let stopQueueButton = NSButton(title: "Stop", target: nil, action: nil)
    let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let columnTitles = ["Name", "Agent", "PR", "Checks", "Queue", "Actions"].map { NSTextField(labelWithString: $0) }
    private let separator = NSView()
    private let scrollView = NSScrollView()
    private let documentView = FlippedView()

    private static let rowHeight: CGFloat = 42
    private static let groupHeight: CGFloat = 28
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
        header.title = "Project Board"
        refreshButton.target = self
        refreshButton.action = #selector(refreshClicked)
        header.trailingButtons = [refreshButton]
        header.menuProvider = { [weak self] in self?.headerMenu() ?? NSMenu() }
        for (button, action) in [
            (startQueueButton, #selector(startQueueClicked)), (stopQueueButton, #selector(stopQueueClicked))
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
        applyQueueHeader(content.queue.map(Self.queueHeader))
        if content.body != previous?.body || content.requiredChecks != previous?.requiredChecks
            || content.baseBranch != previous?.baseBranch || content.queue != previous?.queue {
            if !updateAgentsInPlace(from: previous) { buildBody() }
        }
        layoutContent()
    }

    /// When the rows differ only in their agents' states, and those don't
    /// change any button, updates the Agent labels where they are.
    private func updateAgentsInPlace(from previous: Content?) -> Bool {
        guard let previous, let content,
              previous.requiredChecks == content.requiredChecks, previous.baseBranch == content.baseBranch,
              case .rows(let old) = previous.body, case .rows(let new) = content.body,
              old.count == new.count
        else { return false }
        // A queue change that leaves every cell as it was (its status, a
        // sheet opening) only touches the header.
        let cell = { (row: ProjectBoard.Row, queue: ProjectBoard.QueueState?) in
            queue.flatMap { Self.queueCell(for: row, queue: $0, baseBranch: content.baseBranch) }
        }
        for (before, after) in zip(old, new) {
            var lhs = before
            var rhs = after
            lhs.agent.state = .none
            rhs.agent.state = .none
            guard lhs == rhs, Self.actionSignature(before) == Self.actionSignature(after),
                  cell(before, previous.queue) == cell(after, content.queue)
            else { return false }
        }
        for index in rowViews.indices {
            guard let position = old.firstIndex(of: rowViews[index].row) else { return false }
            let row = new[position]
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
        let projectName = content.projectIsMissing ? "Deleted project" : content.projectName
        header.context = content.repository ?? projectName
        header.titleToolTip = "Project Board · \(projectName)"
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
        let projectItem = menu.addItem(withTitle: "Project", action: nil, keyEquivalent: "")
        projectItem.submenu = projectMenu()
        menu.addItem(withTitle: "Board Settings…", action: #selector(settingsClicked), keyEquivalent: "").target = self
        menu.addItem(.separator())
        ColumnHeaderView.columnMenuItems().forEach(menu.addItem)
        return menu
    }

    /// The projects, the board's own checked; a deleted one first, checked.
    func projectMenu() -> NSMenu {
        let menu = NSMenu(title: "Project")
        guard let content = content?.header else { return menu }
        if content.projectIsMissing {
            let deleted = menu.addItem(withTitle: "Deleted project", action: nil, keyEquivalent: "")
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
        for view in documentView.subviews where view !== messageLabel { view.removeFromSuperview() }
        rowViews = []
        otherWorktreesToggle = nil
        otherRepositoriesTitle = nil
        guard case .rows(let rows)? = content?.body else { return }
        var others = rows.filter { $0.group == .otherWorktree }
        if !isOtherWorktreesExpanded { others = [] }
        for row in rows where row.group == .main || row.group == .active { rowViews.append(makeRow(row)) }
        if rows.contains(where: { $0.group == .otherWorktree }) {
            let count = rows.filter { $0.group == .otherWorktree }.count
            let toggle = NSButton(title: "", target: self, action: #selector(toggleOtherWorktrees))
            toggle.isBordered = false
            toggle.alignment = .left
            toggle.attributedTitle = NSAttributedString(
                string: "\(isOtherWorktreesExpanded ? "▾" : "▸") Other worktrees (\(count))",
                attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: Self.secondaryText]
            )
            documentView.addSubview(toggle)
            otherWorktreesToggle = toggle
        }
        for row in others { rowViews.append(makeRow(row)) }
        if rows.contains(where: { $0.group == .otherRepository }) {
            let title = NSTextField(labelWithString: "Other workspaces")
            title.font = .systemFont(ofSize: 11, weight: .semibold)
            title.textColor = Self.secondaryText
            documentView.addSubview(title)
            otherRepositoriesTitle = title
        }
        for row in rows where row.group == .otherRepository { rowViews.append(makeRow(row)) }
    }

    private func makeRow(_ row: ProjectBoard.Row) -> RowViews {
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
            pullRequest.stringValue = ProjectBoard.pullRequestText(pr, baseBranch: content?.baseBranch, stack: row.stack)
            pullRequest.textColor = pr.isConflicting ? Self.failureColor : (pr.isOpen ? Self.primaryText : Self.secondaryText)
            pullRequest.toolTip = row.stack.map { "\($0.tooltip)\n\(pr.url)" } ?? pr.url
            if pr.isOpen {
                let summary = ProjectBoard.checkSummary(pr.checks, required: content?.requiredChecks ?? [])
                checks.stringValue = summary.text
                checks.textColor = Self.color(for: summary.worst)
                checks.toolTip = pr.checks.map { "\($0.qualifiedName ?? $0.name): \(ProjectBoard.glyph($0.result))" }
                    .joined(separator: "\n")
            }
        }
        let queue = label("", color: Self.secondaryText, size: 11)
        let queueDetail = label("", color: Self.secondaryText, size: 10)
        var queueButton: ActionButton?
        if let cell = queueCell(for: row) {
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
            row: row, name: name, subtitle: subtitle, agent: agent, pullRequest: pullRequest, checks: checks, queue: queue,
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
        if !row.workspaces.isEmpty, row.workspaces.allSatisfy(\.isInactive) { parts.append("inactive") }
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

    /// The row's Queue cell, with the board's queue and base branch.
    private func queueCell(for row: ProjectBoard.Row) -> QueueCell? {
        guard let queue = content?.queue else { return nil }
        return Self.queueCell(for: row, queue: queue, baseBranch: content?.baseBranch)
    }

    /// While a queue runs (here or in another Nirux): the pull request's
    /// place and step. Otherwise: queued, with Remove; Add to Queue; or
    /// why it can't join. A stop of the last queue shows after it.
    nonisolated static func queueCell(
        for row: ProjectBoard.Row, queue: ProjectBoard.QueueState, baseBranch: String?
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
            ? "Another Nirux runs this project’s queue: wait until it ends."
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
            cell.action = .removeFromQueue(number: number)
            return cell
        }
        guard pullRequest.isOpen else { return nil }
        if let refusal = ProjectBoard.queueRefusal(row, baseBranch: baseBranch) {
            if let merged = row.stack?.mergedBase {
                return retargetCell(number: number, merged: merged, refusal: refusal, queue: queue)
            }
            return QueueCell(text: refusal, detail: last.map { "last: \($0)" }, detailTone: lastIsFailure ? .failure : .normal,
                             tooltip: lastReason.map { "Can’t join the queue: \(refusal). Last queue: \($0)" }
                                ?? "Can’t join the queue: \(refusal)")
        }
        var cell = QueueCell(text: "", detail: last.map { "last: \($0)" }, detailTone: lastIsFailure ? .failure : .normal,
                             tooltip: lastReason.map { "Last queue: \($0)" })
        cell.button = QueueButton(title: "Add to Queue", isEnabled: !isFrozen,
                                  tooltip: isFrozen ? locked : "Propose #\(number) at the next Start")
        cell.action = .addToQueue(number: number)
        return cell
    }

    /// A pull request based on a merged branch can't join until it is
    /// based on that branch's base (docs/pr-stacks.md): the button says
    /// so, under why it can't join yet. A dry run doesn't change GitHub.
    private nonisolated static func retargetCell(
        number: Int, merged: ProjectBoard.MergedBase, refusal: String, queue: ProjectBoard.QueueState
    ) -> QueueCell {
        var cell = QueueCell(text: "", detail: refusal, tooltip: "Can’t join the queue: \(refusal)")
        cell.button = QueueButton(
            title: "Retarget to \(merged.onto)", isEnabled: !queue.isDryRun,
            tooltip: queue.isDryRun
                ? "Dry run: this build doesn’t change GitHub." + (queue.dryRunReason.map { "\nThis build: \($0)." } ?? "")
                : "#\(merged.number) is merged: base #\(number) on \(merged.onto), as GitHub does when a merged branch is deleted"
        )
        cell.action = .retarget(number: number, base: merged.onto)
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
                                       tooltip: "Another Nirux runs this project’s queue: Start once it ends there.")
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
        dryRunBadge.isHidden = header?.isDryRun != true
        dryRunBadge.toolTip = Self.dryRunTooltip(reason: header?.dryRunReason)
        queueLabel.stringValue = header?.text ?? ""
        queueLabel.toolTip = header?.text
        queueLabel.textColor = Self.color(for: header?.tone ?? .normal)
        for (button, state) in [(startQueueButton, header?.start), (stopQueueButton, header?.stop)] {
            button.isHidden = state == nil
            button.title = state?.title ?? button.title
            button.isEnabled = state?.isEnabled ?? false
            button.toolTip = state?.tooltip
        }
    }

    /// DRY RUN, the queue's status, then Start or Stop at the right, in
    /// a 24 pt line from `y`.
    private func layoutQueueLine(width: CGFloat, y: CGFloat) {
        let pad = Self.padding
        var right = width - pad
        for button in [stopQueueButton, startQueueButton] where !button.isHidden {
            let buttonWidth = ceil(button.intrinsicContentSize.width) + 8
            button.frame = NSRect(x: right - buttonWidth, y: y, width: buttonWidth, height: 24)
            right = button.frame.minX - 6
        }
        var x = pad
        if !dryRunBadge.isHidden {
            dryRunBadge.frame = NSRect(x: x, y: y + 4, width: 58, height: 15)
            x = dryRunBadge.frame.maxX + 8
        }
        queueLabel.frame = NSRect(x: x, y: y + 4, width: max(0, right - x - 8), height: 16)
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

    /// The header, the queue's line when the board has one, the column
    /// titles; the rows scroll below.
    private func layoutContent() {
        let width = bounds.width
        header.frame = NSRect(x: 0, y: 0, width: width, height: ColumnHeaderView.height)
        var y = ColumnHeaderView.height
        if !queueLabel.isHidden {
            layoutQueueLine(width: width, y: y + 4)
            y += 32
        }

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
            documentView.frame = NSRect(x: 0, y: 0, width: width, height: max(visibleHeight, height + 64))
            return
        }
        messageLabel.isHidden = true
        var y: CGFloat = 4
        var didPlaceToggle = false
        var didPlaceOtherRepositories = false
        let placeToggle = {
            guard !didPlaceToggle, let toggle = self.otherWorktreesToggle else { return }
            toggle.frame = NSRect(x: Self.padding + 2, y: y + 6, width: 240, height: 18)
            y += Self.groupHeight
            didPlaceToggle = true
        }
        for views in rowViews {
            if views.row.group == .otherWorktree || views.row.group == .otherRepository { placeToggle() }
            if views.row.group == .otherRepository, !didPlaceOtherRepositories, let title = otherRepositoriesTitle {
                title.frame = NSRect(x: Self.padding, y: y + 8, width: 240, height: 16)
                y += Self.groupHeight
                didPlaceOtherRepositories = true
            }
            layoutRow(views, y: y, width: width, columns: columns)
            y += Self.rowHeight
        }
        placeToggle()
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

    @objc private func startQueueClicked() { onStartQueue?() }

    @objc private func stopQueueClicked() { onStopQueue?() }

    @objc private func settingsClicked() { onBoardSettings?() }

    @objc private func projectChosen(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        onSelectProject?(id)
    }

    @objc private func actionClicked(_ sender: ActionButton) {
        guard let action = sender.boardAction else { return }
        onAction?(action)
    }

    @objc private func toggleOtherWorktrees() {
        isOtherWorktreesExpanded.toggle()
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
