import AppKit

/// The front editor column (docs/workspaces-and-columns.md, "The front
/// editor"): what an agent, a link or a search opens shows there, centred
/// over the row, which dims behind it and never moves for it. ⌘Y, Esc in
/// it and a click on the row send it back, its tabs, scroll and selection
/// kept; ⌘Y brings it up again.
extension NiruxShellView {
    /// The front editor of `workspace`, made rooted at `cwd` if it has none.
    func frontEditor(in workspace: WorkspaceState, cwd: String) -> EditorColumn? {
        let isNew = workspace.front == nil
        guard let editor = workspace.addFrontEditorColumn(workspaceCwd: cwd)?.editorColumn else { return nil }
        if isNew { wireEditor(editor) }
        return editor
    }

    /// Brings the front column up over the row. `takeKeyboard`: it takes
    /// the focus and the keyboard, the row column that had them kept to
    /// come back to; else typing goes on where it went.
    func showFront(in workspace: WorkspaceState, takeKeyboard: Bool) {
        guard let front = workspace.front, let index = workspace.frontIndex else { return }
        if workspace.focusedIndex < workspace.rowCount { workspace.frontReturnIndex = workspace.focusedIndex }
        let rises = !workspace.isFrontShown
        let moves = agentLightsMayMove && workspace === activeWorkspace
        workspace.setFrontShown(true, duration: moves ? Self.arrivalDuration : nil)
        if takeKeyboard { workspace.focusedIndex = index }
        relayout(animated: false)
        updateSidebar()
        if rises { passFront(front, in: workspace, up: true, moves: moves) }
        if takeKeyboard, workspace === activeWorkspace { focusActiveTerminal(in: window, editorTakesKeyboard: true) }
    }

    /// Sends the front column back down, as it is. Row column `index`, or
    /// the one it came from when it had the focus, takes the focus and the
    /// keyboard.
    func hideFront(in workspace: WorkspaceState, focusing index: Int? = nil) {
        guard let front = workspace.front, workspace.isFrontShown else { return }
        let moves = agentLightsMayMove && workspace === activeWorkspace
        let refocuses = index != nil || workspace.focusedIndex == workspace.frontIndex
        workspace.setFrontShown(false, duration: moves ? Self.closeDuration : nil)
        if refocuses {
            workspace.focusedIndex = min(index ?? workspace.frontReturnIndex, max(workspace.rowCount - 1, 0))
        }
        relayout(animated: true)
        updateSidebar()
        passFront(front, in: workspace, up: false, moves: moves)
        if refocuses, workspace === activeWorkspace { focusActiveTerminal(in: window, editorTakesKeyboard: true) }
    }

    /// ⌘Y: the front column goes back down, or comes up again as it was.
    func toggleFront() {
        guard let workspace = activeWorkspace, workspace.front != nil else { return }
        if workspace.isFrontShown { hideFront(in: workspace) } else { showFront(in: workspace, takeKeyboard: true) }
    }

    /// A click on the shaded row sends the front column back and gives the
    /// clicked column the focus.
    func wireFrontColumn(_ workspace: WorkspaceState) {
        workspace.frontHost.onShadeClick = { [weak self, weak workspace] point in
            guard let self, let workspace else { return }
            self.hideFront(in: workspace, focusing: workspace.rowColumnIndex(at: point) ?? workspace.frontReturnIndex)
        }
    }

    /// Esc in a front editor that nothing in it took sends the column back.
    func editorEscaped(_ editor: EditorColumn) {
        guard let workspace = workspaces.first(where: { $0.front?.editorColumn === editor }) else { return }
        hideFront(in: workspace)
    }

    /// The front card comes in from the front, a little larger, and goes
    /// back receding, as a column arrives and closes; there or gone at once
    /// while the interface may not move.
    private func passFront(_ front: ColumnState, in workspace: WorkspaceState, up: Bool, moves: Bool) {
        guard moves else {
            front.view.layer?.removeAnimation(forKey: ColumnState.passKey)
            front.view.alphaValue = 1
            front.view.isHidden = !up
            return
        }
        if up {
            front.view.isHidden = false
            front.pass(
                from: (Self.arrivalScale, 0), to: 1, alpha: 1, duration: Self.arrivalDuration,
                curve: CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
            ) {}
        } else {
            front.pass(
                to: Self.closeScale, alpha: 0, duration: Self.closeDuration,
                curve: CAMediaTimingFunction(controlPoints: 0.4, 0, 0.6, 1)
            ) { [weak front, weak workspace] in
                guard let front, let workspace, !workspace.isFrontShown else { return }
                front.view.isHidden = true
                front.view.alphaValue = 1
            }
        }
    }
}
