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
        guard let status = resume.status else {
            let button = SidebarActionButton.secondary(
                "Resume", symbol: Theme.Symbol.resume, label: "Resume: type “continue” into claude"
            )
            return SidebarButtonRow.render(
                button,
                key: SidebarHoverTarget.resumeButtonKey(workspaceIndex: workspaceIndex, columnIndex: columnIndex, failedAt: failedAt),
                region: .agentResume(workspaceIndex: workspaceIndex, columnIndex: columnIndex, failedAt: failedAt),
                workspaceIndex: workspaceIndex, x: x, width: width, top: top
            ) { errorLine(y: $0, width: $1) }
        }
        let metrics = SidebarExpandedMetrics.self
        let height = metrics.resumeBlockHeight(for: resume)
        return SidebarApprovalBlockRenderer.Result(
            views: [errorLine(y: top - metrics.actionLineHeight, width: width), self.status(status, y: top - height)],
            hitAreas: [SidebarHitArea(
                frame: NSRect(x: x, y: top - height, width: width, height: height), region: .actionBlock(workspaceIndex: workspaceIndex)
            )],
            buttons: [:]
        )
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

/// The block of a card whose Claude turn went silent: Interrupt, which
/// presses Esc in its terminal, never Enter.
@MainActor
struct SidebarInterruptBlockRenderer {
    let since: TimeInterval
    let workspaceIndex: Int
    let columnIndex: Int
    /// Left edge and width of the card's content.
    let x: CGFloat
    let width: CGFloat
    let top: CGFloat

    func render() -> SidebarApprovalBlockRenderer.Result {
        let button = SidebarActionButton.secondary(
            "Interrupt", symbol: Theme.Symbol.interrupt, label: "Interrupt: press Esc in claude's terminal"
        )
        return SidebarButtonRow.render(
            button,
            key: SidebarHoverTarget.interruptButtonKey(workspaceIndex: workspaceIndex, columnIndex: columnIndex, since: since),
            region: .agentInterrupt(workspaceIndex: workspaceIndex, columnIndex: columnIndex, since: since),
            workspaceIndex: workspaceIndex, x: x, width: width, top: top
        ) { y, width in
            let hint = NSTextField(labelWithString: "Esc stops the turn")
            hint.font = Theme.Font.caption
            hint.textColor = Theme.Color.textSecondary
            hint.lineBreakMode = .byTruncatingTail
            hint.toolTip = AgentAttentionReason.silentAdvice
            hint.frame = NSRect(x: x, y: y - 1, width: max(0, width), height: SidebarExpandedMetrics.actionLineHeight + 2)
            return hint
        }
    }
}

/// A line, then a button at its trailing edge, one button high: Resume's
/// and Interrupt's blocks. `line` gets its baseline row's y and width.
@MainActor
enum SidebarButtonRow {
    static func render(
        _ button: SidebarBadgeView, key: String, region: SidebarHitRegion, workspaceIndex: Int,
        x: CGFloat, width: CGFloat, top: CGFloat, line: (_ y: CGFloat, _ width: CGFloat) -> NSView
    ) -> SidebarApprovalBlockRenderer.Result {
        let metrics = SidebarExpandedMetrics.self
        let buttonWidth = button.fittingWidth
        button.frame = NSRect(x: x + width - buttonWidth, y: top - metrics.buttonHeight, width: buttonWidth, height: metrics.buttonHeight)
        let text = line(top - (metrics.buttonHeight + metrics.actionLineHeight) / 2, button.frame.minX - Theme.Space.sm - x)
        return SidebarApprovalBlockRenderer.Result(
            views: [text, button],
            hitAreas: [
                SidebarHitArea(frame: button.frame.insetBy(dx: -3, dy: -3), region: region),
                SidebarHitArea(
                    frame: NSRect(x: x, y: top - metrics.buttonHeight, width: width, height: metrics.buttonHeight),
                    region: .actionBlock(workspaceIndex: workspaceIndex)
                )
            ],
            buttons: [key: button]
        )
    }
}
