import AppKit

// MARK: - Terminal find bar (⌘F, ⌘G, ⇧⌘G)

extension ColumnState {
    var isFindBarOpen: Bool { findBar.map { !$0.isHidden } ?? false }

    /// True while the find field has the keyboard focus: the key
    /// interceptor must then leave keys to the field, not the PTY.
    var isEditingFind: Bool { isFindBarOpen && findBar?.isEditing == true }

    /// ⌘F: open the find bar, or focus it again with its text selected.
    /// Reopening searches the kept text again. Not over a shell-exited
    /// overlay, which hides the scrollback.
    func showFindBar() {
        guard terminalView != nil, pty?.hasExited != true else { return }
        let bar = findBar ?? makeFindBar()
        // Above the terminal and a shell-exited overlay added since.
        if view.subviews.last !== bar {
            view.addSubview(bar, positioned: .above, relativeTo: nil)
        }
        if bar.isHidden {
            bar.isHidden = false
            terminalSearch?.update(bar.field.stringValue, immediately: true)
        }
        layoutFindBar()
        bar.focusField()
    }

    /// Search Everywhere's pick: the find bar opened on `needle` as a new
    /// search, even on the needle the bar already shows, so that matches
    /// count from Ghostty's newest and oldest ones again
    /// (`selectFindMatch`). Nil when the bar can't open.
    func showFindBar(searching needle: String) -> TerminalSearchSession.Mark? {
        guard terminalView != nil, pty?.hasExited != true else { return nil }
        let bar = findBar ?? makeFindBar()
        bar.field.stringValue = needle
        terminalSearch?.end()
        terminalSearch?.update(needle, immediately: true)
        showFindBar()
        return terminalSearch?.mark
    }

    /// Selects the match `fromBottom` (0 is the newest) of the needle's
    /// `total` matches, after `delay`, unless the search moved past `mark`
    /// (TerminalSearchSession.select).
    func selectFindMatch(fromBottom: Int, of total: Int, after delay: TimeInterval, since mark: TerminalSearchSession.Mark) {
        guard isFindBarOpen else { return }
        terminalSearch?.select(fromBottom: fromBottom, of: total, after: delay, since: mark)
    }

    /// ⌘G / Return: next match. Only while the bar is open.
    func findNext() {
        guard isFindBarOpen else { return }
        terminalSearch?.next()
    }

    /// ⇧⌘G / Shift+Return: previous match. Only while the bar is open.
    func findPrevious() {
        guard isFindBarOpen else { return }
        terminalSearch?.previous()
    }

    /// Escape or the close button: end the search (clearing Ghostty's
    /// highlights), hide the bar and hand the keyboard back to the terminal.
    /// The field keeps its text for the next ⌘F, the viewport its position
    /// until the next keystroke (TerminalSearchSession.returnToPrompt).
    func closeFindBar() {
        guard let bar = findBar, !bar.isHidden else { return }
        let wasEditing = bar.isEditing
        terminalSearch?.end()
        bar.isHidden = true
        if wasEditing, let terminal = terminalView {
            terminal.window?.makeFirstResponder(terminal)
        }
    }

    /// Top-right corner of the terminal, under the title bar.
    func layoutFindBar() {
        guard let bar = findBar, !bar.isHidden else { return }
        let margin: CGFloat = 10
        let width = min(TerminalFindBar.preferredWidth, max(0, view.bounds.width - margin * 2))
        bar.frame = NSRect(
            x: view.bounds.width - margin - width,
            y: view.bounds.height - titleBarHeight - margin - TerminalFindBar.height,
            width: width,
            height: TerminalFindBar.height
        )
    }

    private func makeFindBar() -> TerminalFindBar {
        let bar = TerminalFindBar(frame: .zero)
        bar.isHidden = true
        let search = TerminalSearchSession { [weak self] command in
            _ = self?.terminalView?.performBindingAction(command.bindingAction)
        }
        bar.onNeedleChange = { [weak self] text in self?.terminalSearch?.update(text) }
        bar.onNext = { [weak self] in self?.findNext() }
        bar.onPrevious = { [weak self] in self?.findPrevious() }
        bar.onClose = { [weak self] in self?.closeFindBar() }
        findBar = bar
        terminalSearch = search
        return bar
    }
}

extension WorkspaceState {
    /// The terminal column whose find field has the keyboard focus, if any.
    /// Usually the focused column, but a resize drag or an agent opening an
    /// editor column moves the focus index without moving the keyboard.
    var findFieldColumn: ColumnState? {
        columns.first { $0.isEditingFind }
    }
}

extension NiruxShellView {
    /// The column Edit > Find acts on: the one whose find field is being
    /// edited, else the focused column when it is a terminal.
    var findTargetColumn: ColumnState? {
        guard let workspace = activeWorkspace else { return nil }
        if let column = workspace.findFieldColumn { return column }
        guard let column = workspace.columns[safe: workspace.focusedIndex],
              column.terminalView != nil
        else { return nil }
        return column
    }

    /// Edit > Find in Terminal (⌘F). No-op unless a terminal column has the
    /// focus: editor and browser columns get ⌘F themselves
    /// (WebContentKeyRouting).
    func showTerminalFind() {
        findTargetColumn?.showFindBar()
    }

    func findNextInTerminal() {
        findTargetColumn?.findNext()
    }

    func findPreviousInTerminal() {
        findTargetColumn?.findPrevious()
    }
}
