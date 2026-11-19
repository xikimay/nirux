import AppKit

/// Depth study P5: ⌥⌘↑ shows the space as a plan (`SpacePlanView`) over the
/// viewport, the live views hidden and their terminals resting under it.
extension NiruxShellView {
    /// How far fingers close (or open) before the plan shows (or goes to a
    /// card): a quarter of their span.
    static let pinchThreshold: CGFloat = 0.25

    /// Fingers closing on the work show the plan.
    func pinched(by magnification: CGFloat, began: Bool) {
        if began { pinchTotal = 0 }
        pinchTotal += magnification
        guard spacePlan == nil, planDrawing.isEmpty, pinchTotal <= -Self.pinchThreshold else { return }
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
            frame: viewport.bounds, spaceID: activeProfileID, workspaces: visibleWorkspaceIndices.map { workspaces[$0] },
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

    /// The plan goes; to `target` at once, else back to what showed.
    /// `focusing`: false for a layout's close, whose caller keeps the
    /// keyboard where it was.
    func closeSpacePlan(going target: (workspaceID: String, column: Int)?, focusing: Bool = true) {
        guard let plan = spacePlan else { return }
        spacePlan = nil
        plan.removeFromSuperview()
        verticalStrip.alphaValue = 1
        if let target, let index = workspaces.firstIndex(where: { $0.id == target.workspaceID }),
           workspaceStore.selectWorkspace(at: index), let workspace = activeWorkspace {
            workspace.focusedIndex = max(0, min(target.column, workspace.columns.count - 1))
            return refreshAfterWorkspaceSelection(animated: false)
        }
        syncTerminalOcclusion()
        if focusing { focusActiveTerminal(in: window) }
    }

    /// A layout that moves something (a user's action), or changes the
    /// space, the workspace on screen or the viewport's size, closes the
    /// plan: it would show what no longer is.
    func closeSpacePlanIfStale(animated: Bool, viewport size: NSSize) {
        guard let plan = spacePlan else { return }
        if animated || plan.frame.size != size || plan.spaceID != activeProfileID || plan.workspaceID != activeWorkspace?.id {
            closeSpacePlan(going: nil, focusing: false)
        }
    }

    /// Each row's icon, name and status line, as the rail shows them.
    private func planLabels() -> [String: SpacePlanView.Label] {
        let content = sidebar.railContent
        let items = (content.lead.map { [$0] } ?? []) + content.tasks
        return Dictionary(items.map { item in
            (item.id, SpacePlanView.Label(title: item.title, icon: item.icon, initials: item.label, detail: item.detail))
        }) { first, _ in first }
    }
}
