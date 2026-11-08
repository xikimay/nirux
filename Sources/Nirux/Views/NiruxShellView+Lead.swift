import AppKit

// MARK: - The Lead (docs/spaces.md, "The Lead")

/// One optional Lead per space: a workspace pinned at the top of the space,
/// in its default repository's main checkout, with Claude and the space's
/// Board. The user talks to it; it starts tasks and follows them. Its
/// Claude learns its role from the Nirux MCP server (`NIRUX_LEAD=1` in its
/// shells, see `WorkspaceState.isLead`). Its state lives in Nirux (the
/// board, Missions), so closing it or `/clear` loses nothing.
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
            let board = makeProjectBoard(projectID: spaceID, offersSettings: true)
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
        // The repository whose main checkout the Lead opens in, as
        // `defaultFolder(forSpace:)` picks it.
        let anchors = [space.anchors.defaultAnchor].compactMap { $0 } + space.anchors.filter { !$0.isDefault }
        let repository = anchors.first { $0.folder.map(NiruxURLRequest.directoryExists) == true }
        return SpaceSettingsLeadPane.Model(
            spaceName: space.name,
            isGeneral: !Self.spaceCanHaveLead(space.id),
            hasLead: leadWorkspace(inSpace: space.id) != nil,
            repositoryName: repository?.name
        )
    }

    /// The Lead tab again, after the Lead started or closed.
    func refreshSpaceSettingsLead() {
        guard let settings = spaceSettings, let space = profiles.first(where: { $0.id == settings.spaceID }) else { return }
        let model = spaceSettingsLeadModel(for: space)
        if model != settings.lead.model { settings.lead.update(model) }
    }
}
