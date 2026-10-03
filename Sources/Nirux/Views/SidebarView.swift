import AppKit

/// Decorative layers in the sidebar should not steal events from the
/// registered workspace/column hit regions.
final class SidebarBackgroundView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Laid over the INACTIVE section header's row. It takes the first click
/// on a window in the background, so that click toggles instead of only
/// bringing the window forward, and hands mouse events on up the
/// responder chain to the sidebar's hit regions. VoiceOver sees it as the
/// header's toggle button.
final class SidebarSectionToggleView: NSView {
    var onPress: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }
}

/// Sidebar: the collapsed rail of workspace tiles (SidebarView+Rail), or
/// the expanded workspace cards. Both are views in the scrollable document
/// view, with the same hit areas: click, drag, right-click and hover work
/// alike. Dragging on empty sidebar area moves the window.
final class SidebarView: NSView {
    // Note: card drags don't move the window even so — the drag-reorder
    // tracking loop (SidebarView+Drag) consumes the mouse events before
    // the window-move machinery sees them.
    override var mouseDownCanMoveWindow: Bool { true }
    var onWorkspaceClicked: ((Int) -> Void)?
    var onColumnClicked: ((Int, Int) -> Void)?  // (workspaceIndex, columnIndex)
    /// Allow / Deny clicked: (workspaceIndex, columnIndex, request ID, decision).
    var onPermissionDecision: ((Int, Int, String, PermissionApproval.Behavior) -> Void)?
    /// Resume clicked: (workspaceIndex, columnIndex, the failure it was for).
    var onAgentResume: ((Int, Int, TimeInterval) -> Void)?
    /// Resume on the row of a restored agent that hasn't resumed yet:
    /// (workspaceIndex, columnIndex, column id).
    var onDeferredAgentResume: ((Int, Int, UUID) -> Void)?
    var onDiffStatsClicked: ((Int) -> Void)?
    /// The menu of the card's PR feedback line, by workspace id; nil when
    /// there's nothing.
    var prFeedbackMenu: ((String) -> NSMenu?)?
    /// A card's PR link clicked: (workspaceIndex, url).
    var onWorkspaceURLClicked: ((Int, String) -> Void)?
    var onWorkspaceAction: ((WorkspaceSidebarAction, Int) -> Void)?
    /// Whether the workspace's menu offers "Clean Up Worktree…" (it's open
    /// in a linked worktree, or its folder is gone). Asked on each menu.
    var offersWorktreeCleanup: ((Int) -> Bool)?
    /// Drag-reorder drop: (store index of dragged workspace, target
    /// position within its active/inactive group).
    var onWorkspaceReordered: ((Int, Int) -> Void)?
    var onProfileClicked: ((String) -> Void)?
    var onCreateProfile: (() -> Void)?
    var onRenameProfile: ((String) -> Void)?
    var onEditProfileBrief: ((String) -> Void)?
    var onEditBoardSettings: ((String) -> Void)?
    var onEditTaskTemplates: ((String) -> Void)?
    var onRecolorProfile: ((String, String) -> Void)?
    var onDeleteProfile: ((String) -> Void)?
    /// (workspace id, space id). By id: a close that finishes while the menu
    /// is open can leave a card's index stale.
    var onMoveWorkspaceToProfile: ((String, String) -> Void)?
    /// The rail's "+".
    var onNewWorkspace: (() -> Void)?
    var isExpanded: Bool = false {
        didSet {
            isRailHidden = false
            // Reset on each switch so the new mode follows the active
            // workspace instead of staying at whatever offset was left.
            lastFollowedActiveIndex = Int.min
            rebuildContent()
        }
    }

    var lastInfos: [WorkspaceInfo] = []
    var lastProfiles: [ProfileInfo] = []

