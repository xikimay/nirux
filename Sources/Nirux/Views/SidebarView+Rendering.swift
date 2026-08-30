import AppKit

// MARK: - Expanded mode rendering helpers

extension SidebarView {

    /// Main entry point for rebuilding expanded sidebar content.
    func rebuildContent() {
        // Never rebuild mid-drag: rows would shift under the captured drag
        // geometry. SidebarView+Drag defers updates until the drag ends.
        guard workspaceDrag == nil else {
            rebuildSkippedDuringDrag = true
            return
        }
        resetRenderState()
        guard isExpanded else { setNeedsDisplay(bounds); return }

        rebuildBottomIndicators()

        let padding = SidebarExpandedMetrics.padding
        let activeInfos = displayedWorkspaceInfos.filter { !$0.isInactive }
        let inactiveInfos = displayedWorkspaceInfos.filter { $0.isInactive }
        let hasWorkspaces = !activeInfos.isEmpty || !inactiveInfos.isEmpty
        let activeProfile = lastProfiles.first(where: { $0.isActive })

        // Size the scrollable document so content is top-anchored and never
        // hides behind the bottom space switcher.
        var contentH = SidebarExpandedMetrics.verticalPadding
            + SidebarExpandedMetrics.spaceHeaderHeight
            + SidebarExpandedMetrics.spaceHeaderBottomGap
            + SidebarExpandedMetrics.bottomReserve
        if !activeInfos.isEmpty {
            contentH += SidebarExpandedMetrics.sectionHeaderAdvance
            contentH += SidebarExpandedMetrics.groupHeight(for: activeInfos)
        }
        if !inactiveInfos.isEmpty {
            contentH += SidebarExpandedMetrics.sectionGap
            contentH += SidebarExpandedMetrics.sectionHeaderAdvance
            if !isInactiveSectionCollapsed {
                contentH += SidebarExpandedMetrics.groupHeight(for: inactiveInfos)
            }
        }
        if hasWorkspaces {
            contentH += SidebarExpandedMetrics.shortcutHintGap + SidebarExpandedMetrics.shortcutHintHeight
        }

        let docHeight = max(bounds.height, contentH)
        contentDocumentView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: docHeight)

        var yOffset = docHeight - SidebarExpandedMetrics.verticalPadding

        if let activeProfile {
            yOffset = buildSpaceHeader(activeProfile, padding: padding, yOffset: yOffset)
            yOffset -= SidebarExpandedMetrics.spaceHeaderBottomGap
        }

        if !activeInfos.isEmpty {
            yOffset = buildSectionHeader("active", count: activeInfos.count, padding: padding, yOffset: yOffset)
            yOffset = buildWorkspaceGroup(activeInfos, padding: padding, yOffset: yOffset)
        }
        if !inactiveInfos.isEmpty {
            yOffset -= SidebarExpandedMetrics.sectionGap
            yOffset = buildSectionHeader(
                "inactive", count: inactiveInfos.count, padding: padding,
                yOffset: yOffset, isCollapsed: isInactiveSectionCollapsed
            )
            if !isInactiveSectionCollapsed {
                yOffset = buildWorkspaceGroup(inactiveInfos, padding: padding, yOffset: yOffset)
            }
        }
        if hasWorkspaces {
            yOffset -= SidebarExpandedMetrics.shortcutHintGap
            yOffset = buildShortcutHint(padding: padding, yOffset: yOffset)
        }

        refreshHoverTargetFromMouse()
        let clip = contentScrollView.contentView
        let activeIndex = activeWorkspaceIndex
        let activeChanged = activeIndex != lastFollowedActiveIndex
        let isFirstBuild = lastFollowedActiveIndex == Int.min

