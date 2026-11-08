import AppKit

// MARK: - Board settings (see BoardConfig)

extension NiruxShellView {
    /// "Board Settings…" in a space's menu: Space Settings on its Board tab.
    func showBoardSettings(profileID: String) {
        showSpaceSettings(profileID: profileID, tab: .board)
    }

    /// Fills the Board tab: reads board.json and runs git in the space's
    /// workspace folders and repositories off the main thread, then shows
    /// the form, with `status` by its buttons.
    func loadBoardTab(spaceID: String, status: String? = nil) {
        guard let settings = spaceSettings, settings.spaceID == spaceID, !isReadingBoardSettings else { return }
        guard let store = BoardConfigStore(spaceID: spaceID) else {
            settings.showBoardPlaceholder("Couldn’t find this space’s board settings.")
            return
        }
        // Inactive workspaces belong to the space too; then its repositories.
        let anchorFolders = profiles.first { $0.id == spaceID }?.anchors.compactMap(\.folder) ?? []
        let folders = workspaces.filter { $0.profileID == spaceID && !$0.isClosing }.map(\.cwd) + anchorFolders
        boardSettingsPanel?.dismiss()
        settings.showBoardPlaceholder("Reading the board settings…")
        isReadingBoardSettings = true
        Self.readBoardSettings(store: store, workspaceFolders: folders) { [weak self] loaded, suggestions in
            guard let self else { return }
            self.isReadingBoardSettings = false
            guard let current = self.spaceSettings, current.spaceID == spaceID else {
                // Another space's window opened meanwhile, on its Board tab:
                // its read was refused while this one ran.
                if let current = self.spaceSettings, current.selectedTab == .board,
                   self.boardSettingsPanel?.spaceID != current.spaceID {
                    self.loadBoardTab(spaceID: current.spaceID)
                }
                return
            }
            self.presentBoardSettings(profileID: spaceID, store: store, loaded: loaded, suggestions: suggestions, status: status)
        }
    }

    /// Off the main thread through a nonisolated function, so the closure
    /// can't inherit this view's main-actor isolation (see `runOffMain` in
    /// the worktree cleanup).
    nonisolated private static func readBoardSettings(
        store: BoardConfigStore,
        workspaceFolders: [String],
        completion: @escaping @MainActor @Sendable (BoardConfigStore.Loaded, BoardConfigSuggestions) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let loaded = store.load()
            let suggestions = BoardConfigSuggestions.read(
                workspaceFolders: workspaceFolders,
                repository: loaded.config?.repository,
                baseBranch: loaded.config?.baseBranch
            )
            DispatchQueue.main.async { @MainActor in
                completion(loaded, suggestions)
            }
        }
    }

    private func presentBoardSettings(
        profileID: String,
        store: BoardConfigStore,
        loaded: BoardConfigStore.Loaded,
        suggestions: BoardConfigSuggestions,
        status: String?
    ) {
        // The space may have been deleted, or the window closed, meanwhile.
        guard let settings = spaceSettings, settings.spaceID == profileID,
              let profile = profiles.first(where: { $0.id == profileID })
        else { return }
        settings.hideBoardPlaceholder()
        boardSettingsPanel?.dismiss()
        let panel = BoardSettingsPanel()
        boardSettingsPanel = panel
        settings.boardForm = panel
        panel.onSave = { [weak self] config in
            // Refused if another Nirux saved the file since it was read.
            switch store.save(config, replacing: loaded) {
            case .success:
                // A new form from the file: the next save compares with it.
                self?.loadBoardTab(spaceID: profileID, status: "Saved.")
                return nil
            case .failure(let error):
                return error.message
            }
        }
        panel.onRevert = { [weak self] in self?.loadBoardTab(spaceID: profileID) }
        panel.onDismiss = { [weak self, weak panel] in
            guard let self else { return }
            if self.boardSettingsPanel === panel { self.boardSettingsPanel = nil }
        }
        panel.show(
            in: settings.boardHost,
            content: BoardSettingsPanel.Content(
                spaceID: profileID, spaceName: profile.name, filePath: store.fileURL.path,
                loaded: loaded, suggestions: suggestions
            ),
            status: status
        )
    }
}
