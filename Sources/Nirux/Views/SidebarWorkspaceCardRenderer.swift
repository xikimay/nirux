import AppKit

struct SidebarWorkspaceCardRenderResult {
    let bottomY: CGFloat
    let views: [NSView]
    let hitAreas: [SidebarHitArea]
    /// Initially-clear overlay covering the row — SidebarView tints it
    /// while the pointer is anywhere over the row.
    let cardHoverView: NSView
    /// The "⋯" action badge — brightens while directly hovered.
    let menuBadge: SidebarBadgeView?
    /// Initially-clear backing view per column chip (keyed by column index)
    /// for the chip hover highlight.
    let columnHoverViews: [Int: NSView]
    /// Allow / Deny and Resume buttons, keyed like `SidebarHoverTarget`'s
    /// button keys.
    let approvalButtons: [String: SidebarBadgeView]
}

/// A task row (`SidebarCardLayout`): the state mark, the title and the time,
/// then the status line; the selected row's columns; then the action block.
/// No border: the selected row is tinted, the others light under the
/// pointer. An archived row that asks nothing is one line.
@MainActor
final class SidebarWorkspaceCardRenderer {
    typealias Metrics = SidebarExpandedMetrics

    private let layout: SidebarCardLayout
    private let yOffset: CGFloat

    private var views: [NSView] = []
    private var hitAreas: [SidebarHitArea] = []
    private var menuBadge: SidebarBadgeView?
    private var columnHoverViews: [Int: NSView] = [:]
    private var approvalButtons: [String: SidebarBadgeView] = [:]

    private var workspace: WorkspaceInfo { layout.workspace }

    init(workspace: WorkspaceInfo, sidebarWidth: CGFloat, yOffset: CGFloat) {
        layout = SidebarCardLayout(workspace: workspace, sidebarWidth: sidebarWidth)
        self.yOffset = yOffset
    }

    func render() -> SidebarWorkspaceCardRenderResult {
        let frame = NSRect(
            x: layout.cardX, y: yOffset - layout.height, width: layout.cardWidth, height: layout.height
        )
        if workspace.isActive {
            let selected = SidebarBackgroundView(frame: frame)
            selected.wantsLayer = true
            selected.layer?.cornerRadius = Theme.Radius.card
            selected.layer?.backgroundColor = Theme.Color.fillSelected.cgColor
            append(selected)
        }
        let cardHover = SidebarBackgroundView(frame: frame)
        cardHover.wantsLayer = true
        cardHover.layer?.cornerRadius = layout.isCompact ? Theme.Radius.control : Theme.Radius.card
        append(cardHover)
        if layout.isCompact {
            buildCompactRow(frame: frame)
        } else {
            buildRow(frame: frame)
        }
        // Last: the first area under the pointer takes the click.
        hitAreas.append(SidebarHitArea(frame: frame, region: .workspace(workspace.index)))

        return SidebarWorkspaceCardRenderResult(
            bottomY: frame.minY,
            views: views,
            hitAreas: hitAreas,
            cardHoverView: cardHover,
            menuBadge: menuBadge,
            columnHoverViews: columnHoverViews,
            approvalButtons: approvalButtons
        )
    }

    // MARK: - Row

    private func buildRow(frame: NSRect) {
        var top = frame.maxY - Metrics.rowPaddingY
        buildTitleRow(top: top)
        top -= Metrics.titleRowHeight + Metrics.statusGap
        let statusLink = buildStatusLine(top: top)
        top -= Metrics.statusRowHeight
        let lineCount = max(layout.chipRows.count, layout.links.isEmpty ? 0 : 1)
        var chipAreas: [SidebarHitArea] = []
        if lineCount > 0 { top -= Metrics.columnsGap }
        for line in 0..<lineCount {
            if line == 0 { buildLinks(top: top) }
            if line < layout.chipRows.count {
                chipAreas += buildChips(layout.chipRows[line], top: top)
            }
            top -= Metrics.chipHeight + (line < lineCount - 1 ? Metrics.chipGap : 0)
        }
        buildActionBlock(top: top)
        hitAreas += chipAreas
        if let statusLink { hitAreas.append(statusLink) }
    }

