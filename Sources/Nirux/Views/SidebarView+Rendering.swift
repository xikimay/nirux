import AppKit

private enum SidebarExpandedMetrics {
    static let padding: CGFloat = 20
    static let verticalPadding: CGFloat = 20
    static let bottomReserve: CGFloat = 40
    static let sectionGap: CGFloat = 18
    static let headerHeight: CGFloat = 12
    static let headerAdvance: CGFloat = 18
    static let titleHeight: CGFloat = 18
    static let titleAdvance: CGFloat = 22
    static let branchHeight: CGFloat = 14
    static let branchAdvance: CGFloat = 18
    static let columnGap: CGFloat = 16
    static let columnRowHeight: CGFloat = 14
    static let columnRowAdvance: CGFloat = 24
    static let diffTopGap: CGFloat = 4
    static let diffHeight: CGFloat = 12
    static let diffAdvance: CGFloat = 16
    static let prStateHeight: CGFloat = 12
    static let prStateAdvance: CGFloat = 14
    static let prDetailHeight: CGFloat = 10
    static let prDetailAdvance: CGFloat = 12
    static let separatorTopGap: CGFloat = 6
    static let separatorAdvance: CGFloat = 8

    static func groupHeight(for infos: [WorkspaceInfo]) -> CGFloat {
        infos.enumerated().reduce(CGFloat(0)) { total, item in
            total + workspaceHeight(for: item.element, isLast: item.offset == infos.count - 1)
        }
    }

    private static func workspaceHeight(for workspace: WorkspaceInfo, isLast: Bool) -> CGFloat {
        var height = titleAdvance
        if let branch = workspace.gitBranch, branch != workspace.title { height += branchAdvance }
        height += columnGap
        height += CGFloat(workspace.columns.count) * columnRowAdvance
        if workspace.diffStats != nil { height += diffTopGap + diffAdvance }
        if workspace.prInfo != nil {
            height += prStateAdvance
            if workspace.prInfo?.ciStatus != nil { height += prDetailAdvance }
            if let reviewDecision = workspace.prInfo?.reviewDecision, !reviewDecision.isEmpty {
                height += prDetailAdvance
            }
        }
        height += separatorTopGap
        if !isLast { height += separatorAdvance }
        return height
    }
}

// MARK: - Expanded mode rendering helpers

extension SidebarView {

    /// Main entry point for rebuilding expanded sidebar content.
    func rebuildContent() {
        expandedViews.forEach { $0.removeFromSuperview() }
        expandedViews.removeAll()
        profileIndicatorView?.removeFromSuperview()
        profileIndicatorView = nil
        clickableAreas.removeAll()
        columnClickAreas.removeAll()
        workspaceClickAreas.removeAll()
        guard isExpanded else { setNeedsDisplay(bounds); return }

        rebuildBottomIndicators()

        let padding = SidebarExpandedMetrics.padding
        let activeInfos = displayedWorkspaceInfos.filter { !$0.isInactive }
        let inactiveInfos = displayedWorkspaceInfos.filter { $0.isInactive }

        // Calculate total content height — used both to size the scrollable
        // document view (so overflow scrolls) and to anchor content to the top
        // of the scroll viewport.
        var contentH: CGFloat = 2 * SidebarExpandedMetrics.verticalPadding + SidebarExpandedMetrics.bottomReserve
        contentH += SidebarExpandedMetrics.groupHeight(for: activeInfos)
        if !inactiveInfos.isEmpty {
            contentH += SidebarExpandedMetrics.sectionGap + SidebarExpandedMetrics.headerAdvance
            contentH += SidebarExpandedMetrics.groupHeight(for: inactiveInfos)
        }

        // Document view is at least the viewport height (so short content
        // still fills the sidebar background) and grows beyond when the
        // workspace list overflows. Children below are positioned in the
        // document view's coordinate space.
        let docHeight = max(bounds.height, contentH)
        contentDocumentView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: docHeight)

        var yOffset = docHeight - SidebarExpandedMetrics.verticalPadding

        if !activeInfos.isEmpty {
            yOffset = buildWorkspaceGroup(activeInfos, padding: padding, yOffset: yOffset)
        }
        if !inactiveInfos.isEmpty {
            yOffset -= SidebarExpandedMetrics.sectionGap
            yOffset = buildSectionHeader("inactive", padding: padding, yOffset: yOffset)
            yOffset = buildWorkspaceGroup(inactiveInfos, padding: padding, yOffset: yOffset)
        }

        let clip = contentScrollView.contentView
        let activeIndex = activeWorkspaceIndex
        let activeChanged = activeIndex != lastFollowedActiveIndex
        let isFirstBuild = lastFollowedActiveIndex == Int.min

