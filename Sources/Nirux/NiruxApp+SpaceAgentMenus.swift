import AppKit

// MARK: - Space, Workspaces, Agent and Help menus

/// Every command of the palette has a menu bar item, so the Help menu's
/// search finds it with its shortcut (docs/spaces.md, Interface).
extension NiruxApp {
    // MARK: Space

    /// Whatever the sidebar's "New Space" does.
    @objc func newSpace(_ sender: Any?) {
        shell?.sidebar.onCreateProfile?()
    }

    @objc func openBoard(_ sender: Any?) {
        shell?.openProjectBoard()
    }

    @objc func showSessionHistory(_ sender: Any?) {
        shell?.showSessionHistory()
    }

    @objc func cleanUpMergedWorktrees(_ sender: Any?) {
        shell?.showWorktreeCleanupPanel()
    }

    // MARK: Workspaces

    @objc func newTask(_ sender: Any?) {
        shell?.showNewTaskPanel()
    }

    @objc func newWorktree(_ sender: Any?) {
        shell?.showWorktreePanel()
    }

    @objc func openWorktree(_ sender: Any?) {
        shell?.showWorktreeListPalette()
    }

    @objc func editWorkspaceContext(_ sender: Any?) {
        guard let shell else { return }
        shell.showWorkspaceContextPanel(workspaceIndex: shell.activeWSIndex)
    }

    // MARK: Agent

    @objc func newClaudeCode(_ sender: Any?) {
        shell?.openClaudeCode()
    }

    @objc func newCodex(_ sender: Any?) {
        shell?.openCodex()
    }

    @objc func reviewBranch(_ sender: Any?) {
        shell?.openBranchReview(in: shell?.activeWorkspace)
    }

    @objc func installAgentSkills(_ sender: Any?) {
        shell?.installAgentSkills()
    }

    // MARK: Columns and Help

    @objc func openEditor(_ sender: Any?) {
        shell?.openEditorColumn()
    }

    /// Enabled only with a Chromium browser to import from (see
    /// validateMenuItem), as the palette offers it.
    @objc func importBrowserCookies(_ sender: Any?) {
        shell?.importBrowserCookies()
    }

    @objc func showGettingStarted(_ sender: Any?) {
        shell?.showOnboardingChecklist()
    }

    // MARK: - Menus

    /// The active space's settings come from the sidebar's own builder, so
    /// the space menu there and this one list the same items. They open
    /// today's panels until Space Settings is one window.
    @MainActor
    func spaceMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "Space")
        menu.addItem(withTitle: SidebarView.newSpaceTitle, action: #selector(newSpace(_:)), keyEquivalent: "")
        let settings = NSMenuItem(title: "Space Settings", action: nil, keyEquivalent: "")
        settings.submenu = RebuiltMenu(title: "Space Settings") { [weak self] menu in
            self?.shell?.sidebar.addActiveSpaceSettings(to: menu)
        }
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Board", action: #selector(openBoard(_:)), shortcut: .board)
        menu.addItem(withTitle: "Session History…", action: #selector(showSessionHistory(_:)), keyEquivalent: "")
        menu.addItem(.separator())

        let previousSpaceItem = menu.addItem(withTitle: "Previous Space", action: #selector(previousSpace(_:)), keyEquivalent: "\u{F702}")
        previousSpaceItem.keyEquivalentModifierMask = [.command, .option]
        let nextSpaceItem = menu.addItem(withTitle: "Next Space", action: #selector(nextSpace(_:)), keyEquivalent: "\u{F703}")
        nextSpaceItem.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(.separator())
        menu.addItem(withTitle: "Clean Up Merged Worktrees…", action: #selector(cleanUpMergedWorktrees(_:)), keyEquivalent: "")
        let item = NSMenuItem()
        item.submenu = menu
        return item
    }

    @MainActor
    func workspacesMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "Workspaces")
        menu.addItem(withTitle: "New Workspace", action: #selector(newWorkspace(_:)), shortcut: .newWorkspace)
        menu.addItem(withTitle: "New Task…", action: #selector(newTask(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "New Worktree…", action: #selector(newWorktree(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Open Worktree…", action: #selector(openWorktree(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Rename Workspace", action: #selector(renameWorkspace(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "View/Edit Context…", action: #selector(editWorkspaceContext(_:)), keyEquivalent: "")
        menu.addItem(.separator())

        let workspaceUpItem = menu.addItem(withTitle: "Workspace Up", action: #selector(workspaceUp(_:)), keyEquivalent: "\u{F700}")
        workspaceUpItem.keyEquivalentModifierMask = .command
        menu.addItem(Self.controlAlternate(of: workspaceUpItem))
        let workspaceDownItem = menu.addItem(withTitle: "Workspace Down", action: #selector(workspaceDown(_:)), keyEquivalent: "\u{F701}")
        workspaceDownItem.keyEquivalentModifierMask = .command
        menu.addItem(Self.controlAlternate(of: workspaceDownItem))
        let item = NSMenuItem()
        item.submenu = menu
        return item
    }

    @MainActor
    func agentMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "Agent")
        menu.addItem(withTitle: "New Claude Code", action: #selector(newClaudeCode(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "New Codex", action: #selector(newCodex(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Next Waiting Agent", action: #selector(jumpToNextWaitingAgent(_:)), shortcut: .nextWaitingAgent)
        menu.addItem(withTitle: "Resume All Agents", action: #selector(resumeAllAgents(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Review Branch", action: #selector(reviewBranch(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Install Agent Skills", action: #selector(installAgentSkills(_:)), keyEquivalent: "")
        let item = NSMenuItem()
        item.submenu = menu
        return item
    }

    static let helpMenuTag = 2

    /// setupMenus hands this menu to NSApp.helpMenu, and macOS adds its
    /// search field on top.
    @MainActor
    func helpMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "Help")
        menu.addItem(withTitle: "Getting Started", action: #selector(showGettingStarted(_:)), keyEquivalent: "")
        let item = NSMenuItem()
        item.tag = Self.helpMenuTag
        item.submenu = menu
        return item
    }
}

/// A submenu emptied and filled by `populate` each time it opens. It answers
/// no key equivalent, so a key press never rebuilds it: its items must carry
/// none.
final class RebuiltMenu: NSMenu, NSMenuDelegate {
    private let populate: @MainActor (NSMenu) -> Void

    init(title: String, populate: @escaping @MainActor (NSMenu) -> Void) {
        self.populate = populate
        super.init(title: title)
        delegate = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        populate(menu)
    }

    func menuHasKeyEquivalent(
        _ menu: NSMenu,
        for event: NSEvent,
        target: AutoreleasingUnsafeMutablePointer<AnyObject?>,
        action: UnsafeMutablePointer<Selector?>
    ) -> Bool {
        false
    }
}