    private func buildTitleRow(top: CGFloat) {
        let rowY = top - Metrics.titleRowHeight
        buildMark(layout.summary.mark, centerY: rowY + Metrics.titleRowHeight / 2)

        var maxX = layout.contentMaxX
        if let trailing = trailingLabel() {
            trailing.frame = NSRect(
                x: maxX - trailing.fittingSize.width, y: rowY,
                width: trailing.fittingSize.width, height: Metrics.titleRowHeight
            )
            append(trailing)
            maxX = trailing.frame.minX - Theme.Space.sm
        }
        let badge = menuButton(frame: NSRect(
            x: maxX - Metrics.menuButtonWidth, y: rowY + (Metrics.titleRowHeight - Metrics.menuButtonHeight) / 2,
            width: Metrics.menuButtonWidth, height: Metrics.menuButtonHeight
        ))

        let title = textLabel(workspace.title, font: Theme.Font.title, color: Theme.Color.textPrimary)
        title.toolTip = titleToolTip()
        title.frame = NSRect(
            x: layout.indentX, y: rowY,
            width: max(0, badge.frame.minX - Theme.Space.sm - layout.indentX), height: Metrics.titleRowHeight + 1
        )
        append(title)
    }

    /// The time since the last activity (how long it has waited, how long
    /// the turn has run), or the pull request a "Ready to merge" or
    /// "Merged" line doesn't name.
    private func trailingLabel() -> NSTextField? {
        // The selected row's links name the pull request already.
        let numbersPullRequest = layout.summary.trailing?.hasPrefix("#") == true
        guard let text = numbersPullRequest && !layout.links.isEmpty
            ? workspace.lastActivityAt.map({ SidebarView.cardAge(since: $0) }) : layout.summary.trailing
        else { return nil }
        let label = textLabel(text, font: Theme.Font.caption, color: Theme.Color.textTertiary)
        label.alignment = .right
        if text.hasPrefix("#") {
            label.toolTip = workspace.prInfo.map(SidebarRenderer.pullRequestToolTip)
        } else {
            let description = text == "now" ? "Last activity less than a minute ago" : "Last activity \(text) ago"
            label.toolTip = description
            label.setAccessibilityLabel(description)
        }
        return label
    }

    /// The title's tooltip: what the row doesn't print — the branch, the
    /// changes, the phase, the purpose, the last summary, the next step.
    private func titleToolTip() -> String {
        var lines = [workspace.title]
        if let branch = workspace.gitBranch { lines.append("Branch: \(branch)") }
        if let stats = workspace.diffStats { lines.append("Changes: \(SidebarRenderer.formatDiffStats(stats))") }
        lines.append("Phase: \(workspace.phase.displayName)")
        if let purpose = workspace.purpose { lines.append("Purpose: \(purpose)") }
        if let summary = workspace.lastSummary { lines.append("Last: \(summary)") }
        // The selected row prints the next step, every row its blocker.
        if let action = workspace.sidebarAction, !workspace.isActive, !action.isBlocker { lines.append(action.text) }
        if workspace.lastActivityAt == nil { lines.append("No activity yet") }
        return lines.joined(separator: "\n")
    }

    /// The sign in the state marks' column: amber for the user, red for
    /// something broken, a breathing green dot for work, a speech bubble
    /// for a question to the parent, a check, the merge sign, else grey.
    private func buildMark(_ mark: SidebarRowMark, centerY: CGFloat) {
        let centerX = Metrics.markCenterX
        func symbol(_ name: String, _ color: NSColor, _ label: String) {
            let icon = SidebarImageView(image: SidebarRenderer.symbol(name, color: color, pointSize: 11))
            icon.frame = NSRect(x: centerX - 7, y: centerY - 7, width: 14, height: 14)
            icon.setAccessibilityLabel(label)
            append(icon)
        }
        let color: NSColor
        switch mark {
        case .asking: return symbol(Theme.Symbol.question, Theme.Color.textSecondary, "Asking")
        case .readyToMerge: return symbol(Theme.Symbol.checksPassed, Theme.Color.success, "Ready to merge")
        case .merged: return symbol(Theme.Symbol.merged, Theme.Color.done, "Pull request merged")
        case .needsYou: color = Theme.Color.waiting
        case .error: color = Theme.Color.error
        case .working: color = Theme.Color.working
        case .idle: color = Theme.Color.idle
        }
        let size = Metrics.stateDotSize
        let dot = SidebarBackgroundView(frame: NSRect(x: centerX - size / 2, y: centerY - size / 2, width: size, height: size))
        dot.wantsLayer = true
        dot.layer?.cornerRadius = size / 2
        dot.layer?.backgroundColor = color.cgColor
        if mark == .working { Self.breathe(dot.layer) }
        append(dot)
    }

