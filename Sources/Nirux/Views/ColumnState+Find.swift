import AppKit

// MARK: - Find bar (⌘F, ⌘G, ⇧⌘G) of terminal and browser columns

extension ColumnState {
    var isFindBarOpen: Bool { findBar.map { !$0.isHidden } ?? false }

    /// True while the find field has the keyboard focus: the key
    /// interceptor must then leave keys to the field, not the PTY or page.
    var isEditingFind: Bool { isFindBarOpen && findBar?.isEditing == true }

    /// A browser column, or a terminal whose shell runs: a shell-exited
    /// overlay hides the scrollback.
    var canFind: Bool {
        isWebView || (terminalView != nil && pty?.hasExited != true)
    }

    /// ⌘F: open the find bar, or focus it again with its text selected.
    /// Reopening searches the kept text again, once the field has the
    /// keyboard: a page that loses it drops its selection, so its search
    /// starts over from the top.
    func showFindBar() {
        guard canFind else { return }
        let bar = findBar ?? makeFindBar()
        // Above the terminal or page, and a shell-exited overlay added since.
        if view.subviews.last !== bar {
            view.addSubview(bar, positioned: .above, relativeTo: nil)
        }
        let reopens = bar.isHidden
        bar.isHidden = false
        layoutFindBar()
        bar.focusField()
        if reopens {
            terminalSearch?.update(bar.field.stringValue, immediately: true)
            webViewColumn?.pageFind.update(bar.field.stringValue)
        }
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
        webViewColumn?.pageFind.next()
    }

    /// ⇧⌘G / Shift+Return: previous match. Only while the bar is open.
    func findPrevious() {
        guard isFindBarOpen else { return }
        terminalSearch?.previous()
        webViewColumn?.pageFind.previous()
    }

    /// Escape or the close button: end the search (clearing the
    /// highlights), hide the bar and hand the keyboard back to the terminal
    /// or the page. The field keeps its text for the next ⌘F, a terminal's
    /// viewport its position until the next keystroke
    /// (TerminalSearchSession.returnToPrompt), a page its selected match.
    func closeFindBar() {
        guard let bar = findBar, !bar.isHidden else { return }
        let wasEditing = bar.isEditing
        terminalSearch?.end()
        webViewColumn?.pageFind.end()
        bar.isHidden = true
        let content: NSView? = isWebView ? webViewColumn?.webView : terminalView
        if wasEditing, let content {
            content.window?.makeFirstResponder(content)
        }
    }

    /// Top-right corner of the terminal or page, under the header.
    func layoutFindBar() {
        guard let bar = findBar, !bar.isHidden else { return }
        let margin: CGFloat = 10
        // A browser column draws its header itself.
        let top = isWebView ? ColumnHeaderView.height : headerHeight
        let width = min(FindBar.preferredWidth, max(0, view.bounds.width - margin * 2))
        bar.frame = NSRect(
            x: view.bounds.width - margin - width,
            y: view.bounds.height - top - margin - FindBar.height,
            width: width,
            height: FindBar.height
        )
    }

    private func makeFindBar() -> FindBar {
        let bar = FindBar(target: isWebView ? .page : .terminal)
        bar.isHidden = true
        if let browser = webViewColumn {
            browser.pageFind.onStatusChange = { [weak bar] status in bar?.status = status }
            bar.onNeedleChange = { [weak browser] text in browser?.pageFind.update(text) }
        } else {
            terminalSearch = TerminalSearchSession { [weak self] command in
                _ = self?.terminalView?.performBindingAction(command.bindingAction)
            }
            bar.onNeedleChange = { [weak self] text in self?.terminalSearch?.update(text) }
        }
        bar.onNext = { [weak self] in self?.findNext() }
        bar.onPrevious = { [weak self] in self?.findPrevious() }
        bar.onClose = { [weak self] in self?.closeFindBar() }
        findBar = bar
        return bar
    }
}

extension WorkspaceState {
    /// The column whose find field has the keyboard focus, if any.
    /// Usually the focused column, but a resize drag or an agent opening an
    /// editor column moves the focus index without moving the keyboard.
    var findFieldColumn: ColumnState? {
        columns.first { $0.isEditingFind }
    }
}

extension NiruxShellView {
    /// The column Edit > Find acts on: the one whose find field is being
    /// edited, else the focused column when it can search (`canFind`).
    var findTargetColumn: ColumnState? {
        guard let workspace = activeWorkspace else { return nil }
        if let column = workspace.findFieldColumn { return column }
        guard let column = workspace.columns[safe: workspace.focusedIndex], column.canFind else { return nil }
        return column
    }

    /// Edit > Find (⌘F). No-op unless a terminal or browser column has the
    /// focus: editor columns keep ⌘F for Monaco's find widget
    /// (WebContentKeyRouting).
    func showFind() {
        findTargetColumn?.showFindBar()
    }

    func findNextMatch() {
        findTargetColumn?.findNext()
    }

    func findPreviousMatch() {
        findTargetColumn?.findPrevious()
    }
}
