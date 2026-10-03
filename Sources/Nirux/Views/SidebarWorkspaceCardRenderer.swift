import AppKit

struct SidebarWorkspaceCardRenderResult {
    let bottomY: CGFloat
    let views: [NSView]
    let hitAreas: [SidebarHitArea]
    /// Initially-clear overlay covering the card — SidebarView tints it
    /// while the pointer is anywhere over the card.
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

/// A workspace card (`SidebarCardLayout`): state, title and age / branch
/// and diff / column chips and the pull request, then the action block.
/// An inactive workspace that asks nothing is one line.
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
        let cardHover = SidebarBackgroundView(frame: frame)
        cardHover.wantsLayer = true
        if layout.isCompact {
            cardHover.layer?.cornerRadius = Theme.Radius.control
            append(cardHover)
            buildCompactRow(frame: frame)
        } else {
            append(cardBackground(frame: frame))
            // Above the card background, below all content.
            cardHover.layer?.cornerRadius = Theme.Radius.card
            append(cardHover)
            buildCard(frame: frame)
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

    // MARK: - Card

    private func buildCard(frame: NSRect) {
        var top = frame.maxY - Metrics.cardPaddingY
        buildTitleRow(top: top)
        top -= Metrics.titleRowHeight
        if layout.showsBranchRow {
            top -= Metrics.cardRowGap
            buildBranchRow(top: top)
            top -= Metrics.branchRowHeight
        }
        let lineCount = max(layout.chipRows.count, layout.links.isEmpty ? 0 : 1)
        var chipAreas: [SidebarHitArea] = []
        if lineCount > 0 { top -= Metrics.cardRowGap + Metrics.chipRowTopGap }
        for line in 0..<lineCount {
            if line == 0 { buildLinks(top: top) }
            if line < layout.chipRows.count {
                chipAreas += buildChips(layout.chipRows[line], top: top)
            }
            top -= Metrics.chipHeight + (line < lineCount - 1 ? Metrics.chipGap : 0)
        }
        buildActionBlock(top: top)
        hitAreas += chipAreas
    }

    private func buildTitleRow(top: CGFloat) {
        let rowY = top - Metrics.titleRowHeight
        buildStateIndicator(centerY: rowY + Metrics.titleRowHeight / 2, x: layout.contentX)

        var maxX = layout.contentMaxX
        if let age = ageLabel() {
            age.frame = NSRect(x: maxX - age.fittingSize.width, y: rowY, width: age.fittingSize.width, height: Metrics.titleRowHeight)
            append(age)
            maxX = age.frame.minX - Theme.Space.sm
        }
        let badge = menuButton(revealed: workspace.isActive, frame: NSRect(
            x: maxX - Metrics.menuButtonWidth, y: rowY + (Metrics.titleRowHeight - Metrics.menuButtonHeight) / 2,
            width: Metrics.menuButtonWidth, height: Metrics.menuButtonHeight
        ))

        let titleX = layout.contentX + Metrics.stateDotSize + Theme.Space.sm
        let isQuiet = !workspace.isActive && [.idle, .done].contains(layout.state)
        let title = textLabel(
            workspace.title, font: Theme.Font.title,
            color: isQuiet ? Theme.Color.textSecondary : Theme.Color.textPrimary
        )
        title.toolTip = titleToolTip()
        title.frame = NSRect(x: titleX, y: rowY, width: max(0, badge.frame.minX - Theme.Space.sm - titleX), height: Metrics.titleRowHeight + 1)
        append(title)
    }

    /// Time since the last activity; amber while the workspace waits on
    /// the user, since that's how long it has.
    private func ageLabel() -> NSTextField? {
        guard let lastActivityAt = workspace.lastActivityAt else { return nil }
        let age = SidebarView.cardAge(since: lastActivityAt)
        let label = textLabel(
            age, font: Theme.Font.caption,
            color: layout.state == .waiting ? Theme.Color.waiting : Theme.Color.textTertiary
        )
        label.alignment = .right
        let description = age == "now" ? "Last activity less than a minute ago" : "Last activity \(age) ago"
        label.toolTip = description
        label.setAccessibilityLabel(description)
        return label
    }

    /// The title's tooltip: what the card doesn't print — the phase, the
    /// purpose, the last summary, another card's next step.
    private func titleToolTip() -> String {
        var lines = [workspace.title, "Phase: \(workspace.phase.displayName)"]
        if let purpose = workspace.purpose { lines.append("Purpose: \(purpose)") }
        if let summary = workspace.lastSummary { lines.append("Last: \(summary)") }
        // The selected card prints the next step, every card its blocker.
        if let action = workspace.sidebarAction, !workspace.isActive, !action.isBlocker { lines.append(action.text) }
        if workspace.lastActivityAt == nil { lines.append("No activity yet") }
        return lines.joined(separator: "\n")
    }

    private func buildStateIndicator(centerY: CGFloat, x: CGFloat) {
        let size = Metrics.stateDotSize
        let color: NSColor
        switch layout.state {
        case .done:
            let icon = SidebarImageView(image: SidebarRenderer.symbol(Theme.Symbol.merged, color: Theme.Color.done))
            icon.frame = NSRect(x: x - 2, y: centerY - 6, width: 12, height: 12)
            icon.setAccessibilityLabel("Pull request merged")
            append(icon)
            return
        case .working: color = Theme.Color.working
        case .waiting: color = Theme.Color.waiting
        case .error: color = Theme.Color.error
        case .idle: color = Theme.Color.idle
        }
        if layout.state == .waiting {
            let halo = SidebarBackgroundView(frame: NSRect(x: x - 3, y: centerY - size / 2 - 3, width: size + 6, height: size + 6))
            halo.wantsLayer = true
            halo.layer?.cornerRadius = (size + 6) / 2
            halo.layer?.backgroundColor = Theme.Color.waiting.withAlphaComponent(0.22).cgColor
            append(halo)
        }
        let dot = SidebarBackgroundView(frame: NSRect(x: x, y: centerY - size / 2, width: size, height: size))
        dot.wantsLayer = true
        dot.layer?.cornerRadius = size / 2
        dot.layer?.backgroundColor = color.cgColor
        if layout.state == .working { Self.breathe(dot.layer) }
        append(dot)
    }

    /// The working dot breathes, in phase with every other one: a rebuild
    /// doesn't restart it.
    private static func breathe(_ layer: CALayer?) {
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

    private func buildBranchRow(top: CGFloat) {
        let rowY = top - Metrics.branchRowHeight
        var maxX = layout.contentMaxX
        if let stats = workspace.diffStats {
            let diff = NSTextField.sidebarLine(SidebarRenderer.diffAttributedString(stats), lineBreakMode: .byClipping)
            let width = ceil(diff.fittingSize.width)
            diff.frame = NSRect(x: maxX - width, y: rowY, width: width, height: Metrics.branchRowHeight)
            diff.toolTip = "\(SidebarRenderer.formatDiffStats(stats)) — show the diff"
            append(diff)
            hitAreas.append(SidebarHitArea(
                frame: diff.frame.insetBy(dx: -2, dy: -2),
                region: .link(url: SidebarView.diffActionURL(workspaceIndex: workspace.index), label: diff)
            ))
            maxX = diff.frame.minX - Theme.Space.sm
        }
        if let branchName = workspace.gitBranch {
            let branch = textLabel(branchName, font: Theme.Font.mono, color: Theme.Color.textSecondary)
            branch.toolTip = branchName
            branch.frame = NSRect(x: layout.indentX, y: rowY, width: max(0, maxX - layout.indentX), height: Metrics.branchRowHeight)
            append(branch)
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
                areas.append(buildResumeChip(deferred, columnIndex: chip.column.index, frame: frame))
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

    /// A restored agent that hasn't resumed: its chip is Resume, which
    /// starts it here, and is armed and hovered like Allow / Deny.
    private func buildResumeChip(_ deferred: SidebarDeferredAgent, columnIndex: Int, frame: NSRect) -> SidebarHitArea {
        let button = SidebarBadgeView(text: "", textColor: .clear, fillColor: .clear, font: Theme.Font.caption)
        button.frame = frame
        button.cornerRadius = Theme.Radius.chip
        button.hoverFillColor = Theme.Color.accent.withAlphaComponent(0.14)
        button.toolTip = deferred.tooltip
        button.setAccessibilityRole(.button)
        button.setAccessibilityLabel("Resume \(deferred.processName) here")
        views.last?.setAccessibilityElement(false)
        append(button)
        approvalButtons[SidebarHoverTarget.deferredResumeButtonKey(columnID: deferred.columnID)] = button
        return SidebarHitArea(
            frame: frame.insetBy(dx: -Metrics.chipGap / 2, dy: -2),
            region: .deferredAgentResume(workspaceIndex: workspace.index, columnIndex: columnIndex, columnID: deferred.columnID)
        )
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
        case let .cleanup(offer, number):
            buildCleanup(offer, pullRequest: number, top: top)
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

    /// "PR merged", then "Clean up": the ⋯ menu's "Clean Up Worktree…",
    /// with the same checks and confirmation. "Cleaning up…" while one
    /// runs, which does nothing.
    private func buildCleanup(_ offer: MergedCleanupOffer, pullRequest number: Int, top: CGFloat) {
        let rowY = top - Metrics.actionLineHeight
        let merged = textLabel("PR merged", font: Theme.Font.caption, color: Theme.Color.done)
        merged.toolTip = "Pull request #\(number) merged"
        merged.frame = NSRect(x: layout.contentX, y: rowY, width: merged.fittingSize.width, height: Metrics.actionLineHeight)
        append(merged)
        let link: NSTextField
        switch offer {
        case .available:
            link = textLabel("Clean up", font: Theme.Font.caption, color: Theme.Color.accent)
            link.toolTip = "Clean Up Worktree…: checks, then asks before deleting this worktree’s folder and "
                + "local branch and closing the workspaces open in it. The remote branch is kept."
        case .inProgress:
            link = textLabel("Cleaning up…", font: Theme.Font.caption, color: Theme.Color.textTertiary)
        }
        let width = link.fittingSize.width
        link.alignment = .right
        link.frame = NSRect(x: layout.contentMaxX - width, y: rowY, width: width, height: Metrics.actionLineHeight)
        append(link)
        guard offer == .available else { return }
        hitAreas.append(SidebarHitArea(
            frame: link.frame.insetBy(dx: -2, dy: -2),
            region: .link(url: SidebarView.cleanupActionURL(workspaceIndex: workspace.index), label: link)
        ))
    }

    // MARK: - Compact row

    /// An inactive workspace: its state, its title, its merged PR or age.
    private func buildCompactRow(frame: NSRect) {
        let midY = frame.midY
        let x = layout.contentX
        if layout.state == .done {
            let icon = SidebarImageView(image: SidebarRenderer.symbol(Theme.Symbol.merged, color: Theme.Color.done))
            icon.frame = NSRect(x: x, y: midY - 6, width: 12, height: 12)
            icon.setAccessibilityLabel("Pull request merged")
            append(icon)
        } else {
            let dot = SidebarBackgroundView(frame: NSRect(x: x + 3, y: midY - 3, width: 6, height: 6))
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 3
            dot.layer?.backgroundColor = Theme.Color.idle.cgColor
            append(dot)
        }

        var maxX = layout.contentMaxX
        let trailing: NSTextField?
        if layout.state == .done, let number = workspace.prInfo?.number {
            trailing = textLabel("#\(number)", font: Theme.Font.mono, color: Theme.Color.done)
        } else {
            trailing = ageLabel()
        }
        if let trailing {
            let width = trailing.fittingSize.width
            let height = ceil(trailing.fittingSize.height)
            trailing.frame = NSRect(x: maxX - width, y: midY - height / 2, width: width, height: height)
            append(trailing)
            maxX = trailing.frame.minX - Theme.Space.sm
        }
        let badge = menuButton(revealed: false, frame: NSRect(
            x: maxX - Metrics.menuButtonWidth, y: midY - Metrics.menuButtonHeight / 2,
            width: Metrics.menuButtonWidth, height: Metrics.menuButtonHeight
        ))

        let titleX = x + 12 + Theme.Space.sm
        let title = textLabel(workspace.title, font: Theme.Font.body, color: Theme.Color.textSecondary)
        title.toolTip = titleToolTip()
        let height = ceil(title.fittingSize.height)
        title.frame = NSRect(x: titleX, y: midY - height / 2, width: max(0, badge.frame.minX - Theme.Space.sm - titleX), height: height)
        append(title)
    }

    // MARK: - Pieces

    /// "⋯": the workspace menu. Shown on the selected card, and on the
    /// others while the pointer is over them; it answers clicks either way.
    private func menuButton(revealed: Bool, frame: NSRect) -> SidebarBadgeView {
        let badge = SidebarBadgeView(text: "", textColor: Theme.Color.textSecondary, fillColor: .clear, font: Theme.Font.caption)
        badge.frame = frame
        badge.symbolName = Theme.Symbol.more
        badge.hoverTextColor = Theme.Color.textPrimary
        badge.hoverFillColor = Theme.Color.fillPressed
        badge.hidesUntilHover = !revealed
        badge.toolTip = "Workspace actions"
        badge.setAccessibilityRole(.button)
        badge.setAccessibilityLabel("Workspace actions")
        menuBadge = badge
        append(badge)
        hitAreas.append(SidebarHitArea(frame: frame.insetBy(dx: -4, dy: -3), region: .workspaceMenu(workspace.index)))
        return badge
    }

    private func cardBackground(frame: NSRect) -> SidebarBackgroundView {
        let background = SidebarBackgroundView(frame: frame)
        background.wantsLayer = true
        background.layer?.cornerRadius = Theme.Radius.card
        background.layer?.borderWidth = 1
        let surface = Theme.Color.surface
        switch (layout.state, workspace.isActive) {
        case (.waiting, let isSelected):
            background.layer?.backgroundColor = Theme.Color.tint(Theme.Color.waiting, 0.08, over: surface).cgColor
            background.layer?.borderColor = (isSelected ? Self.selectedBorder : Theme.Color.waiting.withAlphaComponent(0.5)).cgColor
        case (_, true):
            background.layer?.backgroundColor = Theme.Color.tint(Theme.Color.accent, 0.03, over: surface).cgColor
            background.layer?.borderColor = Self.selectedBorder.cgColor
        case (.error, false):
            background.layer?.backgroundColor = surface.cgColor
            background.layer?.borderColor = Theme.Color.error.withAlphaComponent(0.45).cgColor
        default:
            background.layer?.backgroundColor = surface.cgColor
            background.layer?.borderColor = Theme.Color.line.cgColor
        }
        return background
    }

    private static var selectedBorder: NSColor { Theme.Color.accent.withAlphaComponent(0.6) }

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
