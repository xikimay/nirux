import AppKit

// MARK: - Menu Actions & Menu Setup

extension NiruxApp {
    @objc func newTerminalColumn(_ sender: Any?) {
        shell?.addColumn()
    }

    @objc func closeColumn(_ sender: Any?) {
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

    @objc func togglePilotMode(_ sender: Any?) {
        shell?.togglePilotMode()
    }

    @objc func toggleSidebar(_ sender: Any?) {
        shell?.toggleSidebar()
    }

    @MainActor
    func setupMenus() {
        let mainMenu = NSMenu()
        mainMenu.addItem(applicationMenuItem())
        mainMenu.addItem(editMenuItem())
        mainMenu.addItem(columnsMenuItem())
        mainMenu.addItem(workspacesMenuItem())
        NSApp.mainMenu = mainMenu
    }

    @MainActor
    private func applicationMenuItem() -> NSMenuItem {
        // App menu (must be first item — macOS uses index 0 as the application menu)
        let appMenu = NSMenu(title: "Nirux")
        appMenu.addItem(withTitle: "About Nirux", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        let checkUpdate = NSMenuItem(
            title: "Check for Updates...", action: #selector(manualCheckForUpdates(_:)), keyEquivalent: ""
        )
        checkUpdate.target = self
        appMenu.addItem(checkUpdate)
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Settings...", action: #selector(showSettings(_:)), keyEquivalent: ",")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit Nirux", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        return appItem
    }

    @MainActor
    private func editMenuItem() -> NSMenuItem {
        // Edit menu (needed for Cmd+C/V/X/A in text fields and WebViews)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(NSMenuItem.separator())
        let searchItem = NSMenuItem(
            title: "Search Workspace…",
            action: #selector(showWorkspaceSearch(_:)),
            keyEquivalent: "f"
        )
        searchItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(searchItem)

        let diffItem = NSMenuItem(
            title: "Toggle Editor Diff",
            action: #selector(toggleEditorDiff(_:)),
            keyEquivalent: "d"
        )
        diffItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(diffItem)

        let wrapItem = NSMenuItem(
            title: "Toggle Word Wrap",
            action: #selector(toggleWordWrap(_:)),
            keyEquivalent: "z"
        )
        wrapItem.keyEquivalentModifierMask = [.command, .option]
        editMenu.addItem(wrapItem)

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

        let minimapItem = NSMenuItem(
            title: "Toggle Minimap",
            action: #selector(toggleMinimap(_:)),
            keyEquivalent: "m"
        )
        minimapItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(minimapItem)
        let editItem = NSMenuItem()
        editItem.submenu = editMenu
        return editItem
    }

    @MainActor
    private func columnsMenuItem() -> NSMenuItem {
        // Columns menu
        let colMenu = NSMenu(title: "Columns")
        colMenu.addItem(withTitle: "Command Palette", action: #selector(showCommandPalette(_:)), keyEquivalent: "p")
        colMenu.addItem(NSMenuItem.separator())
        colMenu.addItem(
            withTitle: "New Terminal",
            action: #selector(newTerminalColumn(_:)),
            keyEquivalent: NiruxShortcuts.newTerminalKey
        )
        colMenu.addItem(withTitle: "Open Browser", action: #selector(openBrowser(_:)), keyEquivalent: "b")

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

        let devToolsItem = NSMenuItem(title: "Toggle Web Inspector", action: #selector(toggleDevTools(_:)), keyEquivalent: "i")
        devToolsItem.keyEquivalentModifierMask = [.command, .option]
        colMenu.addItem(devToolsItem)

        colMenu.addItem(withTitle: "Focus Address Bar", action: #selector(focusAddressBar(_:)), keyEquivalent: "l")

        colMenu.addItem(withTitle: "Close Column", action: #selector(closeColumn(_:)), keyEquivalent: "w")
        colMenu.addItem(NSMenuItem.separator())

        let focusLeftItem = NSMenuItem(title: "Focus Left", action: #selector(focusLeft(_:)), keyEquivalent: "\u{F702}")
        focusLeftItem.keyEquivalentModifierMask = .command
        colMenu.addItem(focusLeftItem)

        let focusRightItem = NSMenuItem(title: "Focus Right", action: #selector(focusRight(_:)), keyEquivalent: "")
        focusRightItem.keyEquivalent = "\u{F703}"
        focusRightItem.keyEquivalentModifierMask = .command
        colMenu.addItem(focusRightItem)

        colMenu.addItem(NSMenuItem.separator())

        let moveLeftItem = NSMenuItem(title: "Move Left", action: #selector(moveColumnLeft(_:)), keyEquivalent: "\u{F702}")
        moveLeftItem.keyEquivalentModifierMask = [.command, .shift]
        colMenu.addItem(moveLeftItem)

        let moveRightItem = NSMenuItem(title: "Move Right", action: #selector(moveColumnRight(_:)), keyEquivalent: "\u{F703}")
        moveRightItem.keyEquivalentModifierMask = [.command, .shift]
        colMenu.addItem(moveRightItem)

        colMenu.addItem(NSMenuItem.separator())
        colMenu.addItem(withTitle: "Cycle Width", action: #selector(cycleWidth(_:)), keyEquivalent: "e")
        colMenu.addItem(withTitle: "Pilot Mode", action: #selector(togglePilotMode(_:)), keyEquivalent: "o")
        colMenu.addItem(withTitle: "Toggle Sidebar", action: #selector(toggleSidebar(_:)), keyEquivalent: "s")

        let colItem = NSMenuItem()
        colItem.submenu = colMenu
        return colItem
    }

    @MainActor
    private func workspacesMenuItem() -> NSMenuItem {
        // Workspaces menu
        let workspacesMenu = NSMenu(title: "Workspaces")
        workspacesMenu.addItem(
            withTitle: "New Workspace",
            action: #selector(newWorkspace(_:)),
            keyEquivalent: NiruxShortcuts.newWorkspaceKey
        )
        workspacesMenu.addItem(withTitle: "Rename Workspace", action: #selector(renameWorkspace(_:)), keyEquivalent: "")
        workspacesMenu.addItem(NSMenuItem.separator())

        let workspaceUpItem = NSMenuItem(title: "Workspace Up", action: #selector(workspaceUp(_:)), keyEquivalent: "")
        workspaceUpItem.keyEquivalent = "\u{F700}"
        workspaceUpItem.keyEquivalentModifierMask = .command
        workspacesMenu.addItem(workspaceUpItem)

        let workspaceDownItem = NSMenuItem(title: "Workspace Down", action: #selector(workspaceDown(_:)), keyEquivalent: "")
        workspaceDownItem.keyEquivalent = "\u{F701}"
        workspaceDownItem.keyEquivalentModifierMask = .command
        workspacesMenu.addItem(workspaceDownItem)

        workspacesMenu.addItem(NSMenuItem.separator())

        let previousSpaceItem = NSMenuItem(title: "Previous Space", action: #selector(previousSpace(_:)), keyEquivalent: "")
        previousSpaceItem.keyEquivalent = "\u{F702}"
        previousSpaceItem.keyEquivalentModifierMask = NSEvent.ModifierFlags([.command, .option])
        workspacesMenu.addItem(previousSpaceItem)

        let nextSpaceItem = NSMenuItem(title: "Next Space", action: #selector(nextSpace(_:)), keyEquivalent: "")
        nextSpaceItem.keyEquivalent = "\u{F703}"
        nextSpaceItem.keyEquivalentModifierMask = NSEvent.ModifierFlags([.command, .option])
        workspacesMenu.addItem(nextSpaceItem)

        let workspacesItem = NSMenuItem()
        workspacesItem.submenu = workspacesMenu
        return workspacesItem
    }
}