    /// The working dot breathes, in phase with every other one: a rebuild
    /// doesn't restart it.
    static func breathe(_ layer: CALayer?) {
        guard let layer, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 1.0
        animation.toValue = 0.35
        animation.duration = 0.9
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        animation.timeOffset = CACurrentMediaTime().truncatingRemainder(dividingBy: animation.duration * 2)
        // A slow fade all day long: no need for 120 frames a second.
        animation.preferredFrameRateRange = CAFrameRateRange(minimum: 8, maximum: 15, preferred: 12)
        layer.add(animation, forKey: "breathe")
    }

    // MARK: - Status line

    /// "Needs you · npm run migrate" in amber, "Stopped on an API error"
    /// in red, "Working", "Asking web-main", "#39 · checks passed", "Ready
    /// to merge", "Merged · Clean up", else the branch. A line that does
    /// something (the Mission question popover, the pull request, Clean
    /// up) is a link as wide as its text.
    private func buildStatusLine(top: CGFloat) -> SidebarHitArea? {
        let status = layout.summary.status
        let label = NSTextField.sidebarLine(Self.statusText(status))
        let x = layout.indentX
        label.frame = NSRect(x: x, y: top - Metrics.statusRowHeight, width: layout.contentMaxX - x, height: Metrics.statusRowHeight)
        label.toolTip = statusToolTip(status)
        append(label)
        guard let action = status.action else { return nil }
        let url: String
        switch action {
        case .missionQuestion(let columnIndex):
            url = SidebarView.missionQuestionActionURL(workspaceIndex: workspace.index, columnIndex: columnIndex)
        case .open(let target):
            url = SidebarView.openActionURL(workspaceIndex: workspace.index, url: target)
        case .cleanUp:
            url = SidebarView.cleanupActionURL(workspaceIndex: workspace.index)
        }
        let width = min(label.frame.width, ceil(label.attributedStringValue.size().width) + 4)
        return SidebarHitArea(
            frame: NSRect(x: label.frame.minX - 2, y: label.frame.minY - 2, width: width + 2, height: label.frame.height + 4),
            region: .link(url: url, label: label)
        )
    }

    static func statusText(_ status: SidebarStatusLine) -> NSAttributedString {
        let font = status.tone == .branch ? Theme.Font.mono : Theme.Font.body
        let color: NSColor = switch status.tone {
        case .needsYou: Theme.Color.waiting
        case .error: Theme.Color.error
        case .neutral, .branch: Theme.Color.textSecondary
        }
        let text = NSMutableAttributedString(string: status.text, attributes: [.font: font, .foregroundColor: color])
        if status.action == .cleanUp, let range = status.text.range(of: "Clean up") {
            text.addAttribute(.foregroundColor, value: Theme.Color.accent, range: NSRange(range, in: status.text))
        }
        return text
    }

    /// What the line can't hold: the whole question, the pull request,
    /// what Clean up does, what the agent waits on.
    private func statusToolTip(_ status: SidebarStatusLine) -> String {
        switch status.action {
        case .missionQuestion(let columnIndex)?:
            guard let question = workspace.columns.first(where: { $0.index == columnIndex })?.missionQuestion else {
                return status.text
            }
            return "\(question.text)\n\n\(question.explanation) Click to answer."
        case .open?:
            return workspace.prInfo.map(SidebarRenderer.pullRequestToolTip) ?? status.text
        case .cleanUp?:
            return "Clean Up Worktree…: checks, then asks before deleting this worktree’s folder and "
                + "local branch and closing the workspaces open in it. The remote branch is kept."
        case nil:
            let asking = workspace.columns.first { $0.attention == .waiting || $0.attention == .error }
            return [status.text, asking?.attentionToolTip].compactMap { $0 }.joined(separator: "\n")
        }
    }

