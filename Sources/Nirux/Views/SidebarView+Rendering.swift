import AppKit

extension Notification.Name {
    static let niruxSidebarActivityEntryActivated = Notification.Name(
        "nirux.sidebar.activity-entry-activated"
    )
}

/// Transparent click and hover surface laid over one Activity row. Keeping
/// this control local to the renderer preserves the redesigned sidebar's
/// workspace hit-testing model.
private final class SidebarActivityHitView: NSView {
    var onActivate: (() -> Void)?
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let next = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(next)
        tracking = next
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    override func mouseDown(with event: NSEvent) {
        onActivate?()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

// MARK: - Rendering

extension SidebarView {

    /// Main entry point for rebuilding the sidebar's content: the rail or
    /// the cards.
    func rebuildContent() {
        // Never rebuild mid-drag: rows would shift under the captured drag
        // geometry. SidebarView+Drag defers updates until the drag ends.
        guard workspaceDrag == nil else {
            rebuildSkippedDuringDrag = true
            return
        }
        resetRenderState()
        guard isExpanded else {
            // Kept across rebuilds, put back by the next expanded one.
            onboardingCardView?.removeFromSuperview()
            approvalButtonArming.removeAll()
            guard !isRailHidden else { return }
            let docHeight = buildRail()
            refreshHoverTargetFromMouse()
            followActiveWorkspace(docHeight: docHeight)
            return
        }

        rebuildBottomIndicators()

        let padding = SidebarExpandedMetrics.padding
        let activeInfos = displayedWorkspaceInfos.filter { !$0.isInactive }
        let inactiveInfos = displayedWorkspaceInfos.filter { $0.isInactive }
        let listedActiveInfos = activeInfos.filter(listsWorkspace)
        let listedInactiveInfos = inactiveInfos.filter(listsWorkspace)
        let hasWorkspaces = !activeInfos.isEmpty || !inactiveInfos.isEmpty
        let activeProfile = lastProfiles.first(where: { $0.isActive })
        let activityRows = ActivityStore.shared.visibleFeedEntries(maxCount: Self.activityMaxRows)
        let onboardingCard = preparedOnboardingCard()

        let contentH = expandedContentHeight(
            activeInfos: activeInfos,
            inactiveInfos: inactiveInfos,
            listedInactiveInfos: listedInactiveInfos,
            activityCount: activityRows.count,
            onboardingHeight: onboardingCard?.height
        )

        let docHeight = max(bounds.height, contentH)
        contentDocumentView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: docHeight)

        var yOffset = docHeight - SidebarExpandedMetrics.verticalPadding

        if let activeProfile {
            yOffset = buildSpaceHeader(activeProfile, padding: padding, yOffset: yOffset)
            yOffset -= SidebarExpandedMetrics.spaceHeaderBottomGap
        }

        if !activeInfos.isEmpty {
            yOffset = buildSectionHeader("active", count: activeInfos.count, padding: padding, yOffset: yOffset)
            yOffset = buildWorkspaceGroup(listedActiveInfos, padding: padding, yOffset: yOffset)
        }
        if !inactiveInfos.isEmpty {
            yOffset -= SidebarExpandedMetrics.sectionGap
            yOffset = buildSectionHeader(
                "inactive", count: inactiveInfos.count, padding: padding,
                yOffset: yOffset, isCollapsed: isInactiveSectionCollapsed
            )
            yOffset = buildWorkspaceGroup(listedInactiveInfos, padding: padding, yOffset: yOffset)
        }
        // The checklist teaches the same chords as the hint, and more.
        if let onboardingCard {
            yOffset -= SidebarExpandedMetrics.onboardingCardGap
            onboardingCard.frame.origin = NSPoint(
                x: SidebarExpandedMetrics.workspaceInsetX,
                y: yOffset - onboardingCard.height
            )
            yOffset -= onboardingCard.height
        } else if hasWorkspaces {
            yOffset -= SidebarExpandedMetrics.shortcutHintGap
            yOffset = buildShortcutHint(padding: padding, yOffset: yOffset)
        }
        if !activityRows.isEmpty {
            yOffset -= SidebarExpandedMetrics.sectionGap
            yOffset = buildActivitySection(
                activityRows,
                padding: padding,
                yOffset: yOffset
            )
        }

        refreshHoverTargetFromMouse()
        refreshApprovalArming()
        followActiveWorkspace(docHeight: docHeight)
        if revealsOnboardingCardOnNextBuild, onboardingCard != nil {
            revealsOnboardingCardOnNextBuild = false
            revealOnboardingCard()
        }
    }

    /// Scrolls the active workspace into view when it changed, or to the
    /// top on the first build.
    private func followActiveWorkspace(docHeight: CGFloat) {
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

    /// Size the scrollable document so content is top-anchored and never
    /// hides behind the bottom space switcher.
    private func expandedContentHeight(
        activeInfos: [WorkspaceInfo], inactiveInfos: [WorkspaceInfo], listedInactiveInfos: [WorkspaceInfo],
        activityCount: Int, onboardingHeight: CGFloat?
    ) -> CGFloat {
        let listedActiveInfos = activeInfos.filter(listsWorkspace)
        var height = SidebarExpandedMetrics.verticalPadding
            + SidebarExpandedMetrics.spaceHeaderHeight
            + SidebarExpandedMetrics.spaceHeaderBottomGap
            + SidebarExpandedMetrics.bottomReserve
        if !activeInfos.isEmpty {
            height += SidebarExpandedMetrics.sectionHeaderAdvance
            height += SidebarExpandedMetrics.groupHeight(for: listedActiveInfos, sidebarWidth: bounds.width)
                + groupTogglesHeight(listedActiveInfos)
        }
        if !inactiveInfos.isEmpty {
            height += SidebarExpandedMetrics.sectionGap
            height += SidebarExpandedMetrics.sectionHeaderAdvance
            height += SidebarExpandedMetrics.groupHeight(for: listedInactiveInfos, sidebarWidth: bounds.width)
                + groupTogglesHeight(listedInactiveInfos)
        }
        if let onboardingHeight {
            height += SidebarExpandedMetrics.onboardingCardGap + onboardingHeight
        } else if !activeInfos.isEmpty || !inactiveInfos.isEmpty {
            height += SidebarExpandedMetrics.shortcutHintGap + SidebarExpandedMetrics.shortcutHintHeight
        }
        if activityCount > 0 {
            height += SidebarExpandedMetrics.sectionGap
                + SidebarExpandedMetrics.sectionHeaderAdvance
                + CGFloat(activityCount) * Self.activityRowAdvance
        }
        return height
    }

    /// Tear down every view and state snapshot from the previous render
    /// pass before rebuilding.
    private func resetRenderState() {
        expandedViews.forEach { $0.removeFromSuperview() }
        expandedViews.removeAll()
        profileIndicatorView?.removeFromSuperview()
        profileIndicatorView = nil
        hitAreas.removeAll()
        cardHoverViews.removeAll()
        menuBadgeViews.removeAll()
        columnHoverViews.removeAll()
        approvalButtonViews.removeAll()
        spaceHeaderHoverView = nil
        spaceHeaderBadge = nil
        railTileViews.removeAll()
        hoveredTarget = nil
        hideRailTooltip()
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

        let title = textLabel(profile.name, font: Theme.Font.display, color: Theme.Color.textPrimary)
        title.frame = NSRect(x: padding + 16, y: yOffset - 33, width: bounds.width - padding * 2 - 16 - 40, height: 20)
        addSubviewDoc(title)
        expandedViews.append(title)

        // "⋯" space-options badge — same affordance language as the
        // workspace cards; brightens with the header hover.
        let badge = SidebarBadgeView(
            text: "", textColor: Theme.Color.textSecondary, fillColor: Theme.Color.fillHover, font: Theme.Font.caption
        )
        badge.symbolName = Theme.Symbol.more
        badge.hoverTextColor = Theme.Color.textPrimary
        badge.hoverFillColor = Theme.Color.fillPressed
        badge.frame = NSRect(
            x: bounds.width - padding - SidebarExpandedMetrics.countChipWidth,
            y: yOffset - 34,
            width: SidebarExpandedMetrics.countChipWidth,
            height: SidebarExpandedMetrics.countChipHeight
        )
        badge.toolTip = "Project options"
        addSubviewDoc(badge)
        expandedViews.append(badge)
        spaceHeaderBadge = badge

        let subtitle = NSTextField.sidebarLine(spaceSubtitle(profile))
        subtitle.frame = NSRect(x: padding, y: yOffset - 54, width: bounds.width - padding * 2, height: 16)
        addSubviewDoc(subtitle)
        expandedViews.append(subtitle)

        let separator = SidebarBackgroundView(frame: NSRect(x: padding, y: headerFrame.minY, width: bounds.width - padding * 2, height: 1))
        separator.wantsLayer = true
        separator.layer?.backgroundColor = Theme.Color.line.cgColor
        addSubviewDoc(separator)
        expandedViews.append(separator)

        return yOffset - SidebarExpandedMetrics.spaceHeaderHeight
    }

    /// "6 workspaces · 2 waiting": the waiting count in amber, when any.
    private func spaceSubtitle(_ profile: ProfileInfo) -> NSAttributedString {
        let font = Theme.Font.caption
        let text = NSMutableAttributedString(string: Self.workspaceCountText(profile.workspaceCount), attributes: [
            .font: font, .foregroundColor: Theme.Color.textTertiary
        ])
        let waiting = lastInfos.filter { $0.cardState == .waiting }.count
        if waiting > 0 {
            text.append(NSAttributedString(string: " · ", attributes: [.font: font, .foregroundColor: Theme.Color.textTertiary]))
            text.append(NSAttributedString(string: "\(waiting) waiting", attributes: [
                .font: font, .foregroundColor: Theme.Color.waiting
            ]))
        }
        return text
    }

    /// "1 workspace", "6 workspaces".
    static func workspaceCountText(_ count: Int) -> String {
        "\(count) \(count == 1 ? "workspace" : "workspaces")"
    }

    static func profileColor(hex: String) -> NSColor {
        NSColor.niruxColor(hex: hex) ?? Theme.Color.accent
    }

    // MARK: - Bottom spaces

    private func rebuildBottomIndicators() {
        var items = lastProfiles.map { profile in
            SidebarDotIndicatorItem(
                action: .selectProfile(profile.id),
                colorHex: profile.colorHex,
                isActive: profile.isActive,
                attention: profile.attention,
                label: nil,
                isEmpty: profile.workspaceCount == 0
            )
        }
        items.append(SidebarDotIndicatorItem(
            action: .createProfile,
            colorHex: "#FFFFFF",
            isActive: false,
            attention: nil,
            label: "+"
        ))
        let view = SidebarDotIndicatorView(
            frame: NSRect(x: 0, y: 0, width: bounds.width, height: 54),
            items: items,
            tooltip: "Projects"
        )
        view.menuProvider = { [weak self] action in
            guard case .selectProfile(let profileID) = action,
                  let profile = self?.lastProfiles.first(where: { $0.id == profileID })
            else { return nil }
            let menu = NSMenu()
            self?.addSpaceManagementItems(to: menu, for: profile)
            return menu
        }
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
        let label = NSTextField.sidebarLine(NSAttributedString(string: heading.uppercased(), attributes: [
            .font: Theme.Font.label, .kern: Theme.Font.labelKern, .foregroundColor: Theme.Color.textTertiary
        ]))
        label.frame = headerFrame
        addSubviewDoc(label)
        expandedViews.append(label)
        if let isCollapsed {
            // The whole row, as wide as the cards and down to the first
            // one, not just the text band.
            let inset = SidebarExpandedMetrics.workspaceInsetX
            let rowFrame = NSRect(
                x: inset,
                y: yOffset - SidebarExpandedMetrics.sectionHeaderAdvance,
                width: bounds.width - inset * 2,
                height: SidebarExpandedMetrics.sectionHeaderAdvance
            )
            hitAreas.append(SidebarHitArea(
                frame: rowFrame,
                region: .link(url: SidebarView.inactiveSectionActionURL, label: label)
            ))
            let toggle = SidebarSectionToggleView(frame: rowFrame)
            toggle.setAccessibilityLabel("\(title.capitalized) workspaces, \(count)")
            toggle.setAccessibilityExpanded(!isCollapsed)
            toggle.onPress = { [weak self] in self?.toggleInactiveSection() }
            label.setAccessibilityElement(false)
            addSubviewDoc(toggle)
            expandedViews.append(toggle)
        }

        let countChip = SidebarBadgeView(
            text: "\(count)", textColor: Theme.Color.textTertiary, fillColor: Theme.Color.fillHover, font: Theme.Font.label
        )
        countChip.cornerRadius = Theme.Radius.chip
        let labelWidth = ceil(label.attributedStringValue.size().width)
        let countWidth = ceil(("\(count)" as NSString).size(withAttributes: [.font: Theme.Font.label]).width)
        countChip.frame = NSRect(
            x: padding + labelWidth + 6,
            y: yOffset - 15,
            width: max(18, countWidth + 10),
            height: 14
        )
        countChip.setAccessibilityRole(.staticText)
        countChip.setAccessibilityLabel("\(count)")
        // The toggle button already says it.
        countChip.setAccessibilityElement(isCollapsed == nil)
        addSubviewDoc(countChip)
        expandedViews.append(countChip)

        return yOffset - SidebarExpandedMetrics.sectionHeaderAdvance
    }

    private func buildWorkspaceGroup(_ infos: [WorkspaceInfo], padding: CGFloat, yOffset: CGFloat) -> CGFloat {
        var currentY = yOffset
        for workspace in infos {
            currentY = buildWorkspaceSection(workspace: workspace, padding: padding, yOffset: currentY)
            currentY -= SidebarExpandedMetrics.workspaceGap
            if showsGroupToggle(workspace) {
                currentY = buildGroupToggle(workspace, yOffset: currentY) - SidebarExpandedMetrics.workspaceGap
            }
        }
        return currentY
    }

    static let shortcutHints = [
        SidebarShortcutHint(key: NiruxShortcuts.newWorkspaceDisplay, label: "workspace"),
        SidebarShortcutHint(key: NiruxShortcuts.newTerminalDisplay, label: "column")
    ]

    private func buildShortcutHint(padding: CGFloat, yOffset: CGFloat) -> CGFloat {
        let hint = SidebarShortcutHintView(hints: Self.shortcutHints)
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

    // MARK: - Getting Started checklist

    /// The checklist card laid out for the current width, added to the
    /// document view; nil (and the card dropped) when there is no checklist.
    private func preparedOnboardingCard() -> OnboardingChecklistView? {
        guard let checklist = onboardingChecklist else {
            onboardingCardView?.removeFromSuperview()
            onboardingCardView = nil
            return nil
        }
        let width = bounds.width - SidebarExpandedMetrics.workspaceInsetX * 2
        // Mid-expansion the sidebar can still be collapsed-width.
        guard width >= 160 else {
            onboardingCardView?.removeFromSuperview()
            return nil
        }
        let card = onboardingCardView ?? OnboardingChecklistView()
        card.onAction = { [weak self] action in self?.onOnboardingAction?(action) }
        card.update(checklist: checklist, width: width)
        if card.superview !== contentDocumentView { addSubviewDoc(card) }
        onboardingCardView = card
        return card
    }

    /// Scrolls the checklist into view, below a long workspace list; waits
    /// for the next build when the card isn't laid out (sidebar opening).
    func revealOnboardingCard() {
        guard isExpanded, let card = onboardingCardView, card.superview === contentDocumentView else {
            revealsOnboardingCardOnNextBuild = true
            return
        }
        contentDocumentView.scrollToVisible(card.frame.insetBy(dx: 0, dy: -12))
    }

    // MARK: - Activity feed

    private static let activityMaxRows = 6
    private static let activityRowAdvance: CGFloat = 28
    private static let activitySectionIdentifier = NSUserInterfaceItemIdentifier(
        "nirux.sidebar.activity-section"
    )

    /// True when at least part of Activity intersects the scrolled viewport.
    var isActivityFeedVisible: Bool {
        guard isExpanded,
              let marker = expandedViews.first(where: {
                  $0.identifier == Self.activitySectionIdentifier
              })
        else { return false }
        return marker.frame.intersects(contentScrollView.documentVisibleRect)
    }

    private func buildActivitySection(
        _ rows: [ActivityEntry],
        padding: CGFloat,
        yOffset: CGFloat
    ) -> CGFloat {
        let sectionTop = yOffset
        var currentY = buildSectionHeader(
            "activity",
            count: ActivityStore.shared.unreadCount,
            padding: padding,
            yOffset: yOffset
        )
        currentY = buildActivityRows(rows, padding: padding, yOffset: currentY)

        let marker = SidebarBackgroundView(frame: NSRect(
            x: 0, y: currentY, width: bounds.width, height: sectionTop - currentY
        ))
        marker.identifier = Self.activitySectionIdentifier
        addSubviewDoc(marker)
        expandedViews.append(marker)
        return currentY
    }

    private func isActivityTargetGone(_ entry: ActivityEntry) -> Bool {
        guard let id = entry.workspaceID else { return true }
        return !lastInfos.contains(where: { $0.id == id })
    }

    private func buildActivityRows(
        _ rows: [ActivityEntry],
        padding: CGFloat,
        yOffset: CGFloat
    ) -> CGFloat {
        var currentY = yOffset
        for (index, entry) in rows.enumerated() {
            let rowFrame = NSRect(
                x: padding,
                y: currentY - Self.activityRowAdvance,
                width: bounds.width - padding * 2,
                height: Self.activityRowAdvance
            )
            buildActivityRow(entry, index: index, feed: rows, padding: padding, frame: rowFrame)
            currentY -= Self.activityRowAdvance
        }
        return currentY
    }

    private struct ActivityRowStyle {
        let canReply: Bool
        let targetGone: Bool
        let isRead: Bool
        let isHandled: Bool
        let textAlpha: CGFloat
        let dotAlpha: CGFloat
        let ageAlpha: CGFloat

        var canActivate: Bool { canReply || !targetGone }
    }

    private func activityRowStyle(
        for entry: ActivityEntry, index: Int, feed: [ActivityEntry]
    ) -> ActivityRowStyle {
        let canReply = entry.category == .missionQuestion
            && entry.missionEventID.map { MissionStore.shared.response(to: $0) == nil } == true
        let targetGone = !canReply && isActivityTargetGone(entry)
        let isRead = [.missionResponse, .missionInstruction].contains(entry.category)
            || entry.timestamp <= ActivityStore.shared.lastReadTimestamp
        return ActivityRowStyle(
            canReply: canReply,
            targetGone: targetGone,
            isRead: isRead,
            isHandled: ActivityStore.isAttentionSuperseded(at: index, in: feed),
            textAlpha: targetGone ? 0.30 : (isRead ? 0.45 : 0.85),
            dotAlpha: targetGone ? 0.25 : (isRead ? 0.40 : 1.0),
            ageAlpha: targetGone ? 0.20 : (isRead ? 0.26 : 0.38)
        )
    }

    private func buildActivityRow(
        _ entry: ActivityEntry,
        index: Int,
        feed: [ActivityEntry],
        padding: CGFloat,
        frame: NSRect
    ) {
        let style = activityRowStyle(for: entry, index: index, feed: feed)
        let tooltip = activityTooltip(for: entry, style: style)
        addActivityDot(for: entry, frame: frame, padding: padding, style: style)
        addActivityText(for: entry, tooltip: tooltip, frame: frame, padding: padding, style: style)
        if style.canActivate {
            addActivityHit(for: entry, tooltip: tooltip, frame: frame)
        }
    }

    private func activityTooltip(for entry: ActivityEntry, style: ActivityRowStyle) -> String {
        var tooltip = activityText(for: entry)
        if style.isHandled { tooltip += " — handled" }
        if style.canReply { tooltip += " — click to reply" }
        if style.targetGone { tooltip += " — workspace closed" }
        return tooltip
    }

    private func addActivityDot(
        for entry: ActivityEntry, frame: NSRect, padding: CGFloat, style: ActivityRowStyle
    ) {
        let dot = SidebarBackgroundView(frame: NSRect(
            x: padding + 2,
            y: frame.minY + (Self.activityRowAdvance - 7) / 2,
            width: 7,
            height: 7
        ))
        dot.wantsLayer = true
        let color: NSColor = style.isHandled
            ? Theme.Color.textTertiary.withAlphaComponent(style.dotAlpha)
            : Self.activityColor(for: entry).withAlphaComponent(style.dotAlpha)
        dot.layer?.backgroundColor = color.cgColor
        dot.layer?.cornerRadius = 3.5
        addSubviewDoc(dot)
        expandedViews.append(dot)
    }

    private func addActivityText(
        for entry: ActivityEntry,
        tooltip: String,
        frame: NSRect,
        padding: CGFloat,
        style: ActivityRowStyle
    ) {
        let label = textLabel(
            activityText(for: entry),
            font: .systemFont(ofSize: 11, weight: .medium),
            color: NSColor.white.withAlphaComponent(style.textAlpha)
        )
        label.toolTip = tooltip
        // Read state is otherwise conveyed by opacity alone.
        label.setAccessibilityLabel(style.isRead ? tooltip : "unread, \(tooltip)")
        label.frame = NSRect(
            x: padding + 16,
            y: frame.minY + 2,
            width: bounds.width - padding * 2 - 16 - 44,
            height: 16
        )
        addSubviewDoc(label)
        expandedViews.append(label)

        let age = textLabel(
            Self.relativeAge(since: entry.timestamp),
            font: .monospacedSystemFont(ofSize: 10, weight: .regular),
            color: NSColor.white.withAlphaComponent(style.ageAlpha)
        )
        age.alignment = .right
        age.frame = NSRect(
            x: bounds.width - padding - 44,
            y: frame.minY + 3,
            width: 44,
            height: 14
        )
        addSubviewDoc(age)
        expandedViews.append(age)
    }

    private func addActivityHit(for entry: ActivityEntry, tooltip: String, frame: NSRect) {
        let hit = SidebarActivityHitView(frame: frame.insetBy(dx: -8, dy: 1))
        hit.wantsLayer = true
        hit.layer?.cornerRadius = 5
        hit.toolTip = tooltip
        hit.setAccessibilityRole(.button)
        hit.setAccessibilityLabel(tooltip)
        hit.onActivate = { [weak self] in
            guard let self else { return }
            NotificationCenter.default.post(
                name: .niruxSidebarActivityEntryActivated,
                object: self,
                userInfo: ["entry": entry]
            )
        }
        addSubviewDoc(hit)
        expandedViews.append(hit)
    }

    /// Amber only for what waits on the user; an attention row an older
    /// build recorded doesn't say, and stays amber.
    static func activityColor(for entry: ActivityEntry) -> NSColor {
        switch entry.category {
        case .attention: return SidebarRenderer.color(for: entry.signal ?? .waiting)
        case .turnComplete: return SidebarRenderer.color(for: .finished)
        case .sessionStart: return Theme.Color.accent
        case .sessionEnd: return Theme.Color.textTertiary
        case .missionQuestion: return Theme.Color.waiting
        case .missionCompleted: return Theme.Color.success
        case .missionResponse, .missionInstruction: return Theme.Color.accent
        }
    }

    private func activityText(for entry: ActivityEntry) -> String {
        // Agent-provided text: one clean line (older builds stored raw
        // notification messages).
        let detail = entry.detail.flatMap { AgentText.clean($0, maxLength: 300) }
        let summary: String
        switch entry.category {
        case .attention: summary = detail ?? "needs input"
        case .turnComplete: summary = "turn finished"
        case .sessionStart: summary = "session started"
        case .sessionEnd: summary = "session ended"
        case .missionQuestion: summary = "question: \(detail ?? "needs input")"
        case .missionCompleted: summary = "completed: \(detail ?? "done")"
        case .missionResponse: summary = "replied: \(detail ?? "response sent")"
        case .missionInstruction: summary = "told: \(detail ?? "message sent")"
        }
        return "\(entry.workspaceTitle) · \(entry.agentKind) · \(summary)"
    }

    /// A card's age: "now" in the first minute, then `relativeAge`. Seconds
    /// would rebuild the sidebar (and drop its tooltips) every heartbeat.
    nonisolated static func cardAge(since timestamp: TimeInterval, now: Date = Date()) -> String {
        now.timeIntervalSince1970 - timestamp < 60 ? "now" : relativeAge(since: timestamp, now: now)
    }

    /// Compact relative timestamp ("42s", "12m", "1h05", "3d"). Pure —
    /// nonisolated so tests (and any future non-view caller) can use it.
    nonisolated static func relativeAge(since timestamp: TimeInterval, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince1970 - timestamp))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86400 { return "\(seconds / 3600)h\(String(format: "%02d", (seconds % 3600) / 60))" }
        return "\(seconds / 86400)d"
    }

    // MARK: - Workspace section

    private func buildWorkspaceSection(workspace: WorkspaceInfo, padding: CGFloat, yOffset: CGFloat) -> CGFloat {
        let result = SidebarWorkspaceCardRenderer(
            workspace: workspace,
            sidebarWidth: bounds.width,
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
        approvalButtonViews.merge(result.approvalButtons) { _, new in new }
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
}
