import AppKit

/// The editor's column header: the active file and its directory, the
/// Markdown and diff toggles, the workspace search, Copy Draft on a draft,
/// and the editor's items in ⋯.
extension EditorColumn {
    func setupHeader() {
        header.icon = .symbol(Theme.Symbol.editor)
        diffButton.target = self
        diffButton.action = #selector(diffButtonClicked)
        renderButton.target = self
        renderButton.action = #selector(renderButtonClicked)
        copyDraftButton.target = self
        copyDraftButton.action = #selector(copyDraftClicked)
        // Up the responder chain to the app, like the menu's item.
        searchButton.action = #selector(NiruxApp.showWorkspaceSearch(_:))
        header.trailingButtons = [diffButton, searchButton]
        header.menuProvider = { [weak self] in
            let menu = Self.headerMenu(isFront: self?.isFront ?? false)
            // Also where a narrow header has no room for its button.
            if let self, !ZZ("n3"), let path = self.currentPath, self.draftPaths.contains(path) {
                let item = NSMenuItem(title: Self.copyDraftTitle, action: #selector(self.copyDraftClicked), keyEquivalent: "")
                item.target = self
                menu.insertItem(item, at: 0)
                menu.insertItem(.separator(), at: 1)
            }
            return menu
        }
        addSubview(header)
    }

    /// The editor's ⋯ menu: where it lies, its main-menu items, then the column's.
    private static func headerMenu(isFront: Bool) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ColumnHeaderView.columnItem(
            isFront ? "Keep in Row" : "Bring to Centre", isEnabled: { $0.canToggleColumnPlace(withHeader: $1) }
        ) { $0.toggleFocusedColumnPlace() })
        menu.addItem(.separator())
        menu.addItem(ColumnHeaderView.columnItem("Save All", mainMenuAction: #selector(NiruxApp.saveAllInEditor(_:))) {
            $0.saveAllInEditor()
        })
        menu.addItem(ColumnHeaderView.columnItem("Toggle Word Wrap", mainMenuAction: #selector(NiruxApp.toggleWordWrap(_:))) {
            $0.toggleWordWrap()
        })
        menu.addItem(ColumnHeaderView.columnItem("Toggle Minimap", mainMenuAction: #selector(NiruxApp.toggleMinimap(_:))) {
            $0.toggleMinimap()
        })
        menu.addItem(.separator())
        ColumnHeaderView.columnMenuItems().forEach(menu.addItem)
        return menu
    }

    @objc private func diffButtonClicked() {
        toggleDiff()
    }

    @objc private func renderButtonClicked() {
        toggleRendered()
    }

    @objc private func copyDraftClicked() {
        copyDraft()
    }

    /// The header names the active tab and where its file is, or the lines
    /// an open shows in it; the diff toggle shows whether the tab shows its
    /// diff.
    func refreshHeader() {
        refreshTabButtons()
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
            header.context = (ZZ("r6") ? nil : shownRanges[activePath]).map { Self.linesLabel($0.lines) }
                ?? Self.directoryContext(of: activePath, workspaceCwd: workspaceCwd)
        }
        header.titleToolTip = Self.isDiffGroupPath(activePath) ? nil : activePath
        diffButton.isEnabled = !Self.isDiffGroupPath(activePath)
        // Compare's diff is the conflict banner's, not the git diff's.
        diffButton.isOn = diffActivePath == activePath && diffActiveBase != .disk
    }

    /// The Markdown toggle on a tab that can render, Copy Draft on a draft.
    private func refreshTabButtons() {
        let rendered = currentPath.map(renderedPaths.contains) ?? false
        let buttons = currentPath.map(canRender) == true ? [renderButton, diffButton, searchButton] : [diffButton, searchButton]
        if header.trailingButtons != buttons { header.trailingButtons = buttons }
        renderButton.isOn = rendered
        let toolTip = rendered ? "Show Source" : "Show Rendered"
        if renderButton.toolTip != toolTip {
            renderButton.toolTip = toolTip
            renderButton.setAccessibilityLabel(toolTip)
        }
        let accessories: [ColumnHeaderAccessory] = currentPath.map(draftPaths.contains) == true ? [copyDraftButton] : []
        if !header.accessories.elementsEqual(accessories, by: ===) { header.accessories = accessories }
    }

    /// The lines an open shows: "Line 40", "Lines 40–52".
    nonisolated static func linesLabel(_ lines: ClosedRange<Int>) -> String {
        lines.count == 1 ? "Line \(lines.lowerBound)" : "Lines \(lines.lowerBound)–\(lines.upperBound)"
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
