import AppKit

// MARK: - Menu Actions & Menu Setup

extension NiruxApp {
    @objc func newTerminalColumn(_ sender: Any?) {
        shell?.addColumn()
    }

    @objc func closeColumn(_ sender: Any?) {
        // Cmd+W closes the window in front, as elsewhere on macOS: with a
        // panel (Settings, Workspace Context…) or a detached Web Inspector
        // key, the column behind it must stay open.
        if let keyWindow = NSApp.keyWindow, keyWindow !== mainWindow {
            keyWindow.performClose(sender)
            return
        }
        shell?.closeActiveColumn()
    }

    @objc func focusLeft(_ sender: Any?) {
        shell?.focusColumn(.left)
    }

    @objc func focusRight(_ sender: Any?) {
        shell?.focusColumn(.right)
    }

    @objc func cycleWidth(_ sender: Any?) {
        shell?.cycleActiveColumnWidth()
    }

    @objc func newWorkspace(_ sender: Any?) {
        shell?.showNewWorkspacePanel()
    }

    @objc func renameWorkspace(_ sender: Any?) {
        shell?.showRenamePanel()
    }

    @objc func workspaceUp(_ sender: Any?) {
        shell?.focusWorkspace(.up)
    }

    @objc func workspaceDown(_ sender: Any?) {
        shell?.focusWorkspace(.down)
    }

    /// One jump per press: a held ⌘J would spin through the queue.
    @objc func jumpToNextWaitingAgent(_ sender: Any?) {
        if let event = NSApp.currentEvent, event.type == .keyDown, event.isARepeat { return }
        shell?.jumpToNextWaitingAgent()
    }

    @objc func previousSpace(_ sender: Any?) {
        shell?.focusSpace(.previous)
    }

    @objc func nextSpace(_ sender: Any?) {
        shell?.focusSpace(.next)
    }

    @objc func moveColumnLeft(_ sender: Any?) {
        shell?.moveColumn(.left)
    }

    @objc func moveColumnRight(_ sender: Any?) {
        shell?.moveColumn(.right)
    }

    @objc func openBrowser(_ sender: Any?) {
        shell?.showCommandPaletteURLMode()
    }

    @objc func showCommandPalette(_ sender: Any?) {
        shell?.showCommandPalette()
    }

    @objc func showWorkspaceSearch(_ sender: Any?) {
        shell?.showWorkspaceSearch()
    }

    @objc func showGlobalSearch(_ sender: Any?) {
        shell?.showGlobalSearch()
    }

    // The find items act on the main window's focused terminal column only:
    // with a panel or a detached Web Inspector key, the bar would open
    // behind it.
    @objc func showTerminalFind(_ sender: Any?) {
        guard NSApp.keyWindow === mainWindow else { return }
        shell?.showTerminalFind()
    }

    @objc func findNextInTerminal(_ sender: Any?) {
        guard NSApp.keyWindow === mainWindow else { return }
        shell?.findNextInTerminal()
    }

    @objc func findPreviousInTerminal(_ sender: Any?) {
        guard NSApp.keyWindow === mainWindow else { return }
        shell?.findPreviousInTerminal()
    }

    @objc func toggleEditorDiff(_ sender: Any?) {
        shell?.toggleEditorDiff()
    }

    @objc func toggleWordWrap(_ sender: Any?) {
        shell?.toggleWordWrap()
    }

    @objc func sendSelectionToAgent(_ sender: Any?) {
        shell?.sendEditorSelectionToAgent()
    }

    @objc func saveAllInEditor(_ sender: Any?) {
        shell?.saveAllInEditor()
    }

    @objc func toggleMinimap(_ sender: Any?) {
        shell?.toggleMinimap()
    }

    @objc func toggleDevTools(_ sender: Any?) {
        shell?.toggleDevTools()
    }

    @objc func focusAddressBar(_ sender: Any?) {
        shell?.focusAddressBar()
    }

    @objc func focusColumnByNumber(_ sender: NSMenuItem) {
        shell?.focusColumn(number: sender.tag)
    }

    /// Same toggle as the sidebar's INACTIVE header (also in the ⌘P
    /// palette), for the menu bar and Help search.
    @objc func toggleInactiveWorkspaces(_ sender: Any?) {
        shell?.sidebar.toggleInactiveSection()
    }