    /// First-launch checklist, shown below the workspaces while set; nil
    /// hides it. Owned by NiruxShellView.
    var onboardingChecklist: OnboardingChecklist? {
        didSet {
            guard onboardingChecklist != oldValue else { return }
            if onboardingChecklist == nil { revealsOnboardingCardOnNextBuild = false }
            lastRenderSignature = nil
            if isExpanded { rebuildContent() }
        }
    }
    var onOnboardingAction: ((OnboardingChecklistAction) -> Void)?
    /// Kept across rebuilds (see OnboardingChecklistView).
    var onboardingCardView: OnboardingChecklistView?
    /// Set by `revealOnboardingCard()` while the card isn't laid out yet.
    var revealsOnboardingCardOnNextBuild = false
    /// Inactive workspaces are finished work: the section starts folded at
    /// every launch and only `toggleInactiveSection` (the header, View ▸
    /// Show Inactive Workspaces, ⌘P) unfolds it — not the workspace on screen
    /// (see `listsWorkspace`), not a refresh. Unfolding is a look at this
    /// space's section: `update` folds it back on a space switch or once
    /// the section is empty, so it never reappears unfolded. Not saved.
    private(set) var isInactiveSectionCollapsed = true
    /// The last render's views, the cards' or the rail's: the next one
    /// tears them down.
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
    /// `NSEvent.timestamp` of the release that last made an Allow / Deny /
    /// Resume act (see `isLeftoverPress`).
    var lastButtonActionAt: TimeInterval = -.infinity

    // Hover-highlight backing views registered per rebuild (workspace index
    // → view), plus the current target. Tinting is applied/cleared directly
    // so no rebuild is needed as the pointer moves.
    var cardHoverViews: [Int: NSView] = [:]
    var menuBadgeViews: [Int: SidebarBadgeView] = [:]
    var columnHoverViews: [Int: [Int: NSView]] = [:]
    var approvalButtonViews: [String: SidebarBadgeView] = [:]
    /// Kept across rebuilds: see `refreshApprovalArming`.
    var approvalButtonArming: [String: SidebarApprovalButtonArming] = [:]
    var spaceHeaderHoverView: NSView?
    /// "⋯" badge in the space header — brightens with the header hover.
    var spaceHeaderBadge: SidebarBadgeView?
    var hoveredTarget: SidebarHoverTarget?

    /// The rail's tiles, by the hover target that lights them.
    var railTileViews: [SidebarHoverTarget: SidebarRailTileView] = [:]
    /// The hovered tile's tooltip, laid over the columns (see
    /// `updateRailTooltip`); nil while none shows.
    var railTooltipView: SidebarRailTooltipView?
    /// The rail faded out for an expansion: rebuilds leave it empty until
    /// the cards come in.
    var isRailHidden = false
    /// Where the drag ghost started, in the document view.
    var dragGhostOriginY: CGFloat = 0

    private var hoveredLabel: NSTextField?
    private var trackingArea: NSTrackingArea?

    static let accentColor: NSColor = Theme.Color.accent

    /// Scrollable container for the rail and the cards.
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
        layer?.backgroundColor = Theme.Color.base.cgColor

