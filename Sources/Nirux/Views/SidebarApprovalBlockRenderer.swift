import AppKit

/// The Allow / Deny block under a column holding a permission request
/// (see `PermissionApproval`): the request's exact text, then the buttons,
/// or the decision on its way.
@MainActor
struct SidebarApprovalBlockRenderer {
    struct Result {
        let views: [NSView]
        let hitAreas: [SidebarHitArea]
        /// Keyed by `SidebarHoverTarget.approvalButtonKey`.
        let buttons: [String: SidebarBadgeView]
        /// Top of the next row.
        let bottomY: CGFloat
    }

    let approval: SidebarPermissionApproval
    let workspaceIndex: Int
    let columnIndex: Int
    /// Left edge and width of the card's content.
    let x: CGFloat
    let width: CGFloat
    let top: CGFloat

    func render() -> Result {
        let metrics = SidebarExpandedMetrics.self
        let height = metrics.approvalBlockHeight(for: approval)
        var views: [NSView] = [background(height: height), requestText()]
        var hitAreas: [SidebarHitArea] = []
        var buttons: [String: SidebarBadgeView] = [:]

        let buttonsY = top - height + metrics.approvalInset
        if let sent = approval.sent {
            let status = NSTextField(labelWithString: sent == .allow ? "Allowing…" : "Denying…")
            status.font = .systemFont(ofSize: 10.5, weight: .medium)
            status.textColor = NSColor.white.withAlphaComponent(0.55)
            status.frame = NSRect(x: x, y: buttonsY + 2, width: width, height: 16)
            views.append(status)
        } else {
            let description = "\(approval.toolName): \(approval.text)"
            let allow = button("Allow", color: .systemGreen, toolTip: "Allow once: \(description)")
            allow.frame = NSRect(x: x, y: buttonsY, width: metrics.approvalButtonWidth, height: metrics.approvalButtonHeight)
            let deny = button("Deny", color: .systemRed, toolTip: "Deny: \(description)")
            deny.frame = allow.frame.offsetBy(dx: metrics.approvalButtonWidth + 8, dy: 0)
            for (button, behavior) in [(allow, PermissionApproval.Behavior.allow), (deny, .deny)] {
                views.append(button)
                buttons[SidebarHoverTarget.approvalButtonKey(requestID: approval.requestID, behavior: behavior)] = button
                hitAreas.append(SidebarHitArea(
                    frame: button.frame.insetBy(dx: -3, dy: -3),
                    region: .permissionDecision(
                        workspaceIndex: workspaceIndex, columnIndex: columnIndex,
                        requestID: approval.requestID, behavior: behavior
                    )
                ))
            }
        }
        return Result(
            views: views, hitAreas: hitAreas, buttons: buttons, bottomY: top - height - metrics.approvalBottomGap
        )
    }

    private func background(height: CGFloat) -> NSView {
        let background = SidebarBackgroundView(frame: NSRect(x: x - 7, y: top - height, width: width + 14, height: height))
        background.wantsLayer = true
        background.layer?.cornerRadius = 6
        background.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.07).cgColor
        background.layer?.borderWidth = 1
        background.layer?.borderColor = NSColor.systemOrange.withAlphaComponent(0.28).cgColor
        return background
    }

    /// Every character, split only into fixed-width lines.
    private func requestText() -> NSTextField {
        let metrics = SidebarExpandedMetrics.self
        let lines = metrics.approvalLines(approval.text)
        let textHeight = CGFloat(lines.count) * metrics.approvalLineHeight
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = metrics.approvalLineHeight
        paragraph.maximumLineHeight = metrics.approvalLineHeight
        paragraph.lineBreakMode = .byClipping
        let text = NSTextField(labelWithAttributedString: NSAttributedString(
            string: lines.joined(separator: "\n"),
            attributes: [
                .font: metrics.approvalFont,
                .foregroundColor: NSColor.white.withAlphaComponent(0.9),
                .paragraphStyle: paragraph
            ]
        ))
        text.maximumNumberOfLines = lines.count
        text.frame = NSRect(x: x, y: top - metrics.approvalInset - textHeight, width: width, height: textHeight)
        text.toolTip = "\(approval.toolName): \(approval.text) — answer in the terminal for more options"
        text.setAccessibilityLabel("\(approval.toolName) permission request: \(approval.text)")
        return text
    }

    private func button(_ title: String, color: NSColor, toolTip: String) -> SidebarBadgeView {
        let button = SidebarBadgeView(
            text: title,
            textColor: color.withAlphaComponent(0.9),
            fillColor: color.withAlphaComponent(0.14),
            font: .systemFont(ofSize: 11, weight: .semibold)
        )
        button.hoverTextColor = color
        button.hoverFillColor = color.withAlphaComponent(0.28)
        button.toolTip = toolTip
        button.setAccessibilityRole(.button)
        button.setAccessibilityLabel(title)
        return button
    }
}
