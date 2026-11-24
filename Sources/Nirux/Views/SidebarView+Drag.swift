import AppKit

/// Geometry captured when a drag starts, in the scroll document view's
/// coordinate space. Frames stay valid for the whole gesture because
/// sidebar rebuilds are suspended while a drag is in flight.
struct SidebarWorkspaceDrag {
    let workspaceID: String      // stable identity — store indices can shift mid-drag
    let title: String            // shown on the floating ghost card
    let rowFrame: NSRect         // dragged card's hit area
    let groupRowFrames: [NSRect] // rows in the same active/inactive group, top → bottom
    let position: Int            // dragged card's position within groupRowFrames
    let startPoint: NSPoint
    var isDragging = false       // movement exceeded the click threshold
    var currentSlot: Int?        // insertion slot (0...group count)
}

/// Pure drop-target math, kept off the view so tests can exercise it
/// without AppKit plumbing.
enum SidebarDragMath {
    /// Insertion slot for a cursor at `y` given the group rows' vertical
    /// midpoints ordered top → bottom (AppKit y grows upward, so the list
    /// is descending). Slot s means "insert above row s"; s == count means
    /// after the last row.
    static func insertionSlot(forY y: CGFloat, rowMidYs: [CGFloat]) -> Int {
        rowMidYs.filter { $0 > y }.count
    }

    /// Group position (after removal) that dropping at `slot` produces,
    /// or nil when the drop wouldn't move the row.
    static func targetPosition(slot: Int, draggedPosition: Int) -> Int? {
        if slot == draggedPosition || slot == draggedPosition + 1 { return nil }
        return slot > draggedPosition ? slot - 1 : slot
    }
}

// MARK: - Drag-to-reorder tracking (cards)

extension SidebarView {

    /// Called from mouseDown on a `.workspace` hit region. Follows the
    /// press until its mouse-up (`HeldPress`): a gesture that never leaves
    /// its original slot delivers the normal click, anything else becomes a
    /// reorder drag. Taking the events off the queue also keeps the
    /// window-move machinery from seeing them: the sidebar's subviews report
    /// `mouseDownCanMoveWindow == true`.
    func trackWorkspaceDrag(workspaceIndex: Int, rowFrame: NSRect, startPoint: NSPoint) {
        guard let window else {
            clickRow(workspaceIndex)
            return
        }
        guard var drag = makeWorkspaceDrag(workspaceIndex: workspaceIndex, rowFrame: rowFrame, startPoint: startPoint)
        else {
            deliverFallbackClick(workspaceIndex: workspaceIndex, window: window)
            return
        }
        workspaceDrag = drag
        HeldPress(window: window, holds: rowPressHolds).follow(
            isDragging: { drag.isDragging },
            moved: { event in
                dragMoved(event, drag: &drag)
                workspaceDrag = drag
            },
            ended: { end in
                finishWorkspaceDrag()
                if end == .released { deliverDrop(drag) }
            }
        )
    }

    private func makeWorkspaceDrag(workspaceIndex: Int, rowFrame: NSRect, startPoint: NSPoint) -> SidebarWorkspaceDrag? {
        // The Lead stays on top, a Mission child under its parent: a press
        // on either is a click. A card drags among the cards with no parent.
        guard let dragged = lastInfos.first(where: { $0.index == workspaceIndex }), !dragged.isLead, !dragged.isNested
        else { return nil }
        let section = displayedWorkspaceInfos.filter { $0.isInactive == dragged.isInactive && !$0.isLead }
        let group = section.filter { !$0.isNested }
        let frameOf = { (info: WorkspaceInfo) in
            self.hitAreas.first { area in
                if case .workspace(let index) = area.region { return index == info.index }
                return false
            }?.frame
        }
        // A card and the children listed under it are one drop target: the
        // line between two cards falls below the first one's children.
        var frames: [NSRect] = []
        for info in section {
            guard let frame = frameOf(info) else { continue }
            if info.isNested, let last = frames.popLast() {
                frames.append(last.union(frame))
            } else if !info.isNested {
                frames.append(frame)
            }
        }
        guard frames.count == group.count,
              let position = group.firstIndex(where: { $0.index == workspaceIndex })
        else { return nil }
        return SidebarWorkspaceDrag(
            workspaceID: dragged.id,
            title: dragged.title,
            rowFrame: rowFrame,
            groupRowFrames: frames,
            position: position,
            startPoint: startPoint
        )
    }

