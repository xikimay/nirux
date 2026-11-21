import AppKit

// MARK: - Space Settings (docs/design/spaces.md, S8)

extension NiruxShellView {
    /// The Settings window on `profileID`'s `tab`; `tab` nil keeps the pane
    /// shown (Nirux's, when the sidebar's popup picks another space). One
    /// space at a time: the window shows this space in place of another one,
    /// unless text typed there isn't saved, or a sheet of its panes is up.
    /// `boardRepository`: the section the Board pane reads first, when the
    /// window opens for this space (`showBoardSettings`).
    func showSpaceSettings(profileID: String, tab: SpaceSettingsSection.Tab? = .general, boardRepository: String? = nil) {
        guard let space = profiles.first(where: { $0.id == profileID }) else { return }
        if let open = spaceSettings, open.spaceID != profileID, let panel = open.panel {
            // A name or a value still being typed counts.
            panel.makeFirstResponder(nil)
            if open.hasSheet {
                panel.makeKeyAndOrderFront(nil)
                return refuseSpaceSwitch("Finish what is open in this space’s settings first", in: open)
            }
            if let unsaved = open.unsavedParts.first {
                open.show(tab: unsaved.tab, title: Self.spaceSettingsTitle(open.spaceID, in: profiles))
                return refuseSpaceSwitch("Save or revert the changes in this space’s settings first", in: open)
            }
        }
        let settings = spaceSettings.flatMap { $0.spaceID == profileID ? $0 : nil } ?? makeSpaceSettings(for: space)
        // The one it replaces is told first (`onClose`).
        settingsWindow.setSpace(settings)
        spaceSettings = settings
        if let boardRepository { settings.boardRepository = boardRepository }
        let title = Self.spaceSettingsTitle(profileID, in: profiles)
        if let tab {
            settings.show(tab: tab, title: title)
        } else {
            settings.setTitle(title)
            settingsWindow.show()
        }
    }

    /// Why the window keeps its space, said in it: over the space's sheet
    /// up there, else on the window; once, while it shows.
    private func refuseSpaceSwitch(_ reason: String, in settings: SpaceSettingsSection) {
        guard settings.panel != nil else { return showToast(reason) }
        settings.refuse(reason)
    }

    func makeSettingsWindow() -> SettingsWindow {
        let settings = SettingsWindow()
        settings.makeSpaceSection = { [weak self] in self?.spaceSectionForSettings() }
        settings.spaces = { [weak self] in
            self?.profiles.map { SettingsWindow.Space(id: $0.id, name: $0.name, colorHex: $0.colorHex) } ?? []
        }
        settings.onPickSpace = { [weak self] id in
            guard let self else { return }
            // The pane shown stays: the new space's, or Nirux's.
            self.showSpaceSettings(profileID: id, tab: self.spaceSettings?.selectedTab)
        }
        return settings
    }

    /// The active space's section, for the window opening on Nirux's panes.
    private func spaceSectionForSettings() -> SpaceSettingsSection? {
        if let open = spaceSettings { return open }
        guard let space = profiles.first(where: { $0.id == activeProfileID }) else { return nil }
        let section = makeSpaceSettings(for: space)
        section.setTitle(Self.spaceSettingsTitle(space.id, in: profiles))
        spaceSettings = section
        return section
    }

