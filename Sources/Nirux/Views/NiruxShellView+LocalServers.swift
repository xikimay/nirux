import AppKit

// MARK: - Dev-server proposals

extension NiruxShellView {
    /// A proposal chip whose port a browser column already shows reveals
    /// that column instead of opening a second one.
    func wireLocalServerProposals(for workspace: WorkspaceState) {
        workspace.onRevealColumn = { [weak self] targetWorkspace, index in
            guard let self, targetWorkspace === self.activeWorkspace else { return }
            self.focusColumnByIndex(index)
        }
    }
}
