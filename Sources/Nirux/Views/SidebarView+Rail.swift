import AppKit

// MARK: - Collapsed rail

extension SidebarView {
    private typealias Metrics = SidebarRailMetrics

    /// Lays the rail out in the document view, top to bottom: the project,
    /// the active workspaces, the INACTIVE toggle and what it lists; "+" at
    /// the bottom, or after the last tile when they overflow. Returns the
    /// document's height.
    func buildRail() -> CGFloat {
        // Over every workspace, folded ones too: unfolding renumbers nothing.
        let displayed = displayedWorkspaceInfos
        let initials = Dictionary(
            zip(displayed.map(\.id), SidebarRailInitials.initials(for: displayed.map(\.title))),
            uniquingKeysWith: { first, _ in first }
        )
        let listed = railWorkspaceInfos
        let inactiveCount = lastInfos.filter(\.isInactive).count

        var groups: [[RailItem]] = []
        if let project = lastProfiles.first(where: \.isActive) { groups.append([.project(project)]) }
        let active = listed.filter { !$0.isInactive }
        if !active.isEmpty { groups.append(active.map { .workspace($0, initials[$0.id] ?? "?") }) }
        if inactiveCount > 0 {
            groups.append([.inactiveToggle(count: inactiveCount)]
                + listed.filter(\.isInactive).map { .workspace($0, initials[$0.id] ?? "?") })
        }
        let items = Array(groups.joined(separator: [.separator]))

        let contentHeight = Metrics.topPadding + items.map(\.advance).reduce(0, +)
            + Metrics.tileSize + Metrics.bottomPadding
        let docHeight = max(bounds.height, contentHeight)
        contentDocumentView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: docHeight)

        var top = docHeight - Metrics.topPadding
        for item in items {
            switch item {
            case .separator:
                let line = SidebarBackgroundView(frame: NSRect(
                    x: (Metrics.width - Metrics.separatorWidth) / 2, y: top - Metrics.separatorMargin - 1,
                    width: Metrics.separatorWidth, height: 1
                ))
                line.wantsLayer = true
                line.layer?.backgroundColor = Theme.Color.lineStrong.cgColor
                addRailView(line)
            case .project(let profile):
                addRailTile(projectTile(profile), target: .railButton(.project), region: .railButton(.project), top: top)
            case .inactiveToggle(let count):
                let tile = SidebarRailTileView(
                    style: .inactiveToggle(isUnfolded: !isInactiveSectionCollapsed), symbolName: Theme.Symbol.inactiveWorkspaces
                )
                tile.acceptsFirstClick = true
                tile.setAccessibilityLabel("Inactive workspaces, \(count)")
                tile.setAccessibilityExpanded(!isInactiveSectionCollapsed)
                tile.onPress = { [weak self] in self?.toggleInactiveSection() }
                addRailTile(tile, target: .railButton(.inactiveSection), region: .railButton(.inactiveSection), top: top)
            case .workspace(let info, let initials):
                let tile = SidebarRailTileView(
                    style: .workspace(state: info.railState, isSelected: info.isActive, isInactive: info.isInactive),
                    text: initials
                )
                describe(tile, as: info.railTooltip)
                tile.setAccessibilitySelected(info.isActive)
                let index = info.index
                tile.onPress = { [weak self] in self?.onWorkspaceClicked?(index) }
                addRailTile(tile, target: .workspaceCard(index), region: .workspace(index), top: top)
            }
            top -= item.advance
        }

