import AppKit

// MARK: - Dev-server proposals

extension NiruxShellView {
    func wireLocalServerProposals(for workspace: WorkspaceState) {
        // A chip whose port a browser column already shows reveals that
        // column instead of opening a second one.
        workspace.onRevealColumn = { [weak self] targetWorkspace, index in
            guard let self, targetWorkspace === self.activeWorkspace else { return }
            self.focusColumnByIndex(index)
        }
        // ⌘B lists the active workspace's detected dev servers first.
        // App-wide: the first workspace wired sets it.
        guard CommandPalette.detectedURLsProvider == nil else { return }
        CommandPalette.detectedURLsProvider = { [weak self] in
            self?.activeWorkspace?.detectedLocalServerURLs ?? []
        }
    }
}