    private func dragMoved(_ event: NSEvent, drag: inout SidebarWorkspaceDrag) {
        let point = contentDocumentView.convert(event.locationInWindow, from: nil)
        if !drag.isDragging {
            guard hypot(point.x - drag.startPoint.x, point.y - drag.startPoint.y) > HeldPress.dragThreshold else { return }
            drag.isDragging = true
            beginDragVisuals(for: drag)
            NSEvent.startPeriodicEvents(afterDelay: 0.15, withPeriod: HeldPress.tickPeriod)
        }
        contentDocumentView.autoscroll(with: event)
        // Where the pointer is once the list has scrolled, kept to the part
        // of the list in view: past its edge, the row goes to the last slot
        // the user sees, its ghost and the line stay in view. (Autoscroll
        // reveals the pointer's place at once; this holds if it stops short.)
        let visible = contentScrollView.documentVisibleRect
        let y = min(max(contentDocumentView.convert(event.locationInWindow, from: nil).y, visible.minY), visible.maxY)
        dragGhostView?.frame.origin.y = dragGhostOriginY + (y - drag.startPoint.y)
        let slot = SidebarDragMath.insertionSlot(forY: y, rowMidYs: drag.groupRowFrames.map(\.midY))
        drag.currentSlot = slot
        updateInsertionIndicator(slot: slot, drag: drag)
    }

    /// mouseUp: resolve the workspace by ID against the freshest data
    /// (`finishWorkspaceDrag` just applied any deferred update) — store
    /// indices captured at mouseDown may have shifted. A gesture that
    /// ends where it started still counts as a click, matching the old
    /// press-to-switch behavior.
    private func deliverDrop(_ drag: SidebarWorkspaceDrag) {
        guard let currentIndex = lastInfos.first(where: { $0.id == drag.workspaceID })?.index else { return }
        // A reorder is no first click of a double-click.
        if drag.isDragging { lastRowPress = nil }
        if drag.isDragging,
           let slot = drag.currentSlot,
           let target = SidebarDragMath.targetPosition(slot: slot, draggedPosition: drag.position) {
            onWorkspaceReordered?(currentIndex, target)
        } else {
            clickRow(currentIndex)
        }
    }

    /// Geometry capture failed — behave like a plain click, but still
    /// swallow the gesture so window-move can't grab it. Updates apply
    /// live during the wait, so re-resolve the workspace by id.
    private func deliverFallbackClick(workspaceIndex: Int, window: NSWindow) {
        let clickedID = lastInfos.first { $0.index == workspaceIndex }?.id
        // A press that lost its mouse-up clicks nothing.
        guard HeldPress(window: window, holds: rowPressHolds).swallowRest() else { return }
        if let clickedID {
            if let current = lastInfos.first(where: { $0.id == clickedID })?.index {
                clickRow(current)
            }
        } else {
            clickRow(workspaceIndex)
        }
    }

    /// A click on a row: the workspace, on the column that waits on the
    /// user or broke when another row was selected (its chips only show
    /// once it is), else on its focused column.
    func clickRow(_ workspaceIndex: Int) {
        if let info = lastInfos.first(where: { $0.index == workspaceIndex }), !info.isActive,
           let column = info.rowSummary.focusColumn {
            onColumnClicked?(workspaceIndex, column)
        } else {
            onWorkspaceClicked?(workspaceIndex)
        }
    }

    // MARK: - Visuals

    private func beginDragVisuals(for drag: SidebarWorkspaceDrag) {
        let ghost = cardDragGhost(for: drag)
        contentDocumentView.addSubview(ghost)
        dragGhostView = ghost
        dragGhostOriginY = ghost.frame.origin.y

        let indicator = SidebarBackgroundView()
        indicator.wantsLayer = true
        indicator.layer?.backgroundColor = Self.accentColor.cgColor
        indicator.layer?.cornerRadius = 1
        indicator.isHidden = true
        contentDocumentView.addSubview(indicator)
        dragInsertionView = indicator

        NSCursor.closedHand.set()
    }

