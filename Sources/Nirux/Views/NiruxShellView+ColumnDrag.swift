import AppKit

/// A column dragged by its header (window layout study W7): it rises under
/// the pointer and follows it along the strip, the others making room where
/// it would land; let go, it stays there, moved through the model as Move
/// Left/Right moves it. Escape, a drop outside the viewport or a lost press
/// puts it back.
extension NiruxShellView {
    /// A press on `header`, off its controls, followed to its mouse-up. False
    /// when its column isn't in the workspace on screen.
    func dragColumn(withHeader header: ColumnHeaderView, press: NSEvent) -> Bool {
        guard let window, let workspace = activeWorkspace,
              let column = workspace.columns.first(where: { $0.header === header && !$0.isClosing })
        else { return false }
        let start = workspace.stripPoint(fromWindow: press.locationInWindow)
        let grab = start.x - column.view.frame.minX
        var isDragging = false
        HeldPress(window: window).follow(
            isDragging: { isDragging },
            moved: { event in
                // A column closed meanwhile, or another task on screen, is
                // left as it lies.
                guard workspace === activeWorkspace, let index = workspace.columns.firstIndex(where: { $0 === column }) else { return }
                let point = workspace.stripPoint(fromWindow: event.locationInWindow)
                if !isDragging {
                    guard hypot(point.x - start.x, point.y - start.y) > HeldPress.dragThreshold else { return }
                    isDragging = true
                    liftColumn(at: index, in: workspace)
                }
                let outside = !viewport.bounds.contains(viewport.convert(event.locationInWindow, from: nil))
                if workspace.dragColumn(to: point.x - grab, outside: outside) { relayout(animated: true) }
            },
            ended: { end in
                if isDragging { dropColumn(column, in: workspace, cancelled: end != .released) }
            }
        )
        return true
    }

    /// The card at `index` rises under the pointer, its shadow to the
    /// floating level (`applyCardEdges`).
    private func liftColumn(at index: Int, in workspace: WorkspaceState) {
        workspace.beginColumnDrag(at: index)
        workspace.columns[index].raise(animated: agentLightsMayMove)
        NSCursor.closedHand.set()
        relayout(animated: true)
    }

    /// Let go, the card glides to its slot, or back to the one it came from,
    /// and lies with the others again; the strip goes where it wants, and the
    /// keyboard to the column, as after Move Left/Right.
    private func dropColumn(_ column: ColumnState, in workspace: WorkspaceState, cancelled: Bool) {
        workspace.endColumnDrag(cancelled: cancelled)
        column.settle(animated: agentLightsMayMove)
        NSCursor.arrow.set()
        relayout(animated: true)
        focusActiveTerminal(in: window)
    }
}