    // Not `toggleSidebar(_:)`: NSWindow answers that AppKit selector first,
    // so a nil-target menu item would resolve to the window and stay disabled.
    @objc func toggleWorkspaceSidebar(_ sender: Any?) {
        shell?.toggleSidebar()
    }

    @MainActor
    func setupMenus() {
        // Single-window app: keep AppKit from adding native window-tab items
        // (Show Tab Bar, Merge All Windows…) to the View and Window menus.
        NSWindow.allowsAutomaticWindowTabbing = false
        let mainMenu = makeMainMenu()
        NSApp.mainMenu = mainMenu
        // Lets AppKit list open windows and add its tiling items.
        NSApp.windowsMenu = mainMenu.item(withTag: Self.windowMenuTag)?.submenu
    }

    @MainActor
    func makeMainMenu() -> NSMenu {
        let mainMenu = NSMenu()
        mainMenu.addItem(applicationMenuItem())
        mainMenu.addItem(editMenuItem())
        mainMenu.addItem(viewMenuItem())
        mainMenu.addItem(columnsMenuItem())
        mainMenu.addItem(workspacesMenuItem())
        mainMenu.addItem(windowMenuItem())
        return mainMenu
    }

    @MainActor
    private func applicationMenuItem() -> NSMenuItem {
        // App menu (must be first item — macOS uses index 0 as the application menu)
        let appMenu = NSMenu(title: "Nirux")
        appMenu.addItem(withTitle: "About Nirux", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        let checkUpdate = NSMenuItem(
            title: "Check for Updates…", action: #selector(manualCheckForUpdates(_:)), keyEquivalent: ""
        )
        checkUpdate.target = self
        appMenu.addItem(checkUpdate)
        let autoInstall = NSMenuItem(
            title: "Install Updates Automatically", action: #selector(toggleAutomaticUpdates(_:)), keyEquivalent: ""
        )
        autoInstall.target = self
        appMenu.addItem(autoInstall)
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings(_:)), shortcut: .settings)
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit Nirux", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        return appItem
    }

    @MainActor
    private func editMenuItem() -> NSMenuItem {
        // Edit menu (needed for Cmd+Z/X/C/V/A in text fields and WebViews)
        let editMenu = NSMenu(title: "Edit")
        let undoItem = editMenu.addItem(withTitle: "Undo", action: #selector(PanelTextUndo.undo(_:)), keyEquivalent: "z")
        undoItem.target = PanelTextUndo.shared
        let redoItem = editMenu.addItem(withTitle: "Redo", action: #selector(PanelTextUndo.redo(_:)), keyEquivalent: "z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        redoItem.target = PanelTextUndo.shared
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Find in Terminal…", action: #selector(showTerminalFind(_:)), keyEquivalent: "f")
        editMenu.addItem(withTitle: "Find Next", action: #selector(findNextInTerminal(_:)), keyEquivalent: "g")
        let findPreviousItem = editMenu.addItem(
            withTitle: "Find Previous",
            action: #selector(findPreviousInTerminal(_:)),
            keyEquivalent: "g"
        )
        findPreviousItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(
            withTitle: "Search Workspace…",
            action: #selector(showWorkspaceSearch(_:)),
            shortcut: .searchWorkspace
        )
        editMenu.addItem(
            withTitle: "Search Everywhere…",
            action: #selector(showGlobalSearch(_:)),
            shortcut: .searchEverywhere
        )

        let sendSelectionItem = NSMenuItem(
            title: "Send Selection to Agent",
            action: #selector(sendSelectionToAgent(_:)),
            keyEquivalent: "\r"
        )
        sendSelectionItem.keyEquivalentModifierMask = [.command, .option]
        editMenu.addItem(sendSelectionItem)

        let saveAllItem = NSMenuItem(
            title: "Save All",
            action: #selector(saveAllInEditor(_:)),
            keyEquivalent: "s"
        )
        saveAllItem.keyEquivalentModifierMask = [.command, .option]
        editMenu.addItem(saveAllItem)
        let editItem = NSMenuItem()
        editItem.submenu = editMenu
        return editItem
    }

    @MainActor
    private func viewMenuItem() -> NSMenuItem {
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Toggle Sidebar", action: #selector(toggleWorkspaceSidebar(_:)), shortcut: .toggleSidebar)
        viewMenu.addItem(
            withTitle: "Show Inactive Workspaces",
            action: #selector(toggleInactiveWorkspaces(_:)),
            keyEquivalent: ""
        )
        viewMenu.addItem(NSMenuItem.separator())
        viewMenu.addItem(
            withTitle: "Toggle Editor Diff",
            action: #selector(toggleEditorDiff(_:)),
            shortcut: .toggleEditorDiff
        )

        let wrapItem = NSMenuItem(
            title: "Toggle Word Wrap",
            action: #selector(toggleWordWrap(_:)),
            keyEquivalent: "z"
        )
        wrapItem.keyEquivalentModifierMask = [.command, .option]
        viewMenu.addItem(wrapItem)

        let minimapItem = NSMenuItem(
            title: "Toggle Minimap",
            action: #selector(toggleMinimap(_:)),
            keyEquivalent: "m"
        )
        minimapItem.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(minimapItem)
        viewMenu.addItem(NSMenuItem.separator())

        // AppKit retitles this item to "Exit Full Screen" while in full screen.
        let fullScreenItem = viewMenu.addItem(
            withTitle: "Enter Full Screen",
            action: #selector(NSWindow.toggleFullScreen(_:)),
            keyEquivalent: "f"
        )
        fullScreenItem.keyEquivalentModifierMask = [.command, .control]

        let viewItem = NSMenuItem()
        viewItem.submenu = viewMenu
        return viewItem
    }

    @MainActor
    private func columnsMenuItem() -> NSMenuItem {
        // Columns menu
        let colMenu = NSMenu(title: "Columns")
        colMenu.addItem(withTitle: "Command Palette", action: #selector(showCommandPalette(_:)), shortcut: .commandPalette)
        // Shown in place of the item above while Shift is held.
        let paletteAlternate = colMenu.addItem(
            withTitle: "Command Palette",
            action: #selector(showCommandPalette(_:)),
            shortcut: .commandPaletteAlternate
        )
        paletteAlternate.isAlternate = true
        colMenu.addItem(NSMenuItem.separator())
        colMenu.addItem(withTitle: "New Terminal", action: #selector(newTerminalColumn(_:)), shortcut: .newTerminal)
        colMenu.addItem(withTitle: "Open Browser", action: #selector(openBrowser(_:)), shortcut: .openBrowser)

        // Cmd+1…9: jump straight to column N (iTerm-style tab switching).
        for number in 1...9 {
            let item = NSMenuItem(
                title: "Focus Column \(number)",
                action: #selector(focusColumnByNumber(_:)),
                keyEquivalent: "\(number)"
            )
            item.tag = number
            colMenu.addItem(item)
        }
        colMenu.addItem(NSMenuItem.separator())

        colMenu.addItem(withTitle: "Toggle Web Inspector", action: #selector(toggleDevTools(_:)), shortcut: .webInspector)

        colMenu.addItem(withTitle: "Focus Address Bar", action: #selector(focusAddressBar(_:)), keyEquivalent: "l")

        colMenu.addItem(withTitle: "Close Column", action: #selector(closeColumn(_:)), shortcut: .closeColumn)
        colMenu.addItem(NSMenuItem.separator())

        let focusLeftItem = NSMenuItem(title: "Focus Left", action: #selector(focusLeft(_:)), keyEquivalent: "\u{F702}")
        focusLeftItem.keyEquivalentModifierMask = .command
        colMenu.addItem(focusLeftItem)
        colMenu.addItem(Self.controlAlternate(of: focusLeftItem))

        let focusRightItem = NSMenuItem(title: "Focus Right", action: #selector(focusRight(_:)), keyEquivalent: "")
        focusRightItem.keyEquivalent = "\u{F703}"
        focusRightItem.keyEquivalentModifierMask = .command
        colMenu.addItem(focusRightItem)
        colMenu.addItem(Self.controlAlternate(of: focusRightItem))

        colMenu.addItem(NSMenuItem.separator())

        let moveLeftItem = NSMenuItem(title: "Move Left", action: #selector(moveColumnLeft(_:)), keyEquivalent: "\u{F702}")
        moveLeftItem.keyEquivalentModifierMask = [.command, .shift]
        colMenu.addItem(moveLeftItem)

        let moveRightItem = NSMenuItem(title: "Move Right", action: #selector(moveColumnRight(_:)), keyEquivalent: "\u{F703}")
        moveRightItem.keyEquivalentModifierMask = [.command, .shift]
        colMenu.addItem(moveRightItem)

        colMenu.addItem(NSMenuItem.separator())
        colMenu.addItem(withTitle: "Cycle Width", action: #selector(cycleWidth(_:)), shortcut: .cycleWidth)

        let colItem = NSMenuItem()
        colItem.submenu = colMenu
        return colItem
    }

    @MainActor
    private func workspacesMenuItem() -> NSMenuItem {
        // Workspaces menu
        let workspacesMenu = NSMenu(title: "Workspaces")
        workspacesMenu.addItem(withTitle: "New Workspace", action: #selector(newWorkspace(_:)), shortcut: .newWorkspace)
        workspacesMenu.addItem(withTitle: "Rename Workspace", action: #selector(renameWorkspace(_:)), keyEquivalent: "")
        workspacesMenu.addItem(NSMenuItem.separator())

        let workspaceUpItem = NSMenuItem(title: "Workspace Up", action: #selector(workspaceUp(_:)), keyEquivalent: "")
        workspaceUpItem.keyEquivalent = "\u{F700}"
        workspaceUpItem.keyEquivalentModifierMask = .command
        workspacesMenu.addItem(workspaceUpItem)
        workspacesMenu.addItem(Self.controlAlternate(of: workspaceUpItem))

        let workspaceDownItem = NSMenuItem(title: "Workspace Down", action: #selector(workspaceDown(_:)), keyEquivalent: "")
        workspaceDownItem.keyEquivalent = "\u{F701}"
        workspaceDownItem.keyEquivalentModifierMask = .command
        workspacesMenu.addItem(workspaceDownItem)
        workspacesMenu.addItem(Self.controlAlternate(of: workspaceDownItem))

        workspacesMenu.addItem(NSMenuItem.separator())

        let previousSpaceItem = NSMenuItem(title: "Previous Space", action: #selector(previousSpace(_:)), keyEquivalent: "")
        previousSpaceItem.keyEquivalent = "\u{F702}"
        previousSpaceItem.keyEquivalentModifierMask = NSEvent.ModifierFlags([.command, .option])
        workspacesMenu.addItem(previousSpaceItem)

        let nextSpaceItem = NSMenuItem(title: "Next Space", action: #selector(nextSpace(_:)), keyEquivalent: "")
        nextSpaceItem.keyEquivalent = "\u{F703}"
        nextSpaceItem.keyEquivalentModifierMask = NSEvent.ModifierFlags([.command, .option])
        workspacesMenu.addItem(nextSpaceItem)

        workspacesMenu.addItem(NSMenuItem.separator())
        workspacesMenu.addItem(
            withTitle: "Next Waiting Agent",
            action: #selector(jumpToNextWaitingAgent(_:)),
            shortcut: .nextWaitingAgent
        )

        let workspacesItem = NSMenuItem()
        workspacesItem.submenu = workspacesMenu
        return workspacesItem
    }

    /// `item` on Control+Cmd+Arrow, shown in its place while Control is
    /// held. Cmd+Arrow moves the caret while text has the keyboard (see
    /// WebContentKeyRouting.movesCaretToTextEdge); this chord navigates from
    /// anywhere.
    @MainActor
    private static func controlAlternate(of item: NSMenuItem) -> NSMenuItem {
        let alternate = NSMenuItem(title: item.title, action: item.action, keyEquivalent: item.keyEquivalent)
        alternate.keyEquivalentModifierMask = item.keyEquivalentModifierMask.union(.control)
        alternate.isAlternate = true
        return alternate
    }

    static let windowMenuTag = 1

    @MainActor
    private func windowMenuItem() -> NSMenuItem {
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(NSMenuItem.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        let windowItem = NSMenuItem()
        windowItem.tag = Self.windowMenuTag
        windowItem.submenu = windowMenu
        return windowItem
    }
}

private extension NSMenu {
    @discardableResult
    func addItem(withTitle title: String, action: Selector, shortcut: NiruxShortcuts) -> NSMenuItem {
        let item = addItem(withTitle: title, action: action, keyEquivalent: shortcut.chord.key)
        item.keyEquivalentModifierMask = shortcut.chord.modifiers
        return item
    }
}
