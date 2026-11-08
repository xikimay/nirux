import AppKit

// MARK: - The Lead (docs/spaces.md, "The Lead")

/// One optional Lead per space: a workspace pinned at the top of the space,
/// in its default repository's main checkout, with Claude and the space's
/// Board. The user talks to it; it starts tasks and follows them. Its
/// Claude learns its role from the Nirux MCP server (`NIRUX_LEAD=1` in its
/// shells, see `WorkspaceState.isLead`), and its tasks are Missions whatever
/// the Mission handoffs setting (`Mission.reportsToLead`). A Lead started
/// again is a new parent: the earlier tasks' questions come to the user.
extension NiruxShellView {
    static let leadTitle = "Lead"

    /// Any space but General, which takes what no other space claims.
    static func spaceCanHaveLead(_ spaceID: String) -> Bool {
        spaceID != WorkspaceProfile.defaultID
    }

    /// The space's Lead, unless it is closing.
    func leadWorkspace(inSpace spaceID: String) -> WorkspaceState? {
        workspaceStore.leadWorkspace(inSpace: spaceID)
    }

    /// "Start a Lead" (New Space…, Space Settings › Lead, ⌃⌘L): its
    /// workspace opens on top of the space and takes the focus, Claude
    /// started, the Board beside it unless the space shows its Board in
    /// another workspace (one Board per space). One Lead per space: a space
    /// that has one focuses it.
    func startLead(spaceID: String) {
        guard Self.spaceCanHaveLead(spaceID), profiles.contains(where: { $0.id == spaceID }) else { return }
        if let lead = leadWorkspace(inSpace: spaceID) { return focusLead(lead) }
        addWorkspace(
            title: Self.leadTitle,
            cwd: defaultFolder(forSpace: spaceID),
            // The Lead's tools are Claude Code's, whatever the space's
            // default agent.
            agent: .claude,
            profileID: spaceID,
            // Names its Claude session "Lead · <space>" (see SessionName).
            worktreeBranch: Self.leadTitle,
            isLead: true
        )
        if let lead = leadWorkspace(inSpace: spaceID), projectBoardLocation(projectID: spaceID) == nil {
            // Not `openProjectBoard`: a space without board settings would
            // open Space Settings › Board over the Lead and take Claude's
            // keyboard. The Board asks for them when the user clicks it.
            let board = makeProjectBoard(projectID: spaceID, offersSettings: false)
            lead.addProjectBoardColumn(board)
            // Claude keeps the keyboard; the Board sits to its right.
            lead.focusedIndex = 0
            relayout(animated: false)
            updateSidebar()
            focusActiveTerminal(in: window)
            board.reload()
        }
        saveState()
        refreshSpaceSettingsLead()
    }

    /// Turning the Lead off closes its workspace, asking first when Claude
    /// runs there, as Close Workspace does. The tasks it followed stay;
    /// their questions come to the user once their parent is gone.
    func stopLead(spaceID: String) {
        guard let lead = leadWorkspace(inSpace: spaceID),
              let index = workspaces.firstIndex(where: { $0 === lead })
        else { return }
        requestCloseWorkspace(at: index, replacingLast: true)
        refreshSpaceSettingsLead()
    }

    /// ⌃⌘L: the active space's Lead, its Claude focused; a space without
    /// one starts it.
    func focusOrStartLead() {
        guard Self.spaceCanHaveLead(activeProfileID) else { return }
        if let lead = leadWorkspace(inSpace: activeProfileID) {
            focusLead(lead)
        } else {
            startLead(spaceID: activeProfileID)
        }
    }

    /// The Lead's workspace, on its first terminal (where Claude runs).
    func focusLead(_ lead: WorkspaceState) {
        let column = lead.columns.firstIndex { $0.pty != nil && !$0.isClosing }
        focusWorkspace(id: lead.id, column: column)
    }

    // MARK: - Space Settings › Lead

