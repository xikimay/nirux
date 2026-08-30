import AppKit

// MARK: - Card / column / "⋯" badge hover highlights

extension SidebarView {
    /// Swap the card/column/badge hover highlight to a new target. Hovering
    /// any sub-region of a card keeps the whole card tinted; the badge and
    /// column rows add their own accent on top.
    func setHoverTarget(_ target: SidebarHoverTarget?) {
        guard hoveredTarget != target else { return }
        applyHover(hoveredTarget, on: false)
        applyHover(target, on: true)
        hoveredTarget = target
    }

    private func applyHover(_ target: SidebarHoverTarget?, on: Bool) {
        guard let target else { return }
        if let workspaceIndex = target.workspaceIndex {
            cardHoverViews[workspaceIndex]?.layer?.backgroundColor =
                on ? NSColor.white.withAlphaComponent(0.035).cgColor : NSColor.clear.cgColor
        }
        switch target {
        case .workspaceCard:
            break
        case .spaceHeader:
            // The whole header is one menu trigger, so its "⋯" brightens
            // together with the background tint.
            spaceHeaderHoverView?.layer?.backgroundColor =
                on ? NSColor.white.withAlphaComponent(0.05).cgColor : NSColor.clear.cgColor
            spaceHeaderBadge?.isHovered = on
        case .menuBadge(let workspaceIndex):
            menuBadgeViews[workspaceIndex]?.isHovered = on
        case .columnRow(let workspaceIndex, let columnIndex):
            columnHoverViews[workspaceIndex]?[columnIndex]?.layer?.backgroundColor =
                on ? NSColor.white.withAlphaComponent(0.06).cgColor : NSColor.clear.cgColor
        }
    }

    /// Re-derive the hover highlight from the live mouse position. Called
    /// after every rebuild — the registered backing views are new, and rows
    /// may have shifted under a stationary pointer.
    func refreshHoverTargetFromMouse() {
        guard isExpanded, let window else { return }
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
        case .link:
            break
        }
    }
}