    /// Quitting with changes typed in Space Settings asks first, in an
    /// alert (`runModal`): Save, Cancel or Don't Save. True: quit. A save
    /// that fails, or asks about a file changed on disk, cancels the quit
    /// with the window on that tab.
    func spaceSettingsAllowQuit() -> Bool {
        guard let settings = spaceSettings else { return true }
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

    /// The space's name, in the Settings window's title and sidebar.
    static func spaceSettingsTitle(_ spaceID: String, in spaces: [WorkspaceProfile]) -> String {
        spaces.first { $0.id == spaceID }?.name ?? "Space"
    }

    private func makeSpaceSettings(for space: WorkspaceProfile) -> SpaceSettingsSection {
        let spaceID = space.id
        let general = SpaceSettingsGeneralPane(model: spaceSettingsGeneralModel(for: space))
        general.actions = spaceSettingsGeneralActions(spaceID: spaceID)
        let store = SpaceDefaultsStore(spaceID: spaceID)
        let unread = SpaceDefaultsStore.Loaded(defaults: SpaceDefaults(), status: .missing)
        var defaultsActions = SpaceSettingsDefaultsPane.Actions()
        defaultsActions.save = { [weak self] defaults, loaded in
            let saved = store.map { $0.save(defaults, replacing: loaded) } ?? .failure(.couldNotWrite("The space’s folder can’t be named."))
            if case .success = saved { self?.spaceDefaultsSaved(defaults, replacing: loaded.defaults, spaceID: spaceID) }
            return saved
        }
        defaultsActions.reload = { store?.load() ?? unread }
        defaultsActions.settingsClaudeMode = { Self.currentClaudeLaunchMode() }
        defaultsActions.settingsCodexMode = { Self.currentCodexLaunchMode() }
        // Read when its pane first shows (`onTabShown`), not for each ⌘,.
        let defaults = SpaceSettingsDefaultsPane(loaded: unread, actions: defaultsActions)
        let safety = SpaceSettingsSafetyPane(model: spaceSettingsSafetyModel(for: space))
        safety.actions.set = { [weak self] part, on in self?.setClaudeSafety(part, on: on, spaceID: spaceID) }
        safety.actions.setPeriod = { [weak self] days in self?.refreshSpaceSettingsSafety(periodDays: days) }
        safety.actions.add = { [weak self] line in self?.changeClaudeLines(spaceID: spaceID) { $0.add(line) } }
        safety.actions.remove = { [weak self] line in self?.changeClaudeLines(spaceID: spaceID) { $0.remove(line) } }
        let lead = SpaceSettingsLeadPane(model: spaceSettingsLeadModel(for: space))
        lead.actions.setLead = { [weak self] on in
            guard let self else { return }
            if on { self.startLead(spaceID: spaceID) } else { self.stopLead(spaceID: spaceID) }
        }
        lead.actions.restartLead = { [weak self] in self?.requestRestartLead(spaceID: spaceID) }
        lead.actions.setStartsTasks = { [weak self] on in self?.setLeadStartsTasks(on, spaceID: spaceID) }
        lead.actions.setDailyPass = { [weak self] on in self?.setDailyPass(on, spaceID: spaceID) }
        lead.actions.setDailyPassHour = { [weak self] hour in self?.setDailyPassHour(hour, spaceID: spaceID) }
        let settings = SpaceSettingsSection(
            spaceID: spaceID, general: general, defaults: defaults, safety: safety, lead: lead,
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
            case .defaults:
                guard !settings.defaults.hasUnsavedRows else { return }
                settings.defaults.show(defaultsActions.reload())
                settings.fitToContent()
            case .safety: self.refreshSpaceSettingsSafety()
            case .lead: self.refreshSpaceSettingsLead()
            case .brief, .templates: break
            }
        }
        settings.onKeyboardFreed = { [weak self, weak settings] tab in
            guard let self, let settings, self.spaceSettings === settings else { return false }
            switch tab {
            case .board:
                // Its form still being read takes the keyboard as it lands.
                guard let form = self.boardSettingsPanel, form.hostView === settings.boardHost else { return true }
                return form.takeKeyboardIfFree()
            case .memory:
                if let memory = self.projectMemoryPanel, memory.shows(in: settings.memoryHost) { return memory.takeKeyboardIfFree() }
                // A list still being read takes it as it lands; nothing to list takes none.
                return !settings.showsMemoryPlaceholder
            default:
                return false
            }
        }
        settings.onClose = { [weak self, weak settings] windowClosed in
            guard let self, let settings, self.spaceSettings === settings else { return }
            if let sheet = self.setupScriptSheet?.panel { settings.panel?.endSheet(sheet) }
            self.setupScriptSheet = nil
            self.projectMemoryRequest += 1
            self.projectMemoryPanel?.dismiss()
            self.boardSettingsPanel?.dismiss()
            self.spaceSettings = nil
            // Something of the main window's own has its keyboard (an editor,
            // a sidebar field): it keeps it.
            if windowClosed, let window = self.window, (window.firstResponder as? NSView)?.window !== window {
                self.focusActiveTerminal(in: window)
            }
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
            guard let self, let settings = self.spaceSettings else { return }
            self.addRepository(toSpace: spaceID, sheet: settings.panel, notingIn: settings)
        }
        actions.addFolder = { [weak self] in self?.addFolder(toSpace: spaceID) }
        actions.remove = { [weak self] key in self?.removeSpaceAnchor(key: key, fromSpace: spaceID) }
        actions.makeDefault = { [weak self] key in self?.makeDefaultSpaceAnchor(key: key, inSpace: spaceID) }
        actions.editScript = { [weak self] anchor in self?.editSetupScript(of: anchor, inSpace: spaceID) }
        return actions
    }

