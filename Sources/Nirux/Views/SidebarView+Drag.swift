import AppKit

/// Geometry captured when a drag starts, in the scroll document view's
/// coordinate space. Frames stay valid for the whole gesture because
/// sidebar rebuilds are suspended while a drag is in flight.
struct SidebarWorkspaceDrag {
    let workspaceID: String      // stable identity — store indices can shift mid-drag
    let title: String            // shown on the floating ghost card
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
    private static let escapeKeyCode: UInt16 = 53
    /// nextEvent timeout: lets the loop notice a window that closed or a
    /// button that was released without a delivered mouseUp, instead of
    /// blocking the main thread forever.
    private static let eventTimeout: TimeInterval = 0.25

    private static let gestureEventMask: NSEvent.EventTypeMask = [
        .leftMouseDragged, .leftMouseUp, .keyDown, .keyUp, .periodic,
        .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp, .scrollWheel
    ]

    /// Called from mouseDown on a `.workspace` hit region. Runs a local
    /// event-tracking loop until mouseUp: a gesture that never leaves its
    /// original slot delivers the normal click, anything else becomes a
    /// reorder drag. Consuming the events here (instead of relying on
    /// mouseDragged/mouseUp delivery) also keeps the window-move machinery
    /// from seeing them — the sidebar's subviews report
    /// `mouseDownCanMoveWindow == true`.
    func trackWorkspaceDrag(workspaceIndex: Int, rowFrame: NSRect, startPoint: NSPoint) {
        guard let window else {
            onWorkspaceClicked?(workspaceIndex)
            return
        }
        guard var drag = makeWorkspaceDrag(workspaceIndex: workspaceIndex, rowFrame: rowFrame, startPoint: startPoint)
        else {
            deliverFallbackClick(workspaceIndex: workspaceIndex, window: window)
            return
        }
        workspaceDrag = drag
        var lastDragEvent: NSEvent?

        while true {
            guard let event = window.nextEvent(
                matching: Self.gestureEventMask,
                until: Date(timeIntervalSinceNow: Self.eventTimeout),
                inMode: .eventTracking,
                dequeue: true
            ) else {
                // Timeout tick: bail if the gesture can no longer finish.
                if !window.isVisible || NSEvent.pressedMouseButtons & 1 == 0 { break }
                continue
            }
            switch event.type {
            case .leftMouseDragged:
                lastDragEvent = event
                dragMoved(event, drag: &drag)
                workspaceDrag = drag
            case .periodic:
                // Keeps autoscroll running while the cursor holds still
                // past the sidebar edge.
                if drag.isDragging, let lastDragEvent {
                    dragMoved(lastDragEvent, drag: &drag)
                    workspaceDrag = drag
                }
            case .leftMouseUp:
                finishWorkspaceDrag()
                deliverDrop(drag)
                return
            case .keyDown where drag.isDragging:
                if event.keyCode == Self.escapeKeyCode {
                    finishWorkspaceDrag()
                    consumeGestureUntilMouseUp(window)
                    return
                }
                // Other keys are swallowed while the drag is modal.
            case .keyUp where drag.isDragging:
                break // swallowed symmetrically with the keyDowns above
            case .keyDown, .keyUp:
                // Not in drag mode (or a keyUp): a press on a card must
                // not eat typing — hand the event to normal dispatch.
                NSApp.sendEvent(event)
            default:
                break // swallow stray mouse/scroll during the gesture
            }
        }
        finishWorkspaceDrag()
    }

    private func makeWorkspaceDrag(workspaceIndex: Int, rowFrame: NSRect, startPoint: NSPoint) -> SidebarWorkspaceDrag? {
        guard let dragged = lastInfos.first(where: { $0.index == workspaceIndex }) else { return nil }
        let group = displayedWorkspaceInfos.filter { $0.isInactive == dragged.isInactive }
        let frames = group.compactMap { info in
            hitAreas.first { area in
                if case .workspace(let index) = area.region { return index == info.index }
                return false
            }?.frame
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
            guard hypot(point.x - drag.startPoint.x, point.y - drag.startPoint.y) > Self.dragThreshold else { return }
            drag.isDragging = true
            beginDragVisuals(for: drag)
            NSEvent.startPeriodicEvents(afterDelay: 0.15, withPeriod: 0.05)
        }
        contentDocumentView.autoscroll(with: event)
        dragGhostView?.frame.origin.y = drag.rowFrame.origin.y + (point.y - drag.startPoint.y)
        let slot = SidebarDragMath.insertionSlot(forY: point.y, rowMidYs: drag.groupRowFrames.map(\.midY))
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
        if drag.isDragging,
           let slot = drag.currentSlot,
           let target = SidebarDragMath.targetPosition(slot: slot, draggedPosition: drag.position) {
            onWorkspaceReordered?(currentIndex, target)
        } else {
            onWorkspaceClicked?(currentIndex)
        }
    }