        contentScrollView.drawsBackground = false
        contentScrollView.hasVerticalScroller = true
        contentScrollView.hasHorizontalScroller = false
        contentScrollView.scrollerStyle = .overlay
        contentScrollView.autohidesScrollers = true
        contentScrollView.documentView = contentDocumentView
        addSubview(contentScrollView)
        observeScrollingForApprovalArming()
        observeScrollingForRailHover()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        contentScrollView.frame = bounds
        rebuildContent()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { hideRailTooltip() }
    }

    func update(profiles: [ProfileInfo], workspaces: [WorkspaceInfo]) {
        guard workspaceDrag == nil else {
            deferredDragUpdate = SidebarUpdatePayload(profiles: profiles, workspaces: workspaces)
            return
        }
        let spaceChanged = profiles.first(where: \.isActive)?.id != lastProfiles.first(where: \.isActive)?.id
        if spaceChanged || !workspaces.contains(where: \.isInactive) { isInactiveSectionCollapsed = true }
        lastProfiles = profiles
        lastInfos = workspaces
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

    /// Everything the sidebar renders, at display granularity —
    /// time-derived text (relative ages, elapsed durations) is hashed as
    /// its formatted string so the signature only changes when a label
    /// actually would.
    private var lastRenderSignature: Int?

    private func renderSignature() -> Int {
        var hasher = Hasher()
        hasher.combine(lastProfiles)
        hasher.combine(lastInfos)
        hasher.combine(isExpanded)
        hasher.combine(isInactiveSectionCollapsed)
        hasher.combine(onboardingChecklist)
        for workspace in lastInfos {
            if let lastActivityAt = workspace.lastActivityAt {
                hasher.combine(Self.cardAge(since: lastActivityAt))
            }
        }
        hasher.combine(bounds.width)
        hasher.combine(bounds.height)
        return hasher.finalize()
    }

    /// Fade the rail out, then call completion: the sidebar widens empty
    /// and the cards come in once it's wide.
    func fadeOutRail(completion: @escaping () -> Void) {
        guard let bitmapRep = bitmapImageRepForCachingDisplay(in: bounds) else {
            completion()
            return
        }
        cacheDisplay(in: bounds, to: bitmapRep)

        let fadeLayer = CALayer()
        fadeLayer.frame = bounds
        fadeLayer.contents = bitmapRep.cgImage
        layer?.addSublayer(fadeLayer)

        // Clear the tiles so they don't show behind the fade, nor come back
        // while the sidebar widens.
        isRailHidden = true
        rebuildContent()

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

    var displayedWorkspaceInfos: [WorkspaceInfo] {
        lastInfos.filter { !$0.isInactive } + lastInfos.filter { $0.isInactive }
    }

    /// The workspaces the rail shows a tile for, top to bottom.
    var railWorkspaceInfos: [WorkspaceInfo] {
        displayedWorkspaceInfos.filter(listsWorkspace)
    }

    // MARK: - Click handling

    override func mouseDown(with event: NSEvent) {
        // Click areas are registered in the scrollable document view's
        // coordinate space, so we hit-test there (which automatically
        // accounts for the current scroll offset).
        let docLocation = contentDocumentView.convert(event.locationInWindow, from: nil)
        if Self.isLeftoverPress(clickCount: event.clickCount, at: event.timestamp, after: lastButtonActionAt) {
            return
        }

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
            if Self.armedButtonKey(for: area.region) != nil {
                trackApprovalClick(area.region, event: event)
                return
            }
            handleHit(area.region, event: event)
            return
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

        // The checklist's buttons track their own hover and cursor.
        if let card = onboardingCardView, card.superview != nil, card.frame.contains(point) {
            clearHover()
            setHoverTarget(nil)
            if !card.hasButton(at: point) { NSCursor.arrow.set() }
            return
        }

        guard let area = hitArea(at: point) else {
            clearHover()
            setHoverTarget(nil)
            NSCursor.arrow.set()
            return
        }

        switch area.region {
        case .link(_, let label):
            // A card's link keeps its card lit (and its "⋯" shown).
            setHoverTarget(cardIndex(at: point).map { .workspaceCard($0) })
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
        case .permissionDecision(let workspaceIndex, _, _, _), .agentResume(let workspaceIndex, _, _),
             .deferredAgentResume(let workspaceIndex, _, _):
            clearHover()
            if let key = Self.armedButtonKey(for: area.region) {
                setHoverTarget(.approvalButton(workspaceIndex: workspaceIndex, key: key))
            }
            NSCursor.pointingHand.set()
        case .actionBlock(let workspaceIndex):
            clearHover()
            setHoverTarget(.workspaceCard(workspaceIndex))
            NSCursor.arrow.set()
        case .railButton(let button):
            clearHover()
            setHoverTarget(.railButton(button))
            NSCursor.pointingHand.set()
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
                toggleInactiveSection()
            } else if let workspaceIndex = Self.actionWorkspaceIndex(url, prefix: Self.diffActionPrefix) {
                onDiffStatsClicked?(workspaceIndex)
            } else if let workspaceIndex = Self.actionWorkspaceIndex(url, prefix: Self.cleanupActionPrefix) {
                onWorkspaceAction?(.cleanUpWorktree, workspaceIndex)
            } else if let workspaceID = Self.prFeedbackActionWorkspaceID(url) {
                prFeedbackMenu?(workspaceID)?.popUp(positioning: nil, at: convert(event.locationInWindow, from: nil), in: self)
            } else if let (workspaceIndex, url) = Self.openActionTarget(url),
                      case .web = TerminalLinkTarget.parse(url) {
                onWorkspaceURLClicked?(workspaceIndex, url)
            }
        case .column(let workspaceIndex, let columnIndex):
            onColumnClicked?(workspaceIndex, columnIndex)
        case .workspace(let workspaceIndex):
            onWorkspaceClicked?(workspaceIndex)
        case .workspaceMenu(let workspaceIndex):
            let point = convert(event.locationInWindow, from: nil)
            workspaceActionMenu(workspaceIndex: workspaceIndex, columnIndex: nil)
                .popUp(positioning: nil, at: point, in: self)
        case .permissionDecision, .agentResume, .deferredAgentResume, .actionBlock:
            break // buttons go through trackApprovalClick; the block is inert
        case .railButton(.project):
            let point = convert(event.locationInWindow, from: nil)
            setHoverTarget(nil) // the tooltip would stay beside the menu
            projectMenu().popUp(positioning: nil, at: point, in: self)
        case .railButton(.inactiveSection):
            toggleInactiveSection()
        case .railButton(.newWorkspace):
            onNewWorkspace?()
        }
    }

    private func showSpaceMenu(at point: NSPoint) {
        spaceOptionsMenu().popUp(positioning: nil, at: point, in: self)
    }

    /// Space options only — switching spaces lives in the bottom dot
    /// switcher (and ⌥⌘←/→), so the header menu doesn't duplicate it.
    func spaceOptionsMenu() -> NSMenu {
        let menu = NSMenu()
        addSpaceOptions(to: menu)
        return menu
    }

    /// The active space's options, then "New Project".
    func addSpaceOptions(to menu: NSMenu) {
        if let active = lastProfiles.first(where: { $0.isActive }) {
            addSpaceManagementItems(to: menu, for: active)
        }
        menu.addClosureItem(title: "New Project") { [weak self] in
            self?.onCreateProfile?()
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        // Right-click on the space header (or the rail's project) mirrors
        // its left-click menu — every region that advertises a menu
        // answers both buttons.
        let docLocation = contentDocumentView.convert(event.locationInWindow, from: nil)
        switch hitArea(at: docLocation)?.region {
        case .spaceHeader?:
            return spaceOptionsMenu()
        case .railButton(.project)?:
            setHoverTarget(nil)
            return projectMenu()
        default:
            break
        }
        guard let target = menuTarget(at: event) else { return super.menu(for: event) }
        // The rail's tooltip would stay beside the menu.
        if !isExpanded { setHoverTarget(nil) }
        return workspaceActionMenu(workspaceIndex: target.workspaceIndex, columnIndex: target.columnIndex)
    }

    /// Full per-workspace action menu, shared by right-click and the "⋯"
    /// button. `columnIndex` non-nil when invoked from a column row — adds
    /// the column-level actions on top.
    func workspaceActionMenu(workspaceIndex: Int, columnIndex: Int?) -> NSMenu {
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
        addWorktreeCleanupItem(to: menu, workspaceIndex: workspaceIndex)
        addCIFailureItems(to: menu, pullRequest: workspace?.prInfo, workspaceIndex: workspaceIndex)
        menu.addClosureItem(title: "Review Branch") { [weak self] in
            self?.onWorkspaceAction?(.reviewBranch, workspaceIndex)
        }
        menu.addClosureItem(title: "View/Edit Context…") { [weak self] in
            self?.onWorkspaceAction?(.editContext, workspaceIndex)
        }
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
        if let item = moveToSpaceItem(workspaceIndex: workspaceIndex) { menu.addItem(item) }
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
        let docLocation = contentDocumentView.convert(event.locationInWindow, from: nil)
        for area in hitAreas where area.frame.contains(docLocation) {
            switch area.region {
            case .column(let workspaceIndex, let columnIndex),
                 .permissionDecision(let workspaceIndex, let columnIndex, _, _),
                 .agentResume(let workspaceIndex, let columnIndex, _),
                 .deferredAgentResume(let workspaceIndex, let columnIndex, _):
                return MenuTarget(workspaceIndex: workspaceIndex, columnIndex: columnIndex)
            case .workspace(let workspaceIndex), .workspaceMenu(let workspaceIndex),
                 .actionBlock(let workspaceIndex):
                return MenuTarget(workspaceIndex: workspaceIndex, columnIndex: nil)
            case .spaceHeader, .link, .railButton:
                continue
            }
        }
        return nil
    }

    override func mouseExited(with event: NSEvent) {
        clearHover()
        setHoverTarget(nil)
    }

    /// Under the text only, not under a link's icons.
    private func applyUnderline(to label: NSTextField) {
        let attr = NSMutableAttributedString(attributedString: label.attributedStringValue)
        attr.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attr.length)) { attachment, range, _ in
            guard attachment == nil else { return }
            attr.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        }
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

    private static let diffActionPrefix = "action:diff:"
    private static let cleanupActionPrefix = "action:cleanup:"

    static func diffActionURL(workspaceIndex: Int) -> String {
        diffActionPrefix + String(workspaceIndex)
    }

    /// The card's "Clean up", shown next to a merged pull request.
    static func cleanupActionURL(workspaceIndex: Int) -> String {
        cleanupActionPrefix + String(workspaceIndex)
    }

    static func prFeedbackActionURL(workspaceID: String) -> String {
        "action:pr-feedback:\(workspaceID)"
    }

    /// Opens `url` in a browser column of the card's workspace.
    static func openActionURL(workspaceIndex: Int, url: String) -> String {
        "action:open:\(workspaceIndex):\(url)"
    }

    static let inactiveSectionActionURL = "action:inactive-section-toggle"

    private static func actionWorkspaceIndex(_ value: String, prefix: String) -> Int? {
        guard value.hasPrefix(prefix) else { return nil }
        return Int(value.dropFirst(prefix.count))
    }

    private static func prFeedbackActionWorkspaceID(_ value: String) -> String? {
        let prefix = "action:pr-feedback:"
        guard value.hasPrefix(prefix) else { return nil }
        return String(value.dropFirst(prefix.count))
    }

    private static func openActionTarget(_ value: String) -> (Int, String)? {
        let prefix = "action:open:"
        guard value.hasPrefix(prefix) else { return nil }
        let rest = value.dropFirst(prefix.count)
        guard let colon = rest.firstIndex(of: ":"), let workspaceIndex = Int(rest[..<colon]) else { return nil }
        return (workspaceIndex, String(rest[rest.index(after: colon)...]))
    }
}

