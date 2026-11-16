import AppKit

// MARK: - Folded: the icon rail

/// Folded, the sidebar is the glass interface's icon rail (`IconRail`,
/// docs/design/glass-interface.md): the space's Lead, one state icon per
/// task it lists, the archived tasks, a new task and the Board. The rows'
/// gestures that need room (dragging, renaming in place, the archived list)
/// stay in the unfolded sidebar; a task's menu answers a right-click on its
/// icon.
extension SidebarView {
    /// The folded sidebar's width: the rail and its margins. The columns
    /// start where they did beside the rail of initials.
    static let foldedWidth: CGFloat = 52
    static let railMarginTop = Theme.Space.md
    static let railMarginBottom: CGFloat = 10

    /// Where the rail sits, from the sidebar's left edge whatever its width:
    /// the rail stays put while the sidebar folds around it.
    var iconRailFrame: NSRect {
        NSRect(
            x: (Self.foldedWidth - IconRail.width) / 2, y: Self.railMarginBottom,
            width: IconRail.width, height: max(0, bounds.height - Self.railMarginTop - Self.railMarginBottom)
        )
    }

    func wireIconRail() {
        iconRail.isHidden = true
        addSubview(iconRail)
        iconRail.onSelect = { [weak self] id in self?.selectFromRail(id) }
        // The task's request beside its icon (the shell's callout); with
        // none to show, what a click on the row does.
        iconRail.onRequest = { [weak self] id, icon in
            guard let self else { return }
            if onRailRequest?(id, icon) != true { selectFromRail(id) }
        }
        iconRail.onArchived = { [weak self] in self?.onShowArchived?() }
        iconRail.onNew = { [weak self] in self?.onNewWorkspace?() }
        iconRail.onBoard = { [weak self] in self?.onOpenBoard?() }
        iconRail.menuForTask = { [weak self] id in
            self?.notePointer(.menu)
            guard let self, let index = lastInfos.first(where: { $0.id == id })?.index else { return nil }
            return workspaceActionMenu(workspaceIndex: index, columnIndex: nil)
        }
    }

    /// A click on an icon: what a click on its row does (`clickRow`).
    private func selectFromRail(_ id: String) {
        notePointer(.press)
        guard let index = lastInfos.first(where: { $0.id == id })?.index else { return }
        clickRow(index)
    }

    /// Folded and not faded out for an unfold: the rail shows what the
    /// sidebar lists, on the window's colour, where its capsule reads as in
    /// the approved renders (at Opaque the capsule is the sidebar's colour).
    /// Fading out, the picture of the rail fades over the cards' colour.
    func showIconRail() {
        iconRail.isHidden = isExpanded || isRailHidden
        layer?.backgroundColor = (iconRail.isHidden ? Theme.Color.base : Theme.Color.canvas).cgColor
        // Hidden, its icons stop breathing.
        iconRail.animates = animates && !iconRail.isHidden
        guard !iconRail.isHidden else { return }
        iconRail.frame = iconRailFrame
        iconRail.show(railContent)
    }

    /// The Lead, then the tasks the rail lists, the one on screen chosen,
    /// and how many tasks are archived. The tasks listed: the active ones,
    /// then of the archived ones those that the folded list shows (the one
    /// on screen, one whose agent waits on the user or broke) and one with a
    /// question handed to the user (`railState`). Never the whole archived
    /// list: folded, it has nowhere to show. Each row's state is read once:
    /// a rebuild runs at every layout pass.
    var railContent: IconRail.Content {
        var content = IconRail.Content(lead: nil, tasks: [], archivedCount: lastInfos.filter(\.isInactive).count)
        // Over every task, listed or not: a task coming or going renumbers
        // none ("CR2" stays "CR2").
        let tasks = displayedWorkspaceInfos.filter { !$0.isLead }
        let initials = Dictionary(zip(tasks.map(\.id), TaskInitials.initials(for: tasks.map(\.title))), uniquingKeysWith: { first, _ in first })
        for info in displayedWorkspaceInfos {
            let state = info.railState
            guard !info.isInactive || info.isActive || info.asksUser || state == .waiting else { continue }
            let summary = info.rowSummary
            let rowIcon = info.stateIcon(summary: summary)
            let icon = WorkspaceInfo.railIcon(rowIcon, state: state)
            // The row's words, but the branch it prints when nothing goes
            // on, or a row that says less than the amber icon: then the
            // icon's state says more.
            let saysLess = summary.status.tone == .branch || icon != rowIcon
            let item = IconRail.Item(
                id: info.id, title: info.title, icon: icon, detail: saysLess ? nil : summary.status.text,
                label: info.isLead ? nil : initials[info.id]
            )
            if info.isLead, content.lead == nil { content.lead = item } else if !info.isLead { content.tasks.append(item) }
            if info.isActive { content.selectedID = info.id }
        }
        return content
    }
}

@MainActor
extension WorkspaceInfo {
    /// The rail's state: the card's (`cardState`), and amber for a question
    /// a Mission child handed to the user while they were elsewhere
    /// (`notification`).
    var railState: SidebarCardState {
        let state = cardState
        return state != .waiting && !isActive && notification == .waiting ? .waiting : state
    }

    /// The row's state as an icon (`rowSummary`): a wait says its reason,
    /// from the column a click brings up. A question handed to the user
    /// (`railState`) shows amber on the rail even where the row says less.
    var railIcon: StateIcon { Self.railIcon(stateIcon, state: railState) }

    /// `railIcon` from the row's icon and the rail's state.
    static func railIcon(_ rowIcon: StateIcon, state: SidebarCardState) -> StateIcon {
        state == .waiting && !rowIcon.waitsForUser ? StateIcon(.needsYou(.question)) : rowIcon
    }

    /// The row's mark as an icon, its wait's reason from the column a
    /// click brings up (the command bar's task, the rail).
    var stateIcon: StateIcon { stateIcon(summary: rowSummary) }

    func stateIcon(summary: SidebarRowSummary) -> StateIcon {
        let column = columns.first { $0.index == summary.focusColumn ?? focusedColumn }
        return StateIcon(mark: summary.mark, reason: summary.mark == .needsYou ? column.map(Self.waitReason) : nil)
    }

    /// What a waiting column waits on, for its icon: a permission the row
    /// offers, else the dialog on screen (focusing the column clears its
    /// attention, not the dialog), else its attention's reason.
    static func waitReason(of column: ColumnInfo) -> StateIcon.Reason {
        if column.permissionApproval != nil { return .command }
        return StateIcon.Reason(column.openDialog ?? column.attentionReason) ?? .question
    }
}
