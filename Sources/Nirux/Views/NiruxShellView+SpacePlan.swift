import AppKit

/// Depth study P5: ⌥⌘↑ shows the space as a plan (`SpacePlanView`) over the
/// viewport, the live views hidden and their terminals resting under it.
extension NiruxShellView {
    /// How far fingers close (or open) before the plan shows (or goes to a
    /// card): a quarter of their span.
    static let pinchThreshold: CGFloat = 0.25

    /// Fingers closing over the work show the plan, once a pinch; false
    /// elsewhere (the sidebar, the status bar), which the pinch doesn't reach.
    @discardableResult
    func pinched(by magnification: CGFloat, phase: NSEvent.Phase, at point: NSPoint) -> Bool {
        guard viewport.frame.contains(point) else { return false }
        if pinch.moved(by: magnification, phase: phase, past: -Self.pinchThreshold), spacePlan?.isDiving ?? true, planDrawing.isEmpty {
            toggleSpacePlan()
        }
        return true
    }

    /// The plan shows once every listed workspace drew (their terminals rest
    /// while off screen, or never drew since launch), receding from the work
    /// while the interface may move. Asked again meanwhile, it doesn't;
    /// showing, it goes back.
    func toggleSpacePlan() {
        // A pinch under way is done: the plan came or went.
        pinch.end()
        if let plan = spacePlan {
            guard plan.isDiving else { return closeSpacePlan(going: nil) }
            // Asked again while it dives: it lands, and opens anew.
            removeSpacePlan()
        }
        if !planDrawing.isEmpty { return endPlanDrawing() }
        guard activeWorkspace != nil else { return }
        endSpaceCrossing()
        planDrawing = Set(visibleWorkspaceIndices.map { workspaces[$0].id })
        syncTerminalOcclusion()
        spacePlanGeneration += 1
        let generation = spacePlanGeneration
        sideEffects.afterCommit(Self.arrivalDelay) { [weak self] in
            guard let self, spacePlanGeneration == generation else { return }
            let drew = planDrawing
            endPlanDrawing()
            // Another space, or a workspace added or closed meanwhile: not all drew.
            guard drew == Set(visibleWorkspaceIndices.map { workspaces[$0].id }) else { return }
            showSpacePlan()
        }
    }

    private func endPlanDrawing() {
        spacePlanGeneration += 1
        planDrawing = []
        syncTerminalOcclusion()
    }

    private func showSpacePlan() {
        guard let onScreen = activeWorkspace else { return }
        // What the work shows, at rest and at its size: the opening starts
        // sharp.
        endUnderBar()
        let shown = agentLightsMayMove ? FrozenView.freeze(viewport) : nil
        let plan = SpacePlanView(
            frame: viewport.bounds, spaceID: activeProfileID, workspaces: SpacePlanView.listing(planWorkspaces),
            labels: planLabels(), onScreen: onScreen
        )
        guard !plan.rows.isEmpty else { return }
        // A plan already gone closes no other.
        plan.onClose = { [weak self, weak plan] target in
            guard let self, let plan, spacePlan === plan else { return }
            closeSpacePlan(going: target)
        }
        viewport.addSubview(plan)
        spacePlan = plan
        verticalStrip.alphaValue = 0
        syncTerminalOcclusion()
        window?.makeFirstResponder(plan)
        spacePlanGeneration += 1
        guard let shown, let row = plan.rows.firstIndex(where: { $0.workspaceID == onScreen.id }),
              let rect = plan.shownRect(row: row, cameraX: onScreen.lastCameraX, width: viewport.bounds.width) else { return }
        plan.playOpening(from: shown, at: rect)
        let generation = spacePlanGeneration
        sideEffects.afterCommit(SpacePlanView.openingDuration) { [weak self, weak plan] in
            guard let self, spacePlanGeneration == generation else { return }
            plan?.finishOpening()
        }
    }

    /// The plan goes, to `target` or back to what showed. That workspace
    /// shows under it at once, its column taking the keyboard (a card
    /// chosen, whatever held it; going back, if the plan held it), and the
    /// plan dives into it while the interface may move and `animated`, else
    /// goes at once, a dive on its way too.
    func closeSpacePlan(going target: (workspaceID: String, column: Int)?, animated: Bool = true) {
        guard let plan = spacePlan else { return }
        guard !plan.isDiving else { return animated ? () : removeSpacePlan() }
        plan.finishOpening()
        let focusing = target != nil || window?.firstResponder === plan
        let destination = target ?? (plan.workspaceID, activeWorkspace?.focusedIndex ?? 0)
        if let index = workspaces.firstIndex(where: { $0.id == destination.workspaceID }), workspaceStore.selectWorkspace(at: index),
           let workspace = activeWorkspace {
            workspace.focusedIndex = max(0, min(destination.column, workspace.columns.count - 1))
            // Kept through the layout: it dives into what it lays out.
            plan.isDiving = true
            refreshAfterWorkspaceSelection(animated: false, focusing: focusing)
        }
        guard animated, agentLightsMayMove, let workspace = activeWorkspace,
              let row = plan.rows.firstIndex(where: { $0.workspaceID == workspace.id }),
              let rect = plan.shownRect(row: row, cameraX: workspace.lastCameraX, width: viewport.bounds.width),
              let arriving = FrozenView.freeze(workspace.containerView) else { return removeSpacePlan() }
        plan.playDive(into: rect, arriving: arriving)
        spacePlanGeneration += 1
        let generation = spacePlanGeneration
        sideEffects.afterCommit(SpacePlanView.diveDuration) { [weak self] in
            guard let self, spacePlanGeneration == generation else { return }
            removeSpacePlan()
        }
    }

    /// Movement turned off: an opening on its way ends, a dive lands.
    func stillSpacePlan() {
        guard let plan = spacePlan else { return }
        if plan.isDiving { removeSpacePlan() } else { plan.finishOpening() }
    }

    /// The plan gone, the live views back, the keyboard it held to the
    /// column on screen.
    private func removeSpacePlan() {
        guard let plan = spacePlan else { return }
        let heldKeyboard = window?.firstResponder === plan
        spacePlanGeneration += 1
        spacePlan = nil
        plan.removeFromSuperview()
        verticalStrip.alphaValue = 1
        syncTerminalOcclusion()
        if heldKeyboard { focusActiveTerminal(in: window) }
    }

    /// A change to what the plan lists (a workspace, its columns, their
    /// sizes or order), to the space, the workspace on screen or the
    /// viewport's size closes it at once: it would show what no longer is.
    /// A name changing doesn't, nor the layout of its own dive.
    func closeSpacePlanIfStale(viewport size: NSSize) {
        guard let plan = spacePlan, !plan.isDiving else { return }
        if plan.frame.size != size || plan.spaceID != activeProfileID || plan.workspaceID != activeWorkspace?.id
            || plan.listed != SpacePlanView.listing(planWorkspaces).map(SpacePlanView.Listed.init) {
            closeSpacePlan(going: nil, animated: false)
        }
    }

    /// The space's workspaces, in the order they're listed.
    private var planWorkspaces: [WorkspaceState] { visibleWorkspaceIndices.map { workspaces[$0] } }

    /// Each row's icon, name and status line, as the rail shows them; the
    /// archived ones too, which the folded rail leaves out.
    private func planLabels() -> [String: SpacePlanView.Label] {
        Dictionary(sidebar.railItems.map { item in
            (item.id, SpacePlanView.Label(title: item.title, icon: item.icon, initials: item.label, detail: item.detail))
        }) { first, _ in first }
    }
}
