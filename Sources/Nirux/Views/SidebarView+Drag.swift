import AppKit

/// Geometry captured when a drag is armed, in the scroll document view's
/// coordinate space. Frames stay valid for the whole gesture because
/// sidebar rebuilds are suspended while a drag is in flight.
struct SidebarWorkspaceDrag {
    let workspaceIndex: Int      // store index of the dragged workspace
    let rowFrame: NSRect         // dragged card frame
    let groupRowFrames: [NSRect] // cards in the same active/inactive group, top → bottom
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

// MARK: - Drag-to-reorder tracking (expanded mode)

extension SidebarView {

    private static let dragThreshold: CGFloat = 4

    /// Called from mouseDown on a `.workspace` hit region: don't fire the
    /// click yet — capture the group geometry and let mouseDragged/mouseUp
    /// decide between click and reorder.
    func beginPotentialWorkspaceDrag(workspaceIndex: Int, rowFrame: NSRect, at point: NSPoint) {
        guard let dragged = lastInfos.first(where: { $0.index == workspaceIndex }) else {
            onWorkspaceClicked?(workspaceIndex)
            return
        }
        let group = displayedWorkspaceInfos.filter { $0.isInactive == dragged.isInactive }
        let frames = group.compactMap { info in
            hitAreas.first { area in
                if case .workspace(let index) = area.region { return index == info.index }
                return false
            }?.frame
        }
        guard frames.count == group.count,
              let position = group.firstIndex(where: { $0.index == workspaceIndex })
        else {
            onWorkspaceClicked?(workspaceIndex)
            return
        }
        workspaceDrag = SidebarWorkspaceDrag(
            workspaceIndex: workspaceIndex,
            rowFrame: rowFrame,
            groupRowFrames: frames,
            position: position,
            startPoint: point
        )
    }

    override func mouseDragged(with event: NSEvent) {
        guard var drag = workspaceDrag else {
            super.mouseDragged(with: event)
            return
        }
        let point = contentDocumentView.convert(event.locationInWindow, from: nil)
        if !drag.isDragging {
            guard hypot(point.x - drag.startPoint.x, point.y - drag.startPoint.y) > Self.dragThreshold else { return }
            drag.isDragging = true
            beginDragVisuals(for: drag)
        }
        contentDocumentView.autoscroll(with: event)
        dragSnapshotView?.frame.origin.y = drag.rowFrame.origin.y + (point.y - drag.startPoint.y)
        let slot = SidebarDragMath.insertionSlot(forY: point.y, rowMidYs: drag.groupRowFrames.map(\.midY))
        drag.currentSlot = slot
        updateInsertionIndicator(slot: slot, drag: drag)
        workspaceDrag = drag
    }

    override func mouseUp(with event: NSEvent) {
        guard let drag = workspaceDrag else {
            super.mouseUp(with: event)
            return
        }
        finishWorkspaceDrag()
        guard drag.isDragging else {
            onWorkspaceClicked?(drag.workspaceIndex)
            return
        }
        if let slot = drag.currentSlot,
           let target = SidebarDragMath.targetPosition(slot: slot, draggedPosition: drag.position) {
            onWorkspaceReordered?(drag.workspaceIndex, target)
        }
    }

    func cancelWorkspaceDrag() {
        guard workspaceDrag != nil else { return }
        finishWorkspaceDrag()
    }

    // MARK: - Visuals

    private func beginDragVisuals(for drag: SidebarWorkspaceDrag) {
        // Floating snapshot of the card follows the cursor vertically.
        // Snapshot before adding the dim veil so it isn't baked in.
        if let rep = contentDocumentView.bitmapImageRepForCachingDisplay(in: drag.rowFrame) {
            contentDocumentView.cacheDisplay(in: drag.rowFrame, to: rep)
            let image = NSImage(size: drag.rowFrame.size)
            image.addRepresentation(rep)
            let snapshot = NSImageView(frame: drag.rowFrame)
            snapshot.image = image
            snapshot.imageScaling = .scaleNone
            snapshot.wantsLayer = true
            snapshot.alphaValue = 0.9
            snapshot.layer?.shadowColor = NSColor.black.cgColor
            snapshot.layer?.shadowOpacity = 0.5
            snapshot.layer?.shadowRadius = 8
            snapshot.layer?.shadowOffset = .zero
            dragSnapshotView = snapshot
        }

        // Card-shaped veil dimming the original row.
        let dim = SidebarBackgroundView(frame: drag.rowFrame)
        dim.wantsLayer = true
        dim.layer?.backgroundColor = NSColor(red: 0.11, green: 0.11, blue: 0.14, alpha: 0.6).cgColor
        dim.layer?.cornerRadius = 8
        contentDocumentView.addSubview(dim)
        dragDimView = dim
        if let snapshot = dragSnapshotView { contentDocumentView.addSubview(snapshot) }

        let indicator = SidebarBackgroundView()
        indicator.wantsLayer = true
        indicator.layer?.backgroundColor = Self.accentColor.cgColor
        indicator.layer?.cornerRadius = 1
        indicator.isHidden = true
        contentDocumentView.addSubview(indicator)
        dragInsertionView = indicator

        NSCursor.closedHand.set()

        // Escape cancels the drag. The view is not first responder during
        // tracking, so watch key events with a local monitor.
        dragKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            var consumed = false
            MainActor.assumeIsolated {
                guard let self, self.workspaceDrag?.isDragging == true else { return }
                self.cancelWorkspaceDrag()
                consumed = true
            }
            return consumed ? nil : event
        }
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
        indicator.frame = NSRect(
            x: SidebarExpandedMetrics.workspaceInsetX,
            y: y - 1,
            width: bounds.width - SidebarExpandedMetrics.workspaceInsetX * 2,
            height: 2
        )
        indicator.isHidden = false
    }

    /// Tear down drag state/visuals and apply any sidebar update that was
    /// deferred while the drag was in flight.
    private func finishWorkspaceDrag() {
        workspaceDrag = nil
        dragSnapshotView?.removeFromSuperview()
        dragSnapshotView = nil
        dragDimView?.removeFromSuperview()
        dragDimView = nil
        dragInsertionView?.removeFromSuperview()
        dragInsertionView = nil
        if let monitor = dragKeyMonitor {
            NSEvent.removeMonitor(monitor)
            dragKeyMonitor = nil
        }
        NSCursor.arrow.set()
        if let deferred = deferredDragUpdate {
            deferredDragUpdate = nil
            update(profiles: deferred.profiles, workspaces: deferred.workspaces, activity: deferred.activity)
        }
    }
}