    /// The pull request's links, right-aligned on the first chip line.
    private func buildLinks(top: CGFloat) {
        let rowY = top - Metrics.chipHeight
        var x = layout.contentMaxX - layout.links.reduce(CGFloat(0)) { $0 + $1.width }
            - SidebarCardLayout.linkGaps(layout.links)
        for link in layout.links {
            let label = NSTextField.sidebarLine(link.text, lineBreakMode: .byClipping)
            let height = ceil(label.fittingSize.height)
            label.frame = NSRect(x: x - 2, y: rowY + (Metrics.chipHeight - height) / 2, width: link.width + 4, height: height)
            label.toolTip = link.toolTip
            append(label)
            hitAreas.append(SidebarHitArea(
                frame: NSRect(x: x - 2, y: rowY, width: link.width + 4, height: Metrics.chipHeight),
                region: .link(url: link.url, label: label)
            ))
            x += link.width + Theme.Space.xs
        }
    }

    private func buildChips(_ row: [SidebarCardLayout.ChipPlacement], top: CGFloat) -> [SidebarHitArea] {
        let rowY = top - Metrics.chipHeight
        var areas: [SidebarHitArea] = []
        let maxWidth = layout.contentMaxX - layout.indentX
        for placement in row {
            let chip = placement.chip
            let frame = NSRect(
                x: layout.indentX + placement.x, y: rowY,
                width: min(chip.width, maxWidth - placement.x), height: Metrics.chipHeight
            )
            let background = SidebarBackgroundView(frame: frame)
            background.wantsLayer = true
            background.layer?.cornerRadius = Theme.Radius.chip
            background.layer?.backgroundColor = chip.fillColor.cgColor
            append(background)
            // Initially clear, tinted by SidebarView while the pointer is
            // over this chip.
            let hover = SidebarBackgroundView(frame: frame)
            hover.wantsLayer = true
            hover.layer?.cornerRadius = Theme.Radius.chip
            append(hover)
            columnHoverViews[chip.column.index] = hover

            let label = NSTextField.sidebarLine(chip.text, lineBreakMode: .byClipping)
            let height = ceil(label.fittingSize.height)
            label.frame = NSRect(
                x: frame.minX + Metrics.chipPaddingX - 2, y: rowY + (Metrics.chipHeight - height) / 2,
                width: max(0, frame.width - Metrics.chipPaddingX * 2) + 4, height: height
            )
            label.toolTip = chip.toolTip
            label.setAccessibilityLabel(chip.accessibilityLabel)
            append(label)
            if let deferred = chip.column.deferredAgent {
                areas += buildResumeChip(deferred, columnIndex: chip.column.index, frame: frame)
                continue
            }
            // A focused column that waits or broke keeps a sign of focus.
            if chip.column.isFocused, [.waiting, .error].contains(chip.style) {
                background.layer?.borderWidth = 1
                background.layer?.borderColor = Theme.Color.accent.withAlphaComponent(0.6).cgColor
            }
            areas.append(SidebarHitArea(
                frame: frame.insetBy(dx: -Metrics.chipGap / 2, dy: -2),
                region: .column(workspaceIndex: workspace.index, columnIndex: chip.column.index)
            ))
        }
        return areas
    }

    /// A restored agent that hasn't resumed: "Resume" starts it here,
    /// armed and hovered like Allow / Deny; its icon focuses the column, as
    /// the row did around the button.
    private func buildResumeChip(_ deferred: SidebarDeferredAgent, columnIndex: Int, frame: NSRect) -> [SidebarHitArea] {
        let iconWidth = Metrics.chipPaddingX + 12 + Theme.Space.xs / 2
        let (icon, resume) = frame.divided(atDistance: iconWidth, from: .minXEdge)
        let button = SidebarBadgeView(text: "", textColor: .clear, fillColor: .clear, font: Theme.Font.caption)
        button.frame = resume
        button.cornerRadius = Theme.Radius.chip
        button.hoverFillColor = Theme.Color.accent.withAlphaComponent(0.14)
        button.toolTip = deferred.tooltip
        button.setAccessibilityRole(.button)
        button.setAccessibilityLabel("Resume \(deferred.processName) here")
        views.last?.setAccessibilityElement(false)
        append(button)
        approvalButtons[SidebarHoverTarget.deferredResumeButtonKey(columnID: deferred.columnID)] = button
        return [
            SidebarHitArea(
                frame: NSRect(x: resume.minX, y: resume.minY - 2, width: resume.width + Metrics.chipGap / 2, height: resume.height + 4),
                region: .deferredAgentResume(workspaceIndex: workspace.index, columnIndex: columnIndex, columnID: deferred.columnID)
            ),
            SidebarHitArea(
                frame: NSRect(x: icon.minX - Metrics.chipGap / 2, y: icon.minY - 2, width: icon.width + Metrics.chipGap / 2, height: icon.height + 4),
                region: .column(workspaceIndex: workspace.index, columnIndex: columnIndex)
            )
        ]
    }