        let add = SidebarRailTileView(style: .add, symbolName: Theme.Symbol.add)
        add.setAccessibilityLabel("New Workspace")
        add.onPress = { [weak self] in self?.onNewWorkspace?() }
        addRailTile(add, target: .railButton(.newWorkspace), region: .railButton(.newWorkspace),
                    top: Metrics.bottomPadding + Metrics.tileSize)
        return docHeight
    }

    private enum RailItem {
        case project(ProfileInfo)
        case workspace(WorkspaceInfo, String)
        case inactiveToggle(count: Int)
        case separator

        /// Down to the next item.
        var advance: CGFloat {
            switch self {
            case .separator: return Metrics.separatorMargin * 2 + 1 + Metrics.tileGap
            default: return Metrics.tileSize + Metrics.tileGap
            }
        }
    }

    private func projectTile(_ profile: ProfileInfo) -> SidebarRailTileView {
        let tile = SidebarRailTileView(style: .project, text: profile.name.first.map(String.init) ?? "?")
        tile.role = .menuButton
        if let tooltip = railTooltip(for: .railButton(.project)) { describe(tile, as: tooltip) }
        tile.onPress = { [weak self, weak tile] in
            guard let self, let tile else { return }
            projectMenu().popUp(positioning: nil, at: NSPoint(x: tile.frame.maxX, y: tile.frame.maxY), in: contentDocumentView)
        }
        return tile
    }

    /// VoiceOver reads the tooltip: its first two lines, then the rest.
    private func describe(_ tile: SidebarRailTileView, as tooltip: SidebarRailTooltip) {
        tile.setAccessibilityLabel([tooltip.title, tooltip.detail].compactMap { $0 }.joined(separator: ", "))
        tile.setAccessibilityHelp(tooltip.note)
    }

    /// A tile whose top is at `top`; its hit area spans the rail's width
    /// and the gaps around it, so the tiles' areas touch.
    private func addRailTile(_ tile: SidebarRailTileView, target: SidebarHoverTarget, region: SidebarHitRegion, top: CGFloat) {
        tile.place(tileOrigin: NSPoint(x: Metrics.tileX, y: top - Metrics.tileSize))
        addRailView(tile)
        railTileViews[target] = tile
        hitAreas.append(SidebarHitArea(
            frame: NSRect(x: 0, y: top - Metrics.tileSize - Metrics.tileGap / 2, width: bounds.width, height: Metrics.tileSize + Metrics.tileGap),
            region: region
        ))
    }

    private func addRailView(_ view: NSView) {
        addSubviewDoc(view)
        expandedViews.append(view)
    }

    // MARK: - Menus

    /// The rail's project tile: the projects to switch to, then the active
    /// one's options (the expanded sidebar switches in its bottom dots).
    func projectMenu() -> NSMenu {
        let menu = NSMenu()
        if lastProfiles.count > 1 {
            for profile in lastProfiles {
                let item = menu.addClosureItem(title: profile.name) { [weak self] in
                    self?.onProfileClicked?(profile.id)
                }
                item.state = profile.isActive ? .on : .off
                item.image = SidebarRenderer.dot(Self.profileColor(hex: profile.colorHex), diameter: 8)
            }
            menu.addItem(.separator())
        }
        addSpaceOptions(to: menu)
        return menu
    }

    // MARK: - Tooltip

    /// What the tooltip of the tile lit by `target` says.
    func railTooltip(for target: SidebarHoverTarget) -> SidebarRailTooltip? {
        switch target {
        case .workspaceCard(let index):
            return lastInfos.first { $0.index == index }?.railTooltip
        case .railButton(.project):
            guard let profile = lastProfiles.first(where: \.isActive) else { return nil }
            let count = Self.workspaceCountText(profile.workspaceCount)
            let waiting = lastInfos.filter { $0.railState == .waiting }.count
            guard waiting > 0 else { return SidebarRailTooltip(title: profile.name, detail: count) }
            return SidebarRailTooltip(title: profile.name, detail: "\(waiting) waiting", detailColor: Theme.Color.waiting, note: count)
        case .railButton(.inactiveSection):
            let count = lastInfos.filter(\.isInactive).count
            return SidebarRailTooltip(
                title: isInactiveSectionCollapsed ? "Show Inactive Workspaces" : "Hide Inactive Workspaces",
                detail: "\(count) inactive"
            )
        case .railButton(.newWorkspace):
            return SidebarRailTooltip(title: "New Workspace", detail: NiruxShortcuts.newWorkspaceDisplay)
        case .spaceHeader, .menuBadge, .columnRow, .approvalButton:
            return nil
        }
    }

    /// Whether the tooltip may show: the pointer moved since the last
    /// click, no menu or drag tracks the mouse, and the window gets the
    /// mouse events (Nirux active, the window key) — otherwise nothing
    /// would take it down.
    private var isRailTooltipAllowed: Bool {
        guard !isRailTooltipSuppressed, RunLoop.current.currentMode != .eventTracking else { return false }
        return !railTooltipNeedsKeyWindow || (NSApp.isActive && window?.isKeyWindow == true)
    }

    /// Shows the hovered tile's tooltip beside the rail, over the columns,
    /// or hides it. Called on every hover change and pointer move.
    func updateRailTooltip() {
        guard !isExpanded, workspaceDrag == nil, isRailTooltipAllowed, let target = hoveredTarget,
              let tile = railTileViews[target], let tooltip = railTooltip(for: target), let host = superview else {
            hideRailTooltip()
            return
        }
        let view = railTooltipView ?? SidebarRailTooltipView()
        railTooltipView = view
        view.show(tooltip)
        if view.superview !== host { host.addSubview(view, positioned: .above, relativeTo: nil) }
        let tileRect = host.convert(SidebarRailTileView.tileRect, from: tile)
        let margin = Theme.Space.xs
        let y = min(max(tileRect.midY - view.frame.height / 2, host.bounds.minY + margin), host.bounds.maxY - view.frame.height - margin)
        view.setFrameOrigin(NSPoint(x: frame.maxX + Metrics.tooltipGap, y: y))
    }

    func hideRailTooltip() {
        railTooltipView?.removeFromSuperview()
    }

    func observeRailTooltipDismissals() {
        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(railClipViewScrolled(_:)),
            name: NSView.boundsDidChangeNotification, object: contentScrollView.contentView
        )
        center.addObserver(
            self, selector: #selector(railMouseEventsStopped(_:)),
            name: NSApplication.didResignActiveNotification, object: nil
        )
        center.addObserver(
            self, selector: #selector(railMouseEventsStopped(_:)),
            name: NSWindow.didResignKeyNotification, object: nil
        )
    }

    /// Scrolling slides tiles under a still pointer: light (and explain)
    /// the one now under it.
    @objc func railClipViewScrolled(_ notification: Notification) {
        guard !isExpanded, workspaceDrag == nil else { return }
        setHoverTarget(nil)
        refreshHoverTargetFromMouse()
    }

    /// Nirux or its window stopped getting mouse events (another app, a
    /// panel): no `mouseExited` will come to take the tooltip down.
    @objc func railMouseEventsStopped(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window !== self.window { return }
        guard !isExpanded else { return }
        setHoverTarget(nil)
    }
}
