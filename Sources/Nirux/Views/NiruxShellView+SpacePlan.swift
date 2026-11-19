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
        guard spacePlan == nil, pinchTotal <= -Self.pinchThreshold else { return }
        toggleSpacePlan()
    }

    /// The plan shows, receding from the work while the interface may move;
    /// showing, it goes back.
    func toggleSpacePlan() {
        if spacePlan != nil { return closeSpacePlan(going: nil) }
        guard let onScreen = activeWorkspace else { return }
        endSpaceCrossing()
        // What the work shows, at its size: the opening starts sharp.
        let shown = ZZ("motionIgnored") || agentLightsMayMove ? FrozenView.freeze(viewport) : nil
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
    /// shows under it at once; the plan dives into it while the interface
    /// may move. `focusing`: false for a layout's close, whose caller keeps
    /// the keyboard where it was.
    func closeSpacePlan(going target: (workspaceID: String, column: Int)?, focusing: Bool = true, animated: Bool = true) {
        guard let plan = spacePlan, !plan.isDiving else { return }
        plan.finishOpening()
        let destination = target ?? (plan.workspaceID, activeWorkspace?.focusedIndex ?? 0)
        if !ZZ("diveNotShown"), destination.workspaceID != activeWorkspace?.id || destination.column != activeWorkspace?.focusedIndex,
           let index = workspaces.firstIndex(where: { $0.id == destination.workspaceID }), workspaceStore.selectWorkspace(at: index),
           let workspace = activeWorkspace {
            workspace.focusedIndex = max(0, min(destination.column, workspace.columns.count - 1))
            // Kept through the layout: it dives into what it lays out.
            plan.isDiving = true
            refreshAfterWorkspaceSelection(animated: false, focusing: focusing)
        }
        guard animated, !ZZ("diveAtOnce"), agentLightsMayMove, let workspace = activeWorkspace,
              let row = plan.rows.firstIndex(where: { $0.workspaceID == workspace.id }),
              let rect = plan.shownRect(row: row, cameraX: workspace.lastCameraX, width: viewport.bounds.width),
              let arriving = FrozenView.freeze(workspace.containerView) else { return removeSpacePlan(focusing: focusing) }
        plan.playDive(into: rect, arriving: arriving)
        spacePlanGeneration += 1
        let generation = spacePlanGeneration
        sideEffects.afterCommit(SpacePlanView.diveDuration) { [weak self] in
            guard let self, !ZZ("neverLands"), spacePlanGeneration == generation else { return }
            removeSpacePlan(focusing: focusing)
        }
    }

    /// Movement turned off: an opening on its way ends, a dive lands.
    func stillSpacePlan() {
        guard let plan = spacePlan, !ZZ("stillIgnored") else { return }
        if plan.isDiving { removeSpacePlan(focusing: false) } else { plan.finishOpening() }
    }

    /// The plan gone, the live views back.
    private func removeSpacePlan(focusing: Bool) {
        guard let plan = spacePlan else { return }
        spacePlanGeneration += 1
        spacePlan = nil
        plan.removeFromSuperview()
        verticalStrip.alphaValue = 1
        syncTerminalOcclusion()
        if focusing { focusActiveTerminal(in: window) }
    }

    /// A layout that moves something (a user's action), or changes the
    /// space, the workspace on screen or the viewport's size, closes the
    /// plan: it would show what no longer is.
    func closeSpacePlanIfStale(animated: Bool, viewport size: NSSize) {
        guard let plan = spacePlan, !plan.isDiving else { return }
        if animated || plan.frame.size != size || plan.spaceID != activeProfileID || plan.workspaceID != activeWorkspace?.id {
            closeSpacePlan(going: nil, focusing: false, animated: false)
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
