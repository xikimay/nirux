import AppKit

// MARK: - State Persistence

extension NiruxShellView {
    func restoreState() {
        guard let state = Persistence.load(), !state.workspaces.isEmpty else { return }
        for workspace in workspaces { workspace.containerView.removeFromSuperview() }
        workspaces.removeAll()
        for persistedWS in state.workspaces {
            let workspace = WorkspaceState(title: persistedWS.title, cwd: persistedWS.cwd)
            workspace.onMetadataChanged = { [weak self] in self?.updateSidebar(); self?.refreshTitleBarLabels() }
            workspace.onDiffStatsClicked = { [weak self, weak workspace] in
                guard let workspace else { return }
                self?.openDiffInEditor(for: workspace)
            }
            // Remove the default column created by WorkspaceState.init
            if let first = workspace.columns.first { first.view.removeFromSuperview(); workspace.columns.removeAll() }
            for persistedCol in persistedWS.columns {
                switch persistedCol.resolvedType {
                case .webView:
                    workspace.addColumn(webViewURL: persistedCol.webViewURL ?? "about:blank")
                case .claudeCode:
                    let mode = persistedCol.claudeLaunchMode ?? .default
                    workspace.addColumn(command: NiruxShellView.claudeCommand(continueSession: true, mode: mode))
                case .codex:
                    let mode = persistedCol.codexLaunchMode ?? .default
                    workspace.addColumn(command: NiruxShellView.codexCommand(resumeLast: true, mode: mode))
                case .editor:
                    let openFiles = persistedCol.editorOpenFiles ?? []
                    workspace.addEditorColumn(initialFile: openFiles.first, workspaceCwd: persistedCol.cwd)
                    if let editor = workspace.columns.last?.editorColumn {
                        wireEditor(editor)
                        // Re-open the rest of the tabs in their persisted
                        // order, then restore the active one.
                        for path in openFiles.dropFirst() {
                            editor.open(path: path)
                        }
                        if let active = persistedCol.editorActiveFile,
                           openFiles.contains(active),
                           active != openFiles.first {
                            editor.switchTo(path: active)
                        }
                    }
                case .terminal:
                    workspace.addColumn()
                }
                if let width = ColumnWidth(rawValue: CGFloat(persistedCol.widthPreset)) {
                    workspace.columns.last?.widthPreset = width
                }
            }
            workspace.focusedIndex = min(persistedWS.focusedColumnIndex, max(workspace.columns.count - 1, 0))
            workspaces.append(workspace)
            verticalStrip.addSubview(workspace.containerView)
        }
        activeWSIndex = min(state.activeWorkspaceIndex, max(workspaces.count - 1, 0))
        relayout(animated: false)
        updateSidebar()
    }

    func saveState(snapshot: ProcessSnapshot? = nil) {
        let snapshot = snapshot ?? ProcessSnapshot()
        let existingSettings = Persistence.load()?.settings
        Persistence.save(PersistedState(
            workspaces: workspaces.map { workspace in
                PersistedWorkspace(title: workspace.title, cwd: workspace.columns[safe: workspace.focusedIndex]?.pty?.childCwd ?? workspace.cwd,
                    columns: workspace.columns.map { col -> PersistedColumn in
                        let kind: ColumnKind
                        let webURL: String?
                        var editorOpenFiles: [String]? = nil
                        var editorActiveFile: String? = nil
                        var claudeMode: ClaudeLaunchMode?
                        var codexMode: CodexLaunchMode?
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
                        } else if let name = col.pty?.foregroundProcessName(snapshot: snapshot) {
                            switch name {
                            case "claude":
                                kind = .claudeCode; webURL = nil
                                claudeMode = detectClaudeLaunchMode(col: col, snapshot: snapshot)
                            case "codex":
                                kind = .codex; webURL = nil
                                codexMode = detectCodexLaunchMode(col: col, snapshot: snapshot)
                            default: kind = .terminal; webURL = nil
                            }
                        } else {
                            kind = .terminal; webURL = nil
                        }
                        return PersistedColumn(
                            widthPreset: Double(col.widthPreset.rawValue),
                            cwd: col.editorColumn?.workspaceCwd ?? col.pty?.childCwd ?? workspace.cwd,
                            columnType: kind,
                            webViewURL: webURL,
                            editorOpenFiles: editorOpenFiles,
                            editorActiveFile: editorActiveFile,
                            claudeLaunchMode: claudeMode,
                            codexLaunchMode: codexMode
                        )
                    },
                    focusedColumnIndex: workspace.focusedIndex)
            }, activeWorkspaceIndex: activeWSIndex, settings: existingSettings))
    }

    /// Map a running `claude` process's argv flags back to the launch mode it
    /// was started with, so restore reproduces the column faithfully.
    /// `--dangerously-skip-permissions` and `--permission-mode bypassPermissions`
    /// are *not* equivalent (the former bypasses protected dirs too), so they
    /// map to distinct enum cases.
    private func detectClaudeLaunchMode(col: ColumnState, snapshot: ProcessSnapshot) -> ClaudeLaunchMode? {
        guard let pty = col.pty else { return nil }
        if pty.foregroundProcessHasFlag("--dangerously-skip-permissions", snapshot: snapshot) {
            return .skipPermissions
        }
        if let value = pty.foregroundProcessFlagValue("--permission-mode", snapshot: snapshot),
           let mode = ClaudeLaunchMode(rawValue: value) {
            return mode
        }
        return nil
    }

    /// Map a running `codex` process's argv flags back to the launch preset
    /// it was started with. Order matters: bypass beats full-auto beats
    /// read-only since the bypass flag implies the others.
    private func detectCodexLaunchMode(col: ColumnState, snapshot: ProcessSnapshot) -> CodexLaunchMode? {
        guard let pty = col.pty else { return nil }
        if pty.foregroundProcessHasFlag("--dangerously-bypass-approvals-and-sandbox", snapshot: snapshot) {
            return .bypass
        }
        let sandbox = pty.foregroundProcessFlagValue("--sandbox", snapshot: snapshot)
        if sandbox == "workspace-write" {
            return .fullAuto
        }
        if sandbox == "read-only" {
            return .readOnly
        }
        return nil
    }
}
