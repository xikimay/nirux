import AppKit

// MARK: - Board settings (see BoardConfig)

extension NiruxShellView {
    /// What the Board tab shows: board.json, the space's repositories and
    /// the one picked, with suggestions from its checkout.
    struct BoardSettingsRead: Sendable {
        let loaded: BoardConfigStore.Loaded
        let context: BoardSections.Context
        let sections: [BoardSections.Section]
        let section: BoardSections.Section
        let suggestions: BoardConfigSuggestions
    }

    /// "Board Settings…" in the Board's ⋯ menu: Space Settings on its Board tab.
    func showBoardSettings(profileID: String) {
        showSpaceSettings(profileID: profileID, tab: .board)
    }

    /// Fills the Board tab, on `repository` (a section's id) when given,
    /// else the one it showed, else the default one: reads board.json and
    /// runs git in that repository's checkout (the space's workspace
    /// folders, for a space without repository anchors) off the main
    /// thread, then shows the form, with `status` by its buttons. Asked
    /// while it reads, it reads again once that read lands.
    func loadBoardTab(spaceID: String, repository: String? = nil, status: String? = nil) {
        guard let settings = spaceSettings, settings.spaceID == spaceID else { return }
        if let repository { settings.boardRepository = repository }
        guard !isReadingBoardSettings else {
            settings.pendingBoardReload = .some(status)
            return
        }
        guard let store = BoardConfigStore(spaceID: spaceID) else {
            settings.showBoardPlaceholder("Couldn’t find this space’s board settings.")
            return
        }
        // Inactive workspaces belong to the space too; then its folders.
        let anchors = profiles.first { $0.id == spaceID }?.anchors ?? []
        let folders = workspaces.filter { $0.profileID == spaceID && !$0.isClosing }.map(\.cwd) + anchors.compactMap(\.folder)
        boardSettingsPanel?.dismiss()
        settings.showBoardPlaceholder("Reading the board settings…")
        isReadingBoardSettings = true
        Self.readBoardSettings(
            store: store, anchors: anchors, workspaceFolders: folders, repository: settings.boardRepository
        ) { [weak self] read in
            guard let self else { return }
            self.isReadingBoardSettings = false
            guard let current = self.spaceSettings, current.spaceID == spaceID else {
                // Another space's window opened meanwhile, on its Board tab:
                // its read was refused while this one ran.
                if let current = self.spaceSettings, current.selectedTab == .board,
                   self.boardSettingsPanel?.spaceID != current.spaceID {
                    // What it asked meanwhile is this read.
                    current.pendingBoardReload = nil
                    self.loadBoardTab(spaceID: current.spaceID)
                }
                return
            }
            if let pending = current.pendingBoardReload {
                // The later ask wins, and its status: a save's "Saved." isn't
                // the repository picked after it.
                current.pendingBoardReload = nil
                return self.loadBoardTab(spaceID: spaceID, status: pending)
            }
            self.presentBoardSettings(profileID: spaceID, store: store, read: read, status: status)
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
            let suggestions = BoardConfigSuggestions.read(
                workspaceFolders: section.checkoutFolder.map { [$0] } ?? workspaceFolders,
                repository: shown?.repository, baseBranch: shown?.baseBranch
            )
            let read = BoardSettingsRead(
                loaded: loaded, context: context, sections: sections, section: section, suggestions: suggestions
            )
            DispatchQueue.main.async { @MainActor in
                completion(read)
            }
        }
    }

    private func presentBoardSettings(profileID: String, store: BoardConfigStore, read: BoardSettingsRead, status: String?) {
        // The space may have been deleted, or the window closed, meanwhile.
        guard let settings = spaceSettings, settings.spaceID == profileID,
              let profile = profiles.first(where: { $0.id == profileID })
        else { return }
        settings.hideBoardPlaceholder()
        boardSettingsPanel?.dismiss()
        // A repository removed since: the default one shows.
        settings.boardRepository = read.section.id
        let panel = BoardSettingsPanel()
        boardSettingsPanel = panel
        settings.boardForm = panel
        panel.onSave = { [weak self] config in
            if let refusal = Self.boardSaveRefusal(config, read: read) { return refusal }
            // The other repositories' configs stay as read; refused if
            // another Nirux saved the file since it was read.
            let kept = read.loaded.status == .unreadable ? [] : read.loaded.entries
            let entries = BoardSections.entries(saving: config, as: read.section, in: kept, context: read.context)
            switch store.save(entries: entries, replacing: read.loaded) {
            case .success:
                // A new form from the file: the next save compares with it.
                self?.loadBoardTab(spaceID: profileID, status: "Saved.")
                return nil
            case .failure(let error):
                return error.message
            }
        }
        panel.onRevert = { [weak self] in self?.loadBoardTab(spaceID: profileID) }
        panel.onSelectRepository = { [weak self] repository in
            self?.loadBoardTab(spaceID: profileID, repository: repository)
        }
        panel.onDismiss = { [weak self, weak panel] in
            guard let self else { return }
            if self.boardSettingsPanel === panel { self.boardSettingsPanel = nil }
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
        panel.show(in: settings.boardHost, content: content, status: status)
    }

    /// Why Save can't write `config` as the shown repository's, if it can't.
    private static func boardSaveRefusal(_ config: BoardConfig, read: BoardSettingsRead) -> String? {
        // A queue never mixes repositories, and two sections' would be one.
        if let repository = config.gitHubRepository,
           let other = read.sections.first(where: { $0.id != read.section.id && $0.config?.gitHubRepository == repository }) {
            return "“\(other.name ?? "Another repository")” of this space already uses \(repository.ownerAndName): "
                + "each repository needs its own GitHub repository."
        }
        // Which repository schema 1's config belongs to rests on every
        // anchor's remotes.
        let kept = read.loaded.status == .unreadable ? [] : read.loaded.entries
        if kept.contains(where: { $0.slot == .legacy }), let unread = read.context.unread.first {
            let name = read.sections.first { $0.commonDir == unread }?.name ?? (unread as NSString).deletingLastPathComponent
            return "Nirux couldn’t read the remotes of “\(name)”, so it can’t tell which repository the board’s "
                + "current settings belong to. Try again once that repository can be read."
        }
        return nil
    }
}
