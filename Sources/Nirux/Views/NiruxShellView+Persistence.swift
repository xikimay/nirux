import AppKit

// MARK: - State Persistence

extension NiruxShellView {
    func restoreState() {
        guard let state = Persistence.load(), !state.workspaces.isEmpty else { return }
        for workspace in workspaces { workspace.containerView.removeFromSuperview() }
        workspaces.removeAll()
        // A corrupt/hand-edited state file (or an older collision) may map
        // several columns to one thread. Codex permits one writer, so only
        // the first occurrence may auto-resume; duplicates use the picker.
        var claimedCodexSessionIDs = Set<String>()

        let restoredProfiles = state.workspaceProfiles?.isEmpty == false
            ? state.workspaceProfiles!
            : [WorkspaceProfile.defaultProfile]
        workspaceStore.replaceProfiles(restoredProfiles, activeProfileID: state.activeProfileID)
        let validProfileIDs = Set(profiles.map { $0.id })

        for persistedWS in state.workspaces {
            let persistedProfileID = persistedWS.profileID ?? WorkspaceProfile.defaultID
            let profileID = validProfileIDs.contains(persistedProfileID)
                ? persistedProfileID
                : WorkspaceProfile.defaultID
            let workspace = WorkspaceState(
                id: persistedWS.id ?? UUID().uuidString,
                title: persistedWS.title,
                cwd: persistedWS.cwd,
                profileID: profileID
            )
            workspace.isInactive = persistedWS.isInactive
            wireWorkspace(workspace)
            // Remove the default column created by WorkspaceState.init
            if let first = workspace.columns.first { first.view.removeFromSuperview(); workspace.columns.removeAll() }
            for persistedColumn in persistedWS.columns {
                restoreColumn(
                    persistedColumn,
                    in: workspace,
                    claimedCodexSessionIDs: &claimedCodexSessionIDs
                )
            }
            workspace.focusedIndex = min(persistedWS.focusedColumnIndex, max(workspace.columns.count - 1, 0))
            workspaces.append(workspace)
            verticalStrip.addSubview(workspace.containerView)
        }
        if let activeWorkspaceID = state.activeWorkspaceID,
           workspaceStore.selectWorkspace(id: activeWorkspaceID) {
            // Restored by stable identity.
        } else {
            activeWSIndex = min(state.activeWorkspaceIndex, max(workspaces.count - 1, 0))
        }
        // Restore sidebar expanded/collapsed state.
        if let expanded = state.settings?.sidebarExpanded {
            isSidebarExpanded = expanded
            sidebar.isExpanded = expanded
        }
        sidebar.setInactiveSectionCollapsed(
            state.settings?.inactiveWorkspacesCollapsed ?? true
        )
        relayout(animated: false)
        updateSidebar()
    }

    private func restoreColumn(
        _ persistedColumn: PersistedColumn,
        in workspace: WorkspaceState,
        claimedCodexSessionIDs: inout Set<String>
    ) {
        switch persistedColumn.resolvedType {
        case .webView:
            workspace.addColumn(webViewURL: persistedColumn.webViewURL ?? "about:blank")
        case .claudeCode:
            let mode = persistedColumn.claudeLaunchMode ?? .default
            workspace.addColumn(
                command: NiruxShellView.claudeCommand(continueSession: true, mode: mode),
                agentUUID: persistedColumn.agentUUID ?? UUID().uuidString
            )
        case .codex:
            let mode = persistedColumn.codexLaunchMode ?? .default
            let resumeTarget = Self.codexRestoreTarget(
                sessionID: persistedColumn.codexSessionID,
                claimedSessionIDs: &claimedCodexSessionIDs
            )
            workspace.addColumn(
                command: NiruxShellView.codexCommand(resume: resumeTarget, mode: mode),
                agentUUID: persistedColumn.agentUUID ?? UUID().uuidString
            )
            if case .session(let sessionID) = resumeTarget {
                workspace.columns.last?.prepareCodexResume(sessionID: sessionID)
            }
        case .editor:
            let openFiles = persistedColumn.editorOpenFiles ?? []
            // Non-interactive: a binary or huge file in the persisted tab set
            // must not pop a modal alert during launch.
            workspace.addEditorColumn(
                initialFile: openFiles.first,
                workspaceCwd: persistedColumn.cwd,
                interactive: false
            )
            if let editor = workspace.columns.last?.editorColumn {
                wireEditor(editor)
                // Re-open the rest of the tabs in their persisted order, then
                // restore the active one.
                for path in openFiles.dropFirst() {
                    editor.open(path: path, interactive: false)
                }
                if let active = persistedColumn.editorActiveFile,
                   openFiles.contains(active),
                   active != openFiles.first {
                    editor.switchTo(path: active)
                }
            }
        case .terminal:
            workspace.addColumn(agentUUID: persistedColumn.agentUUID ?? UUID().uuidString)
        }
        // Clamp into the drag bounds: a hand-edited or corrupt widthPreset
        // must not restore an invisible sliver or an over-wide column.
        let fraction = CGFloat(persistedColumn.widthPreset)
        workspace.columns.last?.widthFraction = min(
            WorkspaceState.maxWidthFraction,
            max(WorkspaceState.minWidthFraction, fraction)
        )
    }

