import AppKit

/// The block of a task past its space's budget: why on a line, then
/// Continue, Fresh start and Close…, which arm like Allow / Deny.
@MainActor
struct SidebarBudgetBlockRenderer {
    let offer: SidebarBudgetOffer
    let workspaceIndex: Int
    /// Left edge and width of the card's content.
    let x: CGFloat
    let width: CGFloat
    let top: CGFloat

    func render() -> SidebarApprovalBlockRenderer.Result {
        let metrics = SidebarExpandedMetrics.self
        let line = NSTextField(labelWithString: "Past its \(UsageText.tokens(offer.budget)) budget: follow-ups wait")
        line.font = Theme.Font.caption
        line.textColor = Theme.Color.textSecondary
        line.lineBreakMode = .byTruncatingTail
        line.toolTip = "Its last 7 days passed the space's budget (Space Settings › Defaults): Nirux types no follow-up "
            + "round. Continue or Fresh start lifts it for this task for 7 days; Fresh start shows only while its agents rest."
        line.frame = NSRect(x: x, y: top - metrics.actionLineHeight, width: width, height: metrics.actionLineHeight)
        var views: [NSView] = [line]
        var hitAreas: [SidebarHitArea] = []
        var buttons: [String: SidebarBadgeView] = [:]
        let bottom = top - metrics.actionLineHeight - metrics.buttonHeight
        var right = x + width
        for choice in offer.choices.reversed() {
            let button = SidebarActionButton.secondary(choice.title, label: choice.accessibilityLabel)
            button.frame = NSRect(x: right - button.fittingWidth, y: bottom, width: button.fittingWidth, height: metrics.buttonHeight)
            right = button.frame.minX - metrics.buttonGap
            views.append(button)
            let region = SidebarHitRegion.budgetChoice(workspaceIndex: workspaceIndex, offer: offer, choice: choice)
            if let key = SidebarView.armedButtonKey(for: region) { buttons[key] = button }
            hitAreas.append(SidebarHitArea(frame: button.frame.insetBy(dx: -3, dy: -3), region: region))
        }
        // Between the buttons a click does nothing.
        let buttonsLine = NSRect(x: x, y: bottom - 3, width: width, height: metrics.buttonHeight + 6)
        hitAreas.append(SidebarHitArea(frame: buttonsLine, region: .actionBlock(workspaceIndex: workspaceIndex)))
        return SidebarApprovalBlockRenderer.Result(views: views, hitAreas: hitAreas, buttons: buttons)
    }
}
