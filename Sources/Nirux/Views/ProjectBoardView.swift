import AppKit

/// The Project Board column's content (docs/project-board.md, sections 1
/// and 2): a header with the project, its repository, the last post-merge
/// run and the board's buttons, then one row per branch. It only draws:
/// `ProjectBoardController` fills it, the shell runs its buttons.
@MainActor
final class ProjectBoardView: NSView {
    struct Project: Equatable {
        let id: String
        let name: String
    }

    struct Header: Equatable {
        var projectName: String
        var repository: String?
        /// "nightly: success 20:27, 60e0ff2".
        var postMergeRun: String?
        /// When the pull requests were read, or why they weren't.
        var status: String?
        var statusIsError = false
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
    }

    enum Action: Equatable {
        case focus(workspaceID: String, columnID: UUID?)
        case open(path: String, title: String)
        case cleanUp(path: String)
        case resumeFailed(workspaceID: String, columnID: UUID, failedAt: TimeInterval)
        case resumeExited(workspaceID: String, columnID: UUID)
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
        let actions: [ActionButton]
    }

    var onRefresh: (() -> Void)?
    var onSelectProject: ((String) -> Void)?
    var onBoardSettings: (() -> Void)?
    var onAction: ((Action) -> Void)?

    private(set) var content: Content?
    /// "Other worktrees" starts folded, each time the board opens.
    private(set) var isOtherWorktreesExpanded = false
    private(set) var rowViews: [RowViews] = []
    private(set) var otherWorktreesToggle: NSButton?
    private var otherRepositoriesTitle: NSTextField?

    let projectPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let repositoryLabel = NSTextField(labelWithString: "")
    let runLabel = NSTextField(labelWithString: "")
    let statusLabel = NSTextField(labelWithString: "")
    let refreshButton = NSButton(title: "Refresh", target: nil, action: nil)
    let settingsButton = NSButton(title: "Board Settings…", target: nil, action: nil)
    let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let columnTitles = ["Name", "Agent", "PR", "Checks", "Actions"].map { NSTextField(labelWithString: $0) }
    private let separator = NSView()
    private let scrollView = NSScrollView()
    private let documentView = FlippedView()
    /// The project ids behind `projectPopup`'s items.
    private var popupProjectIDs: [String?] = []
    private struct MenuState: Equatable {
        let projects: [Project]
        let projectID: String
        let isMissing: Bool
    }
    private var appliedMenu: MenuState?

    private static let headerHeight: CGFloat = 86
    private static let rowHeight: CGFloat = 42
    private static let groupHeight: CGFloat = 28
    private static let padding: CGFloat = 12
    /// Name, Agent, PR, Checks, Actions.
    private static let columnFractions: [CGFloat] = [0.25, 0.19, 0.13, 0.16, 0.27]