    /// Dims the card and returns a ghost of it. Built from scratch rather
    /// than snapshotted: the card chrome lives in layer properties, which
    /// cacheDisplay does not reliably composite.
    private func cardDragGhost(for drag: SidebarWorkspaceDrag) -> NSView {
        // Card-shaped veil dimming the original row.
        addDragDim(frame: drag.rowFrame)

        let ghost = SidebarBackgroundView(frame: drag.rowFrame)
        ghost.wantsLayer = true
        ghost.layer?.backgroundColor = Theme.Color.raised.withAlphaComponent(0.95).cgColor
        ghost.layer?.cornerRadius = 8
        ghost.layer?.borderWidth = 1
        ghost.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        addGhostShadow(ghost)

        let title = NSTextField(labelWithString: drag.title)
        title.font = Theme.Font.title
        title.textColor = Theme.Color.textPrimary
        title.lineBreakMode = .byTruncatingTail
        // At the row's title, in the ghost's coordinates.
        let inset = SidebarExpandedMetrics.textX - SidebarExpandedMetrics.workspaceInsetX
        let height = min(SidebarExpandedMetrics.titleRowHeight + 1, drag.rowFrame.height)
        title.frame = NSRect(
            x: inset,
            // Centered on a one-line row.
            y: drag.rowFrame.height - min(SidebarExpandedMetrics.rowPaddingY, (drag.rowFrame.height - height) / 2) - height,
            width: drag.rowFrame.width - inset - SidebarExpandedMetrics.cardPaddingX,
            height: height
        )
        ghost.addSubview(title)
        return ghost
    }

    private func addDragDim(frame: NSRect) {
        let dim = SidebarBackgroundView(frame: frame)
        dim.wantsLayer = true
        dim.layer?.backgroundColor = Theme.Color.base.withAlphaComponent(0.6).cgColor
        dim.layer?.cornerRadius = 8
        contentDocumentView.addSubview(dim)
        dragDimView = dim
    }

    private func addGhostShadow(_ ghost: NSView) {
        ghost.layer?.shadowColor = NSColor.black.cgColor
        ghost.layer?.shadowOpacity = 0.5
        ghost.layer?.shadowRadius = 8
        ghost.layer?.shadowOffset = .zero
    }

    private func updateInsertionIndicator(slot: Int, drag: SidebarWorkspaceDrag) {
        guard let indicator = dragInsertionView else { return }
        guard SidebarDragMath.targetPosition(slot: slot, draggedPosition: drag.position) != nil else {
            indicator.isHidden = true
            return
        }
        let rows = drag.groupRowFrames
        let gap = SidebarExpandedMetrics.workspaceGap
        let y: CGFloat
        if slot == 0 {
            y = rows[0].maxY + gap / 2
        } else if slot == rows.count {
            y = rows[rows.count - 1].minY - gap / 2
        } else {
            y = (rows[slot - 1].minY + rows[slot].maxY) / 2
        }
        let inset = SidebarExpandedMetrics.workspaceInsetX
        let width = listWidth - inset * 2
        indicator.frame = NSRect(x: inset, y: y - 1, width: width, height: 2)
        indicator.isHidden = false
    }

    /// Tear down drag state/visuals, then repair whatever was suppressed
    /// mid-drag: apply the deferred data update, and make the rebuild
    /// that was skipped if that update made none (the same data, under a
    /// signature already stored: `animates`, the catch-up card).
    private func finishWorkspaceDrag() {
        let hadDragVisuals = dragDimView != nil
        workspaceDrag = nil
        dragGhostView?.removeFromSuperview()
        dragGhostView = nil
        dragDimView?.removeFromSuperview()
        dragDimView = nil
        dragInsertionView?.removeFromSuperview()
        dragInsertionView = nil
        if hadDragVisuals {
            NSEvent.stopPeriodicEvents()
            NSCursor.arrow.set()
        }
        if let deferred = deferredDragUpdate {
            deferredDragUpdate = nil
            update(
                profiles: deferred.profiles, workspaces: deferred.workspaces
            )
        }
        if rebuildSkippedDuringDrag { rebuildContent() }
    }
}
