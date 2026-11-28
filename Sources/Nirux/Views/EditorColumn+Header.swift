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
            let menu = Self.headerMenu(isFront: self?.isFront ?? false, elsewhere: self?.openElsewhereItems() ?? [])
            // Also where a narrow header has no room for its button.
            if let self, let path = self.currentPath, self.draftPaths.contains(path) {
                let item = NSMenuItem(title: Self.copyDraftTitle, action: #selector(self.copyDraftClicked), keyEquivalent: "")
                item.target = self
                menu.insertItem(item, at: 0)
                menu.insertItem(.separator(), at: 1)
            }
            return menu
        }
        addSubview(header)
    }

    /// The editor's ⋯ menu: where it lies, its main-menu items, where else
    /// the file opens, then the column's.
    private static func headerMenu(isFront: Bool, elsewhere: [NSMenuItem]) -> NSMenu {
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
        elsewhere.forEach(menu.addItem)
        menu.addItem(.separator())
        ColumnHeaderView.columnMenuItems().forEach(menu.addItem)
        return menu
    }

    /// Open in each of the user's editors installed (Save and Open with
    /// unsaved edits), then Reveal in Finder: for a file on disk.
    private func openElsewhereItems() -> [NSMenuItem] {
        let onDisk = currentPath.map { FileManager.default.fileExists(atPath: $0) } ?? false
        let saves = currentPath.map(unsavedPaths.contains) ?? false
        let opens = installedEditors().map { editor in
            let title = (saves ? "Save and Open in " : "Open in ") + editor.name
            let item = NSMenuItem(title: title, action: onDisk ? #selector(openElsewhereClicked(_:)) : nil, keyEquivalent: "")
            item.representedObject = editor.bundleID
            return item
        }
        let reveal = NSMenuItem(title: "Reveal in Finder", action: onDisk ? #selector(revealInFinderClicked) : nil, keyEquivalent: "")
        return (opens + [reveal]).map { item in
            item.target = self
            return item
        }
    }

    /// The user carries on there, with their edits: the caret read first
    /// (an agent's open may switch the tab during the save), then saved, and
    /// nothing opens when the save fails.
    @objc private func openElsewhereClicked(_ sender: NSMenuItem) {
        guard let path = currentPath, let editor = ExternalEditor.withBundleID(sender.representedObject as? String) else { return }
        readCaret(of: path) { [weak self] line, column in
            guard let self else { return }
            let open: () -> Void = { self.onOpenElsewhere?(editor, path, line, column) }
            guard self.unsavedPaths.contains(path) else { return open() }
            self.save(paths: [path]) { written in
                if written { open() }
            }
        }
    }

    @objc private func revealInFinderClicked() {
        guard let path = currentPath else { return }
        onRevealInFinder?(path)
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
            let shown = showsPierreDiff ? nil : shownRanges[activePath]
            header.context = shown.map { Self.linesLabel($0.lines) } ?? Self.directoryContext(of: activePath, workspaceCwd: workspaceCwd)
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
