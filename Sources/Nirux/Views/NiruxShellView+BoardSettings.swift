import AppKit

// MARK: - Board settings (see BoardConfig)

extension NiruxShellView {
    /// "Board Settings…" in a space's menu. Reads board.json and runs git in
    /// the space's workspace folders off the main thread, then opens the form.
    func showBoardSettings(profileID: String) {
        guard window != nil, !isReadingBoardSettings else { return }
        if let panel = boardSettingsPanel {
            panel.focus()
            return
        }
        guard let store = BoardConfigStore(spaceID: profileID) else {
            NSSound.beep()
            return
        }
        // Inactive workspaces belong to the project too.
        let folders = workspaces.filter { $0.profileID == profileID && !$0.isClosing }.map(\.cwd)
        isReadingBoardSettings = true
        Self.readBoardSettings(store: store, workspaceFolders: folders) { [weak self] loaded, suggestions in
            guard let self else { return }
            self.isReadingBoardSettings = false
            self.presentBoardSettings(profileID: profileID, store: store, loaded: loaded, suggestions: suggestions)
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
                workspaceFolders: workspaceFolders, repository: loaded.config?.repository
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
        suggestions: BoardConfigSuggestions
    ) {
        // The space may have been deleted, or the window closed, meanwhile.
        guard let window, boardSettingsPanel == nil,
              let profile = profiles.first(where: { $0.id == profileID })
        else { return }
        let panel = BoardSettingsPanel()
        boardSettingsPanel = panel
        panel.onSave = { config in
            switch store.save(config) {
            case .success: return nil
            case .failure(let error): return error.message
            }
        }
        panel.onDismiss = { [weak self, weak panel] in
            guard let self else { return }
            if self.boardSettingsPanel === panel { self.boardSettingsPanel = nil }
            self.focusActiveTerminal(in: self.window)
        }
        panel.show(
            attachedTo: window,
            content: BoardSettingsPanel.Content(
                spaceName: profile.name, filePath: store.fileURL.path, loaded: loaded, suggestions: suggestions
            )
        )
    }
}
