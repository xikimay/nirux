import AppKit

/// The block under a column whose Claude turn failed on an API error: the
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
        let height = metrics.resumeBlockHeight
        let blockFrame = NSRect(x: x - 7, y: top - height, width: width + 14, height: height)
        var views: [NSView] = [background(frame: blockFrame), errorLine()]
        var hitAreas: [SidebarHitArea] = []
        var buttons: [String: SidebarBadgeView] = [:]

        let buttonsY = top - height + metrics.approvalInset
        if let status = resume.status {
            views.append(self.status(status, x: x, y: buttonsY, width: width, alpha: resume == .sending ? 0.55 : 0.7))
        } else {
            let button = resumeButton()
            button.frame = NSRect(x: x, y: buttonsY, width: metrics.resumeButtonWidth, height: metrics.approvalButtonHeight)
            views.append(button)
            let region = SidebarHitRegion.agentResume(
                workspaceIndex: workspaceIndex, columnIndex: columnIndex, failedAt: failedAt
            )
            buttons[SidebarHoverTarget.resumeButtonKey(
                workspaceIndex: workspaceIndex, columnIndex: columnIndex, failedAt: failedAt
            )] = button
            hitAreas.append(SidebarHitArea(frame: button.frame.insetBy(dx: -3, dy: -3), region: region))
            let offset = metrics.resumeButtonWidth + 8
            views.append(status("types “continue”", x: x + offset, y: buttonsY, width: width - offset, alpha: 0.4))
        }
        hitAreas.append(SidebarHitArea(frame: blockFrame, region: .actionBlock(workspaceIndex: workspaceIndex)))
        return SidebarApprovalBlockRenderer.Result(
            views: views, hitAreas: hitAreas, buttons: buttons, bottomY: top - height - metrics.approvalBottomGap
        )
    }

    private func background(frame: NSRect) -> NSView {
        let background = SidebarBackgroundView(frame: frame)
        background.wantsLayer = true
        background.layer?.cornerRadius = 6
        background.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.07).cgColor
        background.layer?.borderWidth = 1
        background.layer?.borderColor = NSColor.systemRed.withAlphaComponent(0.28).cgColor
        return background
    }

    /// "rate_limit — API Error: 429 …", cut to one line; whole in the tooltip.
    private func errorLine() -> NSTextField {
        let metrics = SidebarExpandedMetrics.self
        let text = [kind ?? "error", detail].compactMap { $0 }.joined(separator: " — ")
        let label = NSTextField(labelWithString: text)
        label.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        label.textColor = NSColor.white.withAlphaComponent(0.8)
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(
            x: x, y: top - metrics.approvalInset - metrics.resumeLineHeight, width: width, height: metrics.resumeLineHeight
        )
        label.toolTip = text
        label.setAccessibilityLabel("Claude stopped on an API error: \(text)")
        return label
    }

    private func status(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat, alpha: CGFloat) -> NSTextField {
        let status = NSTextField(labelWithString: text)
        status.font = .systemFont(ofSize: 10.5, weight: .medium)
        status.textColor = NSColor.white.withAlphaComponent(alpha)
        status.lineBreakMode = .byTruncatingTail
        status.frame = NSRect(x: x, y: y + 2, width: max(0, width), height: 16)
        return status
    }

    private func resumeButton() -> SidebarBadgeView {
        let color = NSColor.niruxAccent
        let label = "Resume: type “continue” into claude"
        let button = SidebarBadgeView(
            text: "Resume",
            textColor: color.withAlphaComponent(0.95),
            fillColor: color.withAlphaComponent(0.16),
            font: .systemFont(ofSize: 11, weight: .semibold)
        )
        button.hoverTextColor = color
        button.hoverFillColor = color.withAlphaComponent(0.3)
        button.toolTip = label
        button.setAccessibilityRole(.button)
        button.setAccessibilityLabel(label)
        return button
    }
}
