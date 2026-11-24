import AppKit

/// The block of a Claude column at rest whose context costs to go on with
/// (`ContextOffer`): why on a line, then Compact and Fresh start, which arm
/// like Allow / Deny.
@MainActor
struct SidebarContextOfferBlockRenderer {
    let offer: ContextOffer
    let workspaceIndex: Int
    let columnIndex: Int
    /// Left edge and width of the card's content.
    let x: CGFloat
    let width: CGFloat
    let top: CGFloat

    func render() -> SidebarApprovalBlockRenderer.Result {
        let metrics = SidebarExpandedMetrics.self
        let line = NSTextField(labelWithString: offer.text)
        line.font = Theme.Font.caption
        line.textColor = Theme.Color.textSecondary
        line.lineBreakMode = .byTruncatingTail
        line.toolTip = ContextOffer.toolTip
        line.frame = NSRect(x: x, y: top - metrics.actionLineHeight, width: width, height: metrics.actionLineHeight)
        var views: [NSView] = [line]
        var hitAreas: [SidebarHitArea] = []
        var buttons: [String: SidebarBadgeView] = [:]
        let bottom = top - metrics.height(of: .contextOffer(columnIndex: columnIndex, offer), width: width, textWidth: width)
        var right = x + width
        for choice in [ContextOffer.Choice.freshStart, .compact] {
            let button = SidebarActionButton.secondary(choice.title, label: choice.accessibilityLabel)
            button.toolTip = ContextOffer.toolTip
            button.frame = NSRect(x: right - button.fittingWidth, y: bottom, width: button.fittingWidth, height: metrics.buttonHeight)
            right = button.frame.minX - metrics.buttonGap
            views.append(button)
            let region = SidebarHitRegion.contextOffer(workspaceIndex: workspaceIndex, columnIndex: columnIndex, offer: offer, choice: choice)
            if let key = SidebarView.armedButtonKey(for: region) { buttons[key] = button }
            hitAreas.append(SidebarHitArea(frame: button.frame.insetBy(dx: -3, dy: -3), region: region))
        }
        // Between the buttons a click does nothing.
        let buttonsLine = NSRect(x: x, y: bottom - 3, width: width, height: metrics.buttonHeight + 6)
        hitAreas.append(SidebarHitArea(frame: buttonsLine, region: .actionBlock(workspaceIndex: workspaceIndex)))
        return SidebarApprovalBlockRenderer.Result(views: views, hitAreas: hitAreas, buttons: buttons)
    }
}
