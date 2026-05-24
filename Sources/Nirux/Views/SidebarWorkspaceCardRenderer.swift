import AppKit

struct SidebarWorkspaceCardRenderResult {
    let bottomY: CGFloat
    let views: [NSView]
    let hitAreas: [SidebarHitArea]
}

@MainActor
final class SidebarWorkspaceCardRenderer {
    private let workspace: WorkspaceInfo
    private let sidebarWidth: CGFloat
    private let padding: CGFloat
    private let yOffset: CGFloat

    private var views: [NSView] = []
    private var hitAreas: [SidebarHitArea] = []

    init(workspace: WorkspaceInfo, sidebarWidth: CGFloat, padding: CGFloat, yOffset: CGFloat) {
        self.workspace = workspace
        self.sidebarWidth = sidebarWidth
        self.padding = padding
        self.yOffset = yOffset
    }

    func render() -> SidebarWorkspaceCardRenderResult {
        var currentY = yOffset
        let rowTopY = currentY
        let rowX = SidebarExpandedMetrics.workspaceInsetX
        let rowW = sidebarWidth - SidebarExpandedMetrics.workspaceInsetX * 2
        let contentX = padding
        let contentW = sidebarWidth - padding * 2

        let background = cardBackground()
        append(background)

        let accentBar = SidebarBackgroundView()
        if workspace.isActive {
            accentBar.wantsLayer = true
            accentBar.layer?.backgroundColor = SidebarView.accentColor.cgColor
            accentBar.layer?.cornerRadius = 1.5
            append(accentBar)
        }

        currentY -= SidebarExpandedMetrics.workspacePaddingY
        currentY = buildTitleRow(contentX: contentX, contentW: contentW, yOffset: currentY)
        currentY = buildBranchRowIfNeeded(contentX: contentX, contentW: contentW, yOffset: currentY)
        currentY = buildMetadataRows(contentX: contentX, yOffset: currentY)
        currentY -= SidebarExpandedMetrics.columnGap
        currentY = buildColumnEntries(columns: workspace.columns, yOffset: currentY, padding: contentX)
        currentY -= SidebarExpandedMetrics.workspacePaddingY

        let rowHeight = rowTopY - currentY
        let rowFrame = NSRect(x: rowX, y: currentY, width: rowW, height: rowHeight)
        background.frame = rowFrame
        if workspace.isActive {
            accentBar.frame = NSRect(x: rowX, y: currentY, width: 3, height: rowHeight)
        }
        hitAreas.append(SidebarHitArea(frame: rowFrame, region: .workspace(workspace.index)))

        return SidebarWorkspaceCardRenderResult(bottomY: currentY, views: views, hitAreas: hitAreas)
    }

    private func buildTitleRow(contentX: CGFloat, contentW: CGFloat, yOffset: CGFloat) -> CGFloat {
        let title = textLabel(
            workspace.title,
            font: .monospacedSystemFont(ofSize: 14, weight: .bold),
            color: workspace.isActive ? NSColor.white.withAlphaComponent(0.92) : NSColor.white.withAlphaComponent(0.68)
        )
        title.frame = NSRect(
            x: contentX,
            y: yOffset - SidebarExpandedMetrics.titleHeight,
            width: contentW - 38,
            height: SidebarExpandedMetrics.titleHeight
        )
        append(title)

        let columnCount = badgeView(
            "\(workspace.columnCount)",
            color: NSColor.white.withAlphaComponent(0.58),
            background: NSColor.white.withAlphaComponent(0.045)
        )
        columnCount.frame = NSRect(
            x: sidebarWidth - padding - SidebarExpandedMetrics.countChipWidth,
            y: yOffset - SidebarExpandedMetrics.titleHeight
                + (SidebarExpandedMetrics.titleHeight - SidebarExpandedMetrics.countChipHeight) / 2,
            width: SidebarExpandedMetrics.countChipWidth,
            height: SidebarExpandedMetrics.countChipHeight
        )
        append(columnCount)

        return yOffset - SidebarExpandedMetrics.titleAdvance
    }

    private func buildBranchRowIfNeeded(contentX: CGFloat, contentW: CGFloat, yOffset: CGFloat) -> CGFloat {
        guard let branch = workspace.gitBranch, branch != workspace.title else { return yOffset }
        let branchLabel = textLabel(
            branch,
            font: .monospacedSystemFont(ofSize: 11, weight: .regular),
            color: NSColor.white.withAlphaComponent(workspace.isActive ? 0.48 : 0.34)
        )
        branchLabel.frame = NSRect(
            x: contentX,
            y: yOffset - SidebarExpandedMetrics.branchHeight,
            width: contentW,
            height: SidebarExpandedMetrics.branchHeight
        )
        append(branchLabel)
        return yOffset - SidebarExpandedMetrics.branchAdvance
    }

