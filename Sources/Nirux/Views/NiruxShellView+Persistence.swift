import AppKit

// MARK: - State Persistence

extension NiruxShellView {
    func restoreState() {
        let persisted = Persistence.load()
        // Before anything saves: the decision needs this launch's starting point.
        decideOnboardingChecklist(
            persisted: persisted,
            hasUnreadableState: persisted == nil && Persistence.hasStoredState
        )
        let loadedProfiles = projectStore.load(
            mirror: persisted?.workspaceProfiles,
            markerPresent: persisted?.projectsFileVersion != nil
        )
        workspaceStore.deletedProfileIDs = projectStore.deletedIDs
        guard let state = persisted, !state.workspaces.isEmpty else {
            workspaceStore.replaceProfiles(loadedProfiles, activeProfileID: activeProfileID)
            return
        }
        for workspace in workspaces { workspace.containerView.removeFromSuperview() }
        workspaces.removeAll()
        // A corrupt/hand-edited state file (or an older collision) may map
        // several columns to one conversation. Two agents appending to one
        // transcript corrupt it, so only the first occurrence may
        // auto-resume; duplicates use the picker.
        var claimedSessionIDs = ClaimedSessionIDs()

        workspaceStore.replaceProfiles(loadedProfiles, activeProfileID: state.activeProfileID)
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
                profileID: profileID,
                missionID: persistedWS.missionID,
                missionHandoffsEnabled: state.settings?.missionHandoffsEnabled == true
            )
            workspace.isInactive = persistedWS.isInactive
            workspace.isGroupFolded = persistedWS.isGroupFolded
            workspace.purpose = persistedWS.purpose
            workspace.phase = persistedWS.phase
            workspace.unknownPhaseRawValue = persistedWS.unknownPhaseRawValue
            workspace.lastSummary = persistedWS.lastSummary
            workspace.lastSummaryIsManual = persistedWS.lastSummaryIsManual
            workspace.lastActivityAt = persistedWS.lastActivityAt
            workspace.nextStep = persistedWS.nextStep
            workspace.blocker = persistedWS.blocker
            for (rawValue, run) in persistedWS.reviewRuns ?? [:] {
                if let pass = ReviewPass(rawValue: rawValue) { workspace.reviewRuns[pass] = run }
            }
            // Remove the default column created by WorkspaceState.init
            if let first = workspace.columns.first { first.view.removeFromSuperview(); workspace.columns.removeAll() }
            for persistedColumn in persistedWS.columns {
                restoreColumn(
                    persistedColumn,
                    in: workspace,
                    claimedSessionIDs: &claimedSessionIDs
                )
            }
            workspace.focusedIndex = min(persistedWS.focusedColumnIndex, max(workspace.columns.count - 1, 0))
            wireWorkspace(workspace)
            workspaces.append(workspace)
            verticalStrip.addSubview(workspace.containerView)
        }
        if let activeWorkspaceID = state.activeWorkspaceID,
           workspaceStore.selectWorkspace(id: activeWorkspaceID) {
            // Restored by stable identity.
        } else {
            activeWSIndex = min(state.activeWorkspaceIndex, max(workspaces.count - 1, 0))
        }
        restoreSidebarState(state.settings)
        // Lays out the workspace on screen, which resumes the agents it
        // shows (see NiruxShellView+LazyRestore.swift).
        relayout(animated: false)
        if (state.settings?.agentResumeOnLaunch ?? .defaultValue) == .allAtOnce {
            resumeAllDeferredAgents()
        }
        updateSidebar()
    }

    private func restoreSidebarState(_ settings: PersistedSettings?) {
        if let expanded = settings?.sidebarExpanded {
            isSidebarExpanded = expanded
            sidebar.isExpanded = expanded
        }
    }

    private struct ClaimedSessionIDs {
        var claude = Set<String>()
        var codex = Set<String>()
    }

    private func restoreColumn(
        _ persistedColumn: PersistedColumn,
        in workspace: WorkspaceState,
        claimedSessionIDs: inout ClaimedSessionIDs
    ) {
        switch persistedColumn.resolvedType {
        case .webView:
            workspace.addColumn(webViewURL: persistedColumn.webViewURL ?? "about:blank")
        case .claudeCode:
            // Claimed now, for the whole layout: whenever each column
            // resumes (see NiruxShellView+LazyRestore.swift), two never
            // share a session.
            let resumeTarget = Self.claudeRestoreTarget(
                sessionID: persistedColumn.claudeSessionID,
                sessionIsUnprompted: persistedColumn.claudeSessionIsUnprompted == true,
                claimedSessionIDs: &claimedSessionIDs.claude
            )
            addDeferredAgentColumn(
                .claude(resume: resumeTarget, mode: persistedColumn.claudeLaunchMode ?? .default),
                restoring: persistedColumn, in: workspace
            )
        case .codex:
            let resumeTarget = Self.agentRestoreTarget(
                sessionID: persistedColumn.codexSessionID,
                claimedSessionIDs: &claimedSessionIDs.codex
            )
            addDeferredAgentColumn(
                .codex(resume: resumeTarget, mode: persistedColumn.codexLaunchMode ?? .default),
                restoring: persistedColumn, in: workspace
            )
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
        case .projectBoard:
            let projectID = persistedColumn.boardProjectID ?? workspace.profileID
            // One board per project: a second one (a hand-edited state)
            // comes back as a terminal, as in an older build.
            if projectBoardLocation(projectID: projectID) != nil
                || workspace.columns.contains(where: { $0.projectBoard?.projectID == projectID }) {
                workspace.addColumn(agentUUID: persistedColumn.agentUUID ?? UUID().uuidString)
            } else {
                let board = makeProjectBoard(projectID: projectID, offersSettings: false)
                workspace.addProjectBoardColumn(board)
                board.reload()
            }
        case .branchReview:
            // One review per worktree: a second one (a hand-edited state)
            // comes back as a terminal, as in an older build.
            if branchReviewLocation(worktree: persistedColumn.cwd) != nil
                || workspace.columns.contains(where: { $0.branchReview.map { Self.isSameFolder($0.worktree, persistedColumn.cwd) } == true }) {
                workspace.addColumn(agentUUID: persistedColumn.agentUUID ?? UUID().uuidString)
            } else {
                // It loads its page and reads the branch once its
                // workspace shows (`scheduleBranchReviewsOnScreen`).
                workspace.addBranchReviewColumn(makeBranchReview(worktree: persistedColumn.cwd, branch: persistedColumn.reviewBranch))
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

    /// An agent column back without its agent, which starts later (see
    /// NiruxShellView+LazyRestore.swift).
    private func addDeferredAgentColumn(
        _ agent: DeferredAgentLaunch.Agent,
        restoring persistedColumn: PersistedColumn,
        in workspace: WorkspaceState
    ) {
        workspace.addColumn(
            deferredAgent: DeferredAgentLaunch(
                agent: agent,
                // Hand-edited state shows like a title Nirux saved.
                title: DeferredAgentLaunch.sessionTitle(fromTerminalTitle: persistedColumn.lastAgentTitle),
                lastStatus: persistedColumn.lastAgentStatus
            ),
            agentUUID: persistedColumn.agentUUID ?? UUID().uuidString,
            cwd: Self.existingDirectory(persistedColumn.cwd)
        )
        guard let column = workspace.columns.last else { return }
        column.restoredColumn = persistedColumn
        column.onResumeDeferredAgent = { [weak self, weak workspace, weak column] in
            guard let self, let workspace, let column, self.resumeDeferredAgent(column, in: workspace) else { return }
            self.updateSidebar()
        }
    }

    /// An agent resumes in the directory it ran in — its conversation's
    /// project — unless that directory is gone (a removed worktree).
    static func existingDirectory(_ path: String) -> String? {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
            ? path
            : nil
    }

    /// Claim an exact session once per restore pass. Missing, malformed and
    /// duplicate IDs require explicit selection instead of guessing. Both
    /// agents use UUIDs; anything else (a hand-edited `--flag`) would be
    /// parsed as an option.
    static func agentRestoreTarget(
        sessionID: String?, claimedSessionIDs: inout Set<String>
    ) -> AgentResumeTarget {
        guard let sessionID, UUID(uuidString: sessionID) != nil,
              claimedSessionIDs.insert(sessionID).inserted else {
            return .picker
        }
        return .session(sessionID)
    }

    /// Nil launches a fresh `claude`: the column's last session was never
    /// prompted, so there is nothing to resume or to pick.
    static func claudeRestoreTarget(
        sessionID: String?, sessionIsUnprompted: Bool, claimedSessionIDs: inout Set<String>
    ) -> AgentResumeTarget? {
        if sessionID == nil, sessionIsUnprompted { return nil }
        return agentRestoreTarget(sessionID: sessionID, claimedSessionIDs: &claimedSessionIDs)
    }

    func saveState(snapshot: ProcessSnapshot? = nil) {
        // projects.json first: a crash in between leaves new spaces with an
        // old mirror, which the marker rule handles (see ProjectStore).
        projectStore.save(workspaceStore.profiles)
        Persistence.save(persistedState(snapshot: snapshot))
    }

    /// The layout on screen, with the saved settings (defaults when none
    /// load), the sidebar's state and the Getting Started checklist's.
    /// Meant to be saved: a restored agent
    /// column that has launched drops its restore state.
    func persistedState(snapshot: ProcessSnapshot? = nil) -> PersistedState {
        let snapshot = snapshot ?? ProcessSnapshot()
        var settings = OnboardingChecklist.settings(
            Persistence.load()?.settings ?? PersistedSettings(), recording: onboardingState
        )
        // The shell is the source of truth for sidebar state — carry the rest.
        settings.sidebarExpanded = isSidebarExpanded
        return PersistedState(
            workspaces: workspaces.map { workspace in
                PersistedWorkspace(
                    id: workspace.id, title: workspace.title,
                    cwd: Self.persistedWorkspaceCwd(for: workspace),
                    columns: workspace.columns.map { persistedColumn($0, in: workspace, snapshot: snapshot) },
                    focusedColumnIndex: workspace.focusedIndex,
                    profileID: workspace.profileID,
                    isInactive: workspace.isInactive,
                    missionID: workspace.missionID,
                    isGroupFolded: workspace.isGroupFolded,
                    purpose: workspace.purpose,
                    phase: workspace.phase,
                    unknownPhaseRawValue: workspace.unknownPhaseRawValue,
                    lastSummary: workspace.lastSummary,
                    lastSummaryIsManual: workspace.lastSummaryIsManual,
                    lastActivityAt: workspace.lastActivityAt,
                    nextStep: workspace.nextStep,
                    blocker: workspace.blocker,
                    reviewRuns: workspace.reviewRuns.isEmpty ? nil : Dictionary(
                        uniqueKeysWithValues: workspace.reviewRuns.map { ($0.key.rawValue, $0.value) }
                    ))
            },
            activeWorkspaceIndex: activeWSIndex,
            settings: settings,
            workspaceProfiles: workspaceStore.profiles,
            activeProfileID: activeProfileID,
            activeWorkspaceID: activeWorkspace?.id,
            // Only when projects.json holds these spaces; see ProjectStore.
            projectsFileVersion: projectStore.isFileCurrent ? ProjectStore.schemaVersion : nil
        )
    }

    private func persistedColumn(
        _ col: ColumnState,
        in workspace: WorkspaceState,
        snapshot: ProcessSnapshot
    ) -> PersistedColumn {
        if let board = col.projectBoard {
            // The workspace's folder: an older build opens a terminal there.
            return PersistedColumn(
                widthPreset: Double(col.widthFraction), cwd: workspace.cwd, columnType: .projectBoard,
                webViewURL: nil, claudeLaunchMode: nil, codexLaunchMode: nil, boardProjectID: board.projectID
            )
        }
        if let review = col.branchReview {
            // The reviewed worktree: an older build opens a terminal there.
            return PersistedColumn(
                widthPreset: Double(col.widthFraction), cwd: review.worktree, columnType: .branchReview,
                webViewURL: nil, claudeLaunchMode: nil, codexLaunchMode: nil, reviewBranch: review.branch
            )
        }
        let foregroundProcess = col.pty?.foregroundProcess(snapshot: snapshot)
        if var restored = col.restoredColumn {
            // Nothing to inspect yet (a save while queued hooks replay at
            // launch, or while rc files load): keep the restored state.
            if Self.isLaunchingRestoredAgent(
                foreground: foregroundProcess,
                shellPID: col.pty?.shellPID ?? 0,
                hasExited: col.pty?.hasExited ?? true
            ) {
                restored.widthPreset = Double(col.widthFraction)
                restored.agentUUID = col.agentUUID
                return restored
            }
            col.restoredColumn = nil
        }
        let kind: ColumnKind
        let webURL: String?
        var editorOpenFiles: [String]?
        var editorActiveFile: String?
        var claudeMode: ClaudeLaunchMode?
        var claudeRestore: ClaudeSessionTracker.Restore?
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
        } else if let foregroundProcess {
            switch foregroundProcess.name {
            case "claude":
                kind = .claudeCode; webURL = nil
                claudeMode = detectClaudeLaunchMode(process: foregroundProcess)
                claudeRestore = col.persistedClaudeRestore(foregroundProcess: foregroundProcess)
            case "codex":
                kind = .codex; webURL = nil
                codexMode = detectCodexLaunchMode(process: foregroundProcess)
            default: kind = .terminal; webURL = nil
            }
        } else {
            kind = .terminal; webURL = nil
        }
        // What the column says next launch, until its agent resumes.
        let isAgent = kind == .claudeCode || kind == .codex
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
            claudeSessionID: claudeRestore?.sessionID,
            claudeSessionIsUnprompted: claudeRestore == .fresh ? true : nil,
            agentUUID: col.agentUUID,
            lastAgentTitle: isAgent ? DeferredAgentLaunch.sessionTitle(fromTerminalTitle: col.terminalTitle) : nil,
            lastAgentStatus: isAgent ? col.pty.map { PersistedAgentStatus($0.cachedAgentState) } : nil
        )
    }

    /// A restored agent column is still launching while its shell hasn't
    /// started, or is itself still running the `-c` launch command (the
    /// agent's exit `exec`s a plain interactive shell, dropping `-c`).
    static func isLaunchingRestoredAgent(
        foreground: ForegroundProcess?,
        shellPID: pid_t,
        hasExited: Bool
    ) -> Bool {
        guard !hasExited else { return false }
        guard let foreground else { return true }
        return foreground.instance.pid == shellPID && foreground.hasFlag("-c")
    }

    static func persistedWorkspaceCwd(for workspace: WorkspaceState) -> String {
        workspace.columns[safe: workspace.focusedIndex]?.pty?.childCwd ?? workspace.cwd
    }

    /// Map a running `claude` process's argv flags back to the launch mode it
    /// was started with, so restore reproduces the column faithfully.
    /// `--dangerously-skip-permissions` and `--permission-mode bypassPermissions`
    /// are *not* equivalent (the former bypasses protected dirs too), so they
    /// map to distinct enum cases.
    private func detectClaudeLaunchMode(process: ForegroundProcess) -> ClaudeLaunchMode? {
        ClaudeLaunchMode.detect(arguments: process.arguments)
    }

    private func detectCodexLaunchMode(process: ForegroundProcess) -> CodexLaunchMode? {
        CodexLaunchMode.detect(arguments: process.arguments)
    }
}

extension ClaudeLaunchMode {
    /// The mode a `claude` argv was launched in (see
    /// `detectClaudeLaunchMode`); nil when it names none.
    static func detect(arguments: [String]) -> ClaudeLaunchMode? {
        if arguments.contains("--dangerously-skip-permissions") {
            return .skipPermissions
        }
        guard let index = arguments.firstIndex(of: "--permission-mode"),
              arguments.indices.contains(index + 1) else { return nil }
        return ClaudeLaunchMode(rawValue: arguments[index + 1])
    }
}
