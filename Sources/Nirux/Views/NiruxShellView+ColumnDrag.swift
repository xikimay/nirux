import AppKit

/// A column dragged by its header (window layout study W7): it rises under
/// the pointer and follows it along the strip, the others making room where
/// it would land, and the strip pans while the pointer holds near an edge;
/// let go, it stays there, moved through the model as Move Left/Right moves
/// it. Escape, a drop outside the viewport or a lost press puts it back.
extension NiruxShellView {
    /// A press on `header`, off its controls, followed to its mouse-up. False
    /// when its column isn't in the workspace on screen.
    func dragColumn(withHeader header: ColumnHeaderView, press: NSEvent) -> Bool {
        guard let window, let workspace = activeWorkspace,
              let column = workspace.columns.first(where: { $0.header === header && !$0.isClosing })
        else { return false }
        var isDragging = false
        // The pointer's place on the card, from its left edge.
        var grab: CGFloat = 0
        HeldPress(window: window).follow(
            isDragging: { isDragging },
            moved: { event, isTick in
                // A column closed meanwhile, or another task on screen, is
                // left as it lies.
                guard workspace === activeWorkspace, let index = workspace.columns.firstIndex(where: { $0 === column }) else { return }
                let pointer = event.locationInWindow
                if !isDragging {
                    let start = press.locationInWindow
                    guard hypot(pointer.x - start.x, pointer.y - start.y) > HeldPress.dragThreshold, liftColumn(at: index, in: workspace)
                    else { return }
                    isDragging = true
                    grab = workspace.stripPoint(fromWindow: pointer).x - column.view.frame.minX
                }
                // From where the viewport rests: passing under the rail, it
                // reaches past its edge.
                let rest = viewportRestFrame, inShell = convert(pointer, from: nil)
                let outside = !rest.contains(inShell)
                workspace.dragPan(outside ? 0 : WorkspaceState.edgePan(at: inShell.x - rest.minX, width: rest.width), isTick: isTick)
                if workspace.dragColumn(to: workspace.stripPoint(fromWindow: pointer).x - grab, outside: outside) {
                    relayout(animated: true)
                }
            },
            ended: { end in
                if isDragging { dropColumn(column, in: workspace, cancelled: end != .released) }
            }
        )
        return true
    }

    /// The card at `index` rises under the pointer, its shadow to the
    /// floating level (`applyCardEdges`); the drag's ticks pan the strip
    /// while the pointer holds near an edge. False for a card on its way
    /// out (closed during the press).
    private func liftColumn(at index: Int, in workspace: WorkspaceState) -> Bool {
        guard workspace.beginColumnDrag(at: index) else { return false }
        workspace.columns[index].raise(animated: agentLightsMayMove)
        NSCursor.closedHand.set()
        sideEffects.runsDragTicks(true)
        relayout(animated: true)
        return true
    }

    /// Let go, the card glides to its slot, or back to the one it came from,
    /// and lies with the others again; the strip goes where it wants, and the
    /// keyboard to the column, as after Move Left/Right.
    private func dropColumn(_ column: ColumnState, in workspace: WorkspaceState, cancelled: Bool) {
        sideEffects.runsDragTicks(false)
        workspace.endColumnDrag(cancelled: cancelled)
        column.settle(animated: agentLightsMayMove)
        NSCursor.arrow.set()
        relayout(animated: true)
        focusActiveTerminal(in: window)
    }
}