    private func buildMetadataRows(contentX: CGFloat, yOffset: CGFloat) -> CGFloat {
        var currentY = yOffset
        if let stats = workspace.diffStats {
            currentY = buildDiffStatsLabel(stats: stats, padding: contentX, yOffset: currentY)
        }
        if let prInfo = workspace.prInfo {
            currentY = buildPRInfoLabels(prInfo: prInfo, padding: contentX, yOffset: currentY)
        }
        return currentY
    }

    private func buildColumnEntries(columns: [ColumnInfo], yOffset: CGFloat, padding: CGFloat) -> CGFloat {
        var currentY = yOffset
        let rightDotSize: CGFloat = 8

        for column in columns {
            let rowHeight = SidebarExpandedMetrics.columnRowHeight
            let rowY = currentY - rowHeight

            if column.isFocused {
                let selected = SidebarBackgroundView(frame: NSRect(
                    x: padding - 7,
                    y: rowY - 3,
                    width: sidebarWidth - padding * 2 + 14,
                    height: rowHeight + 6
                ))
                selected.wantsLayer = true
                selected.layer?.cornerRadius = 6
                selected.layer?.backgroundColor = NSColor.niruxAccent.withAlphaComponent(0.10).cgColor
                append(selected)
            }

            let label = NSTextField(labelWithAttributedString: PilotSidebarRenderer.attributedColumn(column, fontSize: 11))
            label.lineBreakMode = .byTruncatingTail
            label.frame = NSRect(x: padding, y: rowY, width: sidebarWidth - padding * 2 - 18, height: rowHeight)
            append(label)

            let dot = statusDot(status: column.agentStatus)
            dot.frame = NSRect(
                x: sidebarWidth - padding - rightDotSize,
                y: rowY + (rowHeight - rightDotSize) / 2,
                width: rightDotSize,
                height: rightDotSize
            )
            append(dot)

            let hitRect = NSRect(
                x: padding - 8,
                y: currentY - SidebarExpandedMetrics.columnRowAdvance,
                width: sidebarWidth - padding * 2 + 16,
                height: SidebarExpandedMetrics.columnRowAdvance
            )
            hitAreas.append(SidebarHitArea(
                frame: hitRect,
                region: .column(workspaceIndex: workspace.index, columnIndex: column.index)
            ))

            currentY -= SidebarExpandedMetrics.columnRowAdvance
        }

        return currentY
    }

    private func buildDiffStatsLabel(stats: String, padding: CGFloat, yOffset: CGFloat) -> CGFloat {
        let compact = PilotSidebarRenderer.formatDiffStats(stats)
        let statsLabel = NSTextField(labelWithString: "")
        statsLabel.allowsEditingTextAttributes = true
        statsLabel.isSelectable = false
        statsLabel.attributedStringValue = PilotSidebarRenderer.diffStatsAttributedString(compact, fontSize: 10)
        statsLabel.lineBreakMode = .byTruncatingTail
        statsLabel.frame = NSRect(
            x: padding,
            y: yOffset - SidebarExpandedMetrics.diffHeight,
            width: sidebarWidth - padding * 2,
            height: SidebarExpandedMetrics.diffHeight
        )
        append(statsLabel)
        hitAreas.append(SidebarHitArea(
            frame: statsLabel.frame,
            region: .link(url: SidebarView.diffActionURL(workspaceIndex: workspace.index), label: statsLabel)
        ))
        return yOffset - SidebarExpandedMetrics.diffAdvance
    }

    private func buildPRInfoLabels(prInfo: PRInfo, padding: CGFloat, yOffset: CGFloat) -> CGFloat {
        var currentY = yOffset
        let indent: CGFloat = 8
        currentY = buildPRStateLabel(prInfo: prInfo, padding: padding, yOffset: currentY)
        currentY = buildCIStatusLabel(prInfo: prInfo, padding: padding, indent: indent, yOffset: currentY)
        currentY = buildReviewDecisionLabel(prInfo: prInfo, padding: padding, indent: indent, yOffset: currentY)
        return currentY
    }

