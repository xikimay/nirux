import AppKit

// MARK: - Space, Workspaces, Agent and Help menus

/// Every command of the palette has a menu bar item, so the Help menu's
/// search finds it with its shortcut (docs/spaces.md, Interface).
extension NiruxApp {
    // MARK: Space

    /// Whatever the sidebar's "New Space…" does.
    @objc func newSpace(_ sender: Any?) {
        shell?.sidebar.onCreateProfile?()
    }

    /// ⌥⌘1…⌥⌘9: the space at that place in the picker.
    @objc func selectSpaceByNumber(_ sender: NSMenuItem) {
        shell?.selectSpace(number: sender.tag)
    }

    @objc func showActiveSpaceSettings(_ sender: Any?) {
        guard let shell else { return }
        shell.showSpaceSettings(profileID: shell.activeProfileID)
    }

    @objc func openBoard(_ sender: Any?) {
        shell?.openProjectBoard()
    }

    /// ⌃⌘L: the active space's Lead, started when it has none (see
    /// `validateLeadItem`).
    @objc func focusLead(_ sender: Any?) {
        shell?.focusOrStartLead()
    }

    /// "Lead" when the active space has one, else "Start a Lead"; General
    /// has none.
    @MainActor
    func validateLeadItem(_ item: NSMenuItem) -> Bool {
        guard let shell, NiruxShellView.spaceCanHaveLead(shell.activeProfileID) else {
            item.title = Self.leadItemTitle
            return false
        }
        item.title = shell.leadWorkspace(inSpace: shell.activeProfileID) == nil ? Self.startLeadItemTitle : Self.leadItemTitle
        return true
    }

    static let leadItemTitle = "Lead"
    static let startLeadItemTitle = "Start a Lead"

    @objc func showSessionHistory(_ sender: Any?) {
        shell?.showSessionHistory()
    }

    @objc func cleanUpMergedWorktrees(_ sender: Any?) {
        shell?.showWorktreeCleanupPanel()
    }

    // MARK: Workspaces

    @objc func openWorktree(_ sender: Any?) {
        shell?.showWorktreeListPalette()
    }

    /// The card menu's New Sub-task…, for the workspace in front.
    @objc func newSubtask(_ sender: Any?) {
        _ = sender
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

    /// Space Settings acts on the space in front (docs/spaces.md, S8).
    @MainActor
    func spaceMenuItem() -> NSMenuItem {
        let menu = SpaceListMenu(title: "Space") { [weak self] in self?.shell?.sidebar.lastProfiles ?? [] }
        menu.addItem(withTitle: SidebarView.newSpaceTitle, action: #selector(newSpace(_:)), keyEquivalent: "")
        menu.addItem(withTitle: SidebarView.spaceSettingsTitle, action: #selector(showActiveSpaceSettings(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Board", action: #selector(openBoard(_:)), shortcut: .board)
        menu.addItem(withTitle: Self.leadItemTitle, action: #selector(focusLead(_:)), shortcut: .lead)
        menu.addItem(withTitle: "Session History…", action: #selector(showSessionHistory(_:)), keyEquivalent: "")
        menu.addItem(.separator())

        let previousSpaceItem = menu.addItem(withTitle: "Previous Space", action: #selector(previousSpace(_:)), keyEquivalent: "\u{F702}")
        previousSpaceItem.keyEquivalentModifierMask = [.command, .option]
        let nextSpaceItem = menu.addItem(withTitle: "Next Space", action: #selector(nextSpace(_:)), keyEquivalent: "\u{F703}")
        nextSpaceItem.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(.separator())
        menu.addSpaceItems()
        menu.addItem(.separator())
        menu.addItem(withTitle: "Clean Up Merged Worktrees…", action: #selector(cleanUpMergedWorktrees(_:)), keyEquivalent: "")
        let item = NSMenuItem()
        item.submenu = menu
        return item
    }

    @MainActor
    func workspacesMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "Workspaces")
        menu.addItem(withTitle: "New…", action: #selector(newWorkspace(_:)), shortcut: .newWorkspace)
        menu.addItem(withTitle: SidebarView.newSubtaskTitle, action: #selector(newSubtask(_:)), keyEquivalent: "")
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

/// The menu bar's Space menu. Its spaces (⌥⌘1…⌥⌘9) are nine fixed items
/// that follow the picker's list whenever it changes (AppKit doesn't update
/// a menu before matching its key equivalents) and when the menu opens;
/// those past the last space hide.
@MainActor
final class SpaceListMenu: NSMenu, NSMenuDelegate {
    private let profiles: @MainActor () -> [ProfileInfo]
    private(set) var spaceItems: [NSMenuItem] = []
    private var describedProfiles: [ProfileInfo]?

    init(title: String, profiles: @escaping @MainActor () -> [ProfileInfo]) {
        self.profiles = profiles
        super.init(title: title)
        delegate = self
        NotificationCenter.default.addObserver(
            self, selector: #selector(spacesDidChange(_:)), name: SidebarView.spacesDidChangeNotification, object: nil
        )
    }

    @objc private func spacesDidChange(_ notification: Notification) {
        refresh()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    func addSpaceItems() {
        for number in 1...9 {
            let item = addItem(
                withTitle: "Space \(number)", action: #selector(NiruxApp.selectSpaceByNumber(_:)), keyEquivalent: ""
            )
            item.tag = number
            item.isHidden = true
            spaceItems.append(item)
        }
        refresh()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refresh()
    }

    func refresh() {
        // Draw the dots again only on a change.
        let profiles = profiles()
        guard profiles != describedProfiles else { return }
        describedProfiles = profiles
        for (position, item) in spaceItems.enumerated() {
            guard let profile = profiles[safe: position] else {
                item.isHidden = true
                item.keyEquivalent = ""
                continue
            }
            SidebarView.describeSpace(item, profile: profile, position: position)
            // The picker's count and tooltip, not the menu bar's business.
            item.badge = nil
            item.toolTip = nil
            item.isHidden = false
        }
    }
}
