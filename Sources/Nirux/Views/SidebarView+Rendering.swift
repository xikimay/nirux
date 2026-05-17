import AppKit

// MARK: - Expanded mode rendering helpers

extension SidebarView {

    /// Main entry point for rebuilding expanded sidebar content.
    func rebuildContent() {
        expandedViews.forEach { $0.removeFromSuperview() }
        expandedViews.removeAll()
        clickableAreas.removeAll()
        columnClickAreas.removeAll()
        workspaceClickAreas.removeAll()
        guard isExpanded else { setNeedsDisplay(bounds); return }

        let padding: CGFloat = 20

        // Calculate total content height — used both to size the scrollable
        // document view (so overflow scrolls) and to anchor content to the top
        // of the scroll viewport.
        var contentH: CGFloat = 2 * padding
        for workspace in lastInfos {
            contentH += 22 // title
            if let branch = workspace.gitBranch, branch != workspace.title { contentH += 18 }
            contentH += 16 // gap before columns
            contentH += CGFloat(workspace.columns.count) * 24
            if workspace.diffStats != nil { contentH += 20 }
            if workspace.prInfo != nil {
                contentH += 14 // PR state
                if workspace.prInfo?.ciStatus != nil { contentH += 12 }
                if let rd = workspace.prInfo?.reviewDecision, !rd.isEmpty { contentH += 12 }
            }
            contentH += 6 // separator gap
            if workspace.index < lastInfos.count - 1 { contentH += 8 }
        }

        // Document view is at least the viewport height (so short content
        // still fills the sidebar background) and grows beyond when the
        // workspace list overflows. Children below are positioned in the
        // document view's coordinate space.
        let docHeight = max(bounds.height, contentH)
        contentDocumentView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: docHeight)

        var yOffset = docHeight - padding

        for workspace in lastInfos {
            yOffset = buildWorkspaceSection(workspace: workspace, padding: padding, yOffset: yOffset)

            // Separator between workspaces
            yOffset -= 6
            if workspace.index < lastInfos.count - 1 {
                yOffset = buildWorkspaceSeparator(padding: padding, yOffset: yOffset)
            }
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

        currentY -= 16 // gap before columns
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
        titleLabel.frame = NSRect(x: padding, y: yOffset - 18, width: bounds.width - padding * 2, height: 18)
        addSubviewDoc(titleLabel)
        expandedViews.append(titleLabel)
        return yOffset - 22
    }

    // MARK: - Git branch label

    private func buildGitBranchLabel(workspace: WorkspaceInfo, padding: CGFloat, yOffset: CGFloat) -> CGFloat {
        guard let branch = workspace.gitBranch, branch != workspace.title else { return yOffset }
        let branchLabel = NSTextField(labelWithString: branch)
        branchLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        branchLabel.textColor = NSColor.white.withAlphaComponent(0.3)
        branchLabel.lineBreakMode = .byTruncatingTail
        branchLabel.frame = NSRect(x: padding, y: yOffset - 14, width: bounds.width - padding * 2, height: 14)
        addSubviewDoc(branchLabel)
        expandedViews.append(branchLabel)
        return yOffset - 18
    }

    // MARK: - Column entries

    private func buildColumnEntries(columns: [ColumnInfo], wsIndex: Int, padding: CGFloat, yOffset: CGFloat) -> CGFloat {
        var currentY = yOffset
        let agentDotSize: CGFloat = 8
        let dotColumnX: CGFloat = padding
        let textX: CGFloat = padding + agentDotSize + 6

        for column in columns {
            let rowHeight: CGFloat = 14

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
            let hitRect = NSRect(x: 0, y: currentY - 24, width: bounds.width, height: 24)
            columnClickAreas.append((frame: hitRect, wsIndex: wsIndex, colIndex: column.index))

            currentY -= 24
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
        var currentY = yOffset - 4
        let compact = PilotSidebarRenderer.formatDiffStats(stats)
        let statsLabel = NSTextField(labelWithString: "")
        statsLabel.allowsEditingTextAttributes = true
        statsLabel.isSelectable = false

        statsLabel.attributedStringValue = PilotSidebarRenderer.diffStatsAttributedString(compact, fontSize: 10)
        statsLabel.lineBreakMode = .byTruncatingTail
        statsLabel.frame = NSRect(x: padding, y: currentY - 12, width: bounds.width - padding * 2, height: 12)
        addSubviewDoc(statsLabel)
        expandedViews.append(statsLabel)

        clickableAreas.append((
            frame: statsLabel.frame,
            url: SidebarView.diffActionURL(workspaceIndex: workspaceIndex),
            label: statsLabel
        ))

        currentY -= 16
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
        prLabel.frame = NSRect(x: padding, y: yOffset - 12, width: bounds.width - padding * 2, height: 12)
        addSubviewDoc(prLabel)
        expandedViews.append(prLabel)
        clickableAreas.append((frame: prLabel.frame, url: prInfo.url, label: prLabel))
        return yOffset - 14
    }

    private func buildCIStatusLabel(prInfo: PRInfo, padding: CGFloat, indent: CGFloat, yOffset: CGFloat) -> CGFloat {
        guard let ciStatus = prInfo.ciStatus else { return yOffset }
        let (ciDot, ciColor, ciText) = PilotSidebarRenderer.ciStatusDisplay(ciStatus, style: .short)
        let ciLabel = NSTextField(labelWithString: "\(ciDot) \(ciText)")
        ciLabel.font = .monospacedSystemFont(ofSize: 9, weight: .regular)
        ciLabel.textColor = ciColor
        ciLabel.lineBreakMode = .byTruncatingTail
        ciLabel.frame = NSRect(x: padding + indent, y: yOffset - 10, width: bounds.width - padding * 2 - indent, height: 10)
        addSubviewDoc(ciLabel)
        expandedViews.append(ciLabel)
        let ciUrl = (ciStatus == "FAILURE" ? prInfo.failedCheckUrl : nil) ?? prInfo.url
        clickableAreas.append((frame: ciLabel.frame, url: ciUrl, label: ciLabel))
        return yOffset - 12
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
        reviewLabel.frame = NSRect(x: padding + indent, y: yOffset - 10, width: bounds.width - padding * 2 - indent, height: 10)
        addSubviewDoc(reviewLabel)
        expandedViews.append(reviewLabel)
        clickableAreas.append((frame: reviewLabel.frame, url: prInfo.url, label: reviewLabel))
        return yOffset - 12
    }

    // MARK: - Workspace separator

    private func buildWorkspaceSeparator(padding: CGFloat, yOffset: CGFloat) -> CGFloat {
        let separator = NSBox()
        separator.boxType = .separator
        separator.frame = NSRect(x: padding, y: yOffset, width: bounds.width - padding * 2, height: 1)
        addSubviewDoc(separator)
        expandedViews.append(separator)
        return yOffset - 8
    }
}