    private func buildPRStateLabel(prInfo: PRInfo, padding: CGFloat, yOffset: CGFloat) -> CGFloat {
        let (stateText, stateColor) = PilotSidebarRenderer.prStateDisplay(prInfo)
        let prLabel = textLabel(
            "#\(prInfo.number) \(stateText)",
            font: .monospacedSystemFont(ofSize: 9, weight: .medium),
            color: stateColor
        )
        prLabel.frame = NSRect(
            x: padding,
            y: yOffset - SidebarExpandedMetrics.prStateHeight,
            width: sidebarWidth - padding * 2,
            height: SidebarExpandedMetrics.prStateHeight
        )
        append(prLabel)
        hitAreas.append(SidebarHitArea(frame: prLabel.frame, region: .link(url: prInfo.url, label: prLabel)))
        return yOffset - SidebarExpandedMetrics.prStateAdvance
    }

    private func buildCIStatusLabel(prInfo: PRInfo, padding: CGFloat, indent: CGFloat, yOffset: CGFloat) -> CGFloat {
        guard let ciStatus = prInfo.ciStatus else { return yOffset }
        let (ciDot, ciColor, ciText) = PilotSidebarRenderer.ciStatusDisplay(ciStatus, style: .short)
        let ciLabel = textLabel(
            "\(ciDot) \(ciText)",
            font: .monospacedSystemFont(ofSize: 9, weight: .regular),
            color: ciColor
        )
        ciLabel.frame = NSRect(
            x: padding + indent,
            y: yOffset - SidebarExpandedMetrics.prDetailHeight,
            width: sidebarWidth - padding * 2 - indent,
            height: SidebarExpandedMetrics.prDetailHeight
        )
        append(ciLabel)
        let ciUrl = (ciStatus == "FAILURE" ? prInfo.failedCheckUrl : nil) ?? prInfo.url
        hitAreas.append(SidebarHitArea(frame: ciLabel.frame, region: .link(url: ciUrl, label: ciLabel)))
        return yOffset - SidebarExpandedMetrics.prDetailAdvance
    }

    private func buildReviewDecisionLabel(prInfo: PRInfo, padding: CGFloat, indent: CGFloat, yOffset: CGFloat) -> CGFloat {
        guard let display = PilotSidebarRenderer.reviewDecisionDisplay(
            reviewDecision: prInfo.reviewDecision,
            mergeable: prInfo.mergeable
        ) else {
            return yOffset
        }

        let shortText: String
        switch display.text {
        case "changes requested": shortText = "changes"
        case "review requested": shortText = "review"
        default: shortText = display.text
        }

        let reviewLabel = textLabel(
            "\(display.dot) \(shortText)",
            font: .monospacedSystemFont(ofSize: 9, weight: .regular),
            color: display.color
        )
        reviewLabel.frame = NSRect(
            x: padding + indent,
            y: yOffset - SidebarExpandedMetrics.prDetailHeight,
            width: sidebarWidth - padding * 2 - indent,
            height: SidebarExpandedMetrics.prDetailHeight
        )
        append(reviewLabel)
        hitAreas.append(SidebarHitArea(frame: reviewLabel.frame, region: .link(url: prInfo.url, label: reviewLabel)))
        return yOffset - SidebarExpandedMetrics.prDetailAdvance
    }

    private func cardBackground() -> SidebarBackgroundView {
        let background = SidebarBackgroundView()
        background.wantsLayer = true
        background.layer?.cornerRadius = 8
        background.layer?.backgroundColor = (workspace.isActive
            ? NSColor.white.withAlphaComponent(0.050)
            : NSColor.white.withAlphaComponent(0.020)
        ).cgColor
        background.layer?.borderWidth = 1
        background.layer?.borderColor = NSColor.white.withAlphaComponent(workspace.isActive ? 0.09 : 0.045).cgColor
        return background
    }

    private func textLabel(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    private func badgeView(_ text: String, color: NSColor, background: NSColor) -> SidebarBadgeView {
        SidebarBadgeView(
            text: text,
            textColor: color,
            fillColor: background,
            font: .monospacedSystemFont(ofSize: 10, weight: .semibold)
        )
    }

    private func statusDot(status: AgentStatus) -> NSView {
        let dot = SidebarBackgroundView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        let color: NSColor
        switch status {
        case .working:
            color = .systemGreen
        case .needsAttention:
            color = .systemOrange
        case .idle:
            color = NSColor.white.withAlphaComponent(0.22)
        }
        dot.layer?.backgroundColor = color.cgColor
        return dot
    }

    private func append(_ view: NSView) {
        views.append(view)
    }
}
