import AppKit

// MARK: - The Lead island (docs/design/plan.md)

extension NiruxShellView {
    /// The island while the active space plans the day and has a Lead; the Lead's lines leave the sidebar for it
    /// only while it is on screen.
    func refreshLeadIsland(plan: Plan?) {
        let island = leadWorkspace(inSpace: activeProfileID) == nil ? nil : plan?.island
        let shown = commandBarToolbar?.showIsland(island.map { LeadIslandView.Content(now: $0.now?.title, forYou: $0.forYou.count) })
        sidebar.leadLinesInIsland = shown == true
    }

    /// Under the island, or under the bar while the island sits in the » menu.
    func showLeadIslandPanel() {
        let spaceID = activeProfileID
        guard let plan = dayPlans.plan(ofSpace: spaceID), let toolbar = commandBarToolbar else { return }
        let island = toolbar.island
        let onScreen = island.window != nil && !island.isHiddenOrHasHiddenAncestor
        let anchor: NSView = onScreen ? island : toolbar.bar
        guard anchor.window != nil else { return }
        let panel = LeadIslandPanel(island: plan.island) { id in plan.line(id).flatMap { $0.isChecked ? nil : $0.title } }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.appearance = Theme.appearance
        popover.contentViewController = panel
        panel.onDone = { [weak self, weak popover] id in
            self?.checkToDo(id, inSpace: spaceID)
            popover?.performClose(nil)
        }
        popover.show(relativeTo: onScreen ? island.capsuleRect : anchor.bounds, of: anchor, preferredEdge: anchor.isFlipped ? .maxY : .minY)
    }

    /// The island's Done: the user checks a to-do of the space the panel opened in, which may start what waited for it.
    func checkToDo(_ id: String, inSpace spaceID: String) {
        guard let store = planStore(ofSpace: spaceID) else { return }
        do {
            try updatePlan(store, inSpace: spaceID) { try $0.check(id, by: .user, at: Date().timeIntervalSince1970) }
        } catch {
            NSSound.beep()
        }
        updateSidebar()
    }
}