    // MARK: - Action block

    /// Approvals, Resume, the blocker, Clean up, then what's next: under
    /// line 3, after a separator unless it only says something.
    private func buildActionBlock(top: CGFloat) {
        let actions = layout.actions
        guard !actions.isEmpty else { return }
        var top = top
        if actions.allSatisfy(\.isQuiet) {
            top -= Metrics.quietBlockGap
        } else {
            top -= Metrics.actionBlockGap
            let separator = SidebarBackgroundView(frame: NSRect(
                x: layout.contentX, y: top - 1, width: layout.contentMaxX - layout.contentX, height: 1
            ))
            separator.wantsLayer = true
            separator.layer?.backgroundColor = Theme.Color.line.cgColor
            append(separator)
            top -= 1 + Metrics.actionBlockGap
        }
        for (position, action) in actions.enumerated() {
            if position > 0 { top -= Metrics.actionRowGap }
            buildAction(action, top: top)
            top -= Metrics.height(of: action)
        }
    }

    private func buildAction(_ action: SidebarCardAction, top: CGFloat) {
        let x = layout.contentX
        let width = layout.contentMaxX - layout.contentX
        switch action {
        case let .approval(columnIndex, agent, approval):
            add(SidebarApprovalBlockRenderer(
                approval: approval, agent: agent, workspaceIndex: workspace.index, columnIndex: columnIndex,
                x: x, width: width, top: top
            ).render())
        case let .resume(columnIndex, kind, detail, failedAt, resume):
            add(SidebarResumeBlockRenderer(
                kind: kind, detail: detail, failedAt: failedAt, resume: resume,
                workspaceIndex: workspace.index, columnIndex: columnIndex, x: x, width: width, top: top
            ).render())
        case .blocker(let text):
            let label = textLabel(text, font: Theme.Font.caption, color: Theme.Color.error)
            label.toolTip = text
            label.frame = NSRect(x: x, y: top - Metrics.actionLineHeight, width: width, height: Metrics.actionLineHeight)
            append(label)
        case .reviewBadges(let badges):
            let indent = layout.indentX
            let prefix = textLabel("Reviews", font: Theme.Font.caption, color: Theme.Color.textTertiary)
            prefix.frame = NSRect(x: indent, y: top - Metrics.actionLineHeight, width: prefix.fittingSize.width, height: Metrics.actionLineHeight)
            append(prefix)
            let badgesX = prefix.frame.maxX + Theme.Space.sm
            append(SidebarReviewBadgesRow.label(
                badges, x: badgesX, width: layout.contentMaxX - badgesX, top: top
            ))
        case .next(let text):
            let label = NSTextField.sidebarLine(Self.nextText(text))
            label.toolTip = "Next: \(text)"
            label.frame = NSRect(
                x: layout.indentX, y: top - Metrics.actionLineHeight,
                width: layout.contentMaxX - layout.indentX, height: Metrics.actionLineHeight
            )
            append(label)
        }
    }