        if activeChanged, let activeFrame = workspaceClickAreas.first(where: { $0.wsIndex == activeIndex })?.frame {
            // Follow the active workspace only when it actually changes (e.g.
            // Cmd+arrow navigation) so we don't yank the viewport back to it
            // every 1.5s while the user is scrolling through the list.
            let pad: CGFloat = 12
            let padded = activeFrame.insetBy(dx: 0, dy: -pad)
            contentDocumentView.scrollToVisible(padded)
            lastFollowedActiveIndex = activeIndex
        } else if isFirstBuild {
            // First build after expansion: anchor to the top so the user
            // sees workspace 0 rather than NSScrollView's default (bottom).
            let topOrigin = NSPoint(x: 0, y: docHeight - clip.bounds.height)
            clip.scroll(to: topOrigin)
            contentScrollView.reflectScrolledClipView(clip)
            lastFollowedActiveIndex = activeIndex
        }
    }

    /// Index of the active workspace in `lastInfos`, or -1 if none. Used by
    /// `rebuildContent` to scroll the sidebar so the active section stays
    /// visible after `updateSidebar()` triggers a rebuild.
    private var activeWorkspaceIndex: Int {
        lastInfos.first(where: { $0.isActive })?.index ?? -1
    }


    private func rebuildBottomIndicators() {
        var items = lastProfiles.map { profile in
            SidebarDotIndicatorItem(
                action: .selectProfile(profile.id),
                colorHex: profile.colorHex,
                isActive: profile.isActive,
                hasAttention: profile.hasAttention,
                label: nil
            )
        }
        items.append(SidebarDotIndicatorItem(
            action: .createProfile, colorHex: "#FFFFFF", isActive: false, hasAttention: false, label: "+"
        ))
        let width = min(bounds.width - 24, SidebarDotIndicatorView.preferredWidth(itemCount: items.count))
        let view = SidebarDotIndicatorView(
            frame: NSRect(x: (bounds.width - width) / 2, y: 10, width: width, height: 22),
            items: items,
            tooltip: "Spaces"
        )
        view.onSelect = { [weak self] action in
            switch action {
            case .createProfile:
                self?.onCreateProfile?()
            case .selectProfile(let profileID):
                self?.onProfileClicked?(profileID)
            }
        }
        addSubview(view)
        profileIndicatorView = view
    }

    private func buildSectionHeader(_ title: String, padding: CGFloat, yOffset: CGFloat) -> CGFloat {
        let label = NSTextField(labelWithString: title.uppercased())
        label.font = .monospacedSystemFont(ofSize: 9, weight: .semibold)
        label.textColor = NSColor.white.withAlphaComponent(0.28)
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(
            x: padding,
            y: yOffset - SidebarExpandedMetrics.headerHeight,
            width: bounds.width - padding - 10,
            height: SidebarExpandedMetrics.headerHeight
        )
        addSubviewDoc(label)
        expandedViews.append(label)
        return yOffset - SidebarExpandedMetrics.headerAdvance
    }

    private func buildWorkspaceGroup(_ infos: [WorkspaceInfo], padding: CGFloat, yOffset: CGFloat) -> CGFloat {
        var currentY = yOffset
        for (position, workspace) in infos.enumerated() {
            currentY = buildWorkspaceSection(workspace: workspace, padding: padding, yOffset: currentY)
            currentY -= SidebarExpandedMetrics.separatorTopGap
            if position < infos.count - 1 {
                currentY = buildWorkspaceSeparator(padding: padding, yOffset: currentY)
            }
        }
        return currentY
    }

    // MARK: - Workspace section

    private func buildWorkspaceSection(workspace: WorkspaceInfo, padding: CGFloat, yOffset: CGFloat) -> CGFloat {
        var currentY = yOffset

        // Accent bar for active workspace — positioned via defer after section height is known
        var accentBar: NSView?
        let barStartY = currentY
        if workspace.isActive {
            let bar = NSView(frame: NSRect(x: 0, y: 0, width: 2, height: 0))
            bar.wantsLayer = true
            bar.layer?.backgroundColor = Self.accentColor.cgColor
            addSubviewDoc(bar)
            expandedViews.append(bar)
            accentBar = bar
        }

        currentY = buildWorkspaceTitleLabel(workspace: workspace, padding: padding, yOffset: currentY)
        currentY = buildGitBranchLabel(workspace: workspace, padding: padding, yOffset: currentY)

        currentY -= SidebarExpandedMetrics.columnGap
        currentY = buildColumnEntries(columns: workspace.columns, wsIndex: workspace.index, padding: padding, yOffset: currentY)

        if let stats = workspace.diffStats {
            currentY = buildDiffStatsLabel(
                stats: stats,
                workspaceIndex: workspace.index,
                padding: padding,
                yOffset: currentY
            )
        }

        if let prInfo = workspace.prInfo {
            currentY = buildPRInfoLabels(prInfo: prInfo, padding: padding, yOffset: currentY)
        }

        // Finalize accent bar height now that we know the section extent
        if let bar = accentBar {
            bar.frame = NSRect(x: 0, y: currentY, width: 2, height: barStartY - currentY)
        }

        // Register workspace section click area (columns and PR links take priority in mouseDown)
        workspaceClickAreas.append((
            frame: NSRect(x: 0, y: currentY, width: bounds.width, height: barStartY - currentY),
            wsIndex: workspace.index
        ))

        return currentY
    }

    // MARK: - Title label

    private func buildWorkspaceTitleLabel(workspace: WorkspaceInfo, padding: CGFloat, yOffset: CGFloat) -> CGFloat {
        let titleLabel = NSTextField(labelWithString: workspace.title)
        titleLabel.font = .monospacedSystemFont(ofSize: 14, weight: .bold)
        titleLabel.textColor = workspace.isActive
            ? NSColor.white.withAlphaComponent(0.9)
            : NSColor.white.withAlphaComponent(0.4)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.frame = NSRect(
            x: padding,
            y: yOffset - SidebarExpandedMetrics.titleHeight,
            width: bounds.width - padding * 2,
            height: SidebarExpandedMetrics.titleHeight
        )
        addSubviewDoc(titleLabel)
        expandedViews.append(titleLabel)
        return yOffset - SidebarExpandedMetrics.titleAdvance
    }

    // MARK: - Git branch label

    private func buildGitBranchLabel(workspace: WorkspaceInfo, padding: CGFloat, yOffset: CGFloat) -> CGFloat {
        guard let branch = workspace.gitBranch, branch != workspace.title else { return yOffset }
        let branchLabel = NSTextField(labelWithString: branch)
        branchLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        branchLabel.textColor = NSColor.white.withAlphaComponent(0.3)
        branchLabel.lineBreakMode = .byTruncatingTail
        branchLabel.frame = NSRect(
            x: padding,
            y: yOffset - SidebarExpandedMetrics.branchHeight,
            width: bounds.width - padding * 2,
            height: SidebarExpandedMetrics.branchHeight
        )
        addSubviewDoc(branchLabel)
        expandedViews.append(branchLabel)
        return yOffset - SidebarExpandedMetrics.branchAdvance
    }

    // MARK: - Column entries

    private func buildColumnEntries(columns: [ColumnInfo], wsIndex: Int, padding: CGFloat, yOffset: CGFloat) -> CGFloat {
        var currentY = yOffset
        let agentDotSize: CGFloat = 8
        let dotColumnX: CGFloat = padding
        let textX: CGFloat = padding + agentDotSize + 6

        for column in columns {
            let rowHeight = SidebarExpandedMetrics.columnRowHeight

            if let dot = PilotSidebarRenderer.makeAgentDot(
                status: column.agentStatus, x: dotColumnX,
                yOffset: currentY, rowHeight: rowHeight, size: agentDotSize
            ) {
                addSubviewDoc(dot)
                expandedViews.append(dot)
            }

            let label = NSTextField(labelWithAttributedString: attributedColumn(column))
            label.lineBreakMode = .byTruncatingTail
            label.frame = NSRect(x: textX, y: currentY - rowHeight, width: bounds.width - textX - padding, height: rowHeight)
            addSubviewDoc(label)
            expandedViews.append(label)

            // Full-width hit area for column click
            let hitRect = NSRect(
                x: 0,
                y: currentY - SidebarExpandedMetrics.columnRowAdvance,
                width: bounds.width,
                height: SidebarExpandedMetrics.columnRowAdvance
            )
            columnClickAreas.append((frame: hitRect, wsIndex: wsIndex, colIndex: column.index))

            currentY -= SidebarExpandedMetrics.columnRowAdvance
        }

        return currentY
    }

    // MARK: - Diff stats

    private func buildDiffStatsLabel(
        stats: String,
        workspaceIndex: Int,
        padding: CGFloat,
        yOffset: CGFloat
    ) -> CGFloat {
        var currentY = yOffset - SidebarExpandedMetrics.diffTopGap
        let compact = PilotSidebarRenderer.formatDiffStats(stats)
        let statsLabel = NSTextField(labelWithString: "")
        statsLabel.allowsEditingTextAttributes = true
        statsLabel.isSelectable = false

        statsLabel.attributedStringValue = PilotSidebarRenderer.diffStatsAttributedString(compact, fontSize: 10)
        statsLabel.lineBreakMode = .byTruncatingTail
        statsLabel.frame = NSRect(
            x: padding,
            y: currentY - SidebarExpandedMetrics.diffHeight,
            width: bounds.width - padding * 2,
            height: SidebarExpandedMetrics.diffHeight
        )
        addSubviewDoc(statsLabel)
        expandedViews.append(statsLabel)

        clickableAreas.append((
            frame: statsLabel.frame,
            url: SidebarView.diffActionURL(workspaceIndex: workspaceIndex),
            label: statsLabel
        ))

        currentY -= SidebarExpandedMetrics.diffAdvance
        return currentY
    }

    // MARK: - PR info

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
        let prLabel = NSTextField(labelWithString: "#\(prInfo.number) \(stateText)")
        prLabel.font = .monospacedSystemFont(ofSize: 9, weight: .medium)
        prLabel.textColor = stateColor
        prLabel.lineBreakMode = .byTruncatingTail
        prLabel.frame = NSRect(
            x: padding,
            y: yOffset - SidebarExpandedMetrics.prStateHeight,
            width: bounds.width - padding * 2,
            height: SidebarExpandedMetrics.prStateHeight
        )
        addSubviewDoc(prLabel)
        expandedViews.append(prLabel)
        clickableAreas.append((frame: prLabel.frame, url: prInfo.url, label: prLabel))
        return yOffset - SidebarExpandedMetrics.prStateAdvance
    }

    private func buildCIStatusLabel(prInfo: PRInfo, padding: CGFloat, indent: CGFloat, yOffset: CGFloat) -> CGFloat {
        guard let ciStatus = prInfo.ciStatus else { return yOffset }
        let (ciDot, ciColor, ciText) = PilotSidebarRenderer.ciStatusDisplay(ciStatus, style: .short)
        let ciLabel = NSTextField(labelWithString: "\(ciDot) \(ciText)")
        ciLabel.font = .monospacedSystemFont(ofSize: 9, weight: .regular)
        ciLabel.textColor = ciColor
        ciLabel.lineBreakMode = .byTruncatingTail
        ciLabel.frame = NSRect(
            x: padding + indent,
            y: yOffset - SidebarExpandedMetrics.prDetailHeight,
            width: bounds.width - padding * 2 - indent,
            height: SidebarExpandedMetrics.prDetailHeight
        )
        addSubviewDoc(ciLabel)
        expandedViews.append(ciLabel)
        let ciUrl = (ciStatus == "FAILURE" ? prInfo.failedCheckUrl : nil) ?? prInfo.url
        clickableAreas.append((frame: ciLabel.frame, url: ciUrl, label: ciLabel))
        return yOffset - SidebarExpandedMetrics.prDetailAdvance
    }

    private func buildReviewDecisionLabel(prInfo: PRInfo, padding: CGFloat, indent: CGFloat, yOffset: CGFloat) -> CGFloat {
        guard let display = PilotSidebarRenderer.reviewDecisionDisplay(
            reviewDecision: prInfo.reviewDecision, mergeable: prInfo.mergeable
        ) else {
            return yOffset
        }

        // Sidebar uses shorter text: "changes requested" → "changes", "review requested" → "review".
        let shortText: String
        switch display.text {
        case "changes requested": shortText = "changes"
        case "review requested": shortText = "review"
        default: shortText = display.text
        }

        let reviewLabel = NSTextField(labelWithString: "\(display.dot) \(shortText)")
        reviewLabel.font = .monospacedSystemFont(ofSize: 9, weight: .regular)
        reviewLabel.textColor = display.color
        reviewLabel.lineBreakMode = .byTruncatingTail
        reviewLabel.frame = NSRect(
            x: padding + indent,
            y: yOffset - SidebarExpandedMetrics.prDetailHeight,
            width: bounds.width - padding * 2 - indent,
            height: SidebarExpandedMetrics.prDetailHeight
        )
        addSubviewDoc(reviewLabel)
        expandedViews.append(reviewLabel)
        clickableAreas.append((frame: reviewLabel.frame, url: prInfo.url, label: reviewLabel))
        return yOffset - SidebarExpandedMetrics.prDetailAdvance
    }

    // MARK: - Workspace separator

    private func buildWorkspaceSeparator(padding: CGFloat, yOffset: CGFloat) -> CGFloat {
        let separator = NSBox()
        separator.boxType = .separator
        separator.frame = NSRect(x: padding, y: yOffset, width: bounds.width - padding * 2, height: 1)
        addSubviewDoc(separator)
        expandedViews.append(separator)
        return yOffset - SidebarExpandedMetrics.separatorAdvance
    }
}