// MARK: - Inactive section

extension SidebarView {
    /// Whether the sidebar lists a workspace. The folded section still
    /// lists the inactive workspace on screen, alone, until the user moves
    /// to another one, and those whose agent waits on the user or broke
    /// (`asksUser`) — the section itself stays folded.
    func listsWorkspace(isInactive: Bool, isActive: Bool, asksUser: Bool = false) -> Bool {
        !isInactive || isActive || asksUser || !isInactiveSectionCollapsed
    }

    func listsWorkspace(_ workspace: WorkspaceInfo) -> Bool {
        listsWorkspace(isInactive: workspace.isInactive, isActive: workspace.isActive, asksUser: workspace.asksUser)
    }

    var hasInactiveWorkspaces: Bool { lastInfos.contains(where: \.isInactive) }

    /// The header row's hit area (the rail's toggle tile), in document
    /// coordinates.
    var inactiveSectionHeaderFrame: NSRect? {
        hitAreas.first {
            switch $0.region {
            case .link(let url, _): return url == Self.inactiveSectionActionURL
            case .railButton(.inactiveSection): return true
            default: return false
            }
        }?.frame
    }

    /// No-op without an inactive workspace: an unfold nobody sees would
    /// show up later, when one is parked.
    func toggleInactiveSection() {
        guard hasInactiveWorkspaces else { return }
        isInactiveSectionCollapsed.toggle()
        lastRenderSignature = nil
        // Mid-drag the rebuild is deferred to the drag's end.
        guard workspaceDrag == nil else {
            rebuildContent()
            return
        }
        // Keep the header under the pointer for the next click. Only rows
        // below it change, but the document view isn't flipped, so a
        // rebuild keeps the distance to the bottom: keep the one to the top.
        let clip = contentScrollView.contentView
        let visibleTopFromDocumentTop = contentDocumentView.frame.height - clip.bounds.maxY
        rebuildContent()
        let highestOrigin = max(0, contentDocumentView.frame.height - clip.bounds.height)
        let originY = contentDocumentView.frame.height - visibleTopFromDocumentTop - clip.bounds.height
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: min(max(0, originY), highestOrigin)))
        contentScrollView.reflectScrolledClipView(clip)
        // From the menu or ⌘P the header may be out of view.
        if let header = inactiveSectionHeaderFrame { contentDocumentView.scrollToVisible(header) }
        // The rebuild read the pointer before the rows moved under it.
        setHoverTarget(nil)
        refreshHoverTargetFromMouse()
        lastRenderSignature = renderSignature()
    }
}
