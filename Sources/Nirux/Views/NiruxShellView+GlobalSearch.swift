import AppKit

// MARK: - Search Everywhere (⌥⌘F)

extension NiruxShellView {
    func showGlobalSearch() {
        guard let window else { return }
        if globalSearchPanel == nil { globalSearchPanel = GlobalSearchPanel() }
        globalSearchPanel?.show(
            relativeTo: window,
            targets: { [weak self] in self?.globalSearchTargets() ?? [] },
            onPick: { [weak self] pick in self?.revealSearchMatch(pick) }
        )
    }

    /// Every terminal column of every workspace: the active workspace's
    /// first, then the rest of its project in sidebar order, then the
    /// other projects'. Columns read left to right. A terminal whose shell
    /// exited is left out: its restart overlay hides the find bar.
    func globalSearchTargets() -> [GlobalSearchPanel.Target] {
        let visible = visibleWorkspaceIndices
        let order = [activeWSIndex]
            + visible.filter { $0 != activeWSIndex }
            + workspaces.indices.filter { $0 != activeWSIndex && !visible.contains($0) }
        return order.compactMap { workspaces[safe: $0] }
            .filter { !$0.isClosing }
            .flatMap { workspace in
                workspace.columns.enumerated().compactMap { index, column -> GlobalSearchPanel.Target? in
                    guard !column.isClosing, column.terminalView != nil,
                          let pty = column.pty, !pty.hasExited
                    else { return nil }
                    let session = pty.terminalSession
                    let title = column.titleText.isEmpty ? "Terminal \(index + 1)" : column.titleText
                    return GlobalSearchPanel.Target(
                        column: column,
                        place: "\(workspace.title) › \(title)",
                        read: { TerminalScreenText.read(session) }
                    )
                }
            }
    }

    /// Brings the picked match's column forward, wherever it is now, and
    /// opens its find bar on the match. Output printed since the search may
    /// hold newer matches: they are counted again, and the pick keeps its
    /// place counted from the oldest.
    func revealSearchMatch(_ pick: GlobalSearchPanel.Pick) {
        let column = pick.column
        guard let workspace = workspaces.first(where: { $0.columns.contains { $0 === column } }),
              let columnIndex = workspace.columns.firstIndex(where: { $0 === column }),
              let session = column.pty?.terminalSession
        else { return NSSound.beep() }
        window?.makeKey()
        focusWorkspace(id: workspace.id, column: columnIndex)
        column.showFindBar(searching: pick.needle)
        let fromBottom = pick.fromBottom
        let fromTop = pick.total - 1 - fromBottom
        GlobalTerminalSearch.recount(pick.needle, read: { TerminalScreenText.read(session) }) { [weak column] counted in
            let fromBottom = counted.map { $0.total - 1 - fromTop } ?? fromBottom
            let delay = TerminalSearchSession.pickDelay(textBytes: counted?.textBytes ?? 0)
            column?.selectFindMatch(fromBottom: fromBottom, after: delay)
        }
    }
}
