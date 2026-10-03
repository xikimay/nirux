import AppKit

/// The block of a card whose Claude turn failed on an API error: the
/// error, then Resume (which types `continue`), `continue` on its way, or
/// why Resume waits.
@MainActor
struct SidebarResumeBlockRenderer {
    let kind: String?
    let detail: String?
    let failedAt: TimeInterval
    let resume: SidebarStuckState.Resume
    let workspaceIndex: Int
    let columnIndex: Int
    /// Left edge and width of the card's content.
    let x: CGFloat
    let width: CGFloat
    let top: CGFloat

    func render() -> SidebarApprovalBlockRenderer.Result {
        let metrics = SidebarExpandedMetrics.self
        let height = metrics.resumeBlockHeight(for: resume)
        let blockFrame = NSRect(x: x, y: top - height, width: width, height: height)
        var views: [NSView] = []
        var hitAreas: [SidebarHitArea] = []
        var buttons: [String: SidebarBadgeView] = [:]

        if let status = resume.status {
            views.append(errorLine(y: top - metrics.actionLineHeight, width: width))
            views.append(self.status(status, y: top - height))
        } else {
            let button = SidebarActionButton.secondary(
                "Resume", symbol: Theme.Symbol.resume, label: "Resume: type “continue” into claude"
            )
            let buttonWidth = button.fittingWidth
            button.frame = NSRect(x: x + width - buttonWidth, y: top - height, width: buttonWidth, height: metrics.buttonHeight)
            views.append(errorLine(
                y: top - (metrics.buttonHeight + metrics.actionLineHeight) / 2,
                width: button.frame.minX - Theme.Space.sm - x
            ))
            views.append(button)
            buttons[SidebarHoverTarget.resumeButtonKey(
                workspaceIndex: workspaceIndex, columnIndex: columnIndex, failedAt: failedAt
            )] = button
            hitAreas.append(SidebarHitArea(
                frame: button.frame.insetBy(dx: -3, dy: -3),
                region: .agentResume(workspaceIndex: workspaceIndex, columnIndex: columnIndex, failedAt: failedAt)
            ))
        }
        hitAreas.append(SidebarHitArea(frame: blockFrame, region: .actionBlock(workspaceIndex: workspaceIndex)))
        return SidebarApprovalBlockRenderer.Result(views: views, hitAreas: hitAreas, buttons: buttons)
    }

    /// "rate_limit"; "rate_limit — API Error: 429 …" in the tooltip.
    private func errorLine(y: CGFloat, width: CGFloat) -> NSTextField {
        let metrics = SidebarExpandedMetrics.self
        let font = Theme.Font.caption
        let text = [kind ?? "error", detail].compactMap { $0 }.joined(separator: " — ")
        let line = NSMutableAttributedString()
        // The kind fits the line; the error as the terminal showed it is in
        // the tooltip.
        let shown = kind ?? detail ?? "error"
        if let icon = SidebarRenderer.symbol(Theme.Symbol.agentError, color: Theme.Color.error) {
            line.append(SidebarColumnChip.attachment(icon, side: 12, font: font))
            line.append(SidebarColumnChip.spacer(6))
        }
        line.append(NSAttributedString(string: shown, attributes: [.font: font, .foregroundColor: Theme.Color.error]))
        let label = NSTextField.sidebarLine(line)
        label.frame = NSRect(x: x, y: y - 1, width: max(0, width), height: metrics.actionLineHeight + 2)
        label.toolTip = text
        label.setAccessibilityLabel("Claude stopped on an API error: \(text)")
        return label
    }

    private func status(_ text: String, y: CGFloat) -> NSTextField {
        let status = NSTextField(labelWithString: text)
        status.font = Theme.Font.caption
        status.textColor = resume == .sending ? Theme.Color.textTertiary : Theme.Color.textSecondary
        status.lineBreakMode = .byTruncatingTail
        status.frame = NSRect(x: x, y: y, width: width, height: SidebarExpandedMetrics.actionLineHeight)
        return status
    }
}
