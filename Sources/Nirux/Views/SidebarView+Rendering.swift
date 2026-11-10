import AppKit

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

        // The space's Lead goes above the Tasks header (docs/spaces.md).
        let leadInfos = displayedWorkspaceInfos.filter { !$0.isInactive && $0.isLead }
        let activeInfos = displayedWorkspaceInfos.filter { !$0.isInactive && !$0.isLead }
        let inactiveInfos = displayedWorkspaceInfos.filter { $0.isInactive }
        let listedInactiveInfos = inactiveInfos.filter(listsWorkspace)
        let archivedListHeight = archivedListHeight(listedInactiveInfos)
        let activeProfile = lastProfiles.first(where: { $0.isActive })
        let onboardingCard = preparedOnboardingCard()

        let contentH = expandedContentHeight(
            hasPicker: activeProfile != nil,
            leadInfos: leadInfos,
            activeInfos: activeInfos,
            archivedHeight: inactiveInfos.isEmpty ? nil : archivedListHeight,
            onboardingHeight: onboardingCard?.height
        )

        let docHeight = max(bounds.height, contentH)
        contentDocumentView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: docHeight)

        var yOffset = docHeight - SidebarExpandedMetrics.topPadding
        if let activeProfile {
            yOffset = buildSpacePicker(activeProfile, top: yOffset)
            yOffset -= SidebarExpandedMetrics.pickerBottomGap
        }
        if !leadInfos.isEmpty {
            yOffset = buildWorkspaceGroup(leadInfos, yOffset: yOffset) + SidebarExpandedMetrics.workspaceGap
            yOffset -= SidebarExpandedMetrics.leadGap
        }
        yOffset = buildTasksHeader(top: yOffset)
        yOffset = buildWorkspaceGroup(activeInfos, yOffset: yOffset)
        if let onboardingCard {
            yOffset -= SidebarExpandedMetrics.onboardingCardGap
            onboardingCard.frame.origin = NSPoint(
                x: SidebarExpandedMetrics.workspaceInsetX,
                y: yOffset - onboardingCard.height
            )
        }
        if !inactiveInfos.isEmpty {
            buildArchivedBlock(count: inactiveInfos.count, listed: listedInactiveInfos, listHeight: archivedListHeight)
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

    /// Everything the expanded sidebar stacks, so the document view holds
    /// it all: the picker, the Tasks header and the cards (with the
    /// checklist) from the top, the archived block from the bottom.
    /// `archivedHeight`: the archived list's (`archivedListHeight`), nil
    /// without an Archived row.
    private func expandedContentHeight(
        hasPicker: Bool, leadInfos: [WorkspaceInfo], activeInfos: [WorkspaceInfo], archivedHeight: CGFloat?,
        onboardingHeight: CGFloat?
    ) -> CGFloat {
        typealias Metrics = SidebarExpandedMetrics
        var height = Metrics.topPadding + Metrics.tasksHeaderHeight
            + Metrics.groupHeight(for: activeInfos, sidebarWidth: bounds.width)
        if !leadInfos.isEmpty {
            height += Metrics.groupHeight(for: leadInfos, sidebarWidth: bounds.width) - Metrics.workspaceGap + Metrics.leadGap
        }
        if hasPicker { height += Metrics.pickerHeight + Metrics.pickerBottomGap }
        if let onboardingHeight { height += Metrics.onboardingCardGap + onboardingHeight }
        if let archivedHeight { height += Metrics.archivedGap + archivedHeight + Metrics.archivedRowHeight }
        return height + Metrics.bottomPadding
    }

    /// The archived workspaces listed above the Archived row, with the line
    /// above them and the gap under them; 0 when none is listed.
    private func archivedListHeight(_ listed: [WorkspaceInfo]) -> CGFloat {
        guard !listed.isEmpty else { return 0 }
        return 1 + SidebarExpandedMetrics.workspaceGap
            + SidebarExpandedMetrics.groupHeight(for: listed, sidebarWidth: bounds.width)
            - SidebarExpandedMetrics.workspaceGap + SidebarExpandedMetrics.archivedListGap
    }

    /// Tear down every view and state snapshot from the previous render
    /// pass before rebuilding.
    private func resetRenderState() {
        expandedViews.forEach { $0.removeFromSuperview() }
        expandedViews.removeAll()
        hitAreas.removeAll()
        cardHoverViews.removeAll()
        menuBadgeViews.removeAll()
        columnHoverViews.removeAll()
        approvalButtonViews.removeAll()
        spacePickerHoverView = nil
        newTaskButton = nil
        archivedRowHoverView = nil
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

    // MARK: - Space picker

    /// The active space's color, its name and a chevron: a click lists the
    /// spaces (`spacePickerMenu`). A small amber dot before the chevron
    /// says an agent waits on the user in another space, which the
    /// sidebar doesn't show.
    private func buildSpacePicker(_ profile: ProfileInfo, top: CGFloat) -> CGFloat {
        typealias Metrics = SidebarExpandedMetrics
        let frame = spacePickerFrame(top: top)
        hitAreas.append(SidebarHitArea(frame: frame, region: .spacePicker))

        spacePickerHoverView = addRowHover(frame: frame)

        let dotSize = Metrics.pickerDotSize
        let dot = SidebarBackgroundView(frame: NSRect(
            x: Metrics.markCenterX - dotSize / 2, y: frame.midY - dotSize / 2, width: dotSize, height: dotSize
        ))
        dot.wantsLayer = true
        dot.layer?.backgroundColor = Self.profileColor(hex: profile.colorHex).cgColor
        dot.layer?.cornerRadius = dotSize / 2
        addExpandedView(dot)

        var maxX = frame.maxX - Metrics.cardPaddingX
        let chevron = SidebarImageView(image: SidebarRenderer.symbol(
            Theme.Symbol.spacePicker, color: Theme.Color.textSecondary, pointSize: 11
        ))
        chevron.frame = NSRect(x: maxX - 12, y: frame.midY - 7, width: 12, height: 14)
        chevron.setAccessibilityElement(false)
        addExpandedView(chevron)
        maxX = chevron.frame.minX - Theme.Space.sm

        let waitingElsewhere = spacesWaitingElsewhere
        if !waitingElsewhere.isEmpty {
            let amber = SidebarBackgroundView(frame: NSRect(x: maxX - 7, y: frame.midY - 3.5, width: 7, height: 7))
            amber.wantsLayer = true
            amber.layer?.backgroundColor = Theme.Color.waiting.cgColor
            amber.layer?.cornerRadius = 3.5
            addExpandedView(amber)
            maxX = amber.frame.minX - Theme.Space.sm
        }

        let nameX = Metrics.textX
        let name = textLabel(profile.name, font: Theme.Font.display, color: Theme.Color.textPrimary)
        let nameHeight = ceil(name.fittingSize.height)
        name.frame = NSRect(x: nameX, y: frame.midY - nameHeight / 2, width: max(0, maxX - nameX), height: nameHeight)
        name.setAccessibilityElement(false)
        addExpandedView(name)

        // A pull-down: spaces and commands. VoiceOver reads "Space", the
        // space's name, and the wait elsewhere the amber dot shows.
        let button = SidebarSectionToggleView(frame: frame)
        button.acceptsFirstClick = false
        button.role = .menuButton
        button.setAccessibilityLabel("Space")
        var value = profile.name
        if !waitingElsewhere.isEmpty {
            let note = "An agent waits for you in \(ListFormatter.localizedString(byJoining: waitingElsewhere.map(\.name)))"
            value += ". \(note)"
            button.toolTip = note
        }
        button.setAccessibilityValue(value)
        button.onPress = { [weak self] in self?.showSpacePicker() }
        addExpandedView(button)
        return frame.minY
    }

    /// The other spaces where an agent waits on the user: the sidebar
    /// lists only the active space's, so the picker (and the rail's space
    /// tile) marks them.
    var spacesWaitingElsewhere: [ProfileInfo] {
        lastProfiles.filter { !$0.isActive && $0.attention == .waiting }
    }

    /// The picker's row, as wide as the cards.
    private func spacePickerFrame(top: CGFloat) -> NSRect {
        let inset = SidebarExpandedMetrics.workspaceInsetX
        return NSRect(
            x: inset, y: top - SidebarExpandedMetrics.pickerHeight,
            width: bounds.width - inset * 2, height: SidebarExpandedMetrics.pickerHeight
        )
    }

    /// "1 workspace", "6 workspaces".
    static func workspaceCountText(_ count: Int) -> String {
        "\(count) \(count == 1 ? "workspace" : "workspaces")"
    }

    static func profileColor(hex: String) -> NSColor {
        NSColor.niruxColor(hex: hex) ?? Theme.Color.accent
    }

    // MARK: - Tasks

    /// "Tasks", and "+" for a new one, under the Lead's row.
    private func buildTasksHeader(top: CGFloat) -> CGFloat {
        typealias Metrics = SidebarExpandedMetrics
        let rowY = top - Metrics.tasksHeaderHeight
        let x = Metrics.workspaceInsetX + Metrics.cardPaddingX
        let label = textLabel("Tasks", font: Theme.Font.captionEmphasized, color: Theme.Color.textTertiary)
        let labelHeight = ceil(label.fittingSize.height)
        label.frame = NSRect(x: x, y: rowY + (Metrics.tasksHeaderHeight - labelHeight) / 2, width: 120, height: labelHeight)
        label.setAccessibilityRole(.staticText)
        addExpandedView(label)

        let size = Metrics.headerButtonSize
        let buttonFrame = NSRect(
            x: bounds.width - Metrics.workspaceInsetX - Metrics.cardPaddingX + (Theme.Space.xs + 2) - size,
            y: rowY + (Metrics.tasksHeaderHeight - size) / 2, width: size, height: size
        )
        let button = SidebarBadgeView(text: "", textColor: Theme.Color.textSecondary, fillColor: .clear, font: Theme.Font.caption)
        button.symbolName = Theme.Symbol.add
        button.hoverTextColor = Theme.Color.textPrimary
        button.hoverFillColor = Theme.Color.fillPressed
        button.frame = buttonFrame
        button.toolTip = "\(Self.newTaskTitle) (\(NiruxShortcuts.newWorkspaceDisplay))"
        button.setAccessibilityElement(true)
        button.setAccessibilityRole(.button)
        button.setAccessibilityLabel(Self.newTaskTitle)
        button.onPress = { [weak self] in self?.onNewWorkspace?() }
        addExpandedView(button)
        newTaskButton = button
        hitAreas.append(SidebarHitArea(frame: buttonFrame.insetBy(dx: -4, dy: -3), region: .newTask))
        return rowY
    }

    /// What the Tasks header's "+" and the rail's "+" open: ⌘N's sheet.
    static let newTaskTitle = "New…"

    private func buildWorkspaceGroup(_ infos: [WorkspaceInfo], yOffset: CGFloat) -> CGFloat {
        var currentY = yOffset
        for workspace in infos {
            currentY = buildWorkspaceSection(workspace: workspace, yOffset: currentY)
            currentY -= SidebarExpandedMetrics.workspaceGap
        }
        return currentY
    }

    // MARK: - Archived

    /// The Archived row at the bottom, and above it, after a line, the
    /// archived workspaces it lists: all of them unfolded; folded, the one
    /// on screen and those asking the user (`listsWorkspace`). The row
    /// keeps its place when the list opens, so the same click folds it.
    private func buildArchivedBlock(count: Int, listed: [WorkspaceInfo], listHeight: CGFloat) {
        typealias Metrics = SidebarExpandedMetrics
        let inset = Metrics.workspaceInsetX
        let rowFrame = NSRect(
            x: inset, y: Metrics.bottomPadding, width: bounds.width - inset * 2, height: Metrics.archivedRowHeight
        )
        buildArchivedRow(count: count, frame: rowFrame)
        guard !listed.isEmpty else { return }

        let listTop = rowFrame.maxY + listHeight - 1
        let line = SidebarBackgroundView(frame: NSRect(
            x: inset + Metrics.cardPaddingX, y: listTop, width: rowFrame.width - Metrics.cardPaddingX * 2, height: 1
        ))
        line.wantsLayer = true
        line.layer?.backgroundColor = Theme.Color.line.cgColor
        addExpandedView(line)
        _ = buildWorkspaceGroup(listed, yOffset: listTop - Metrics.workspaceGap)
    }

    private func buildArchivedRow(count: Int, frame: NSRect) {
        typealias Metrics = SidebarExpandedMetrics
        hitAreas.append(SidebarHitArea(frame: frame, region: .archivedToggle))
        archivedRowHoverView = addRowHover(frame: frame)

        let icon = SidebarImageView(image: SidebarRenderer.symbol(
            Theme.Symbol.inactiveWorkspaces, color: Theme.Color.textSecondary, pointSize: 12
        ))
        icon.frame = NSRect(x: Metrics.markCenterX - 7, y: frame.midY - 7, width: 14, height: 14)
        icon.setAccessibilityElement(false)
        addExpandedView(icon)

        let countLabel = textLabel("\(count)", font: Theme.Font.caption, color: Theme.Color.textSecondary)
        countLabel.alignment = .right
        let countSize = countLabel.fittingSize
        countLabel.frame = NSRect(
            x: frame.maxX - Metrics.cardPaddingX - countSize.width, y: frame.midY - ceil(countSize.height) / 2,
            width: countSize.width, height: ceil(countSize.height)
        )
        countLabel.setAccessibilityElement(false)
        addExpandedView(countLabel)

        let titleX = Metrics.textX
        let title = textLabel(Self.archivedTitle, font: Theme.Font.body, color: Theme.Color.textSecondary)
        let titleHeight = ceil(title.fittingSize.height)
        title.frame = NSRect(
            x: titleX, y: frame.midY - titleHeight / 2,
            width: max(0, countLabel.frame.minX - Theme.Space.sm - titleX), height: titleHeight
        )
        title.setAccessibilityElement(false)
        addExpandedView(title)

        // Takes the first click on a window in the background, and is what
        // VoiceOver sees.
        let toggle = SidebarSectionToggleView(frame: frame)
        toggle.setAccessibilityLabel("\(Self.archivedTitle), \(count)")
        toggle.setAccessibilityExpanded(!isInactiveSectionCollapsed)
        toggle.onPress = { [weak self] in self?.toggleInactiveSection() }
        addExpandedView(toggle)
    }

    static let archivedTitle = "Archived"

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

    private func buildWorkspaceSection(workspace: WorkspaceInfo, yOffset: CGFloat) -> CGFloat {
        let result = SidebarWorkspaceCardRenderer(
            workspace: workspace,
            sidebarWidth: bounds.width,
            yOffset: yOffset,
            animates: animates,
            turnEndedAt: turnEndedAt[workspace.id]
        ).render()
        result.views.forEach(addExpandedView)
        hitAreas.append(contentsOf: result.hitAreas)
        cardHoverViews[workspace.index] = result.cardHoverView
        if let badge = result.menuBadge {
            menuBadgeViews[workspace.index] = badge
            // VoiceOver's press: the menu a click on it opens.
            let index = workspace.index
            badge.onPress = { [weak self, weak badge] in
                guard let self, let badge else { return }
                workspaceActionMenu(workspaceIndex: index, columnIndex: nil)
                    .popUp(positioning: nil, at: NSPoint(x: badge.frame.minX, y: badge.frame.minY), in: contentDocumentView)
            }
        }
        columnHoverViews[workspace.index] = result.columnHoverViews
        approvalButtonViews.merge(result.approvalButtons) { _, new in new }
        return result.bottomY
    }

    // MARK: - Small controls

    /// Clear until hovered (`applyHover` tints it), so a row that acts as
    /// one control reads as one: the picker, the Archived row.
    private func addRowHover(frame: NSRect) -> NSView {
        let hover = SidebarBackgroundView(frame: frame)
        hover.wantsLayer = true
        hover.layer?.cornerRadius = Theme.Radius.card
        addExpandedView(hover)
        return hover
    }

    /// A view of this render, in the document view; the next render tears
    /// it down.
    private func addExpandedView(_ view: NSView) {
        addSubviewDoc(view)
        expandedViews.append(view)
    }

    private func textLabel(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        return label
    }
}