    private static let primaryText = NSColor.white.withAlphaComponent(0.85)
    private static let secondaryText = NSColor.white.withAlphaComponent(0.45)
    private static let waitingColor = NSColor.systemOrange
    private static let failureColor = NSColor(red: 0.97, green: 0.46, blue: 0.56, alpha: 1)
    private static let workingColor = NSColor(red: 0.62, green: 0.81, blue: 0.42, alpha: 1)

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1).cgColor
        appearance = NSAppearance(named: .darkAqua)

        projectPopup.controlSize = .small
        projectPopup.font = .systemFont(ofSize: 12, weight: .semibold)
        projectPopup.target = self
        projectPopup.action = #selector(projectChosen(_:))
        for label in [repositoryLabel, runLabel, statusLabel] {
            label.font = .systemFont(ofSize: 11)
            label.textColor = Self.secondaryText
            label.lineBreakMode = .byTruncatingTail
        }
        repositoryLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        statusLabel.alignment = .right
        for (button, action) in [(refreshButton, #selector(refreshClicked)), (settingsButton, #selector(settingsClicked))] {
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
        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        messageLabel.font = .systemFont(ofSize: 12)
        messageLabel.textColor = Self.secondaryText
        messageLabel.alignment = .center

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = documentView

        for view in [projectPopup, repositoryLabel, refreshButton, settingsButton, runLabel, statusLabel, separator, scrollView]
            as [NSView] {
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
        if content.body != previous?.body || content.requiredChecks != previous?.requiredChecks
            || content.baseBranch != previous?.baseBranch {
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
        for (before, after) in zip(old, new) {
            var lhs = before
            var rhs = after
            lhs.agent.state = .none
            rhs.agent.state = .none
            guard lhs == rhs, Self.actionSignature(before) == Self.actionSignature(after) else { return false }
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

    private func applyHeader(_ header: Header, force: Bool = false) {
        // Built again only when the projects change: reads that land while
        // its menu is open must not pull the items from under it.
        let menu = MenuState(projects: header.projects, projectID: header.projectID, isMissing: header.projectIsMissing)
        if force || menu != appliedMenu {
            appliedMenu = menu
            projectPopup.removeAllItems()
            popupProjectIDs = []
            if header.projectIsMissing {
                projectPopup.addItem(withTitle: "Deleted project")
                popupProjectIDs.append(nil)
            }
            for project in header.projects {
                // A pop-up merges items of the same title: two spaces may share a name.
                projectPopup.addItem(withTitle: "")
                projectPopup.lastItem?.title = project.name
                popupProjectIDs.append(project.id)
            }
            let selected = header.projectIsMissing ? 0 : (popupProjectIDs.firstIndex(of: header.projectID) ?? 0)
            if projectPopup.numberOfItems > 0 { projectPopup.selectItem(at: selected) }
        }
        repositoryLabel.stringValue = header.repository ?? ""
        runLabel.stringValue = header.postMergeRun ?? ""
        statusLabel.stringValue = header.status ?? ""
        statusLabel.textColor = header.statusIsError ? Self.failureColor : Self.secondaryText
        statusLabel.toolTip = header.status
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
            pullRequest.stringValue = ProjectBoard.pullRequestText(pr, baseBranch: content?.baseBranch)
            pullRequest.textColor = pr.isConflicting ? Self.failureColor : (pr.isOpen ? Self.primaryText : Self.secondaryText)
            pullRequest.toolTip = pr.url
            if pr.isOpen {
                let summary = ProjectBoard.checkSummary(pr.checks, required: content?.requiredChecks ?? [])
                checks.stringValue = summary.text
                checks.textColor = Self.color(for: summary.worst)
                checks.toolTip = pr.checks.map { "\($0.qualifiedName ?? $0.name): \(ProjectBoard.glyph($0.result))" }
                    .joined(separator: "\n")
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
        for view in [name, subtitle, agent, pullRequest, checks] + actions { container.addSubview(view) }
        documentView.addSubview(container)
        return RowViews(
            row: row, name: name, subtitle: subtitle, agent: agent, pullRequest: pullRequest, checks: checks, actions: actions
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

    private static func color(for result: ProjectBoard.CheckResult?) -> NSColor {
        switch result {
        case .failure?: return failureColor
        case .pending?: return waitingColor
        case .success?: return workingColor
        case .neutral?, .skipped?, nil: return secondaryText
        }
    }

    // MARK: - Layout

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutContent()
    }

    private func layoutContent() {
        let width = bounds.width
        let pad = Self.padding
        let settingsWidth: CGFloat = 112
        let refreshWidth: CGFloat = 70
        settingsButton.frame = NSRect(x: width - pad - settingsWidth, y: 8, width: settingsWidth, height: 24)
        refreshButton.frame = NSRect(x: settingsButton.frame.minX - 6 - refreshWidth, y: 8, width: refreshWidth, height: 24)
        let popupWidth = min(200, max(80, refreshButton.frame.minX - pad - 120))
        projectPopup.frame = NSRect(x: pad - 3, y: 8, width: popupWidth, height: 24)
        repositoryLabel.frame = NSRect(
            x: projectPopup.frame.maxX + 8, y: 13,
            width: max(0, refreshButton.frame.minX - projectPopup.frame.maxX - 16), height: 16
        )
        let halfWidth = max(0, (width - 2 * pad) / 2)
        runLabel.frame = NSRect(x: pad, y: 38, width: halfWidth, height: 16)
        statusLabel.frame = NSRect(x: pad + halfWidth, y: 38, width: halfWidth, height: 16)

        let columns = columnFrames(width: width)
        for (title, frame) in zip(columnTitles, columns) {
            title.frame = NSRect(x: frame.minX, y: 64, width: frame.width, height: 14)
        }
        separator.frame = NSRect(x: 0, y: Self.headerHeight - 1, width: width, height: 1)
        scrollView.frame = NSRect(x: 0, y: Self.headerHeight, width: width, height: max(0, bounds.height - Self.headerHeight))
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
        var x = columns[4].minX
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

    @objc private func settingsClicked() { onBoardSettings?() }

    @objc private func projectChosen(_ sender: NSPopUpButton) {
        guard let id = popupProjectIDs[safe: sender.indexOfSelectedItem] ?? nil else { return }
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

    /// The menu shows the board's project again, after a pick that went
    /// to another board.
    func resetProjectMenu() {
        if let header = content?.header { applyHeader(header, force: true) }
    }

    /// Picks the project as the menu would.
    func chooseProject(id: String) {
        guard let index = popupProjectIDs.firstIndex(of: id) else { return }
        projectPopup.selectItem(at: index)
        projectChosen(projectPopup)
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
