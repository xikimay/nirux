import AppKit

/// Decorative layers in the sidebar should not steal events from the
/// registered workspace/column hit regions.
final class SidebarBackgroundView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Sidebar: minimal dots in normal mode, expanded detail panel (pilot-style) in expanded mode.
/// Dragging on empty sidebar area moves the window.
final class SidebarView: NSView {
    // Note: card drags don't move the window even so — the drag-reorder
    // tracking loop (SidebarView+Drag) consumes the mouse events before
    // the window-move machinery sees them.
    override var mouseDownCanMoveWindow: Bool { true }
    var onWorkspaceClicked: ((Int) -> Void)?
    var onColumnClicked: ((Int, Int) -> Void)?  // (workspaceIndex, columnIndex)
    var onDiffStatsClicked: ((Int) -> Void)?
    var onWorkspaceAction: ((WorkspaceSidebarAction, Int) -> Void)?
    /// Drag-reorder drop: (store index of dragged workspace, target
    /// position within its active/inactive group).
    var onWorkspaceReordered: ((Int, Int) -> Void)?
    var onProfileClicked: ((String) -> Void)?
    var onCreateProfile: (() -> Void)?
    var onRenameProfile: ((String) -> Void)?
    var onInactiveSectionCollapsedChange: ((Bool) -> Void)?
    var isExpanded: Bool = false {
        didSet {
            // Clear dot pulse layers when switching modes
            pulseLayers.forEach { $0.removeFromSuperlayer() }
            pulseLayers.removeAll()
            if !isExpanded { dotsHidden = false }
            // Force redraw to clear old dot content from backing store
            setNeedsDisplay(bounds)
            contentScrollView.isHidden = !isExpanded
            // Reset on collapse so the next expansion re-follows the active
            // workspace instead of staying at whatever offset was left.
            if !isExpanded { lastFollowedActiveIndex = Int.min }
            rebuildContent()
        }
    }

    var lastInfos: [WorkspaceInfo] = []
    var lastProfiles: [ProfileInfo] = []
    /// Inactive workspaces default to hidden so a large archive cannot
    /// consume the whole sidebar. Persisted by NiruxShellView.
    var isInactiveSectionCollapsed = true
    var expandedViews: [NSView] = []
    var profileIndicatorView: SidebarDotIndicatorView?
    var hitAreas: [SidebarHitArea] = []

    // Workspace drag-reorder state; the tracking logic lives in
    // SidebarView+Drag.swift (stored properties can't go in extensions).
    var workspaceDrag: SidebarWorkspaceDrag?
    var dragGhostView: NSView?
    var dragDimView: NSView?
    var dragInsertionView: NSView?
    /// Sidebar data that arrived mid-drag; applied when the drag ends so
    /// rebuilds don't tear down rows under the captured drag geometry.
    var deferredDragUpdate: SidebarUpdatePayload?
    /// A layout()-driven rebuild was suppressed mid-drag; recover with an
    /// unconditional rebuild when the drag ends.
    var rebuildSkippedDuringDrag = false

    /// Active workspace the sidebar last auto-scrolled to. Used by
    /// `rebuildContent` so we only follow the active workspace when it
    /// actually changes — not on every periodic refresh, which would yank
    /// the viewport back while the user is dragging the scroller.
    var lastFollowedActiveIndex: Int = Int.min

    // Hover-highlight backing views registered per rebuild (workspace index
    // → view), plus the current target. Tinting is applied/cleared directly
    // so no rebuild is needed as the pointer moves.
    var cardHoverViews: [Int: NSView] = [:]
    var menuBadgeViews: [Int: SidebarBadgeView] = [:]
    var columnHoverViews: [Int: [Int: NSView]] = [:]
    var spaceHeaderHoverView: NSView?
    /// "⋯" badge in the space header — brightens with the header hover.
    var spaceHeaderBadge: SidebarBadgeView?
    var hoveredTarget: SidebarHoverTarget?

