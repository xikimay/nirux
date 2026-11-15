import AppKit

/// The Allow / Deny block of a card whose column holds a permission
/// request (see `PermissionApproval`): who asks, the request's exact text,
/// then the buttons, the decision on its way, or its failure.
@MainActor
struct SidebarApprovalBlockRenderer {
    struct Result {
        let views: [NSView]
        /// The buttons, then the whole block (inert): first match wins.
        let hitAreas: [SidebarHitArea]
        /// Keyed by `SidebarHoverTarget.approvalButtonKey`.
        let buttons: [String: SidebarBadgeView]
    }

    let approval: SidebarPermissionApproval
    /// The agent's name, as its chip has it.
    let agent: String
    let workspaceIndex: Int
    let columnIndex: Int
    /// Left edge and width of the card's content.
    let x: CGFloat
    let width: CGFloat
    let top: CGFloat

    func render() -> Result {
        let metrics = SidebarExpandedMetrics.self
        let height = metrics.approvalBlockHeight(for: approval)
        let blockFrame = NSRect(x: x, y: top - height, width: width, height: height)
        var views: [NSView] = [header()]
        let boxHeight = metrics.approvalBoxHeight(for: approval)
        let boxTop = top - metrics.actionLineHeight - metrics.actionRowGap
        views.append(box(frame: NSRect(x: x, y: boxTop - boxHeight, width: width, height: boxHeight)))
        views.append(requestText(top: boxTop - metrics.approvalBoxPaddingY))
        var hitAreas: [SidebarHitArea] = []
        var buttons: [String: SidebarBadgeView] = [:]

        let buttonsY = top - height
        switch approval.display {
        case .open:
            // macOS order (`RequestChoices`), the approving action last, at
            // the right edge.
            var right = x + width
            var placed: [(SidebarBadgeView, PermissionApproval.Behavior)] = []
            for choice in RequestChoices.permission(approval).reversed() {
                guard case .permission(let behavior) = choice.choice else { continue }
                let button = choice.role == .primary
                    ? SidebarActionButton.primary(choice.title, label: choice.accessibilityLabel)
                    : SidebarActionButton.secondary(choice.title, label: choice.accessibilityLabel)
                let buttonWidth = max(button.fittingWidth, 56)
                button.frame = NSRect(x: right - buttonWidth, y: buttonsY, width: buttonWidth, height: metrics.buttonHeight)
                right = button.frame.minX - metrics.buttonGap
                placed.insert((button, behavior), at: 0)
            }
            // Read left to right: Deny, then Allow.
            for (button, behavior) in placed {
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
        case .sending:
            views.append(status(RequestChoices.permissionStatus(approval.display) ?? "", y: buttonsY, color: Theme.Color.textTertiary))
        case .undelivered:
            views.append(status(RequestChoices.permissionStatus(approval.display) ?? "", y: buttonsY, color: Theme.Color.textSecondary))
        }
        hitAreas.append(SidebarHitArea(frame: blockFrame, region: .actionBlock(workspaceIndex: workspaceIndex)))
        return Result(views: views, hitAreas: hitAreas, buttons: buttons)
    }

    /// "claude wants to run", or "claude wants WebFetch".
    private func header() -> NSTextField {
        let metrics = SidebarExpandedMetrics.self
        let font = Theme.Font.caption
        let text = NSMutableAttributedString()
        if let icon = SidebarRenderer.symbol(Theme.Symbol.permission, color: Theme.Color.waiting) {
            text.append(SidebarColumnChip.attachment(icon, side: 12, font: font))
            text.append(SidebarColumnChip.spacer(6))
        }
        // Short: the tool's name must survive a long agent name.
        let what = RequestChoices.permissionVerb(toolName: approval.toolName)
        text.append(NSAttributedString(string: "\(agent) \(what)", attributes: [
            .font: font, .foregroundColor: Theme.Color.textSecondary
        ]))
        let label = NSTextField.sidebarLine(text)
        label.frame = NSRect(x: x, y: top - metrics.actionLineHeight - 1, width: width, height: metrics.actionLineHeight + 2)
        return label
    }

    private func box(frame: NSRect) -> NSView {
        let box = SidebarBackgroundView(frame: frame)
        box.wantsLayer = true
        box.layer?.cornerRadius = Theme.Radius.control
        box.layer?.backgroundColor = Theme.Color.canvas.withAlphaComponent(0.6).cgColor
        box.layer?.borderWidth = 1
        box.layer?.borderColor = Theme.Color.line.cgColor
        return box
    }

    private func status(_ text: String, y: CGFloat, color: NSColor) -> NSTextField {
        let metrics = SidebarExpandedMetrics.self
        let status = NSTextField(labelWithString: text)
        status.font = Theme.Font.caption
        status.textColor = color
        status.lineBreakMode = .byTruncatingTail
        status.frame = NSRect(
            x: x, y: y + (metrics.buttonHeight - metrics.actionLineHeight) / 2, width: width, height: metrics.actionLineHeight
        )
        return status
    }

    /// Every character, split only into fixed-width lines.
    private func requestText(top: CGFloat) -> NSTextField {
        let metrics = SidebarExpandedMetrics.self
        let lines = metrics.approvalLines(approval.text)
        let textHeight = CGFloat(lines.count) * metrics.approvalLineHeight
        let text = NSTextField(labelWithAttributedString: Self.attributedLines(lines))
        text.maximumNumberOfLines = lines.count
        text.frame = NSRect(
            x: x + metrics.approvalBoxPaddingX, y: top - textHeight,
            width: width - metrics.approvalBoxPaddingX * 2 + 4, height: textHeight
        )
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
            .foregroundColor: Theme.Color.textPrimary,
            .paragraphStyle: paragraph
        ]
        var mark = base
        mark[.foregroundColor] = Theme.Color.textTertiary
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
}
