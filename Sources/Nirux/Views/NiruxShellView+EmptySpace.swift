import AppKit

// MARK: - Empty space (see EmptySpaceView)

extension NiruxShellView {
    func wireEmptySpaceView() {
        emptySpaceView.onNew = { [weak self] in self?.showNewWorkspacePanel() }
        emptySpaceView.onAddRepository = { [weak self] in
            guard let self else { return }
            self.addRepository(toSpace: self.activeProfileID)
        }
    }

    /// Shows the view over the viewport while the active space has no
    /// workspace, with what that space offers; hides it otherwise.
    func refreshEmptySpaceView() {
        let isEmpty = activeWorkspace == nil
        emptySpaceView.isHidden = !isEmpty
        guard isEmpty else { return }
        if emptySpaceView.frame != viewport.bounds { emptySpaceView.frame = viewport.bounds }
        let space = workspaceStore.activeProfile
        emptySpaceView.show(EmptySpaceView.Content(
            spaceName: space.name,
            offersAddRepository: space.id != WorkspaceProfile.defaultID && !space.anchors.contains(where: \.isKnown)
        ))
    }

    /// Where a space's brief or task templates open: the active workspace's
    /// editor, else (on an empty space) a new workspace in that space.
    func workspaceForSpaceFile(spaceID: String, spaceName: String) -> WorkspaceState? {
        if let activeWorkspace { return activeWorkspace }
        addWorkspace(title: spaceName, profileID: spaceID)
        return activeWorkspace
    }
}
