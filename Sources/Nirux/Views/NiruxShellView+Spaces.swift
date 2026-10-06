import AppKit

// MARK: - Space management (see ProjectStore)

extension NiruxShellView {
    func recolorSpace(profileID: String, colorHex: String) {
        guard workspaceStore.setProfileColor(id: profileID, colorHex: colorHex) else { return }
        updateSidebar()
        saveState()
    }

    /// Asks, then deletes a space: its workspaces move to the default space.
    /// Its brief stays on disk.
    func confirmDeleteSpace(profileID: String) {
        guard profileID != WorkspaceProfile.defaultID,
              let space = profiles.first(where: { $0.id == profileID })
        else { return }
        guard !refuseToDeleteSpaceWithRunningQueue(profileID: profileID) else { return }
        guard projectStore.availability == .writable else {
            // Deleting needs projects.json: the mirror alone can't record it,
            // so the space would come back at the next launch.
            let alert = NSAlert()
            alert.messageText = "Projects can't be deleted right now"
            alert.informativeText = "They were saved by a newer version of Nirux, or projects.json can't be read."
            runModal(alert)
            return
        }
        let count = workspaces.filter { $0.profileID == profileID && !$0.isClosing }.count
        let target = profiles.first { $0.id == WorkspaceProfile.defaultID }?.name
            ?? WorkspaceProfile.defaultProfile.name
        let moved = count == 0
            ? "It has no workspaces."
            : "Its \(count == 1 ? "workspace moves" : "\(count) workspaces move") to \"\(target)\"."
        guard confirmDestructiveClose(
            message: "Delete the project \"\(space.name)\"?",
            details: [moved, "Its brief stays on disk. Folders and repositories aren't touched."],
            confirmTitle: "Delete Project"
        ) else { return }
        deleteSpace(profileID: profileID)
    }

    /// Its shells keep the old NIRUX_PROFILE_ID until they restart.
    func moveWorkspaceToSpace(workspaceID: String, profileID: String) {
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceID }) else { return }
        let oldProfileID = workspaces[index].profileID
        guard workspaceStore.moveWorkspace(at: index, toProfile: profileID) else { return }
        projectHistoryWorkspacesMoved([workspaceID], from: oldProfileID, to: profileID)
        refreshAfterWorkspaceMutation()
    }

    func deleteSpace(profileID: String) {
        // Asked while the confirmation was up: a queue started meanwhile.
        guard mergeQueues[profileID]?.isRunning != true else {
            return showToast("A merge queue started in this project: stop it before deleting the project")
        }
        let moved = Set(workspaces.filter { $0.profileID == profileID }.map(\.id))
        guard workspaceStore.deleteProfile(id: profileID) else { return }
        projectHistoryWorkspacesMoved(moved, from: profileID, to: WorkspaceProfile.defaultID)
        projectStore.markDeleted(profileID)
        // Opened while the confirmation was up: its space is gone.
        if boardSettingsPanel?.spaceID == profileID { boardSettingsPanel?.dismiss() }
        refreshAfterWorkspaceMutation()
    }
}