    /// After a space changed (name, color, repositories) or went away:
    /// the Settings window shows it again, or the active space in its place
    /// (Nirux's panes stay).
    func spaceSettingsSpacesChanged() {
        guard let settings = spaceSettings else { return }
        guard let space = profiles.first(where: { $0.id == settings.spaceID }) else {
            settings.brief.revert()
            settings.templates.revert()
            guard let active = profiles.first(where: { $0.id == activeProfileID }) else { return settings.close() }
            // What was typed there has no space left to go to, nor what a
            // sheet of its panes would add; Nirux's own sheet stays, and so
            // does the window.
            settings.endSheets()
            let tab = settings.selectedTab
            let replacement = makeSpaceSettings(for: active)
            settingsWindow.setSpace(replacement)
            spaceSettings = replacement
            replacement.setTitle(Self.spaceSettingsTitle(active.id, in: profiles))
            if let tab { replacement.select(tab) }
            return
        }
        settings.general.update(spaceSettingsGeneralModel(for: space))
        settings.lead.update(spaceSettingsLeadModel(for: space))
        refreshSpaceSettingsSafety()
        settings.setTitle(Self.spaceSettingsTitle(space.id, in: profiles))
        // Their templates name the space.
        settings.brief.replaceSource(Self.briefSource(for: space))
        settings.templates.replaceSource(Self.templatesSource(for: space))
        settings.fitToContent()
        // Read again when General shows.
        if settings.selectedTab == .general { refreshSpaceSettingsGitHub() }
    }

    /// General's rows again (a setup script saved or removed).
    func refreshSpaceSettingsGeneral() {
        guard let settings = spaceSettings, let space = profiles.first(where: { $0.id == settings.spaceID }) else { return }
        settings.general.update(spaceSettingsGeneralModel(for: space))
    }

    /// Reads each repository's GitHub repository (where its pull requests
    /// live, as the Board reads it: `GitHubBaseRemote`) off the main thread,
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
                if case .gitHub(let name, _) = GitHubBaseRemote.read(at: repository.folder) {
                    names[repository.key] = name
                }
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
        editor.askInSheet = { [weak settings] alert, parent, answer in settings?.ask(alert, on: parent, answer: answer) }
        let close = { [weak self, weak window, weak sheet] in
            guard let self, let sheet else { return }
            window?.endSheet(sheet)
            if self.setupScriptSheet?.panel === sheet { self.setupScriptSheet = nil }
            self.refreshSpaceSettingsGeneral()
        }
        editor.onSaved = close
        editor.onCancel = close
        let ended = settings.noteSheet(sheet, on: window)
        window.beginSheet(sheet) { _ in MainActor.assumeIsolated { ended() } }
        sheet.makeFirstResponder(editor.textView)
    }

    // MARK: - Folders

    /// "Add Folder…": a folder of its own, even inside a repository (the
    /// most specific anchor wins), never the home folder or one holding it.
    func addFolder(toSpace spaceID: String) {
        guard spaceID != WorkspaceProfile.defaultID, profiles.contains(where: { $0.id == spaceID }), canChangeAnchors() else { return }
        let ended = spaceSettings?.noteSheet()
        sideEffects.chooseFolder("Add Folder", spaceSettings?.panel ?? window) { [weak self] folder in
            ended?()
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
