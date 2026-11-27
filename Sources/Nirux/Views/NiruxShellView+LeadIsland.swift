import AppKit

// MARK: - The Lead island (docs/design/plan.md)

extension NiruxShellView {
    /// The island while the active space plans the day and has a Lead; the Lead's lines leave the sidebar for it.
    func refreshLeadIsland(plan: Plan?) {
        let island = leadWorkspace(inSpace: activeProfileID) == nil ? nil : plan?.island
        commandBarToolbar?.showIsland(island.map { LeadIslandView.Content(now: $0.now?.title, forYou: $0.forYou.count) })
        sidebar.leadLinesInIsland = island != nil
    }

    func showLeadIslandPanel() {
        guard let plan = dayPlans.plan(ofSpace: activeProfileID), let anchor = commandBarToolbar?.island, anchor.window != nil else { return }
        let panel = LeadIslandPanel(island: plan.island) { id in plan.line(id).flatMap { $0.isChecked ? nil : $0.title } }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.appearance = Theme.appearance
        popover.contentViewController = panel
        panel.onDone = { [weak self, weak popover] id in
            self?.checkToDo(id)
            popover?.performClose(nil)
        }
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: anchor.isFlipped ? .maxY : .minY)
    }

    /// The island's Done: the user checks a to-do, which may start what waited for it.
    func checkToDo(_ id: String) {
        guard let store = planStore(ofSpace: activeProfileID) else { return }
        do {
            try updatePlan(store, inSpace: activeProfileID) { try $0.check(id, by: .user, at: Date().timeIntervalSince1970) }
        } catch {
            NSSound.beep()
        }
        updateSidebar()
    }
}