    private var hoveredLabel: NSTextField?
    private var pulseLayers: [CALayer] = []
    private var trackingArea: NSTrackingArea?

    private static let dotSize: CGFloat = 6
    private static let dotGap: CGFloat = 8
    static let accentColor: NSColor = .niruxAccent
    private static let dimColor = NSColor.white.withAlphaComponent(0.25)
    private static let notifColor = NSColor.systemOrange

    /// Scrollable container for expanded-mode content. In collapsed mode it's
    /// hidden and we just draw dots into the sidebar's own layer.
    let contentScrollView = NSScrollView()
    let contentDocumentView = NSView()

    /// Add a child to the scrollable document view. Used by SidebarView+Rendering
    /// so that rebuilt content scrolls when the workspace list overflows.
    func addSubviewDoc(_ view: NSView) {
        contentDocumentView.addSubview(view)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(red: 0.11, green: 0.11, blue: 0.14, alpha: 1).cgColor

        contentScrollView.drawsBackground = false
        contentScrollView.hasVerticalScroller = true
        contentScrollView.hasHorizontalScroller = false
        contentScrollView.scrollerStyle = .overlay
        contentScrollView.autohidesScrollers = true
        contentScrollView.documentView = contentDocumentView
        contentScrollView.isHidden = true
        addSubview(contentScrollView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        contentScrollView.frame = bounds
        if isExpanded { rebuildContent() } else { setNeedsDisplay(bounds) }
    }

    func update(profiles: [ProfileInfo], workspaces: [WorkspaceInfo]) {
        guard workspaceDrag == nil else {
            deferredDragUpdate = SidebarUpdatePayload(profiles: profiles, workspaces: workspaces)
            return
        }
        let shouldRevealInactive = isInactiveSectionCollapsed
            && workspaces.contains { $0.isInactive && $0.isActive }
        if shouldRevealInactive { isInactiveSectionCollapsed = false }
        lastProfiles = profiles
        lastInfos = workspaces
        if shouldRevealInactive { onInactiveSectionCollapsedChange?(false) }
        guard isExpanded else { setNeedsDisplay(bounds); return }
        // The 2s heartbeat calls this even when nothing visible changed.
        // Rebuilding then is not just wasted work: it tears down every
        // row's tooltip tracking rect (the system tooltip delay never
        // elapses) and blanks the hover highlight under a stationary
        // cursor. Skip when the rendered output would be identical.
        let signature = renderSignature()
        guard signature != lastRenderSignature else { return }
        lastRenderSignature = signature
        rebuildContent()
    }

    /// Everything the expanded sidebar renders, at display granularity —
    /// time-derived text (relative ages, elapsed durations) is hashed as
    /// its formatted string so the signature only changes when a label
    /// actually would.
    private var lastRenderSignature: Int?

    private func renderSignature() -> Int {
        var hasher = Hasher()
        hasher.combine(lastProfiles)
        hasher.combine(lastInfos)
        hasher.combine(isInactiveSectionCollapsed)
        hasher.combine(bounds.width)
        hasher.combine(bounds.height)
        return hasher.finalize()
    }

    /// Fade out the collapsed dots, then call completion.
    func fadeOutDots(completion: @escaping () -> Void) {
        // Snapshot the current dot content into a temporary layer
        guard let bitmapRep = bitmapImageRepForCachingDisplay(in: bounds) else {
            completion()
            return
        }
        cacheDisplay(in: bounds, to: bitmapRep)

        let fadeLayer = CALayer()
        fadeLayer.frame = bounds
        fadeLayer.contents = bitmapRep.cgImage
        layer?.addSublayer(fadeLayer)

        // Remove pulse layers immediately (they'd keep pulsing otherwise)
        pulseLayers.forEach { $0.removeFromSuperlayer() }
        pulseLayers.removeAll()
        // Clear the CG-drawn dots so they don't show behind the fade
        dotsHidden = true
        setNeedsDisplay(bounds)

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak fadeLayer] in
            fadeLayer?.removeFromSuperlayer()
            completion()
        }
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = 1.0
        anim.toValue = 0.0
        anim.duration = 0.15
        anim.fillMode = .forwards
        anim.isRemovedOnCompletion = false
        fadeLayer.add(anim, forKey: "fadeOut")
        CATransaction.commit()
    }

    private var dotsHidden = false

    // MARK: - Collapsed mode (dots)

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // Clear previous dot drawing when expanded or during fade
        if isExpanded || dotsHidden {
            if let ctx = NSGraphicsContext.current?.cgContext {
                ctx.clear(bounds)
            }
            return
        }
        guard !lastInfos.isEmpty,
              let ctx = NSGraphicsContext.current?.cgContext else { return }

        // Remove old pulse layers
        pulseLayers.forEach { $0.removeFromSuperlayer() }
        pulseLayers.removeAll()

        let dotDiameter = Self.dotSize
        let gap = Self.dotGap
        let displayInfos = dotWorkspaceInfos
        let totalHeight = CGFloat(displayInfos.count) * dotDiameter + CGFloat(displayInfos.count - 1) * gap
        let startY = bounds.midY + totalHeight / 2

        for (position, workspace) in displayInfos.enumerated() {
            let dotY = startY - CGFloat(position) * (dotDiameter + gap) - dotDiameter
            let isFocused = workspace.isActive
            let dotWidth = isFocused ? dotDiameter + 2 : dotDiameter
            let dotX = (bounds.width - dotWidth) / 2

            let hasColumnAttention = workspace.columns.contains { $0.agentStatus == .needsAttention }
            let isNotification = hasColumnAttention || (workspace.hasNotification && !workspace.isActive)

            if isNotification {
                ctx.setFillColor(Self.notifColor.cgColor)
            } else if isFocused {
                ctx.setFillColor(Self.accentColor.cgColor)
            } else {
                ctx.setFillColor(Self.dimColor.cgColor)
            }

            ctx.fillEllipse(in: CGRect(x: dotX, y: dotY - (isFocused ? 1 : 0), width: dotWidth, height: dotWidth))

            // Add pulsing glow ring for notification dots
            if isNotification, let rootLayer = layer {
                let glowSize = dotWidth + 6
                let glow = CALayer()
                glow.frame = CGRect(x: dotX - 3, y: dotY - (isFocused ? 1 : 0) - 3, width: glowSize, height: glowSize)
                glow.cornerRadius = glowSize / 2
                glow.backgroundColor = NSColor.clear.cgColor
                glow.borderWidth = 1.5
                glow.borderColor = Self.notifColor.cgColor

                let pulse = CABasicAnimation(keyPath: "opacity")
                pulse.fromValue = 1.0
                pulse.toValue = 0.15
                pulse.duration = 0.6
                pulse.autoreverses = true
                pulse.repeatCount = .infinity
                pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                glow.add(pulse, forKey: "pulse")

                rootLayer.addSublayer(glow)
                pulseLayers.append(glow)
            }
        }
    }

    var displayedWorkspaceInfos: [WorkspaceInfo] {
        lastInfos.filter { !$0.isInactive } + lastInfos.filter { $0.isInactive }
    }

    var dotWorkspaceInfos: [WorkspaceInfo] {
        isInactiveSectionCollapsed
            ? displayedWorkspaceInfos.filter { !$0.isInactive }
            : displayedWorkspaceInfos
    }

    func setInactiveSectionCollapsed(_ collapsed: Bool, notify: Bool = false) {
        // Never hide the workspace currently on screen. This can happen when
        // every workspace in a space is inactive and keyboard navigation
        // selects one of them.
        let effectiveValue = collapsed
            && !lastInfos.contains { $0.isInactive && $0.isActive }
        guard effectiveValue != isInactiveSectionCollapsed else { return }
        isInactiveSectionCollapsed = effectiveValue
        lastRenderSignature = nil
        if isExpanded { rebuildContent() } else { setNeedsDisplay(bounds) }
        if notify { onInactiveSectionCollapsedChange?(effectiveValue) }
    }

    // MARK: - Click handling

    override func mouseDown(with event: NSEvent) {
        if isExpanded {
            // Click areas are registered in the scrollable document view's
            // coordinate space, so we hit-test there (which automatically
            // accounts for the current scroll offset).
            let docLocation = contentDocumentView.convert(event.locationInWindow, from: nil)

            if let area = hitArea(at: docLocation) {
                // Workspace rows don't click on mouseDown: run the drag
                // tracking loop, which decides between click and reorder.
                if case .workspace(let workspaceIndex) = area.region {
                    if event.clickCount == 2 {
                        onWorkspaceClicked?(workspaceIndex)
                        onWorkspaceAction?(.rename, workspaceIndex)
                        return
                    }
                    trackWorkspaceDrag(workspaceIndex: workspaceIndex, rowFrame: area.frame, startPoint: docLocation)
                    return
                }
                handleHit(area.region, event: event)
                return
            }
            super.mouseDown(with: event)
            return
        }

        // Collapsed mode: dot hit-test in self's coordinate space.
        let clickLocation = convert(event.locationInWindow, from: nil)
        let dotDiameter = Self.dotSize
        let gap = Self.dotGap
        let displayInfos = dotWorkspaceInfos
        let totalHeight = CGFloat(displayInfos.count) * dotDiameter + CGFloat(displayInfos.count - 1) * gap
        let startY = bounds.midY + totalHeight / 2

        for (position, workspace) in displayInfos.enumerated() {
            let dotY = startY - CGFloat(position) * (dotDiameter + gap) - dotDiameter
            let hitRect = NSRect(x: 0, y: dotY - 4, width: bounds.width, height: dotDiameter + 8)
            if hitRect.contains(clickLocation) {
                onWorkspaceClicked?(workspace.index)
                return
            }
        }
        super.mouseDown(with: event)
    }

    // MARK: - Hover handling

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        guard isExpanded else { clearHover(); setHoverTarget(nil); return }

        // The bottom space switcher tracks its own hover — keep the pointing
        // hand (its cursor rect would otherwise be overridden below) and drop
        // any list highlight while the pointer is there.
        if let indicator = profileIndicatorView,
           indicator.frame.contains(convert(event.locationInWindow, from: nil)) {
            clearHover()
            setHoverTarget(nil)
            NSCursor.pointingHand.set()
            return
        }
        let point = contentDocumentView.convert(event.locationInWindow, from: nil)

        guard let area = hitArea(at: point) else {
            clearHover()
            setHoverTarget(nil)
            NSCursor.arrow.set()
            return
        }

        switch area.region {
        case .link(_, let label):
            setHoverTarget(nil)
            NSCursor.pointingHand.set()
            if hoveredLabel !== label {
                clearHover()
                applyUnderline(to: label)
                hoveredLabel = label
            }
        case .spaceHeader:
            clearHover()
            setHoverTarget(.spaceHeader)
            NSCursor.pointingHand.set()
        case .workspace(let workspaceIndex):
            clearHover()
            setHoverTarget(.workspaceCard(workspaceIndex))
            NSCursor.pointingHand.set()
        case .workspaceMenu(let workspaceIndex):
            clearHover()
            setHoverTarget(.menuBadge(workspaceIndex))
            NSCursor.pointingHand.set()
        case .column(let workspaceIndex, let columnIndex):
            clearHover()
            setHoverTarget(.columnRow(workspaceIndex: workspaceIndex, columnIndex: columnIndex))
            NSCursor.pointingHand.set()
        case .activity:
            clearHover()
            setHoverTarget(nil)
            NSCursor.arrow.set()
        }
    }

    func hitArea(at point: NSPoint) -> SidebarHitArea? {
        hitAreas.first { $0.frame.contains(point) }
    }

    private func handleHit(_ region: SidebarHitRegion, event: NSEvent) {
        switch region {
        case .spaceHeader:
            let point = convert(event.locationInWindow, from: nil)
            showSpaceMenu(at: point)
        case .link(let url, _):
            if url == Self.inactiveSectionActionURL {
                setInactiveSectionCollapsed(!isInactiveSectionCollapsed, notify: true)
            } else if let workspaceIndex = Self.diffActionWorkspaceIndex(url) {
                onDiffStatsClicked?(workspaceIndex)
            } else if let url = URL(string: url) {
                NSWorkspace.shared.open(url)
            }
        case .column(let workspaceIndex, let columnIndex):
            onColumnClicked?(workspaceIndex, columnIndex)
        case .workspace(let workspaceIndex):
            onWorkspaceClicked?(workspaceIndex)
        case .workspaceMenu(let workspaceIndex):
            let point = convert(event.locationInWindow, from: nil)
            workspaceActionMenu(workspaceIndex: workspaceIndex, columnIndex: nil)
                .popUp(positioning: nil, at: point, in: self)
        case .activity:
            break
        }
    }

    private func showSpaceMenu(at point: NSPoint) {
        spaceOptionsMenu().popUp(positioning: nil, at: point, in: self)
    }

    /// Space options only — switching spaces lives in the bottom dot
    /// switcher (and ⌘←/→), so the header menu doesn't duplicate it.
    private func spaceOptionsMenu() -> NSMenu {
        let menu = NSMenu()
        if let active = lastProfiles.first(where: { $0.isActive }) {
            menu.addClosureItem(title: "Rename Space…") { [weak self] in
                self?.onRenameProfile?(active.id)
            }
        }
        menu.addClosureItem(title: "New Space") { [weak self] in
            self?.onCreateProfile?()
        }
        return menu
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        // Right-click on the space header mirrors its left-click menu —
        // every region that advertises a menu answers both buttons.
        if isExpanded {
            let docLocation = contentDocumentView.convert(event.locationInWindow, from: nil)
            if let area = hitArea(at: docLocation), case .spaceHeader = area.region {
                return spaceOptionsMenu()
            }
        }
        guard let target = menuTarget(at: event) else { return super.menu(for: event) }
        return workspaceActionMenu(workspaceIndex: target.workspaceIndex, columnIndex: target.columnIndex)
    }

    /// Full per-workspace action menu, shared by right-click and the "⋯"
    /// button. `columnIndex` non-nil when invoked from a column row — adds
    /// the column-level actions on top.
    private func workspaceActionMenu(workspaceIndex: Int, columnIndex: Int?) -> NSMenu {
        let workspace = lastInfos.first { $0.index == workspaceIndex }

        let menu = NSMenu()
        menu.autoenablesItems = false

        if let columnIndex {
            menu.addClosureItem(title: "Focus Column") { [weak self] in
                self?.onColumnClicked?(workspaceIndex, columnIndex)
            }
            // Wording and ⌘W match the main menu's Column ▸ Close Column.
            menu.addClosureItem(title: "Close Column", keyEquivalent: "w") { [weak self] in
                self?.onWorkspaceAction?(.closeColumn(columnIndex: columnIndex), workspaceIndex)
            }.isEnabled = (workspace?.columnCount ?? 0) > 1
            menu.addItem(.separator())
        }

        menu.addClosureItem(title: "Close Workspace") { [weak self] in
            self?.onWorkspaceAction?(.close, workspaceIndex)
        }.isEnabled = WorkspaceClosePolicy.canClose(totalWorkspaceCount: totalWorkspaceCount)
        menu.addClosureItem(title: "Rename Workspace") { [weak self] in
            self?.onWorkspaceAction?(.rename, workspaceIndex)
        }
        menu.addItem(.separator())
        menu.addClosureItem(title: "New Workspace", keyEquivalent: NiruxShortcuts.newWorkspaceKey) { [weak self] in
            self?.onWorkspaceAction?(.newWorkspace, workspaceIndex)
        }
        menu.addItem(.separator())
        menu.addClosureItem(title: "Move Up") { [weak self] in
            self?.onWorkspaceAction?(.moveUp, workspaceIndex)
        }
        menu.addClosureItem(title: "Move Down") { [weak self] in
            self?.onWorkspaceAction?(.moveDown, workspaceIndex)
        }
        menu.addItem(.separator())
        if workspace?.isInactive == true {
            menu.addClosureItem(title: "Move to Active") { [weak self] in
                self?.onWorkspaceAction?(.markActive, workspaceIndex)
            }
        } else {
            menu.addClosureItem(title: "Move to Inactive") { [weak self] in
                self?.onWorkspaceAction?(.markInactive, workspaceIndex)
            }
        }
        return menu
    }

    /// Workspace count across every space — the sidebar only lists the
    /// active space's workspaces, but `closeWorkspace` guards on the global
    /// count, so the Close item must too.
    private var totalWorkspaceCount: Int {
        let profileTotal = lastProfiles.reduce(0) { $0 + $1.workspaceCount }
        return max(profileTotal, lastInfos.count)
    }

    private struct MenuTarget {
        let workspaceIndex: Int
        let columnIndex: Int?
    }

    private func menuTarget(at event: NSEvent) -> MenuTarget? {
        if isExpanded {
            let docLocation = contentDocumentView.convert(event.locationInWindow, from: nil)
            for area in hitAreas where area.frame.contains(docLocation) {
                switch area.region {
                case .column(let workspaceIndex, let columnIndex):
                    return MenuTarget(workspaceIndex: workspaceIndex, columnIndex: columnIndex)
                case .workspace(let workspaceIndex), .workspaceMenu(let workspaceIndex):
                    return MenuTarget(workspaceIndex: workspaceIndex, columnIndex: nil)
                case .spaceHeader, .link, .activity:
                    continue
                }
            }
            return nil
        }

        let clickLocation = convert(event.locationInWindow, from: nil)
        let dotDiameter = Self.dotSize
        let gap = Self.dotGap
        let displayInfos = dotWorkspaceInfos
        let totalHeight = CGFloat(displayInfos.count) * dotDiameter + CGFloat(displayInfos.count - 1) * gap
        let startY = bounds.midY + totalHeight / 2

        for (position, workspace) in displayInfos.enumerated() {
            let dotY = startY - CGFloat(position) * (dotDiameter + gap) - dotDiameter
            let hitRect = NSRect(x: 0, y: dotY - 4, width: bounds.width, height: dotDiameter + 8)
            if hitRect.contains(clickLocation) {
                return MenuTarget(workspaceIndex: workspace.index, columnIndex: nil)
            }
        }
        return nil
    }

    override func mouseExited(with event: NSEvent) {
        clearHover()
        setHoverTarget(nil)
    }

    private func applyUnderline(to label: NSTextField) {
        let attr = NSMutableAttributedString(attributedString: label.attributedStringValue)
        attr.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue,
                          range: NSRange(location: 0, length: attr.length))
        label.attributedStringValue = attr
    }

    private func clearHover() {
        guard let label = hoveredLabel else { return }
        let attr = NSMutableAttributedString(attributedString: label.attributedStringValue)
        attr.removeAttribute(.underlineStyle, range: NSRange(location: 0, length: attr.length))
        label.attributedStringValue = attr
        hoveredLabel = nil
        NSCursor.arrow.set()
    }

    static func diffActionURL(workspaceIndex: Int) -> String {
        "action:diff:\(workspaceIndex)"
    }

    static let inactiveSectionActionURL = "action:inactive-section-toggle"

    private static func diffActionWorkspaceIndex(_ value: String) -> Int? {
        let prefix = "action:diff:"
        guard value.hasPrefix(prefix) else { return nil }
        return Int(value.dropFirst(prefix.count))
    }
}
