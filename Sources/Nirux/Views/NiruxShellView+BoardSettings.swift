import AppKit

// MARK: - Board settings (see BoardConfig)

extension NiruxShellView {
    /// What Board Settings shows: board.json, the space's repositories
    /// and the one picked, with suggestions from its checkouts.
    struct BoardSettingsRead: Sendable {
        let loaded: BoardConfigStore.Loaded
        let context: BoardSections.Context
        let sections: [BoardSections.Section]
        let section: BoardSections.Section
        let suggestions: BoardConfigSuggestions
    }

    /// "Board Settings…" in a space's menu, on the repository with this id
    /// (else the default one). Reads board.json and runs git in the
    /// repository's checkout (the space's workspace folders, for a space
    /// without repository anchors) off the main thread, then opens the form.
    func showBoardSettings(profileID: String, repository: String? = nil) {
        guard window != nil else { return }
        guard !isReadingBoardSettings else {
            showToast("Board settings are still loading")
            return
        }
        if let panel = boardSettingsPanel {
            if panel.spaceID == profileID {
                panel.focus()
            } else {
                showToast("Another space’s board settings are open: close them first")
            }
            return
        }
        guard let store = BoardConfigStore(spaceID: profileID) else {
            showToast("Couldn’t find this space’s board settings", tone: .error)
            return
        }
        // Inactive workspaces belong to the project too.
        let folders = workspaces.filter { $0.profileID == profileID && !$0.isClosing }.map(\.cwd)
        let anchors = profiles.first { $0.id == profileID }?.anchors ?? []
        isReadingBoardSettings = true
        Self.readBoardSettings(store: store, anchors: anchors, workspaceFolders: folders, repository: repository) { [weak self] read in
            guard let self else { return }
            self.isReadingBoardSettings = false
            self.presentBoardSettings(profileID: profileID, store: store, read: read)
        }
    }

    /// Off the main thread through a nonisolated function, so the closure
    /// can't inherit this view's main-actor isolation (see `runOffMain` in
    /// the worktree cleanup).
    nonisolated private static func readBoardSettings(
        store: BoardConfigStore,
        anchors: [SpaceAnchor],
        workspaceFolders: [String],
        repository: String?,
        completion: @escaping @MainActor @Sendable (BoardSettingsRead) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let loaded = store.load()
            let context = BoardSections.readContext(anchors: anchors)
            let sections = BoardSections.sections(loaded.status == .unreadable ? [] : loaded.entries, context: context)
            let section = sections.first { $0.id == repository } ?? sections[0]
            let shown = loaded.view(for: section.slot).config
            let folders = section.checkoutFolder.map { [$0] } ?? workspaceFolders
            let suggestions = BoardConfigSuggestions.read(
                workspaceFolders: folders, repository: shown?.repository, baseBranch: shown?.baseBranch
            )
            let read = BoardSettingsRead(
                loaded: loaded, context: context, sections: sections, section: section, suggestions: suggestions
            )
            DispatchQueue.main.async { @MainActor in
                completion(read)
            }
        }
    }

    private func presentBoardSettings(profileID: String, store: BoardConfigStore, read: BoardSettingsRead) {
        // The space may have been deleted, or the window closed, meanwhile.
        guard let window, boardSettingsPanel == nil,
              let profile = profiles.first(where: { $0.id == profileID })
        else { return }
        let panel = BoardSettingsPanel()
        boardSettingsPanel = panel
        panel.onSave = { config in
            // The other repositories' configs stay as read; refused if
            // another Nirux saved the file since it was read.
            let kept = read.loaded.status == .unreadable ? [] : read.loaded.entries
            let entries = BoardSections.entries(saving: config, as: read.section, in: kept, context: read.context)
            switch store.save(entries: entries, replacing: read.loaded) {
            case .success: return nil
            case .failure(let error): return error.message
            }
        }
        panel.onSelectRepository = { [weak self, weak panel] repository in
            guard let self, let panel else { return }
            panel.dismiss()
            self.showBoardSettings(profileID: profileID, repository: repository)
        }
        panel.onDismiss = { [weak self, weak panel] in
            guard let self else { return }
            if self.boardSettingsPanel === panel { self.boardSettingsPanel = nil }
            self.focusActiveTerminal(in: self.window)
        }
        var content = BoardSettingsPanel.Content(
            spaceID: profileID, spaceName: profile.name, filePath: store.fileURL.path,
            loaded: read.loaded.view(for: read.section.slot), suggestions: read.suggestions
        )
        if read.sections.count > 1 {
            let names = BoardSections.displayNames(read.sections)
            content.repositories = read.sections.map {
                BoardSettingsPanel.Repository(id: $0.id, title: names[$0.id] ?? $0.name ?? "Repository")
            }
            content.selectedRepository = read.section.id
        }
        panel.show(attachedTo: window, content: content)
    }
}