    /// Claim an exact thread once per restore pass. Missing, empty and
    /// duplicate IDs require explicit selection instead of guessing.
    static func codexRestoreTarget(
        sessionID: String?, claimedSessionIDs: inout Set<String>
    ) -> CodexResumeTarget {
        guard let sessionID, !sessionID.isEmpty,
              claimedSessionIDs.insert(sessionID).inserted else {
            return .picker
        }
        return .session(sessionID)
    }

    func saveState(snapshot: ProcessSnapshot? = nil) {
        let snapshot = snapshot ?? ProcessSnapshot()
        var settings = Persistence.load()?.settings ?? PersistedSettings()
        // The shell is the source of truth for sidebar state — carry the rest.
        settings.sidebarExpanded = isSidebarExpanded
        settings.inactiveWorkspacesCollapsed = sidebar.isInactiveSectionCollapsed
        Persistence.save(PersistedState(
            workspaces: workspaces.map { workspace in
                PersistedWorkspace(
                    id: workspace.id, title: workspace.title,
                    cwd: workspace.columns[safe: workspace.focusedIndex]?.pty?.childCwd ?? workspace.cwd,
                    columns: workspace.columns.map { col -> PersistedColumn in
                        let kind: ColumnKind
                        let webURL: String?
                        var editorOpenFiles: [String]?
                        var editorActiveFile: String?
                        var claudeMode: ClaudeLaunchMode?
                        var codexMode: CodexLaunchMode?
                        let foregroundProcess = col.pty?.foregroundProcess(snapshot: snapshot)
                        if col.isEditor {
                            kind = .editor
                            webURL = nil
                            if let editor = col.editorColumn {
                                editorOpenFiles = editor.openPaths.isEmpty ? nil : editor.openPaths
                                editorActiveFile = editor.activePath
                            }
                        } else if col.isWebView {
                            kind = .webView
                            webURL = col.webViewColumn?.currentURL
                        } else if let foregroundProcess {
                            switch foregroundProcess.name {
                            case "claude":
                                kind = .claudeCode; webURL = nil
                                claudeMode = detectClaudeLaunchMode(process: foregroundProcess)
                            case "codex":
                                kind = .codex; webURL = nil
                                codexMode = detectCodexLaunchMode(process: foregroundProcess)
                            default: kind = .terminal; webURL = nil
                            }
                        } else {
                            kind = .terminal; webURL = nil
                        }
                        return PersistedColumn(
                            widthPreset: Double(col.widthFraction),
                            cwd: col.editorColumn?.workspaceCwd ?? col.pty?.childCwd ?? workspace.cwd,
                            columnType: kind,
                            webViewURL: webURL,
                            editorOpenFiles: editorOpenFiles,
                            editorActiveFile: editorActiveFile,
                            claudeLaunchMode: claudeMode,
                            codexLaunchMode: codexMode,
                            codexSessionID: kind == .codex
                                ? col.persistedCodexSessionID(foregroundProcess: foregroundProcess)
                                : nil,
                            agentUUID: col.agentUUID
                        )
                    },
                    focusedColumnIndex: workspace.focusedIndex,
                    profileID: workspace.profileID,
                    isInactive: workspace.isInactive)
            },
            activeWorkspaceIndex: activeWSIndex,
            settings: settings,
            workspaceProfiles: workspaceStore.navigableProfiles,
            activeProfileID: activeProfileID,
            activeWorkspaceID: activeWorkspace?.id
        ))
    }

    /// Map a running `claude` process's argv flags back to the launch mode it
    /// was started with, so restore reproduces the column faithfully.
    /// `--dangerously-skip-permissions` and `--permission-mode bypassPermissions`
    /// are *not* equivalent (the former bypasses protected dirs too), so they
    /// map to distinct enum cases.
    private func detectClaudeLaunchMode(process: ForegroundProcess) -> ClaudeLaunchMode? {
        if process.hasFlag("--dangerously-skip-permissions") {
            return .skipPermissions
        }
        if let value = process.flagValue("--permission-mode"),
           let mode = ClaudeLaunchMode(rawValue: value) {
            return mode
        }
        return nil
    }

    private func detectCodexLaunchMode(process: ForegroundProcess) -> CodexLaunchMode? {
        CodexLaunchMode.detect(arguments: process.arguments)
    }
}