    private static func nextText(_ text: String) -> NSAttributedString {
        let font = Theme.Font.caption
        let result = NSMutableAttributedString(string: "Next", attributes: [
            .font: font, .foregroundColor: Theme.Color.textTertiary
        ])
        result.append(SidebarColumnChip.spacer(6))
        result.append(NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: Theme.Color.textSecondary
        ]))
        return result
    }

    private func add(_ block: SidebarApprovalBlockRenderer.Result) {
        views += block.views
        hitAreas += block.hitAreas
        approvalButtons.merge(block.buttons) { _, new in new }
    }

    // MARK: - Compact row

    /// An archived workspace: its state, its title, its merged PR or age.
    private func buildCompactRow(frame: NSRect) {
        let midY = frame.midY
        buildMark(layout.state == .done ? .merged : .idle, centerY: midY)

        var maxX = layout.contentMaxX
        let trailing: NSTextField?
        if layout.state == .done, let number = workspace.prInfo?.number {
            trailing = textLabel("#\(number)", font: Theme.Font.caption, color: Theme.Color.textTertiary)
        } else {
            trailing = trailingLabel()
        }
        if let trailing {
            let width = trailing.fittingSize.width
            let height = ceil(trailing.fittingSize.height)
            trailing.frame = NSRect(x: maxX - width, y: midY - height / 2, width: width, height: height)
            append(trailing)
            maxX = trailing.frame.minX - Theme.Space.sm
        }
        let badge = menuButton(frame: NSRect(
            x: maxX - Metrics.menuButtonWidth, y: midY - Metrics.menuButtonHeight / 2,
            width: Metrics.menuButtonWidth, height: Metrics.menuButtonHeight
        ))

        let titleX = layout.indentX
        let title = textLabel(workspace.title, font: Theme.Font.body, color: Theme.Color.textSecondary)
        title.toolTip = titleToolTip()
        let height = ceil(title.fittingSize.height)
        title.frame = NSRect(x: titleX, y: midY - height / 2, width: max(0, badge.frame.minX - Theme.Space.sm - titleX), height: height)
        append(title)
    }

    // MARK: - Pieces

    /// "⋯": the workspace menu, shown while the pointer is over the row; it
    /// answers clicks either way.
    private func menuButton(frame: NSRect) -> SidebarBadgeView {
        let badge = SidebarBadgeView(text: "", textColor: Theme.Color.textSecondary, fillColor: .clear, font: Theme.Font.caption)
        badge.frame = frame
        badge.symbolName = Theme.Symbol.more
        badge.hoverTextColor = Theme.Color.textPrimary
        badge.hoverFillColor = Theme.Color.fillPressed
        badge.hidesUntilHover = true
        badge.toolTip = "Workspace actions"
        badge.setAccessibilityRole(.button)
        badge.setAccessibilityLabel("Workspace actions")
        menuBadge = badge
        append(badge)
        hitAreas.append(SidebarHitArea(frame: frame.insetBy(dx: -4, dy: -2), region: .workspaceMenu(workspace.index)))
        return badge
    }

    private func textLabel(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    private func append(_ view: NSView) {
        views.append(view)
    }
}

/// An image drawn in its frame, aspect kept; clicks go through to the
/// sidebar's hit areas.
final class SidebarImageView: NSView {
    private let image: NSImage?

    init(image: NSImage?) {
        self.image = image
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .image }

    override func draw(_ dirtyRect: NSRect) {
        guard let image, image.size.width > 0, image.size.height > 0 else { return }
        let scale = min(bounds.width / image.size.width, bounds.height / image.size.height, 1)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        image.draw(in: NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                              width: size.width, height: size.height))
    }
}

/// The action block's buttons.
@MainActor
enum SidebarActionButton {
    /// Allow: the one action the block recommends.
    static func primary(_ title: String, label: String) -> SidebarBadgeView {
        let button = SidebarBadgeView(
            text: title, textColor: Theme.Color.canvas, fillColor: Theme.Color.accent,
            font: NSFont.systemFont(ofSize: Theme.Font.caption.pointSize, weight: .semibold)
        )
        button.hoverFillColor = Theme.Color.tint(Theme.Color.textPrimary, 0.18, over: Theme.Color.accent)
        return configured(button, label: label)
    }

    static func secondary(_ title: String, symbol: String? = nil, label: String) -> SidebarBadgeView {
        let button = SidebarBadgeView(
            text: title, textColor: Theme.Color.textPrimary, fillColor: Theme.Color.fillHover,
            font: NSFont.systemFont(ofSize: Theme.Font.caption.pointSize, weight: .medium)
        )
        button.symbolName = symbol
        button.borderColor = Theme.Color.lineStrong
        button.hoverFillColor = Theme.Color.fillPressed
        return configured(button, label: label)
    }

    private static func configured(_ button: SidebarBadgeView, label: String) -> SidebarBadgeView {
        button.cornerRadius = Theme.Radius.control
        button.toolTip = label
        button.setAccessibilityRole(.button)
        button.setAccessibilityLabel(label)
        return button
    }
}