        if activeChanged, let activeFrame = workspaceFrame(for: activeIndex) {
            let pad: CGFloat = 12
            contentDocumentView.scrollToVisible(activeFrame.insetBy(dx: 0, dy: -pad))
            lastFollowedActiveIndex = activeIndex
        } else if isFirstBuild {
            let topOrigin = NSPoint(x: 0, y: docHeight - clip.bounds.height)
            clip.scroll(to: topOrigin)
            contentScrollView.reflectScrolledClipView(clip)
            lastFollowedActiveIndex = activeIndex
        }
    }

    /// Tear down every view and state snapshot from the previous expanded
    /// render pass before rebuilding.
    private func resetRenderState() {
        expandedViews.forEach { $0.removeFromSuperview() }
        expandedViews.removeAll()
        profileIndicatorView?.removeFromSuperview()
        profileIndicatorView = nil
        hitAreas.removeAll()
        cardHoverViews.removeAll()
        menuBadgeViews.removeAll()
        columnHoverViews.removeAll()
        spaceHeaderHoverView = nil
        spaceHeaderBadge = nil
        hoveredTarget = nil
    }

    /// Index of the active workspace in `lastInfos`, or -1 if none. Used by
    /// `rebuildContent` to scroll the sidebar so the active section stays
    /// visible after `updateSidebar()` triggers a rebuild.
    private var activeWorkspaceIndex: Int {
        lastInfos.first(where: { $0.isActive })?.index ?? -1
    }

    private func workspaceFrame(for index: Int) -> NSRect? {
        hitAreas.first { area in
            if case .workspace(let workspaceIndex) = area.region {
                return workspaceIndex == index
            }
            return false
        }?.frame
    }

    // MARK: - Space header

    private func buildSpaceHeader(_ profile: ProfileInfo, padding: CGFloat, yOffset: CGFloat) -> CGFloat {
        let headerFrame = NSRect(
            x: padding,
            y: yOffset - SidebarExpandedMetrics.spaceHeaderHeight,
            width: bounds.width - padding * 2,
            height: SidebarExpandedMetrics.spaceHeaderHeight
        )
        hitAreas.append(SidebarHitArea(frame: headerFrame, region: .spaceHeader))

        // Initially-clear hover backing behind the space name/subtitle —
        // tinted while hovered so the header reads as a clickable menu.
        let hover = SidebarBackgroundView(frame: NSRect(
            x: padding - 8,
            y: headerFrame.minY + 8,
            width: headerFrame.width + 16,
            height: headerFrame.height - 8
        ))
        hover.wantsLayer = true
        hover.layer?.cornerRadius = 8
        addSubviewDoc(hover)
        expandedViews.append(hover)
        spaceHeaderHoverView = hover

        let dot = SidebarBackgroundView(frame: NSRect(
            x: padding,
            y: yOffset - 28,
            width: 9,
            height: 9
        ))
        dot.wantsLayer = true
        dot.layer?.backgroundColor = Self.profileColor(hex: profile.colorHex).cgColor
        dot.layer?.cornerRadius = 4.5
        addSubviewDoc(dot)
        expandedViews.append(dot)

        let title = textLabel(
            profile.name,
            font: .systemFont(ofSize: 17, weight: .semibold),
            color: NSColor.white.withAlphaComponent(0.92)
        )
        title.frame = NSRect(x: padding + 16, y: yOffset - 35, width: bounds.width - padding * 2 - 16 - 40, height: 24)
        addSubviewDoc(title)
        expandedViews.append(title)

        // "⋯" space-options badge — same affordance language as the
        // workspace cards; brightens with the header hover.
        let badge = SidebarBadgeView(
            text: "⋯",
            textColor: NSColor.white.withAlphaComponent(0.58),
            fillColor: NSColor.white.withAlphaComponent(0.045),
            font: .monospacedSystemFont(ofSize: 10, weight: .semibold)
        )
        badge.hoverTextColor = NSColor.white.withAlphaComponent(0.92)
        badge.hoverFillColor = NSColor.white.withAlphaComponent(0.14)
        badge.frame = NSRect(
            x: bounds.width - padding - SidebarExpandedMetrics.countChipWidth,
            y: yOffset - 34,
            width: SidebarExpandedMetrics.countChipWidth,
            height: SidebarExpandedMetrics.countChipHeight
        )
        badge.toolTip = "Space options"
        addSubviewDoc(badge)
        expandedViews.append(badge)
        spaceHeaderBadge = badge

        let subtitle = textLabel(
            "\(profile.workspaceCount) \(profile.workspaceCount == 1 ? "workspace" : "workspaces")",
            font: .systemFont(ofSize: 12, weight: .medium),
            color: NSColor.white.withAlphaComponent(0.48)
        )
        subtitle.frame = NSRect(x: padding, y: yOffset - 56, width: bounds.width - padding * 2, height: 18)
        addSubviewDoc(subtitle)
        expandedViews.append(subtitle)

        let separator = SidebarBackgroundView(frame: NSRect(x: padding, y: headerFrame.minY, width: bounds.width - padding * 2, height: 1))
        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        addSubviewDoc(separator)
        expandedViews.append(separator)

        return yOffset - SidebarExpandedMetrics.spaceHeaderHeight
    }

    private static func profileColor(hex: String) -> NSColor {
        var raw = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("#") { raw.removeFirst() }
        guard raw.count == 6, let value = UInt32(raw, radix: 16) else { return .niruxAccent }
        return NSColor(
            red: CGFloat((value >> 16) & 0xFF) / 255.0,
            green: CGFloat((value >> 8) & 0xFF) / 255.0,
            blue: CGFloat(value & 0xFF) / 255.0,
            alpha: 1
        )
    }

    // MARK: - Bottom spaces

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
            action: .createProfile,
            colorHex: "#FFFFFF",
            isActive: false,
            hasAttention: false,
            label: "+"
        ))
        let view = SidebarDotIndicatorView(
            frame: NSRect(x: 0, y: 0, width: bounds.width, height: 54),
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
        view.refreshHoverFromMouse()
        profileIndicatorView = view
    }

    // MARK: - Sections

    private func buildSectionHeader(
        _ title: String, count: Int, padding: CGFloat, yOffset: CGFloat,
        isCollapsed: Bool? = nil
    ) -> CGFloat {
        let headerFrame = NSRect(
            x: padding,
            y: yOffset - SidebarExpandedMetrics.sectionHeaderHeight,
            width: bounds.width - padding * 2,
            height: SidebarExpandedMetrics.sectionHeaderHeight
        )
        let heading = isCollapsed.map { "\($0 ? "▸" : "▾") \(title)" } ?? title
        let label = textLabel(
            heading.uppercased(),
            font: .monospacedSystemFont(ofSize: 10, weight: .bold),
            color: NSColor.white.withAlphaComponent(0.46)
        )
        label.frame = headerFrame
        addSubviewDoc(label)
        expandedViews.append(label)
        if isCollapsed != nil {
            hitAreas.append(SidebarHitArea(
                frame: headerFrame,
                region: .link(url: SidebarView.inactiveSectionActionURL, label: label)
            ))
        }

        let countChip = badgeView(
            "\(count)",
            color: NSColor.white.withAlphaComponent(0.60),
            background: NSColor.white.withAlphaComponent(0.07)
        )
        countChip.frame = NSRect(
            x: padding + (isCollapsed == nil ? 62 : 82),
            y: yOffset - 18,
            width: 28,
            height: 18
        )
        countChip.setAccessibilityRole(.staticText)
        countChip.setAccessibilityLabel("\(count)")
        addSubviewDoc(countChip)
        expandedViews.append(countChip)

        return yOffset - SidebarExpandedMetrics.sectionHeaderAdvance
    }

    private func buildWorkspaceGroup(_ infos: [WorkspaceInfo], padding: CGFloat, yOffset: CGFloat) -> CGFloat {
        var currentY = yOffset
        for workspace in infos {
            currentY = buildWorkspaceSection(workspace: workspace, padding: padding, yOffset: currentY)
            currentY -= SidebarExpandedMetrics.workspaceGap
        }
        return currentY
    }

    private func buildShortcutHint(padding: CGFloat, yOffset: CGFloat) -> CGFloat {
        let hint = SidebarShortcutHintView(hints: [
            SidebarShortcutHint(key: NiruxShortcuts.newWorkspaceDisplay, label: "workspace"),
            SidebarShortcutHint(key: NiruxShortcuts.newTerminalDisplay, label: "pane")
        ])
        hint.frame = NSRect(
            x: padding,
            y: yOffset - SidebarExpandedMetrics.shortcutHintHeight,
            width: bounds.width - padding * 2,
            height: SidebarExpandedMetrics.shortcutHintHeight
        )
        addSubviewDoc(hint)
        expandedViews.append(hint)
        return yOffset - SidebarExpandedMetrics.shortcutHintHeight
    }

    // MARK: - Workspace section

    private func buildWorkspaceSection(workspace: WorkspaceInfo, padding: CGFloat, yOffset: CGFloat) -> CGFloat {
        let result = SidebarWorkspaceCardRenderer(
            workspace: workspace,
            sidebarWidth: bounds.width,
            padding: padding,
            yOffset: yOffset
        ).render()
        for view in result.views {
            addSubviewDoc(view)
            expandedViews.append(view)
        }
        hitAreas.append(contentsOf: result.hitAreas)
        cardHoverViews[workspace.index] = result.cardHoverView
        if let badge = result.menuBadge { menuBadgeViews[workspace.index] = badge }
        columnHoverViews[workspace.index] = result.columnHoverViews
        return result.bottomY
    }

    // MARK: - Small controls

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

}