    /// Geometry capture failed — behave like a plain click, but still
    /// swallow the gesture so window-move can't grab it. Updates apply
    /// live during the wait, so re-resolve the workspace by id.
    private func deliverFallbackClick(workspaceIndex: Int, window: NSWindow) {
        let clickedID = lastInfos.first { $0.index == workspaceIndex }?.id
        consumeGestureUntilMouseUp(window)
        if let clickedID {
            if let current = lastInfos.first(where: { $0.id == clickedID })?.index {
                onWorkspaceClicked?(current)
            }
        } else {
            onWorkspaceClicked?(workspaceIndex)
        }
    }

    private func consumeGestureUntilMouseUp(_ window: NSWindow) {
        while true {
            guard let event = window.nextEvent(
                matching: Self.gestureEventMask,
                until: Date(timeIntervalSinceNow: Self.eventTimeout),
                inMode: .eventTracking,
                dequeue: true
            ) else {
                if !window.isVisible || NSEvent.pressedMouseButtons & 1 == 0 { return }
                continue
            }
            switch event.type {
            case .leftMouseUp:
                return
            case .keyDown, .keyUp:
                // No drag is modal here — don't eat typing.
                NSApp.sendEvent(event)
            default:
                break
            }
        }
    }

    // MARK: - Visuals

    private func beginDragVisuals(for drag: SidebarWorkspaceDrag) {
        // Card-shaped veil dimming the original row.
        let dim = SidebarBackgroundView(frame: drag.rowFrame)
        dim.wantsLayer = true
        dim.layer?.backgroundColor = NSColor(red: 0.11, green: 0.11, blue: 0.14, alpha: 0.6).cgColor
        dim.layer?.cornerRadius = 8
        contentDocumentView.addSubview(dim)
        dragDimView = dim

        // Lightweight ghost card that follows the cursor. Built from
        // scratch rather than snapshotted: the card chrome lives in layer
        // properties, which cacheDisplay does not reliably composite.
        let ghost = SidebarBackgroundView(frame: drag.rowFrame)
        ghost.wantsLayer = true
        ghost.layer?.backgroundColor = NSColor(red: 0.16, green: 0.16, blue: 0.20, alpha: 0.95).cgColor
        ghost.layer?.cornerRadius = 8
        ghost.layer?.borderWidth = 1
        ghost.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        ghost.layer?.shadowColor = NSColor.black.cgColor
        ghost.layer?.shadowOpacity = 0.5
        ghost.layer?.shadowRadius = 8
        ghost.layer?.shadowOffset = .zero

        let title = NSTextField(labelWithString: drag.title)
        title.font = .monospacedSystemFont(ofSize: 14, weight: .bold)
        title.textColor = NSColor.white.withAlphaComponent(0.92)
        title.lineBreakMode = .byTruncatingTail
        let inset = SidebarExpandedMetrics.padding - SidebarExpandedMetrics.workspaceInsetX
        title.frame = NSRect(
            x: inset,
            y: drag.rowFrame.height - SidebarExpandedMetrics.workspacePaddingY - SidebarExpandedMetrics.titleHeight,
            width: drag.rowFrame.width - inset * 2,
            height: SidebarExpandedMetrics.titleHeight
        )
        ghost.addSubview(title)
        contentDocumentView.addSubview(ghost)
        dragGhostView = ghost

        let indicator = SidebarBackgroundView()
        indicator.wantsLayer = true
        indicator.layer?.backgroundColor = Self.accentColor.cgColor
        indicator.layer?.cornerRadius = 1
        indicator.isHidden = true
        contentDocumentView.addSubview(indicator)
        dragInsertionView = indicator

        NSCursor.closedHand.set()
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

    /// Tear down drag state/visuals, then repair whatever was suppressed
    /// mid-drag: apply the deferred data update, or redo a skipped
    /// layout()-driven rebuild.
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
            update(profiles: deferred.profiles, workspaces: deferred.workspaces, activity: deferred.activity)
        } else if rebuildSkippedDuringDrag {
            rebuildContent()
        }
        rebuildSkippedDuringDrag = false
    }
}
