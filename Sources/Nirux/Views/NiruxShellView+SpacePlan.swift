import AppKit

/// Depth study P5: ⌥⌘↑ shows the space as a plan (`SpacePlanView`) over the
/// viewport, the live views hidden and their terminals resting under it.
extension NiruxShellView {
    func toggleSpacePlan() {
        if spacePlan != nil { return closeSpacePlan(going: nil) }
        guard let onScreen = activeWorkspace else { return }
        endSpaceCrossing()
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
