import AppKit

// MARK: - Workspaces & Sidebar Toggle

extension NiruxShellView {
    enum VDir { case up, down }
    enum SpaceDir { case previous, next }

    var visibleWorkspaceIndices: [Int] { workspaceStore.visibleWorkspaceIndices }

    var activeVisibleWorkspacePosition: Int? { workspaceStore.activeVisibleWorkspacePosition }

    func addWorkspace(
        title: String? = nil,
        cwd: String? = nil,
        agent: NiruxApp.WorkspaceAgent? = nil,
        profileID requestedProfileID: String? = nil,
        workspaceID: String = UUID().uuidString,
        initialAgentUUID: String = UUID().uuidString,
        missionID: String? = nil,
        parentWorkspaceID: String? = nil,
        reportsToLead: Bool = false,
        deliveredHandover: Bool = false,
        worktreeBranch: String? = nil,
        startedOutsideNirux: Bool = false,
        startedByAgent: Bool = false,
        setupScript: URL? = nil,
        isLead: Bool = false,
        isFolderTask: Bool = false,
        activate: Bool = true,
        slidesIn: Bool = false
    ) {
        // In the background (a task its Lead started): no selection, no
        // focus, no slide; the user stays where they type.
        let snapshot: NSImageView? = !activate ? nil : {
            guard let rep = viewport.bitmapImageRepForCachingDisplay(in: viewport.bounds) else { return nil }
            viewport.cacheDisplay(in: viewport.bounds, to: rep)
            let imageView = NSImageView(frame: viewport.bounds)
            let img = NSImage(size: viewport.bounds.size)
            img.addRepresentation(rep)
            imageView.image = img
            imageView.imageScaling = .scaleNone
            imageView.wantsLayer = true
            return imageView
        }()

        let targetProfileID = workspaceStore.targetProfileID(for: requestedProfileID)
        // A space with anchors opens a plain workspace in its default
        // folder, never in the home folder (docs/spaces.md).
        let wsCwd = cwd ?? defaultFolder(forSpace: targetProfileID)
        let workspace = WorkspaceState(
            id: workspaceID,
            // Unnamed: its folder's name (docs/spaces.md, "One door: ⌘N").
            title: title ?? NewTask.folderTitle(wsCwd, home: sideEffects.homeDirectory()),
            cwd: wsCwd,
            profileID: targetProfileID,
            missionID: missionID,
            parentWorkspaceID: subtaskParentID(parentWorkspaceID),
            missionHandoffsEnabled: Self.currentMissionHandoffsEnabled(),
            startedOutsideNirux: startedOutsideNirux,
            startedByAgent: startedByAgent,
            isLead: isLead,
            reportsToLead: reportsToLead,
            isFolderTask: isFolderTask,
            initialAgentUUID: initialAgentUUID
        )
        wireWorkspace(workspace)
        workspaceStore.appendWorkspace(workspace, activate: activate)
        verticalStrip.addSubview(workspace.containerView)
        relayout(animated: false)
        updateSidebar()
        if activate { focusActiveTerminal(in: window) }

        // The setup script, then the agent, in the new workspace's terminal.
        // Never for a workspace opened from outside Nirux.
        let setupScript = startedOutsideNirux ? nil : setupScript
        if let agent {
            launchAgent(
                agent, in: workspace, deliveredHandover: deliveredHandover,
                worktreeBranch: worktreeBranch, setupScript: setupScript
            )
        } else if let setupScript, let column = workspace.columns.first {
            sideEffects.launchAgent(column, setupCommand(setupScript, in: workspace, then: nil))
        }

        if let snapshot, slidesIn, agentLightsMayMove {
            // A task born from the ⌘N sheet (NiruxShellView+TaskBirth).
            slideInNewWorkspace(workspace, over: snapshot)
        } else if let snapshot {
            viewport.addSubview(snapshot)
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.3
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                snapshot.animator().alphaValue = 0
                snapshot.animator().frame.origin.y += self.viewport.bounds.height * 0.5
            }, completionHandler: {
                DispatchQueue.main.async { snapshot.removeFromSuperview() }
            })
        }
    }

    /// `id` when it names an open task (see `isTask`).
    func subtaskParentID(_ id: String?) -> String? {
        guard let id, let parent = workspaces.first(where: { $0.id == id && !$0.isClosing }), Self.isTask(parent) else { return nil }
        return parent.id
    }

    /// What can have sub-tasks (docs/spaces.md, "Sub-tasks under their
    /// task"): a workspace in a git worktree, as ⌘N and the Lead start
    /// tasks, or a task without a repository in its folder. Not the main
    /// checkout, where worktrees an agent opens are tasks of their own, nor
    /// the Lead (its tasks are the space's list itself). Reads a file or
    /// two (see `taskLocation(of:)`): asked when a menu opens or a
    /// workspace does, never on a sidebar refresh.
    static func isTask(_ workspace: WorkspaceState) -> Bool {
        !workspace.isLead && (workspace.isFolderTask || taskLocation(of: workspace) != nil)
    }

    /// `taskLocation(cwd:)` for a workspace, kept once found: its folder
    /// never moves. Kept while that folder is there and its worktree's
    /// `.git` file stays as it was (two stats), read again otherwise: a
    /// worktree removed is no task, one re-added or repaired may be another
    /// repository's.
    static func taskLocation(of workspace: WorkspaceState) -> FolderIdentity? {
        if let cached = workspace.taskLocationCache, FileManager.default.fileExists(atPath: workspace.cwd),
           modificationDate(of: cached.gitFile) == cached.gitFileDate {
            return cached.location
        }
        workspace.taskLocationCache = taskLocationAndGitFile(cwd: workspace.cwd).flatMap { found in
            modificationDate(of: found.gitFile).map { (found.location, found.gitFile, $0) }
        }
        return workspace.taskLocationCache?.location
    }

    private static func modificationDate(of path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    /// Where a task works, from its linked worktree's `.git` file (no git):
    /// its repository's common git dir, and its folder as it is in the main
    /// checkout, so routing's anchor rule finds the space's repository or
    /// folder of it. Nil outside a linked worktree, or with the folder gone.
    nonisolated static func taskLocation(cwd: String) -> FolderIdentity? {
        taskLocationAndGitFile(cwd: cwd)?.location
    }

    /// A folder that is surely no task: in a main checkout, a submodule, or
    /// outside git. False when it can't tell, as for a linked worktree whose
    /// repository can't be found now (a volume not mounted yet) or a `.git`
    /// file it can't read: ask again later.
    nonisolated static func isSurelyNoTask(cwd: String) -> Bool {
        guard let folder = cwd.realPath else { return false }
        var url = URL(fileURLWithPath: folder)
        while true {
            let gitPath = url.appendingPathComponent(".git").path
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: gitPath, isDirectory: &isDirectory) {
                if isDirectory.boolValue { return true }
                guard let contents = try? String(contentsOfFile: gitPath, encoding: .utf8) else { return false }
                return worktreeGitDir(contents: contents, root: url.path) == nil
            }
            let parent = url.deletingLastPathComponent()
            guard url.path != "/", parent.path != url.path else { return true }
            url = parent
        }
    }

    private nonisolated static func taskLocationAndGitFile(cwd: String) -> (location: FolderIdentity, gitFile: String)? {
        // Resolved, so the worktree found walking up is too.
        guard let folder = cwd.realPath, let worktree = linkedWorktree(holding: folder),
              // `<common dir>/worktrees/<id>`.
              let commonDir = ((worktree.gitDir as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent.realPath
        else { return nil }
        // A bare repository has no main checkout: the worktree stands in.
        let mainCheckout = (commonDir as NSString).lastPathComponent == ".git"
            ? (commonDir as NSString).deletingLastPathComponent : worktree.root
        let inside = String(folder.dropFirst(worktree.root.count))
        return (FolderIdentity(path: mainCheckout + inside, commonDir: commonDir, topLevel: mainCheckout), worktree.root + "/.git")
    }

    /// The sheet's repository for a sub-task of `task`: the one of its space
    /// the task works in, or a folder of it, by key; nil when ⌘N can't
    /// start there (a folder holding the whole checkout is in no
    /// repository).
    func subtaskRepositoryKey(of task: WorkspaceState) -> String? {
        guard !task.isLead, let location = Self.taskLocation(of: task),
              let space = profiles.first(where: { $0.id == task.profileID }),
              let anchor = SpaceRouting.anchoring(location, in: [space])?.anchor, let key = anchor.key,
              newTaskRepositories(of: space).contains(where: { $0.key == key })
        else { return nil }
        if case .folder(let path) = anchor.kind, let checkout = location.topLevel, !SpaceRouting.contains(checkout, path) {
            return nil
        }
        return key
    }

    /// The card menu's and the menu bar's New Sub-task…: a task, active.
    /// A task without a repository has its sub-tasks in folders inside its
    /// own, while that folder is there; a worktree's work in its repository,
    /// so its space must have that repository (General never has one).
    func offersSubtask(_ workspace: WorkspaceState) -> Bool {
        guard !workspace.isInactive, !workspace.isLead else { return false }
        if workspace.isFolderTask { return NiruxURLRequest.directoryExists(workspace.cwd) }
        return workspace.profileID != WorkspaceProfile.defaultID && subtaskRepositoryKey(of: workspace) != nil
    }

    /// Startup prompt for a freshly launched agent. The handover line is
    /// only added when this very request delivered one: a handover file that
    /// merely exists in the folder (committed to the branch, left by an
    /// earlier session, shipped in a downloaded archive) is never followed.
    nonisolated static func agentStartupPrompt(
        agent: NiruxApp.WorkspaceAgent, deliveredHandover: Bool, isMission: Bool
    ) -> String? {
        startupPrompt(
            agent: agent, deliveredHandover: deliveredHandover,
            mission: isMission ? (agent == .claude ? typedAnswerMission : waitingMission) : nil
        )
    }

    nonisolated static func startupPrompt(
        agent: NiruxApp.WorkspaceAgent, deliveredHandover: Bool, mission: String?
    ) -> String? {
        var instructions: [String] = []
        if deliveredHandover {
            let handoverName = handoverFilename(for: agent)
            instructions.append("Read \(handoverName) for full context, then proceed with the next steps described there.")
        }
        if let mission { instructions.append(mission) }
        return instructions.isEmpty ? nil : instructions.joined(separator: " ")
    }

    /// A Claude Code child: Nirux types the answer into its prompt
    /// (`MissionPromptText`).
    nonisolated static let typedAnswerMission = "This is a Nirux mission workspace. To ask the parent agent, run "
        + "\"$NIRUX_CLI_PATH\" --mission ask --message \"...\" "
        + "(at most \(MissionEventCLI.maxMessageLength) characters), then end your turn: Nirux types "
        + "the answer into your prompt as a message starting with \(MissionPromptText.prefix). "
        + "If it exits with status 3, run the exact same command again: it does not ask twice. "
        + "Status 4 means the Mission is over; do not retry. Report the final result with "
        + "\"$NIRUX_CLI_PATH\" --mission completed --message \"...\"."

    /// A Codex child, and every child before Nirux typed answers: `ask`
    /// waits for the answer.
    nonisolated static let waitingMission = "This is a Nirux mission workspace. Ask the parent and wait safely with "
        + "\"$NIRUX_CLI_PATH\" --mission ask --message \"...\" "
        + "(at most \(MissionEventCLI.maxMessageLength) characters); the command output is the parent's answer. "
        + "It waits up to \(Int(MissionEventCLI.defaultWaitTimeout)) seconds, so allow it a shell-tool timeout "
        + "of at least 120 seconds. If it exits with status 3, or your shell tool stops it before it "
        + "prints anything, run the exact same command again: it resumes the same question. "
        + "Status 4 means the Mission is over; do not retry. Report the final result with "
        + "\"$NIRUX_CLI_PATH\" --mission completed --message \"...\"."

    /// `worktreeBranch` is the branch read back from the checkout
    /// (`GitWorktree.currentBranch(at:)`) of a worktree workspace Nirux just
    /// opened; nil when unreadable, detached, or not a worktree workspace. It
    /// names the Claude session (see `SessionName`).
    private func launchAgent(
        _ agent: NiruxApp.WorkspaceAgent,
        in workspace: WorkspaceState,
        deliveredHandover: Bool,
        worktreeBranch: String?,
        setupScript: URL?
    ) {
        guard let col = workspace.columns[safe: workspace.focusedIndex] else { return }
        let handoverPrompt = Self.agentStartupPrompt(
            agent: agent,
            deliveredHandover: deliveredHandover,
            isMission: workspace.missionID != nil
        )

        let brief = spaceBriefInjection(for: workspace)
        let cmd: String
        switch agent {
        case .claude:
            cmd = NiruxShellView.claudeCommand(
                mode: NiruxShellView.claudeLaunchMode(for: workspace),
                sessionName: SessionName.make(
                    worktreeBranch: worktreeBranch,
                    spaceName: workspaceStore.profiles.first { $0.id == workspace.profileID }?.name,
                    isDefaultSpace: workspace.profileID == WorkspaceProfile.defaultID
                ),
                briefFile: brief?.claudePromptFile,
                handoverPrompt: handoverPrompt
            )
        case .codex:
            cmd = NiruxShellView.codexCommand(
                mode: NiruxShellView.codexLaunchMode(for: workspace),
                briefFile: NiruxShellView.codexBriefFile(from: brief, launchDirectory: workspace.cwd),
                handoverPrompt: handoverPrompt
            )
        }

        sideEffects.launchAgent(col, setupScript.map { setupCommand($0, in: workspace, then: cmd) } ?? cmd)
    }

    /// The setup script's line (see SpaceSetupScript), then `agentCommand`.
    private func setupCommand(_ script: URL, in workspace: WorkspaceState, then agentCommand: String?) -> String {
        SpaceSetupScript.command(
            script: script.path, executable: Self.niruxExecutable, workspaceID: workspace.id, then: agentCommand
        )
    }

    func focusWorkspace(_ dir: VDir) {
        let delta = dir == .up ? -1 : 1
        let before = activeWorkspace
        guard workspaceStore.selectAdjacentWorkspace(delta: delta) != nil else { return }
        // The card, if up, keeps through the relayout: its words change.
        workspaceSwitch.isAnnouncing = activeWorkspace !== before
        refreshAfterWorkspaceSelection(animated: true)
        workspaceSwitch.isAnnouncing = false
        if activeWorkspace !== before { announceWorkspaceSwitch() }
    }

    func switchToWorkspace(_ index: Int, editorTakesKeyboard: Bool = true) {
        let space = activeProfileID
        guard workspaceStore.selectWorkspace(at: index) else { return }
        // Into another space: its workspace shows at once, as when a close
        // changes the space, not slid in from the last space's place.
        refreshAfterWorkspaceSelection(animated: activeProfileID == space, editorTakesKeyboard: editorTakesKeyboard)
    }

    /// Focus a workspace by ID (notification click-through), optionally
    /// jumping straight to a specific column. Always flashes the target
    /// column's border: when the target is already focused, switching is
    /// a visual no-op and the click would otherwise feel dead.
    func focusWorkspace(id: String, column columnIndex: Int? = nil, editorTakesKeyboard: Bool = true) {
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else { return }
        switchToWorkspace(index, editorTakesKeyboard: editorTakesKeyboard)
        if let columnIndex, workspaces.indices.contains(index) {
            focusColumnByIndex(columnIndex)
        }
        flashColumnBorder(workspaceIndex: index, columnIndex: columnIndex)
    }

    /// AgentHookCenter resolver: locate the column owning a NIRUX_AGENT_UUID
    /// and report whether the user is currently watching it. The app must be
    /// active: without that, a turn ending in the FOCUSED column while the
    /// user sits in another app would produce no dock bounce, no native
    /// notification and no badge — the exact regression the hooks replaced.
    func resolveAgentColumn(uuid: String) -> AgentHookCenter.Resolution? {
        for (wsIndex, workspace) in workspaces.enumerated() {
            guard let colIndex = workspace.columns.firstIndex(where: { $0.agentUUID == uuid }) else { continue }
            let isUserFocused = NSApp.isActive
                && colIndex == workspace.focusedIndex
                && wsIndex == activeWSIndex
            return AgentHookCenter.Resolution(
                workspace: workspace,
                column: workspace.columns[colIndex],
                columnIndex: colIndex,
                isUserFocused: isUserFocused,
                approvalHold: approvalHold(
                    workspaceIndex: wsIndex, columnIndex: colIndex, listed: Set(visibleWorkspaceIndices)
                )
            )
        }
        return nil
    }

    func refreshAfterWorkspaceSelection(animated: Bool, editorTakesKeyboard: Bool = true) {
        quickSwitch.focusMoved()
        guard let workspace = activeWorkspace else {
            // An empty space: its view shows and takes the keyboard (see
            // EmptySpaceView).
            relayout(animated: animated)
            updateSidebar()
            focusActiveTerminal(in: window)
            return
        }
        workspace.notification = nil
        relayout(animated: animated)
        refreshGitContextNow(for: workspace)
        // Headers of a workspace off screen weren't refreshed: bring
        // them (and their agent usage) up to date now, not on the next
        // heartbeat. Also refreshes the sidebar.
        refreshMetadata()
        focusActiveTerminal(in: window, editorTakesKeyboard: editorTakesKeyboard)
    }

    func selectProfile(_ profileID: String) {
        activateProfile(profileID, slideOutDirection: nil)
    }

    /// ⌥⌘1…⌥⌘9: the space at that place in the space picker, read off
    /// the list the menu shows, so the chord goes where its item says.
    func selectSpace(number: Int) {
        guard let profile = sidebar.lastProfiles[safe: number - 1] else { return }
        selectProfile(profile.id)
    }

    func focusSpace(_ dir: SpaceDir) {
        let slideOutDirection: CGFloat
        let delta: Int
        switch dir {
        case .previous:
            delta = -1
            slideOutDirection = 1
        case .next:
            delta = 1
            slideOutDirection = -1
        }
        guard let profile = workspaceStore.selectAdjacentProfile(delta: delta) else { return }
        activateProfile(profile.id, slideOutDirection: slideOutDirection, profileAlreadySelected: true)
    }

    private func activateProfile(_ profileID: String, slideOutDirection: CGFloat?, profileAlreadySelected: Bool = false) {
        let previousProfileID = activeProfileID
        let snapshot = slideOutDirection.flatMap { _ in viewportSnapshot() }
        guard profileAlreadySelected || workspaceStore.selectProfile(profileID) else { return }
        guard profileAlreadySelected || previousProfileID != activeProfileID else { return }

        // An empty space (spaces persist) says what to do instead of
        // opening a workspace.
        refreshAfterWorkspaceSelection(animated: false)
        saveState()

        if let snapshot, let slideOutDirection {
            animateSpaceSnapshot(snapshot, slideOutDirection: slideOutDirection)
        }
    }

    private func viewportSnapshot() -> NSImageView? {
        guard viewport.bounds.width > 0, viewport.bounds.height > 0,
              let rep = viewport.bitmapImageRepForCachingDisplay(in: viewport.bounds) else { return nil }
        viewport.cacheDisplay(in: viewport.bounds, to: rep)
        let image = NSImage(size: viewport.bounds.size)
        image.addRepresentation(rep)
        let imageView = NSImageView(frame: viewport.bounds)
        imageView.image = image
        imageView.imageScaling = .scaleNone
        imageView.wantsLayer = true
        return imageView
    }

    private func animateSpaceSnapshot(_ snapshot: NSImageView, slideOutDirection: CGFloat) {
        viewport.addSubview(snapshot)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            snapshot.animator().frame.origin.x += slideOutDirection * viewport.bounds.width * 0.35
            snapshot.animator().alphaValue = 0
        }, completionHandler: {
            DispatchQueue.main.async { snapshot.removeFromSuperview() }
        })
    }

    func handleWorkspaceSidebarAction(_ action: WorkspaceSidebarAction, workspaceIndex: Int) {
        guard workspaces.indices.contains(workspaceIndex) else { return }
        let didChange: Bool
        switch action {
        case .rename:
            showRenamePanel(workspaceIndex: workspaceIndex)
            return
        case .moveUp:
            didChange = workspaceStore.moveWorkspace(at: workspaceIndex, delta: -1)
        case .moveDown:
            didChange = workspaceStore.moveWorkspace(at: workspaceIndex, delta: 1)
        case .moveOutOfParent:
            didChange = workspaceStore.moveOutOfParent(at: workspaceIndex)
        case .markActive:
            // By identity: back among the active ones, it may take another
            // slot (its children follow it, see WorkspaceStore).
            let restored = workspaces[workspaceIndex]
            didChange = workspaceStore.setWorkspaceInactive(at: workspaceIndex, false)
            if didChange { workspaceStore.selectWorkspace(id: restored.id) }
        case .markInactive:
            didChange = workspaceStore.setWorkspaceInactive(at: workspaceIndex, true)
        case .close:
            requestCloseWorkspace(at: workspaceIndex)
            return
        case .editContext:
            showWorkspaceContextPanel(workspaceIndex: workspaceIndex)
            return
        case .reviewBranch:
            openBranchReview(in: workspaces[workspaceIndex])
            return
        case .newSubtask:
            showNewSubtaskPanel(under: workspaces[workspaceIndex])
            return
        case .closeColumn(let columnIndex):
            closeColumn(workspaceIndex: workspaceIndex, columnIndex: columnIndex)
            return
        case .cleanUpWorktree:
            requestWorktreeCleanup(workspaceIndex: workspaceIndex)
            return
        case .askWhyCIFailed:
            askAgentWhyCIFailed(workspaces[workspaceIndex])
            return
        case .rerunFailedCI:
            confirmRerunFailedCI(workspaces[workspaceIndex])
            return
        }
        guard didChange else { return }
        refreshAfterWorkspaceMutation()
        if case .markActive = action, let restored = activeWorkspace {
            refreshGitContextNow(for: restored)
            refreshPRInfo(for: [restored])
        }
    }

    /// Drop handler for sidebar drag-reorder: move the workspace to an
    /// absolute position within its active/inactive group, then run the
    /// same refresh dance as the context-menu moves.
    func handleWorkspaceReorder(workspaceIndex: Int, targetPosition: Int) {
        guard workspaces.indices.contains(workspaceIndex),
              workspaceStore.moveWorkspace(at: workspaceIndex, toPosition: targetPosition)
        else {
            // Stale or no-op drop — repaint so the sidebar leaves drag state.
            updateSidebar()
            return
        }
        refreshAfterWorkspaceMutation()
    }

    func refreshAfterWorkspaceMutation() {
        relayout(animated: true)
        updateSidebar()
        focusActiveTerminal(in: window)
        saveState()
    }

    // MARK: - Sidebar toggle

    func toggleSidebar() {
        let expanding = !isSidebarExpanded
        isSidebarExpanded = expanding
        sidebarToggleGeneration += 1
        let generation = sidebarToggleGeneration
        saveState()

        if expanding {
            refreshOnboardingChecklist()
            sidebar.fadeOutRail {
                self.relayout(animated: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    // Toggled again meanwhile: that toggle decides.
                    guard let self, self.sidebarToggleGeneration == generation else { return }
                    self.sidebar.isExpanded = true
                }
            }
        } else {
            sidebar.isExpanded = false
            relayout(animated: true)
        }
    }

    // MARK: - Layout Helpers

    struct StripLayout {
        let viewportW, totalH, rowH, targetY: CGFloat
        let animated: Bool
    }

    struct ChromeFrames {
        let sidebar, divider, viewport: NSRect
        let glowLeft, glowRight, glowTop, glowBottom: NSRect
        let indicator, statusBar: NSRect
    }

    func applyChromeLayout(_ frames: ChromeFrames, animated: Bool) {
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                sidebar.animator().frame = frames.sidebar
                divider.animator().frame = frames.divider
                viewport.animator().frame = frames.viewport
                edgeGlowLeft.animator().frame = frames.glowLeft
                edgeGlowRight.animator().frame = frames.glowRight
                edgeGlowTop.animator().frame = frames.glowTop
                edgeGlowBottom.animator().frame = frames.glowBottom
                columnIndicator.animator().frame = frames.indicator
            }
        } else {
            sidebar.frame = frames.sidebar
            divider.frame = frames.divider
            viewport.frame = frames.viewport
            edgeGlowLeft.frame = frames.glowLeft
            edgeGlowRight.frame = frames.glowRight
            edgeGlowTop.frame = frames.glowTop
            edgeGlowBottom.frame = frames.glowBottom
            columnIndicator.frame = frames.indicator
        }
        statusBar.frame = frames.statusBar
    }

    /// Set the frame of each workspace container and of the strip that
    /// holds them.
    private func applyWorkspaceFrames(_ layout: StripLayout) {
        verticalStrip.frame = NSRect(x: 0, y: layout.targetY, width: layout.viewportW, height: layout.totalH)
        let visible = visibleWorkspaceIndices
        let visibleSet = Set(visible)
        for (index, workspace) in workspaces.enumerated() {
            workspace.containerView.isHidden = !visibleSet.contains(index)
        }
        for (position, index) in visible.enumerated() {
            let workspace = workspaces[index]
            let wsY = layout.totalH - CGFloat(position + 1) * layout.rowH
            workspace.containerView.frame = NSRect(x: 0, y: wsY, width: layout.viewportW, height: layout.rowH)
        }
    }

    /// Only the space on screen is laid out. A terminal whose shell starts
    /// in another space (a task its Lead started there, an agent Resume All
    /// Agents started) would get no surface: what it prints would wait
    /// unparsed, its PTY stay 80x24 and its terminal queries go unanswered.
    /// As its shell starts it gets the size it will have on screen, and
    /// keeps its surface when shown; it draws nothing meanwhile (see
    /// `syncTerminalOcclusion`). Only that column: a hidden workspace's
    /// browsers and editors don't render off screen.
    func sizeTerminalOffScreen(_ column: ColumnState, in workspace: WorkspaceState) {
        guard isOffScreen(workspace), column.terminalView != nil else { return }
        let viewport = workspaceViewportSize
        guard viewport.width > 0, viewport.height > 0 else { return }
        let size = workspace.size(of: column, viewportWidth: viewport.width, height: viewport.height)
        // Built hidden, whatever layout ran last.
        column.terminalView?.setSurfaceVisible(false)
        column.view.frame = NSRect(origin: column.view.frame.origin, size: size)
        column.layoutWithHeader(width: size.width, height: size.height)
    }

    /// In another space than the one on screen, and not closing.
    private func isOffScreen(_ workspace: WorkspaceState) -> Bool {
        workspace.profileID != activeProfileID && !workspace.isClosing
    }

    /// The viewport changed size (window, sidebar, status bar): hidden
    /// terminals that have a size take the new one, so their PTYs follow
    /// as they would on screen.
    private func resizeTerminalsOffScreen(to size: NSSize) {
        guard size != offScreenViewportSize else { return }
        offScreenViewportSize = size
        for workspace in workspaces where isOffScreen(workspace) {
            for column in workspace.columns where column.terminalView != nil && !column.view.frame.isEmpty {
                sizeTerminalOffScreen(column, in: workspace)
            }
        }
    }

    /// Displays woke: a hidden terminal whose shell runs without a surface
    /// (its build failed) gets its size again, which builds one.
    func retryTerminalSurfacesOffScreen() {
        for workspace in workspaces where isOffScreen(workspace) {
            for column in workspace.columns where column.isShellStartScheduled && !column.hasSurface {
                sizeTerminalOffScreen(column, in: workspace)
            }
        }
    }

    func layoutWorkspaceStrip(_ layout: StripLayout) {
        let viewportW = layout.viewportW
        let rowH = layout.rowH
        let animated = layout.animated

        let oldY = verticalStrip.frame.origin.y
        let leaving = workspaceOnScreenBeforeLayout()
        applyWorkspaceFrames(layout)
        for index in visibleWorkspaceIndices {
            workspaces[index].layoutAndScroll(viewportWidth: viewportW, height: rowH, animated: animated)
        }
        resizeTerminalsOffScreen(to: NSSize(width: viewportW, height: rowH))
        // Animated path: a vertical slide over the direct frame change.
        slideWorkspaceStrip(from: oldY, leaving: leaving, animated: animated)

        // Focus border and header icon. The agents' lights lie over the
        // columns, in views of their own (NiruxShellView+AgentLights).
        let accent = Theme.Color.accent.withAlphaComponent(0.7).cgColor
        for (wsIndex, workspace) in workspaces.enumerated() {
            for (colIndex, col) in workspace.columns.enumerated() {
                let isFocus = (wsIndex == activeWSIndex && colIndex == workspace.focusedIndex)
                col.setHeaderFocused(isFocus)
                col.view.layer?.cornerRadius = isFocus ? 6 : 0
                col.view.layer?.borderWidth = isFocus ? 2 : 0
                col.view.layer?.borderColor = isFocus ? accent : nil
            }
        }
    }
}
