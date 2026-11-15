import AppKit

// MARK: - Command bar (glass interface, step 3.1)

extension NiruxShellView {
    /// Gives `window` the toolbar with the command bar (docs/design/
    /// glass-interface.md): the space and its menu, the task on screen and
    /// its menu, ⌘P, and the agents waiting for the user (⌘J).
    func installCommandBar(in window: NSWindow) {
        let bar = CommandBarView(level: .opaque)
        let toolbar = CommandBarToolbar(bar: bar)
        toolbar.install(in: window)
        commandBarToolbar = toolbar
        bar.onSpace = { [weak self] in self?.showSpaceMenuFromCommandBar() }
        bar.onTask = { [weak self] in self?.showTaskMenuFromCommandBar() }
        bar.onSearch = { [weak self] in self?.showCommandPalette() }
        bar.onWaiting = { [weak self] in self?.jumpToNextWaitingAgent() }
        scheduleMetadataRefresh()
    }

    /// The bar follows the sidebar's refresh: the space on screen, the task
    /// on screen (`task`, its row's info), and the agents waiting for the
    /// user in every space (`waitingCount`).
    func updateCommandBar(task: WorkspaceInfo?, waitingCount: Int) {
        commandBarToolbar?.bar.show(Self.commandBarContent(space: workspaceStore.activeProfile, task: task, waitingCount: waitingCount))
    }

    /// What the bar shows: the space's name and colour; the task's title,
    /// its row's state as an icon (the station waits for a follow-up: an
    /// empty ring) and its status as the row says it ("Working 12m": the
    /// turn's time only while it works); and how many agents wait for the
    /// user.
    static func commandBarContent(space: WorkspaceProfile, task: WorkspaceInfo?, waitingCount: Int) -> CommandBarView.Content {
        var content = CommandBarView.Content(
            spaceName: space.name, spaceColor: NSColor.niruxColor(hex: space.colorHex) ?? Theme.Color.accent,
            taskTitle: nil, taskIcon: nil, taskDetail: nil, waitingCount: waitingCount
        )
        guard let task else { return content }
        let summary = task.rowSummary
        let column = task.columns.first { $0.index == summary.focusColumn ?? task.focusedColumn }
        content.taskTitle = task.title
        content.taskIcon = StateIcon(mark: summary.mark, reason: summary.mark == .needsYou ? column.map(Self.waitReason) : nil)
        var detail = summary.status.text
        if case .turn(let time)? = summary.trailing { detail += " \(time)" }
        content.taskDetail = detail
        return content
    }

    /// The bar's count: of what ⌘J would visit (`queue`, as
    /// `WaitingAgentQueue.collect` gives it), what waits for the user's
    /// answer (amber: not an agent stopped on an error or exited, which ⌘J
    /// also visits), leaving out the column on screen, where ⌘J never goes.
    static func commandBarWaitingCount(queue: [WaitingAgent], onScreen: UUID?) -> Int {
        queue.filter { $0.columnID != onScreen && $0.wait.reason.signal == .waiting }.count
    }

    /// What a waiting column waits on, for its icon: a permission the row
    /// offers, else the dialog on screen (focusing the column clears its
    /// attention, not the dialog), else its attention's reason.
    static func waitReason(of column: ColumnInfo) -> StateIcon.Reason {
        if column.permissionApproval != nil { return .command }
        return StateIcon.Reason(column.openDialog ?? column.attentionReason) ?? .question
    }

    /// The space menu, as the sidebar's picker has it, under the bar's space
    /// segment.
    private func showSpaceMenuFromCommandBar() {
        guard let bar = commandBarToolbar?.bar else { return }
        popUpUnder(bar.spaceButton, sidebar.spacePickerMenu())
    }

    /// The task's menu, as its row's ⋯ has it, under the bar's task segment;
    /// with nothing open, the New sheet.
    private func showTaskMenuFromCommandBar() {
        guard let bar = commandBarToolbar?.bar else { return }
        guard activeWorkspace != nil else {
            _ = showNewPanel()
            return
        }
        popUpUnder(bar.taskButton, sidebar.workspaceActionMenu(workspaceIndex: activeWSIndex, columnIndex: nil))
    }

    private func popUpUnder(_ segment: NSView, _ menu: NSMenu) {
        let below = segment.isFlipped ? segment.bounds.maxY + Theme.Space.xs : segment.bounds.minY - Theme.Space.xs
        sideEffects.popUpMenu(menu, NSPoint(x: segment.bounds.minX, y: below), segment)
    }
}