    func spaceSettingsLeadModel(for space: WorkspaceProfile) -> SpaceSettingsLeadPane.Model {
        let lead = leadWorkspace(inSpace: space.id)
        let defaults = SpaceDefaultsStore(spaceID: space.id)?.load()
        return SpaceSettingsLeadPane.Model(
            spaceName: space.name,
            isGeneral: !Self.spaceCanHaveLead(space.id),
            hasLead: lead != nil,
            place: leadPlace(in: space, leadFolder: lead?.cwd),
            startsTasks: leadStartsTasksWithoutAsking(spaceID: space.id),
            canChangeStartsTasks: defaults?.isWritable ?? false
        )
    }

    /// "Starts tasks without asking", saved in the space's defaults.json
    /// (on is the default, so it writes nothing).
    func setLeadStartsTasks(_ on: Bool, spaceID: String) {
        guard let store = SpaceDefaultsStore(spaceID: spaceID) else { return }
        let loaded = store.load()
        var defaults = loaded.defaults
        defaults.leadStartsTasks = on ? nil : false
        // An unreadable file is replaced (set aside first) even with nothing
        // to change: it reads as off until then.
        if defaults != loaded.defaults || loaded.status == .unreadable,
           case .failure(let error) = store.save(defaults, replacing: loaded) {
            showToast(error.message, tone: .error)
        }
        // The Defaults tab shows the file as it is now, unless it holds
        // variables being typed.
        if let settings = spaceSettings, settings.spaceID == spaceID, !settings.defaults.hasUnsavedRows {
            settings.defaults.show(store.load())
        }
        refreshSpaceSettingsLead()
    }

    /// Whether the space's Lead starts tasks itself. A defaults.json Nirux
    /// can't read asks first: off is the safe side.
    func leadStartsTasksWithoutAsking(spaceID: String) -> Bool {
        guard let loaded = SpaceDefaultsStore(spaceID: spaceID)?.load() else { return false }
        switch loaded.status {
        case .missing, .loaded:
            return loaded.defaults.leadStartsTasksWithoutAsking
        case .unreadable, .readOnly(.notARegularFile), .readOnly(.tooLarge):
            return true
        case .readOnly:
            if let value = loaded.defaults.leadStartsTasks { return value }
            let raw = loaded.contents.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
            return raw?["leadStartsTasks"] == nil
        }
    }

    /// Where the running Lead works (`leadFolder`), else where a new one
    /// would start (`defaultFolder(forSpace:)`).
    private func leadPlace(in space: WorkspaceProfile, leadFolder: String?) -> SpaceSettingsLeadPane.Place {
        let firstRepository = space.anchors.first { anchor in
            if case .gitRepository = anchor.kind { return anchor.folder != nil }
            return false
        }?.name
        func place(of anchor: SpaceAnchor) -> SpaceSettingsLeadPane.Place {
            if case .gitRepository = anchor.kind { return .repository(anchor.name) }
            return .folder(anchor.name, repository: firstRepository)
        }
        let start = defaultFolderAnchor(forSpace: space.id)
        guard let leadFolder else { return start.map(place(of:)) ?? .home }
        let standardized = { (path: String) in URL(fileURLWithPath: path).standardizedFileURL.path }
        if let anchor = space.anchors.first(where: { $0.folder.map(standardized) == standardized(leadFolder) }) {
            return place(of: anchor)
        }
        if standardized(leadFolder) == standardized(sideEffects.homeDirectory()), start == nil { return .home }
        let repository = start.flatMap { anchor -> String? in
            if case .gitRepository = anchor.kind { return anchor.name }
            return nil
        }
        return .elsewhere(path: leadFolder, repository: repository)
    }

    /// The Lead tab again, after the Lead started or closed.
    func refreshSpaceSettingsLead() {
        guard let settings = spaceSettings, let space = profiles.first(where: { $0.id == settings.spaceID }) else { return }
        let model = spaceSettingsLeadModel(for: space)
        if model != settings.lead.model { settings.lead.update(model) }
    }
}
