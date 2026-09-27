import AppKit

/// The Allow / Deny block under a column holding a permission request
/// (see `PermissionApproval`): the request's exact text, then the buttons,
/// the decision on its way, or its failure.
@MainActor
struct SidebarApprovalBlockRenderer {
    struct Result {
        let views: [NSView]
        /// The buttons, then the whole block (inert): first match wins.
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
        let blockFrame = NSRect(x: x - 7, y: top - height, width: width + 14, height: height)
        var views: [NSView] = [background(frame: blockFrame), requestText()]
        var hitAreas: [SidebarHitArea] = []
        var buttons: [String: SidebarBadgeView] = [:]

        let buttonsY = top - height + metrics.approvalInset
        switch approval.display {
        case .open:
            // macOS order, the approving action last: Allow sits away from
            // where the row labels below start.
            let description = "\(approval.toolName): \(approval.text)"
            let deny = button("Deny", color: .systemRed, label: "Deny \(description)")
            deny.frame = NSRect(x: x, y: buttonsY, width: metrics.approvalButtonWidth, height: metrics.approvalButtonHeight)
            let allow = button("Allow", color: .systemGreen, label: "Allow once \(description)")
            allow.frame = deny.frame.offsetBy(dx: metrics.approvalButtonWidth + 8, dy: 0)
            for (button, behavior) in [(deny, PermissionApproval.Behavior.deny), (allow, .allow)] {
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
        case .sending(let behavior):
            views.append(status(behavior == .allow ? "Allowing…" : "Denying…", y: buttonsY, alpha: 0.55))
        case .undelivered:
            views.append(status("Not delivered — answer in the terminal", y: buttonsY, alpha: 0.75))
        }
        hitAreas.append(SidebarHitArea(frame: blockFrame, region: .permissionBlock(workspaceIndex: workspaceIndex)))
        return Result(
            views: views, hitAreas: hitAreas, buttons: buttons, bottomY: top - height - metrics.approvalBottomGap
        )
    }

    private func background(frame: NSRect) -> NSView {
        let background = SidebarBackgroundView(frame: frame)
        background.wantsLayer = true
        background.layer?.cornerRadius = 6
        background.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.07).cgColor
        background.layer?.borderWidth = 1
        background.layer?.borderColor = NSColor.systemOrange.withAlphaComponent(0.28).cgColor
        return background
    }

    private func status(_ text: String, y: CGFloat, alpha: CGFloat) -> NSTextField {
        let status = NSTextField(labelWithString: text)
        status.font = .systemFont(ofSize: 10.5, weight: .medium)
        status.textColor = NSColor.white.withAlphaComponent(alpha)
        status.lineBreakMode = .byTruncatingTail
        status.frame = NSRect(x: x, y: y + 2, width: width, height: 16)
        return status
    }

    /// Every character, split only into fixed-width lines.
    private func requestText() -> NSTextField {
        let metrics = SidebarExpandedMetrics.self
        let lines = metrics.approvalLines(approval.text)
        let textHeight = CGFloat(lines.count) * metrics.approvalLineHeight
        let text = NSTextField(labelWithAttributedString: Self.attributedLines(lines))
        text.maximumNumberOfLines = lines.count
        text.frame = NSRect(x: x, y: top - metrics.approvalInset - textHeight, width: width, height: textHeight)
        text.toolTip = "\(approval.toolName): \(approval.text) — answer in the terminal for more options"
        text.setAccessibilityLabel("\(approval.toolName) permission request: \(approval.text)")
        return text
    }

    /// The wrapped lines, with a space at either end of a line drawn as a
    /// dim "␣": a line break must never hide one (`rm -rf ./old *` split
    /// after `old` would otherwise read as `old*`). The text is printable
    /// ASCII (`AgentToolInput.isExactDisplay`), so the mark can't be
    /// mistaken for part of it.
    static func attributedLines(_ lines: [String]) -> NSAttributedString {
        let metrics = SidebarExpandedMetrics.self
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = metrics.approvalLineHeight
        paragraph.maximumLineHeight = metrics.approvalLineHeight
        paragraph.lineBreakMode = .byClipping
        let base: [NSAttributedString.Key: Any] = [
            .font: metrics.approvalFont,
            .foregroundColor: NSColor.white.withAlphaComponent(0.9),
            .paragraphStyle: paragraph
        ]
        var mark = base
        mark[.foregroundColor] = NSColor.white.withAlphaComponent(0.4)
        let result = NSMutableAttributedString()
        for (index, line) in lines.enumerated() {
            if index > 0 { result.append(NSAttributedString(string: "\n", attributes: base)) }
            for (position, character) in line.enumerated() {
                let atEdge = position == 0 || position == line.count - 1
                if character == " ", atEdge {
                    result.append(NSAttributedString(string: "\u{2423}", attributes: mark))
                } else {
                    result.append(NSAttributedString(string: String(character), attributes: base))
                }
            }
        }
        return result
    }

    private func button(_ title: String, color: NSColor, label: String) -> SidebarBadgeView {
        let button = SidebarBadgeView(
            text: title,
            textColor: color.withAlphaComponent(0.9),
            fillColor: color.withAlphaComponent(0.14),
            font: .systemFont(ofSize: 11, weight: .semibold)
        )
        button.hoverTextColor = color
        button.hoverFillColor = color.withAlphaComponent(0.28)
        button.toolTip = label
        button.setAccessibilityRole(.button)
        button.setAccessibilityLabel(label)
        return button
    }
}
