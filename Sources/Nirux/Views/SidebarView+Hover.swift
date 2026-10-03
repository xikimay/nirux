import AppKit

// MARK: - Card / column / "⋯" badge / rail tile hover highlights

extension SidebarView {
    /// Swap the card/column/badge hover highlight to a new target. Hovering
    /// any sub-region of a card keeps the whole card tinted; the badge and
    /// column rows add their own accent on top.
    func setHoverTarget(_ target: SidebarHoverTarget?) {
        guard hoveredTarget != target else { return }
        applyHover(hoveredTarget, on: false)
        applyHover(target, on: true)
        hoveredTarget = target
        updateRailTooltip()
    }

    private func applyHover(_ target: SidebarHoverTarget?, on: Bool) {
        guard let target else { return }
        railTileViews[target]?.isHovered = on
        if let workspaceIndex = target.workspaceIndex {
            cardHoverViews[workspaceIndex]?.layer?.backgroundColor =
                on ? Theme.Color.fillHover.cgColor : NSColor.clear.cgColor
            menuBadgeViews[workspaceIndex]?.isCardHovered = on
        }
        switch target {
        case .workspaceCard, .railButton:
            break
        case .spaceHeader:
            // The whole header is one menu trigger, so its "⋯" brightens
            // together with the background tint.
            spaceHeaderHoverView?.layer?.backgroundColor =
                on ? Theme.Color.fillHover.cgColor : NSColor.clear.cgColor
            spaceHeaderBadge?.isHovered = on
        case .menuBadge(let workspaceIndex):
            menuBadgeViews[workspaceIndex]?.isHovered = on
        case .columnRow(let workspaceIndex, let columnIndex):
            columnHoverViews[workspaceIndex]?[columnIndex]?.layer?.backgroundColor =
                on ? Theme.Color.fillHover.cgColor : NSColor.clear.cgColor
        case .approvalButton(_, let key):
            approvalButtonViews[key]?.isHovered = on
        }
    }

    /// The card under `point`, whatever region of it is on top.
    func cardIndex(at point: NSPoint) -> Int? {
        for area in hitAreas where area.frame.contains(point) {
            if case .workspace(let index) = area.region { return index }
        }
        return nil
    }

    /// Re-derive the hover highlight from the live mouse position. Called
    /// after every rebuild — the registered backing views are new, and rows
    /// may have shifted under a stationary pointer.
    func refreshHoverTargetFromMouse() {
        guard let window else { return }
        let point = contentDocumentView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard let area = hitArea(at: point) else { return }
        switch area.region {
        case .spaceHeader:
            setHoverTarget(.spaceHeader)
        case .workspace(let workspaceIndex):
            setHoverTarget(.workspaceCard(workspaceIndex))
        case .workspaceMenu(let workspaceIndex):
            setHoverTarget(.menuBadge(workspaceIndex))
        case .column(let workspaceIndex, let columnIndex):
            setHoverTarget(.columnRow(workspaceIndex: workspaceIndex, columnIndex: columnIndex))
        case .permissionDecision(let workspaceIndex, _, _, _), .agentResume(let workspaceIndex, _, _),
             .deferredAgentResume(let workspaceIndex, _, _):
            if let key = Self.armedButtonKey(for: area.region) {
                setHoverTarget(.approvalButton(workspaceIndex: workspaceIndex, key: key))
            }
        case .actionBlock(let workspaceIndex):
            setHoverTarget(.workspaceCard(workspaceIndex))
        case .link:
            if let card = cardIndex(at: point) { setHoverTarget(.workspaceCard(card)) }
        case .railButton(let button):
            setHoverTarget(.railButton(button))
        }
    }
}
