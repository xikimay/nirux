import AppKit

/// The editor's column header: the active file and its directory, the
/// diff toggle and the workspace search, and the editor's items in ⋯.
extension EditorColumn {
    func setupHeader() {
        header.icon = .symbol(Theme.Symbol.editor)
        diffButton.target = self
        diffButton.action = #selector(diffButtonClicked)
        // Up the responder chain to the app, like the menu's item.
        searchButton.action = #selector(NiruxApp.showWorkspaceSearch(_:))
        header.trailingButtons = [diffButton, searchButton]
        header.menuProvider = { Self.headerMenu() }
        addSubview(header)
    }

    /// The editor's ⋯ menu: its main-menu items, then the column's.
    private static func headerMenu() -> NSMenu {
        let menu = NSMenu()
        let saveAll = menu.addItem(withTitle: "Save All", action: #selector(NiruxApp.saveAllInEditor(_:)), keyEquivalent: "s")
        saveAll.keyEquivalentModifierMask = [.command, .option]
        let wrap = menu.addItem(withTitle: "Toggle Word Wrap", action: #selector(NiruxApp.toggleWordWrap(_:)), keyEquivalent: "z")
        wrap.keyEquivalentModifierMask = [.command, .option]
        let minimap = menu.addItem(withTitle: "Toggle Minimap", action: #selector(NiruxApp.toggleMinimap(_:)), keyEquivalent: "m")
        minimap.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        ColumnHeaderView.columnMenuItems().forEach(menu.addItem)
        return menu
    }

    @objc private func diffButtonClicked() {
        toggleDiff()
    }

    /// The header names the active tab and where its file is; the diff
    /// toggle shows whether the tab shows its diff.
    func refreshHeader() {
        guard let activePath else {
            header.title = "Editor"
            header.context = ""
            header.titleToolTip = nil
            diffButton.isEnabled = false
            diffButton.isOn = false
            return
        }
        if let groupTitle = activeDiffGroupTitle {
            header.title = groupTitle
            header.context = ""
        } else {
            header.title = (activePath as NSString).lastPathComponent
            header.context = Self.directoryContext(of: activePath, workspaceCwd: workspaceCwd)
        }
        header.titleToolTip = Self.isDiffGroupPath(activePath) ? nil : activePath
        diffButton.isEnabled = !Self.isDiffGroupPath(activePath)
        diffButton.isOn = diffActivePath == activePath
    }

    /// The file's directory relative to the workspace ("Sources/Nirux"),
    /// empty at its root; abbreviated when outside it.
    nonisolated static func directoryContext(of path: String, workspaceCwd: String) -> String {
        let directory = (path as NSString).deletingLastPathComponent
        let root = workspaceCwd.hasSuffix("/") ? String(workspaceCwd.dropLast()) : workspaceCwd
        if directory == root { return "" }
        if directory.hasPrefix(root + "/") { return String(directory.dropFirst(root.count + 1)) }
        return directory.abbreviatedPath()
    }
}
