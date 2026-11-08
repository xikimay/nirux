import AppKit

// MARK: - Space Settings (docs/spaces.md, S8)

extension NiruxShellView {
    /// Space Settings for `profileID`, on `tab`. One space at a time: the
    /// window open for another one closes first, unless text typed there
    /// isn't saved.
    func showSpaceSettings(profileID: String, tab: SpaceSettingsWindow.Tab = .general) {
        guard let space = profiles.first(where: { $0.id == profileID }) else { return }
        if let open = spaceSettings, open.spaceID != profileID {
            // A name or a value still being typed counts.
            open.panel?.makeFirstResponder(nil)
            guard !open.hasUnsavedChanges else {
                open.show(tab: open.selectedTab ?? .general, title: Self.spaceSettingsTitle(open.spaceID, in: profiles))
                return showToast("Save or revert the changes in this Space Settings first")
            }
            open.close()
        }
        let settings = spaceSettings ?? makeSpaceSettings(for: space)
        spaceSettings = settings
        settings.show(tab: tab, title: Self.spaceSettingsTitle(profileID, in: profiles))
    }

    /// Quitting with changes typed in Space Settings asks first, in an
    /// alert (`runModal`): Save, Cancel or Don't Save. True: quit. A save
    /// that fails, or asks about a file changed on disk, cancels the quit
    /// with the window on that tab.
    func spaceSettingsAllowQuit() -> Bool {
        guard let settings = spaceSettings, false else { return true }
        settings.panel?.makeFirstResponder(nil)
        let parts = settings.unsavedParts
        guard !parts.isEmpty else { return true }
        settings.show(tab: parts[0].tab, title: Self.spaceSettingsTitle(settings.spaceID, in: profiles))
        let alert = NSAlert()
        alert.messageText = "Save your changes in Space Settings before quitting?"
        alert.informativeText = "The \(parts.map(\.name).joined(separator: ", ")) \(parts.count == 1 ? "has" : "have") "
            + "changes that are lost if you don’t save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don’t Save").hasDestructiveAction = true
        switch runModal(alert) {
        case .alertFirstButtonReturn:
            for part in parts {
                settings.select(part.tab)
                if !part.save() { return false }
            }
            return true
        case .alertThirdButtonReturn:
            return true
        default:
            return false
        }
    }

    static func spaceSettingsTitle(_ spaceID: String, in spaces: [WorkspaceProfile]) -> String {
        "\(spaces.first { $0.id == spaceID }?.name ?? "Space") Settings"
    }

    private func makeSpaceSettings(for space: WorkspaceProfile) -> SpaceSettingsWindow {
        let spaceID = space.id
        let general = SpaceSettingsGeneralPane(model: spaceSettingsGeneralModel(for: space))
        general.actions = spaceSettingsGeneralActions(spaceID: spaceID)
        let store = SpaceDefaultsStore(spaceID: spaceID)
        var defaultsActions = SpaceSettingsDefaultsPane.Actions()
        defaultsActions.save = { defaults, loaded in
            store.map { $0.save(defaults, replacing: loaded) } ?? .failure(.couldNotWrite("The space’s folder can’t be named."))
        }
        defaultsActions.reload = {
            store?.load() ?? SpaceDefaultsStore.Loaded(defaults: SpaceDefaults(), status: .missing)
        }
        defaultsActions.settingsClaudeMode = { Self.currentClaudeLaunchMode() }
        defaultsActions.settingsCodexMode = { Self.currentCodexLaunchMode() }
        let defaults = SpaceSettingsDefaultsPane(loaded: defaultsActions.reload(), actions: defaultsActions)
        let settings = SpaceSettingsWindow(
            spaceID: spaceID, general: general, defaults: defaults,
            brief: SpaceFileEditorPane(source: Self.briefSource(for: space)),
            templates: SpaceFileEditorPane(source: Self.templatesSource(for: space))
        )
        settings.onTabShown = { [weak self, weak settings] tab in
            guard let self, let settings, self.spaceSettings === settings else { return }
            switch tab {
            case .memory:
                // An edit or a write under way stays: reading again would drop it.
                if let memory = self.projectMemoryPanel, memory.shows(in: settings.memoryHost), memory.isBusy { return }
                self.loadProjectMemoryTab(spaceID: spaceID)
            case .board: if self.boardSettingsPanel?.spaceID != spaceID { self.loadBoardTab(spaceID: spaceID) }
            case .general: self.refreshSpaceSettingsGitHub()
            // What another Nirux saved, and Settings' modes, as they are
            // now; variables typed and held back by a problem stay.
            case .defaults: settings.defaults.show(defaultsActions.reload())
            case .brief, .templates: break
            }
        }
        settings.onClose = { [weak self, weak settings] in
            guard let self, let settings, self.spaceSettings === settings else { return }
            if let sheet = self.setupScriptSheet?.panel { settings.panel?.endSheet(sheet) }
            self.setupScriptSheet = nil
            self.projectMemoryRequest += 1
            self.projectMemoryPanel?.dismiss()
            self.boardSettingsPanel?.dismiss()
            self.spaceSettings = nil
            self.focusActiveTerminal(in: self.window)
        }
        return settings
    }

    private static func briefSource(for space: WorkspaceProfile) -> SpaceFileEditorPane.Source {
        SpaceFileEditorPane.Source.brief(spaceID: space.id, spaceName: space.name) ?? unavailableSource("brief")
    }

    private static func templatesSource(for space: WorkspaceProfile) -> SpaceFileEditorPane.Source {
        SpaceFileEditorPane.Source.taskTemplates(spaceID: space.id, spaceName: space.name) ?? unavailableSource("task templates")
    }

    /// A space id that can't name a folder (never one Nirux made).
    private static func unavailableSource(_ name: String) -> SpaceFileEditorPane.Source {
        SpaceFileEditorPane.Source(
            documentName: name, explanation: "",
            read: { .unreadable("This space’s folder can’t be named.") },
            write: { _ in }, template: { "" }
        )
    }

    // MARK: - General

    func spaceSettingsGeneralModel(for space: WorkspaceProfile) -> SpaceSettingsGeneralPane.Model {
        let rows = space.anchors.compactMap { anchor -> SpaceSettingsGeneralPane.Row? in
            guard let key = anchor.key else { return nil }
            return SpaceSettingsGeneralPane.Row(
                anchor: anchor, key: key, folder: anchor.folder, gitHub: spaceSettingsGitHub[key],
                hasScript: SpaceSetupScript.scriptToRun(spaceID: space.id, anchor: anchor) != nil
            )
        }
        return SpaceSettingsGeneralPane.Model(
            name: space.name, colorHex: space.colorHex, isGeneral: space.id == WorkspaceProfile.defaultID,
            rows: rows, anchorsLocked: projectStore.availability != .writable
        )
    }

    private func spaceSettingsGeneralActions(spaceID: String) -> SpaceSettingsGeneralPane.Actions {
        var actions = SpaceSettingsGeneralPane.Actions()
        actions.rename = { [weak self] name in
            guard let self, self.workspaceStore.renameProfile(id: spaceID, to: name) else { return false }
            self.updateSidebar()
            self.saveState()
            self.spaceSettingsSpacesChanged()
            return true
        }
        actions.recolor = { [weak self] hex in self?.recolorSpace(profileID: spaceID, colorHex: hex) }
        actions.addRepository = { [weak self] in
            self?.addRepository(toSpace: spaceID, presentingIn: self?.spaceSettings?.panel)
        }
        actions.addFolder = { [weak self] in self?.addFolder(toSpace: spaceID) }
        actions.remove = { [weak self] key in self?.removeSpaceAnchor(key: key, fromSpace: spaceID) }
        actions.makeDefault = { [weak self] key in self?.makeDefaultSpaceAnchor(key: key, inSpace: spaceID) }
        actions.editScript = { [weak self] anchor in self?.editSetupScript(of: anchor, inSpace: spaceID) }
        return actions
    }

    /// After a space changed (name, color, repositories) or went away:
    /// Space Settings shows it again, or closes.
    func spaceSettingsSpacesChanged() {
        guard let settings = spaceSettings else { return }
        guard let space = profiles.first(where: { $0.id == settings.spaceID }) else {
            settings.brief.revert()
            settings.templates.revert()
            return settings.close()
        }
        settings.general.update(spaceSettingsGeneralModel(for: space))
        settings.setTitle(Self.spaceSettingsTitle(space.id, in: profiles))
        // Their templates name the space.
        settings.brief.replaceSource(Self.briefSource(for: space))
        settings.templates.replaceSource(Self.templatesSource(for: space))
        settings.fitToContent()
        refreshSpaceSettingsGitHub()
    }

    /// General's rows again (a setup script saved or removed).
    func refreshSpaceSettingsGeneral() {
        guard let settings = spaceSettings, let space = profiles.first(where: { $0.id == settings.spaceID }) else { return }
        settings.general.update(spaceSettingsGeneralModel(for: space))
    }

    /// Reads each repository's GitHub remote (`origin`) off the main thread,
    /// then shows it in General's rows.
    func refreshSpaceSettingsGitHub() {
        guard let settings = spaceSettings,
              let space = profiles.first(where: { $0.id == settings.spaceID })
        else { return }
        let repositories = space.anchors.compactMap { anchor -> (key: String, folder: String)? in
            guard let key = anchor.key, case .gitRepository(let commonDir) = anchor.kind else { return nil }
            return (key, anchor.folder ?? commonDir)
        }
        guard !repositories.isEmpty else { return }
        Self.readGitHubNames(repositories) { [weak self] names in
            guard let self, let settings = self.spaceSettings, settings.spaceID == space.id else { return }
            for repository in repositories { self.spaceSettingsGitHub[repository.key] = names[repository.key] }
            guard let current = self.profiles.first(where: { $0.id == space.id }) else { return }
            let model = self.spaceSettingsGeneralModel(for: current)
            if model != settings.general.model { settings.general.update(model) }
        }
    }

    /// Off the main thread through a nonisolated function, so the closure
    /// can't inherit this view's main-actor isolation.
    nonisolated private static func readGitHubNames(
        _ repositories: [(key: String, folder: String)],
        completion: @escaping @MainActor @Sendable ([String: String]) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            var names: [String: String] = [:]
            for repository in repositories {
                let url = GitCommand.output(["remote", "get-url", "--", "origin"], cwd: repository.folder, timeout: 5)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                names[repository.key] = url.flatMap(BoardConfigSuggestions.repositoryName(remoteURL:))
            }
            let found = names
            DispatchQueue.main.async { @MainActor in completion(found) }
        }
    }

    // MARK: - Setup scripts

    /// A repository's setup script, in a sheet on Space Settings.
    func editSetupScript(of anchor: SpaceAnchor, inSpace spaceID: String) {
        guard let settings = spaceSettings, settings.spaceID == spaceID, let window = settings.panel,
              setupScriptSheet == nil,
              let url = SpaceSetupScript.url(spaceID: spaceID, anchor: anchor)
        else { return }
        let editor = SpaceFileEditorPane(source: .setupScript(url: url, anchorName: anchor.name), mode: .sheet)
        let sheet = NSPanel(
            contentRect: NSRect(origin: .zero, size: SpaceFileEditorPane.size),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        sheet.appearance = Theme.appearance
        sheet.backgroundColor = Theme.Color.base
        sheet.isReleasedWhenClosed = false
        sheet.title = "Setup Script · \(anchor.name)"
        sheet.contentView = editor.view
        setupScriptSheet = (sheet, editor)
        settings.setupScriptEditor = editor
        let close = { [weak self, weak window, weak sheet] in
            guard let self, let sheet else { return }
            window?.endSheet(sheet)
            if self.setupScriptSheet?.panel === sheet { self.setupScriptSheet = nil }
            self.refreshSpaceSettingsGeneral()
        }
        editor.onSaved = close
        editor.onCancel = close
        window.beginSheet(sheet)
        sheet.makeFirstResponder(editor.textView)
    }

    // MARK: - Folders

    /// "Add Folder…": a folder of its own, even inside a repository (the
    /// most specific anchor wins), never the home folder or one holding it.
    func addFolder(toSpace spaceID: String) {
        guard spaceID != WorkspaceProfile.defaultID, profiles.contains(where: { $0.id == spaceID }), canChangeAnchors() else { return }
        sideEffects.chooseFolder("Add Folder", spaceSettings?.panel ?? window) { [weak self] folder in
            guard let folder else { return }
            Self.pickAnchor(folder, asRepository: false) { [weak self] pick in
                self?.runFromRunLoop { [weak self] in
                    guard let self else { return }
                    switch pick {
                    case .anchor(let anchor): self.addAnchor(anchor, toSpace: spaceID)
                    case .missing(let folder), .notARepository(let folder):
                        self.showToast("That folder is gone: \(folder.abbreviatedPath())", tone: .error)
                    }
                }
            }
        }
    }
}
