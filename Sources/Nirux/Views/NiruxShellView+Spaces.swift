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
        let count = workspaces.filter { $0.profileID == profileID && !$0.isClosing }.count
        let target = profiles.first { $0.id == WorkspaceProfile.defaultID }?.name
            ?? WorkspaceProfile.defaultProfile.name
        let moved = count == 0
            ? "It has no workspaces."
            : "Its \(count == 1 ? "workspace moves" : "\(count) workspaces move") to \"\(target)\"."
        guard confirmDestructiveClose(
            message: "Delete the space \"\(space.name)\"?",
            details: [moved, "Its brief stays on disk."],
            confirmTitle: "Delete Space"
        ) else { return }
        deleteSpace(profileID: profileID)
    }

    func deleteSpace(profileID: String) {
        guard workspaceStore.deleteProfile(id: profileID) else { return }
        projectStore.markDeleted(profileID)
        refreshAfterWorkspaceMutation()
    }
}
