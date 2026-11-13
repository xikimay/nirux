import AppKit

/// Decorative layers in the sidebar should not steal events from the
/// registered workspace/column hit regions.
final class SidebarBackgroundView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Laid over a sidebar row that acts as one control: the Archived row,
/// the space picker. It hands mouse events on up the responder chain to
/// the sidebar's hit regions; VoiceOver sees it as the row's button. The
/// Archived row's takes the first click on a window in the background, so
/// that click toggles instead of only bringing the window forward.
final class SidebarSectionToggleView: NSView {
    var onPress: (() -> Void)?
    var acceptsFirstClick = true
    var role: NSAccessibility.Role = .button

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { acceptsFirstClick }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { role }
    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }
}

/// Sidebar: the collapsed rail of workspace tiles (SidebarView+Rail), or
/// the expanded workspace cards. Both are views in the scrollable document
/// view, with the same hit areas: click, drag, right-click and hover work
/// alike.
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
    /// (question, answer, the button): Yes, No or Reply… under a turn's
    /// question.
    var onTurnAnswer: ((SidebarTurnQuestion, SidebarTurnAnswer, NSView?) -> Void)?
    /// "Dismiss Question" in a row's menu: (column id, when the question
    /// was asked).
    var onQuestionDismissed: ((UUID, TimeInterval) -> Void)?
    /// Resume on the row of a restored agent that hasn't resumed yet:
    /// (workspaceIndex, columnIndex, column id).
    var onDeferredAgentResume: ((Int, Int, UUID) -> Void)?
    var onDiffStatsClicked: ((Int) -> Void)?
    /// A card's Mission question row: the workspace, the column, and the
    /// row's label to anchor the reply popover to.
    var onMissionQuestionClicked: ((Int, Int, NSView) -> Void)?
    /// The Lead row's "Rule proposed · Review", by space id: the rows may
    /// have moved since it was drawn.
    var onRuleProposalsClicked: ((String) -> Void)?
    /// The menu of the card's PR feedback line, by workspace id; nil when
    /// there's nothing.
    var prFeedbackMenu: ((String) -> NSMenu?)?
    /// A card's PR link clicked: (workspaceIndex, url).
    var onWorkspaceURLClicked: ((Int, String) -> Void)?
    var onWorkspaceAction: ((WorkspaceSidebarAction, Int) -> Void)?
    /// Where the workspace's menu offers "Clean Up Worktree…", nil outside
    /// a linked worktree. Asked on each menu.
    var worktreeCleanupOffer: ((Int) -> WorktreeCleanupMenuOffer?)?
    /// Whether the workspace's menu offers "New Sub-task…". Asked on each
    /// menu.
    var offersSubtask: ((Int) -> Bool)?
    /// The store index of the open workspace with this id, nil once it is
    /// gone: a menu's items act on the workspace it was built for.
    var workspaceIndexForID: ((String) -> Int?)?
    /// The id of the open workspace at this store index.
    var workspaceIDForIndex: ((Int) -> String?)?
    /// The index of the open column with this id in that workspace, nil once
    /// it is gone: a column row's menu acts on that column.
    var columnIndexForID: ((String, UUID) -> Int?)?
    /// Drag-reorder drop: (store index of dragged workspace, target
    /// position within its active/inactive group).
    var onWorkspaceReordered: ((Int, Int) -> Void)?
    var onProfileClicked: ((String) -> Void)?
    /// "New Space…": the sheet (see NewSpacePanel).
    var onCreateProfile: (() -> Void)?
    /// (space id): Space Settings….
    var onShowSpaceSettings: ((String) -> Void)?
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
            // The rail shows none of the rows' moments: none replays when
            // the list opens again.
            if !isExpanded { forgetRowMoments() }
            rebuildContent()
        }
    }

    var lastInfos: [WorkspaceInfo] = []
    var lastProfiles: [ProfileInfo] = []
    /// The workspace each row of the last build stands for, by the index
    /// its hit area carries: `lastInfos` is already the next build's when
    /// a rebuild reads where the list was (`scrollAnchor`).
    var builtRowIDs: [Int: String] = [:]

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
    /// What happened while the user was away, above the task list (see
    /// `SidebarCatchUp`); nil shows nothing. Set before `update`, or
    /// followed by `refreshCatchUpCard`.
    var catchUp: SidebarCatchUp? {
        didSet {
            guard catchUp != oldValue else { return }
            // It and the rows under it moved: no press acts until they
            // have stood a moment (the click that activated Nirux, a
            // double click).
            catchUpChangedAt = clock()
        }
    }
    var onCatchUpAction: ((SidebarCatchUpAction) -> Void)?
    /// When the card last changed (`clock`).
    var catchUpChangedAt: CFTimeInterval = -.infinity
    var revealsCatchUpOnNextBuild = false
    /// How long the card's presses wait after it changed.
    static let catchUpArming: CFTimeInterval = 0.6

    /// The card changed outside a refresh (the user just came back);
    /// `reveal` brings it into view.
    func refreshCatchUpCard(reveal: Bool = false) {
        revealsCatchUpOnNextBuild = reveal && isExpanded && catchUp != nil
        let signature = renderSignature()
        guard signature != lastRenderSignature else { return }
        lastRenderSignature = signature
        rebuildContent()
    }
    /// Kept across rebuilds (see OnboardingChecklistView).
    var onboardingCardView: OnboardingChecklistView?
    /// Set by `revealOnboardingCard()` while the card isn't laid out yet.
    var revealsOnboardingCardOnNextBuild = false
    /// Archived (inactive) workspaces are finished work: their list starts
    /// folded at every launch and only `toggleInactiveSection` (the Archived
    /// row, View ▸ Show Archived, ⌘P) unfolds it — not the workspace on
    /// screen (see `listsWorkspace`), not a refresh. Unfolding is a look at
    /// this space's list: `update` folds it back on a space switch or once
    /// the list is empty, so it never reappears unfolded. Not saved.
    private(set) var isInactiveSectionCollapsed = true
    /// The last render's views, the cards' or the rail's: the next one
    /// tears them down.
    var expandedViews: [NSView] = []
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
    /// A rebuild was suppressed mid-drag (a layout, the rows' motion, the
    /// catch-up card): the drag's end makes it, unless the update it
    /// applies already rebuilt.
    var rebuildSkippedDuringDrag = false
    /// Whether the press a row gesture tracks still holds: its window
    /// shows and the button is down. Tests say: events posted to the app
    /// move no button, and a drag made of them is lost once it holds
    /// still for a quarter of a second.
    var rowPressHolds: @MainActor (NSWindow) -> Bool = { $0.isVisible && NSEvent.pressedMouseButtons & 1 != 0 }

    /// Active workspace the sidebar last auto-scrolled to. Used by
    /// `rebuildContent` so we only follow the active workspace when it
    /// actually changes — not on every periodic refresh, which would yank
    /// the viewport back while the user is dragging the scroller.
    var lastFollowedActiveIndex: Int = Int.min
    /// `NSEvent.timestamp` of the release that last made an Allow / Deny /
    /// Resume act (see `isLeftoverPress`).
    var lastButtonActionAt: TimeInterval = -.infinity
    /// The row a single press landed on, and when: the double-click's
    /// second press renames it, wherever the rows moved meanwhile.
    var lastRowPress: (workspaceIndex: Int, at: TimeInterval)?

    // Hover-highlight backing views registered per rebuild (workspace index
    // → view), plus the current target. Tinting is applied/cleared directly
    // so no rebuild is needed as the pointer moves.
    var cardHoverViews: [Int: NSView] = [:]
    var menuBadgeViews: [Int: SidebarBadgeView] = [:]
    var columnHoverViews: [Int: [Int: NSView]] = [:]
    var approvalButtonViews: [String: SidebarBadgeView] = [:]
    /// Kept across rebuilds: see `refreshApprovalArming`.
    var approvalButtonArming: [String: SidebarApprovalButtonArming] = [:]
    var spacePickerHoverView: NSView?
    var newTaskButton: SidebarBadgeView?
    var archivedRowHoverView: NSView?
    var hoveredTarget: SidebarHoverTarget?

    /// The rail's tiles, by the hover target that lights them.
    var railTileViews: [SidebarHoverTarget: SidebarRailTileView] = [:]
    /// The hovered tile's tooltip, laid over the columns while it shows
    /// (see `updateRailTooltip`), kept for the next one.
    var railTooltipView: SidebarRailTooltipView?
    /// A click hid the tooltip: it stays hidden until the pointer moves,
    /// not to cover the terminal the click brought up.
    var isRailTooltipSuppressed = false
    /// The rail lights tiles and shows tooltips only for a live pointer:
    /// Nirux active, its window key. Tests turn it off: xctest never makes
    /// the app active, and the real pointer is anywhere.
    var railHoverNeedsLivePointer = true
    /// The rail faded out for an expansion: rebuilds leave it empty until
    /// the cards come in.
    var isRailHidden = false
    /// Where the drag ghost started, in the document view.
    var dragGhostOriginY: CGFloat = 0

    private var hoveredLabel: NSTextField?
    private var trackingArea: NSTrackingArea?

    static let accentColor: NSColor = Theme.Color.accent

    /// Scrollable container for the rail and the cards.
    let contentScrollView = SidebarScrollView()
    let contentDocumentView = NSView()
    /// The width the rows were last laid out at: what the clip shows. A
    /// legacy scroller (the Mac's "Show scroll bars: Always", or a mouse)
    /// sits beside them, as in Finder's sidebar; an overlay one takes none.
    var listWidth: CGFloat = 0
    /// The scroll view takes the sidebar's size: the rebuild that follows
    /// lays the rows out at the width it leaves.
    private var isResizingScrollView = false

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
        contentScrollView.autohidesScrollers = true
        contentScrollView.documentView = contentDocumentView
        contentScrollView.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(clipResized), name: NSView.frameDidChangeNotification, object: contentScrollView.contentView
        )
        addSubview(contentScrollView)
        observeScrollingForApprovalArming()
        observeRailTooltipDismissals()
        contentScrollView.onScrollWheel = { [weak self] in self?.notePointer(.scroll) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        isResizingScrollView = true
        contentScrollView.frame = bounds
        isResizingScrollView = false
        rebuildContent()
    }

    /// The width a legacy scroller leaves beside a list taller than the
    /// sidebar; the sidebar's own with overlay scrollers.
    var widthBesideScroller: CGFloat {
        NSScrollView.contentSize(
            forFrameSize: bounds.size, horizontalScrollerClass: nil,
            verticalScrollerClass: contentScrollView.hasVerticalScroller ? NSScroller.self : nil,
            borderType: contentScrollView.borderType, controlSize: .regular, scrollerStyle: contentScrollView.scrollerStyle
        ).width
    }

    /// A legacy scroller came or went under rows already laid out (the
    /// Mac's "Show scroll bars" setting changed, or a mouse came): they
    /// take the width it leaves.
    @objc private func clipResized() {
        guard !isResizingScrollView, contentScrollView.frame.size == bounds.size,
              contentScrollView.contentSize.width != listWidth else { return }
        needsLayout = true
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { hideRailTooltip() }
    }

    func update(profiles: [ProfileInfo], workspaces: [WorkspaceInfo]) {
        lastUpdateAt = clock()
        guard workspaceDrag == nil else {
            deferredDragUpdate = SidebarUpdatePayload(profiles: profiles, workspaces: workspaces)
            return
        }
        let spaceChanged = profiles.first(where: \.isActive)?.id != lastProfiles.first(where: \.isActive)?.id
        if spaceChanged || !workspaces.contains(where: \.isInactive) { isInactiveSectionCollapsed = true }
        let spacesChanged = profiles != lastProfiles
        // Before the rows change: what happened to them, in the same space.
        if spaceChanged {
            // Another space's rows: what played for the last one stops.
            forgetRowMoments()
        } else if !lastProfiles.isEmpty || !lastInfos.isEmpty {
            noteRowMoments(from: lastInfos, to: workspaces)
        }
        lastProfiles = profiles
        lastInfos = workspaces
        if spacesChanged { NotificationCenter.default.post(name: Self.spacesDidChangeNotification, object: self) }
        // The 2s heartbeat calls this even when nothing visible changed.
        // Rebuilding then is not just wasted work: it tears down every
        // row's tooltip tracking rect (the system tooltip delay never
        // elapses) and blanks the hover highlight under a stationary
        // cursor. Skip when the rendered output would be identical.
        // (A row whose check starts changed its mark: the rebuild follows.)
        settleOwedTurnEnds()
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

    /// The merge's moments on a row (see SidebarView+Merge), by workspace
    /// and on the `clock`: when its checks passed, when its pull request
    /// was merged; the rows that just left the list; when the Archived
    /// count last went up; and that count's label, in the rows as they
    /// are now.
    var readyAt: [String: CFTimeInterval] = [:]
    var mergedAt: [String: CFTimeInterval] = [:]
    var folds: [Fold] = []
    var archivedBumpAt: CFTimeInterval?
    weak var archivedCountLabel: NSTextField?

    /// When a task's row opens (`clock`), by workspace, while its birth
    /// plays: with a spring (see SidebarView+Birth).
    var rowOpensAt: [String: CFTimeInterval] = [:]

    /// The clock the rows' movements are timed from; tests set it.
    var clock: () -> CFTimeInterval = { CACurrentMediaTime() }

    /// For the stale-rows log (see SidebarView+StaleLog), on the `clock`:
    /// when the rows were last rebuilt, when an update last came, when
    /// the pointer last moved, pressed, scrolled or right-clicked on the
    /// sidebar.
    var lastRebuildAt: CFTimeInterval?
    var lastUpdateAt: CFTimeInterval?
    var lastPointerAt: CFTimeInterval?
    /// The pointer came back to the sidebar (`notePointer`): the gesture,
    /// and how long it had left the sidebar alone.
    var onPointerReturn: ((SidebarStaleLog.Trigger, CFTimeInterval?) -> Void)?

    /// When a row began to draw its turn end's check (`clock`), by
    /// workspace: its mark draws it for
    /// `SidebarWorkspaceCardRenderer.checkDuration`, across rebuilds.
    private(set) var turnEndNotedAt: [String: CFTimeInterval] = [:]
    /// The turn ends noted while their row still read "working", and when:
    /// Codex's closing output reads as work for a few seconds, and another
    /// agent of the task may work on. The check is owed for
    /// `turnEndGrace`, and draws if the row turns grey meanwhile.
    private(set) var owedTurnEnds: [String: CFTimeInterval] = [:]
    static let turnEndGrace: CFTimeInterval = 5

    /// The turns that just ended in these workspaces: each of their rows
    /// that shows the grey dot now draws its check, if rows may move. A
    /// row still at work is owed its check for a moment (`owedTurnEnds`).
    /// Nothing is kept for a row that says something else (a wait, a pull
    /// request's state), nor for the rail: a check never shows up late,
    /// and nothing is rebuilt for nothing.
    func noteTurnEnded(workspaceIDs: Set<String>) {
        let now = clock()
        turnEndNotedAt = turnEndNotedAt.filter { now - $0.value < SidebarWorkspaceCardRenderer.checkDuration }
        guard animates, isExpanded, !workspaceIDs.isEmpty else { return }
        var draws = false
        for row in lastInfos where workspaceIDs.contains(row.id) && showsTurnEnds(on: row) {
            switch row.rowSummary.mark {
            case let mark where SidebarWorkspaceCardRenderer.drawsTurnEnd(over: mark):
                turnEndNotedAt[row.id] = now
                draws = true
            case .working:
                owedTurnEnds[row.id] = now
            default:
                break
            }
        }
        if draws { rebuildContent() }
    }

    /// A row draws turn ends: a task's full row in the list (see
    /// `SidebarWorkspaceCardRenderer.showsTurnEnds`).
    private func showsTurnEnds(on row: WorkspaceInfo) -> Bool {
        listsWorkspace(row) && SidebarWorkspaceCardRenderer.showsTurnEnds(row)
    }

    /// At a refresh: a row that turned grey while its turn end was owed
    /// draws its check now, from the start. One that says something else
    /// by now, or that took too long, draws none.
    private func settleOwedTurnEnds() {
        guard !owedTurnEnds.isEmpty else { return }
        guard animates, isExpanded else {
            owedTurnEnds = [:]
            return
        }
        let now = clock()
        for (id, notedAt) in owedTurnEnds {
            let isInTime = now - notedAt < Self.turnEndGrace
            let row = lastInfos.first { $0.id == id }
            let mark = row.flatMap { showsTurnEnds(on: $0) ? $0.rowSummary.mark : nil }
            if mark == .working, isInTime { continue }
            owedTurnEnds[id] = nil
            if let mark, SidebarWorkspaceCardRenderer.drawsTurnEnd(over: mark), isInTime { turnEndNotedAt[id] = now }
        }
    }

    /// The rows move: a line of light under a working one, a check at a
    /// turn's end, the rail's breathing badges; false: states show steady.
    /// The shell decides (`NiruxShellView.agentLightsMayMove`): Reduce
    /// motion, the setting, a window nobody sees.
    var animates = true {
        didSet {
            guard animates != oldValue else { return }
            lastRenderSignature = renderSignature()
            rebuildContent()
        }
    }

    private func renderSignature() -> Int {
        var hasher = Hasher()
        hasher.combine(lastProfiles)
        hasher.combine(lastInfos)
        hasher.combine(isExpanded)
        hasher.combine(isInactiveSectionCollapsed)
        hasher.combine(onboardingChecklist)
        // The rail draws no card.
        if isExpanded { hasher.combine(catchUp) }
        hasher.combine(animates)
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

    /// The workspaces the rail shows a tile for, top to bottom: the cards'
    /// and, in the folded section, an amber one (`railState`).
    var railWorkspaceInfos: [WorkspaceInfo] {
        displayedWorkspaceInfos.filter {
            listsWorkspace(isInactive: $0.isInactive, isActive: $0.isActive, asksUser: $0.asksUser || $0.railState == .waiting)
        }
    }

    // MARK: - Click handling

    override func mouseDown(with event: NSEvent) {
        notePointer(.press)
        // Click areas are registered in the scrollable document view's
        // coordinate space, so we hit-test there (which automatically
        // accounts for the current scroll offset).
        let docLocation = contentDocumentView.convert(event.locationInWindow, from: nil)
        if Self.isLeftoverPress(clickCount: event.clickCount, at: event.timestamp, after: lastButtonActionAt) {
            return
        }
        if !isExpanded {
            isRailTooltipSuppressed = true
            hideRailTooltip()
        }

        // A double-click renames the row its first click landed on: that
        // click selected it, and the rows moved (the selected row is taller).
        if event.clickCount == 2, let first = lastRowPress,
           event.timestamp - first.at <= NSEvent.doubleClickInterval {
            lastRowPress = nil
            onWorkspaceClicked?(first.workspaceIndex)
            onWorkspaceAction?(.rename, first.workspaceIndex)
            return
        }
        if let area = hitArea(at: docLocation) {
            // The catch-up card just came, went or changed: what is under
            // the pointer moved (see `catchUpChangedAt`).
            guard clock() - catchUpChangedAt >= Self.catchUpArming else { return }
            // Workspace rows don't click on mouseDown: run the drag
            // tracking loop, which decides between click and reorder.
            if case .workspace(let workspaceIndex) = area.region {
                if event.clickCount == 2 {
                    onWorkspaceClicked?(workspaceIndex)
                    onWorkspaceAction?(.rename, workspaceIndex)
                    return
                }
                lastRowPress = event.clickCount == 1 ? (workspaceIndex, event.timestamp) : nil
                trackWorkspaceDrag(workspaceIndex: workspaceIndex, rowFrame: area.frame, startPoint: docLocation)
                return
            }
            lastRowPress = nil
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
        notePointer(.move)
        isRailTooltipSuppressed = false
        defer { if !isExpanded { updateRailTooltip() } }
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
        case .spacePicker, .newTask, .archivedToggle:
            clearHover()
            setHoverTarget(Self.hoverTarget(of: area.region))
            NSCursor.pointingHand.set()
        case .catchUp:
            clearHover()
            setHoverTarget(nil)
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
             .deferredAgentResume(let workspaceIndex, _, _), .turnAnswer(let workspaceIndex, _, _, _):
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
        case .spacePicker:
            showSpacePicker()
        case .newTask:
            onNewWorkspace?()
        case .archivedToggle:
            toggleInactiveSection()
        case .catchUp(let action):
            // Its second press lands on what moved under the pointer.
            lastButtonActionAt = event.timestamp
            onCatchUpAction?(action)
        case .link(let url, let label):
            if let target = Self.missionQuestionTarget(url) {
                onMissionQuestionClicked?(target.workspaceIndex, target.columnIndex, label)
            } else if let workspaceIndex = Self.actionWorkspaceIndex(url, prefix: Self.diffActionPrefix) {
                onDiffStatsClicked?(workspaceIndex)
            } else if let workspaceIndex = Self.actionWorkspaceIndex(url, prefix: Self.cleanupActionPrefix) {
                onWorkspaceAction?(.cleanUpWorktree, workspaceIndex)
            } else if url.hasPrefix(Self.ruleProposalsActionPrefix) {
                onRuleProposalsClicked?(String(url.dropFirst(Self.ruleProposalsActionPrefix.count)))
            } else if let target = Self.resumeTarget(url) {
                onDeferredAgentResume?(target.workspaceIndex, target.columnIndex, target.columnID)
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
        case .permissionDecision, .agentResume, .deferredAgentResume, .turnAnswer, .actionBlock:
            break // buttons go through trackApprovalClick; the block is inert
        case .railButton(.project):
            let point = convert(event.locationInWindow, from: nil)
            setHoverTarget(nil) // the tooltip would stay beside the menu
            spacePickerMenu().popUp(positioning: nil, at: point, in: self)
        case .railButton(.inactiveSection):
            toggleInactiveSection()
        case .railButton(.newWorkspace):
            onNewWorkspace?()
        }
    }

    /// Pops the space picker's menu up under the picker, left-aligned with
    /// it, as a pull-down does.
    func showSpacePicker() {
        guard let frame = hitAreas.first(where: { if case .spacePicker = $0.region { true } else { false } })?.frame
        else { return }
        spacePickerMenu().popUp(
            positioning: nil, at: NSPoint(x: frame.minX, y: frame.minY - Theme.Space.xs), in: contentDocumentView
        )
    }

    /// Posted when `lastProfiles` changes: the menu bar's Space menu
    /// (`SpaceListMenu`) follows, so ⌥⌘1…⌥⌘9 match the picker before that
    /// menu ever opens.
    static let spacesDidChangeNotification = Notification.Name("NiruxSidebarSpacesDidChange")

    /// Shared with the menu bar's Space › New Space…, which runs the same
    /// `onCreateProfile`.
    static let newSpaceTitle = "New Space…"

    override func menu(for event: NSEvent) -> NSMenu? {
        notePointer(.menu)
        // Right-click on the space picker (or the rail's space tile)
        // mirrors its left-click menu — every region that advertises a menu
        // answers both buttons.
        let docLocation = contentDocumentView.convert(event.locationInWindow, from: nil)
        switch hitArea(at: docLocation)?.region {
        case .spacePicker?:
            return spacePickerMenu()
        case .railButton(.project)?:
            setHoverTarget(nil)
            return spacePickerMenu()
        default:
            break
        }
        guard let target = menuTarget(at: event) else { return super.menu(for: event) }
        // The rail's tooltip would stay beside the menu.
        if !isExpanded { setHoverTarget(nil) }
        return workspaceActionMenu(workspaceIndex: target.workspaceIndex, columnIndex: target.columnIndex)
    }

    /// Per-workspace action menu, shared by right-click and the "⋯" button:
    /// what the workspace's state offers first (Review Branch, failed CI,
    /// Dismiss Question, Clean Up once merged), then New Sub-task… and
    /// Organize, then Rename,
    /// its context and Close (with Clean Up before it, not merged yet).
    /// `columnIndex` non-nil when invoked from a column row — adds the
    /// column-level actions on top.
    ///
    /// Its items act on the workspace it was built for, found by id when
    /// one is picked, and do nothing once it is gone: the store may change
    /// while the menu is open (a worktree arriving moves the cards below its
    /// task), and an index would then name another card, which Close
    /// Workspace would close.
    func workspaceActionMenu(workspaceIndex: Int, columnIndex: Int?) -> NSMenu {
        let workspace = lastInfos.first { $0.index == workspaceIndex }
        // The card shown; else (a workspace of another space) the store's.
        let workspaceID = workspace?.id ?? workspaceIDForIndex?(workspaceIndex)
        let act: (WorkspaceSidebarAction) -> Void = { [weak self] action in
            guard let self, let index = self.currentIndex(ofWorkspace: workspaceID) else { return }
            self.onWorkspaceAction?(action, index)
        }

        let menu = NSMenu()
        menu.autoenablesItems = false

        if let columnIndex {
            // The column too, by id: one closing meanwhile shifts the others.
            let columnID = workspace?.columns.first { $0.index == columnIndex }?.id
            let column = { [weak self] () -> (workspace: Int, column: Int)? in
                guard let self, let workspaceID, let columnID, let index = self.currentIndex(ofWorkspace: workspaceID),
                      let column = self.columnIndexForID?(workspaceID, columnID)
                else { return nil }
                return (index, column)
            }
            menu.addClosureItem(title: "Focus Column") { [weak self] in
                guard let target = column() else { return }
                self?.onColumnClicked?(target.workspace, target.column)
            }
            // Wording and ⌘W match the main menu's Column ▸ Close Column.
            menu.addClosureItem(title: "Close Column", keyEquivalent: "w") { [weak self] in
                guard let target = column() else { return }
                self?.onWorkspaceAction?(.closeColumn(columnIndex: target.column), target.workspace)
            }.isEnabled = (workspace?.columnCount ?? 0) > 1
            menu.addItem(.separator())
        }

        let cleanup = worktreeCleanupOffer?(workspaceIndex)
        menu.addClosureItem(title: "Review Branch") { act(.reviewBranch) }
        addCIFailureItems(to: menu, pullRequest: workspace?.prInfo, flakyReason: workspace?.ciFlakyReason, act: act)
        // The card's own Dismiss, for each question the row says: also
        // while its card has no buttons to put it next to.
        // From a column's own menu, that column's alone.
        let asked = (workspace?.columns ?? []).compactMap { column -> (column: UUID, at: TimeInterval)? in
            guard columnIndex == nil || column.index == columnIndex, let id = column.id, let at = column.questionAskedAt
            else { return nil }
            return (id, at)
        }
        if !asked.isEmpty {
            menu.addClosureItem(title: Self.dismissQuestionTitle) { [weak self] in
                for question in asked { self?.onQuestionDismissed?(question.column, question.at) }
            }
        }
        if cleanup == .suggested { addWorktreeCleanupItem(to: menu, act: act) }
        menu.addItem(.separator())
        // The Lead stays on top of its space, and in it.
        if workspace?.isLead != true {
            if offersSubtask?(workspaceIndex) == true {
                menu.addClosureItem(title: Self.newSubtaskTitle) { act(.newSubtask) }
            }
            menu.addItem(organizeItem(workspaceIndex: workspaceIndex, workspace: workspace, act: act))
            menu.addItem(.separator())
        }
        menu.addClosureItem(title: "Rename Workspace") { act(.rename) }
        menu.addClosureItem(title: "View/Edit Context…") { act(.editContext) }
        menu.addClosureItem(title: Self.addRuleTitle) { act(.addRuleToBrief) }
        // Apart, so a click aimed at the context doesn't close the workspace.
        menu.addItem(.separator())
        if cleanup == .available { addWorktreeCleanupItem(to: menu, act: act) }
        menu.addClosureItem(title: "Close Workspace") { act(.close) }
            .isEnabled = WorkspaceClosePolicy.canClose(totalWorkspaceCount: totalWorkspaceCount)
        return menu
    }

    /// Where the workspace a menu was built for is now (`workspaceIndexForID`);
    /// nil once it is gone, or when it can't be told: never another card.
    private func currentIndex(ofWorkspace id: String?) -> Int? {
        id.flatMap { workspaceIndexForID?($0) }
    }

    static let newSubtaskTitle = "New Sub-task…"
    static let addRuleTitle = "Add a Rule to the Brief…"
    static let dismissQuestionTitle = "Dismiss Question"

    /// "Move Out of “<task>”": a sub-task becomes a task of its own.
    static func moveOutTitle(parentTitle: String) -> String {
        "Move Out of “\(parentTitle)”"
    }

    /// The card's moves: up, down, out from under its task, to another
    /// space, to Archived and back.
    private func organizeItem(
        workspaceIndex: Int, workspace: WorkspaceInfo?, act: @escaping (WorkspaceSidebarAction) -> Void
    ) -> NSMenuItem {
        let submenu = NSMenu()
        submenu.addClosureItem(title: "Move Up") { act(.moveUp) }
        submenu.addClosureItem(title: "Move Down") { act(.moveDown) }
        if let parentTitle = workspace?.parentTitle {
            submenu.addClosureItem(title: Self.moveOutTitle(parentTitle: parentTitle)) { act(.moveOutOfParent) }
        }
        if let item = moveToSpaceItem(workspaceIndex: workspaceIndex) { submenu.addItem(item) }
        submenu.addItem(.separator())
        if workspace?.isInactive == true {
            submenu.addClosureItem(title: "Unarchive") { act(.markActive) }
        } else {
            submenu.addClosureItem(title: "Archive") { act(.markInactive) }
        }
        let item = NSMenuItem(title: "Organize", action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
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
                 .deferredAgentResume(let workspaceIndex, let columnIndex, _),
                 .turnAnswer(let workspaceIndex, let columnIndex, _, _):
                return MenuTarget(workspaceIndex: workspaceIndex, columnIndex: columnIndex)
            case .workspace(let workspaceIndex), .workspaceMenu(let workspaceIndex),
                 .actionBlock(let workspaceIndex):
                return MenuTarget(workspaceIndex: workspaceIndex, columnIndex: nil)
            case .spacePicker, .newTask, .archivedToggle, .link, .railButton, .catchUp:
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
    /// Under the link's words when only some are ("Merged · Clean up":
    /// the accent ones), else under all the text.
    private func applyUnderline(to label: NSTextField) {
        let attr = NSMutableAttributedString(attributedString: label.attributedStringValue)
        let whole = NSRange(location: 0, length: attr.length)
        var linkRanges: [NSRange] = []
        attr.enumerateAttribute(.foregroundColor, in: whole) { color, range, _ in
            if (color as? NSColor) == Theme.Color.accent { linkRanges.append(range) }
        }
        if linkRanges.isEmpty || linkRanges == [whole] {
            attr.enumerateAttribute(.attachment, in: whole) { attachment, range, _ in
                guard attachment == nil else { return }
                linkRanges.append(range)
            }
        }
        for range in linkRanges {
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
    private static let missionQuestionActionPrefix = "action:mission-question:"
    private static let ruleProposalsActionPrefix = "action:rule-proposals:"

    /// The Lead row's "Rule proposed · Review", for its space.
    static func ruleProposalsActionURL(spaceID: String) -> String {
        ruleProposalsActionPrefix + spaceID
    }

    /// The card's "Asking …" / "Needs you · a question" row.
    static func missionQuestionActionURL(workspaceIndex: Int, columnIndex: Int) -> String {
        missionQuestionActionPrefix + "\(workspaceIndex):\(columnIndex)"
    }

    private static func missionQuestionTarget(_ value: String) -> (workspaceIndex: Int, columnIndex: Int)? {
        guard value.hasPrefix(missionQuestionActionPrefix) else { return nil }
        let parts = value.dropFirst(missionQuestionActionPrefix.count).split(separator: ":")
        guard parts.count == 2, let workspaceIndex = Int(parts[0]), let columnIndex = Int(parts[1]) else { return nil }
        return (workspaceIndex, columnIndex)
    }

    private static let resumeActionPrefix = "action:resume:"

    /// A row's "Paused · Resume": starts the restored agent of that column
    /// without switching rows.
    static func resumeActionURL(workspaceIndex: Int, columnIndex: Int, columnID: UUID) -> String {
        resumeActionPrefix + "\(workspaceIndex):\(columnIndex):\(columnID.uuidString)"
    }

    private static func resumeTarget(_ value: String) -> (workspaceIndex: Int, columnIndex: Int, columnID: UUID)? {
        guard value.hasPrefix(resumeActionPrefix) else { return nil }
        let parts = value.dropFirst(resumeActionPrefix.count).split(separator: ":")
        guard parts.count == 3, let workspaceIndex = Int(parts[0]), let columnIndex = Int(parts[1]),
              let columnID = UUID(uuidString: String(parts[2])) else { return nil }
        return (workspaceIndex, columnIndex, columnID)
    }

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

// MARK: - Archived list

extension SidebarView {
    /// Whether the sidebar lists a workspace. The folded archived list
    /// still lists the archived workspace on screen, alone, until the user
    /// moves to another one, and those whose agent waits on the user or
    /// broke (`asksUser`) — the list itself stays folded.
    func listsWorkspace(isInactive: Bool, isActive: Bool, asksUser: Bool = false) -> Bool {
        !isInactive || isActive || asksUser || !isInactiveSectionCollapsed
    }

    func listsWorkspace(_ workspace: WorkspaceInfo) -> Bool {
        listsWorkspace(isInactive: workspace.isInactive, isActive: workspace.isActive, asksUser: workspace.asksUser)
    }

    var hasInactiveWorkspaces: Bool { lastInfos.contains(where: \.isInactive) }

    /// The Archived row's hit area (the rail's toggle tile), in document
    /// coordinates.
    var inactiveSectionHeaderFrame: NSRect? {
        hitAreas.first {
            switch $0.region {
            case .archivedToggle, .railButton(.inactiveSection): return true
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
        // Keep the toggle under the pointer for the next click. The
        // Archived row sits at the bottom with its list growing above it:
        // it keeps its distance to the bottom, which the rebuild's own
        // anchor (the top, or the topmost row) would give up. The rail's
        // tile has its list below it: it keeps its distance to the top.
        let clip = contentScrollView.contentView
        let visibleTopFromDocumentTop = contentDocumentView.frame.height - clip.bounds.maxY
        let originFromBottom = clip.bounds.origin.y
        rebuildContent()
        let highestOrigin = max(0, contentDocumentView.frame.height - clip.bounds.height)
        let originY = isExpanded
            ? originFromBottom
            : contentDocumentView.frame.height - visibleTopFromDocumentTop - clip.bounds.height
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
