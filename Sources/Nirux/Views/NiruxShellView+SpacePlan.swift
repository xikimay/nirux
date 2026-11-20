import AppKit

/// Depth study P5: ⌥⌘↑ shows the space as a plan (`SpacePlanView`) over the
/// viewport, the live views hidden and their terminals resting under it.
extension NiruxShellView {
    /// How far fingers close (or open) before the plan shows (or goes to a
    /// card): a quarter of their span.
    static let pinchThreshold: CGFloat = 0.25

    /// Fingers closing on the work show the plan.
    func pinched(by magnification: CGFloat, began: Bool) {
        if began, !ZZ("noReset") { pinchTotal = 0 }
        pinchTotal += ZZ("wrongWay") ? -magnification : magnification
        guard spacePlan == nil, planDrawing.isEmpty || ZZ("drawCancelled"), ZZ("pinchEager") || pinchTotal <= -Self.pinchThreshold else { return }
        toggleSpacePlan()
    }

    /// The plan shows once every listed workspace drew: their terminals rest
    /// while off screen, or never drew since launch. Asked again meanwhile,
    /// it doesn't.
    func toggleSpacePlan() {
        if spacePlan != nil { return closeSpacePlan(going: nil) }
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
        let plan = SpacePlanView(
            frame: viewport.bounds, spaceID: activeProfileID, workspaces: SpacePlanView.listing(planWorkspaces),
            labels: planLabels(), onScreen: onScreen
        )
        guard !plan.rows.isEmpty else { return }
        plan.onClose = { [weak self] target in self?.closeSpacePlan(going: target) }
        viewport.addSubview(plan)
        spacePlan = plan
        verticalStrip.alphaValue = 0
        syncTerminalOcclusion()
        window?.makeFirstResponder(plan)
    }

    /// The plan goes; to `target` at once, else back to what showed. The
    /// keyboard it held goes back to the column on screen.
    func closeSpacePlan(going target: (workspaceID: String, column: Int)?) {
        guard let plan = spacePlan else { return }
        let heldKeyboard = window?.firstResponder === plan
        spacePlan = nil
        plan.removeFromSuperview()
        verticalStrip.alphaValue = 1
        if let target, let index = workspaces.firstIndex(where: { $0.id == target.workspaceID }),
           workspaceStore.selectWorkspace(at: index), let workspace = activeWorkspace {
            workspace.focusedIndex = max(0, min(target.column, workspace.columns.count - 1))
            return refreshAfterWorkspaceSelection(animated: false)
        }
        syncTerminalOcclusion()
        if heldKeyboard { focusActiveTerminal(in: window) }
    }

    /// A change to what the plan lists (a workspace, its columns, their
    /// sizes or order), to the space, the workspace on screen or the
    /// viewport's size closes it: it would show what no longer is. A name
    /// changing doesn't.
    func closeSpacePlanIfStale(viewport size: NSSize) {
        guard let plan = spacePlan else { return }
        if plan.frame.size != size || plan.spaceID != activeProfileID || plan.workspaceID != activeWorkspace?.id
            || plan.listed != SpacePlanView.listing(planWorkspaces).map(SpacePlanView.Listed.init) {
            closeSpacePlan(going: nil)
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
