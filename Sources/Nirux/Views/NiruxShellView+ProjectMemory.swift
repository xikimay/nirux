import AppKit

// MARK: - Project Memory panel (⌘P › Project Memory…, the project's menu)

extension NiruxShellView {
    /// Opens what agents know about the active workspace's repository; from
    /// a project's menu, about that project's workspace's (see
    /// `projectMemoryWorkspace`). The workspace's own folder decides, not
    /// where its focused terminal has `cd`'d.
    func showProjectMemory(profileID: String? = nil) {
        guard window != nil else { return }
        guard let workspace = profileID.map(projectMemoryWorkspace(inProject:)) ?? activeWorkspace else {
            showToast("Open a workspace in this project to see what agents know")
            return
        }
        // A read that hangs (a stalled network volume) never blocks the
        // next request; only the latest one shows.
        projectMemoryRequest += 1
        let request = projectMemoryRequest
        Self.readProjectMemory(
            folder: workspace.cwd,
            brief: SpaceBrief.briefURL(spaceID: workspace.profileID),
            home: sideEffects.homeDirectory(),
            environment: ProcessInfo.processInfo.environment,
            managed: sideEffects.claudeManagedSettings()
        ) { [weak self, weak workspace] model in
            guard let self, request == projectMemoryRequest else { return }
            presentProjectMemory(model, workspace: workspace)
        }
    }

    /// From a project's menu: its active workspace when it is the active
    /// project, else its first one.
    func projectMemoryWorkspace(inProject profileID: String) -> WorkspaceState? {
        if let active = activeWorkspace, active.profileID == profileID, !active.isClosing { return active }
        return projectWorkspaces(of: profileID).first
    }

    /// An item's file opens in the editor of the workspace it was read for,
    /// brought forward, as the project brief opens in the workspace's.
    private func presentProjectMemory(_ model: ProjectMemoryPanel.Model, workspace: WorkspaceState?) {
        guard let window else { return }
        if projectMemoryPanel == nil { projectMemoryPanel = ProjectMemoryPanel() }
        projectMemoryPanel?.show(relativeTo: window, model: model) { [weak self, weak workspace] url, line in
            guard let self else { return }
            window.makeKey()
            let target = workspace.flatMap { workspace in
                workspace.isClosing ? nil : workspaces.firstIndex { $0 === workspace }
            }
            if let target, workspaces[target] !== activeWorkspace { switchToWorkspace(target) }
            openInEditorColumn(path: url.path, line: line, in: target.map { workspaces[$0] })
        }
    }

    /// Off the main thread through a nonisolated function, so the closure
    /// can't inherit this view's main-actor isolation.
    nonisolated private static func readProjectMemory(
        folder: String, brief: URL?, home: String, environment: [String: String], managed: ProjectMemory.ManagedFolders,
        completion: @escaping @MainActor @Sendable (ProjectMemoryPanel.Model) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let location = ProjectMemory.locate(folder: folder, home: home, environment: environment, managed: managed)
            let model = ProjectMemoryPanel.Model(
                repository: URL(fileURLWithPath: location.projectRoot).lastPathComponent,
                location: location,
                knowledge: ProjectMemory.knowledge(folder: folder, brief: brief, location: location)
            )
            DispatchQueue.main.async { @MainActor in
                completion(model)
            }
        }
    }
}
