import AppKit

// MARK: - Workspaces & Sidebar Toggle

extension NiruxShellView {
    enum VDir { case up, down }
    enum SpaceDir { case previous, next }

    var visibleWorkspaceIndices: [Int] { workspaceStore.visibleWorkspaceIndices }

    var activeVisibleWorkspacePosition: Int? { workspaceStore.activeVisibleWorkspacePosition }

    private var activeProfile: WorkspaceProfile { workspaceStore.activeProfile }

    func addWorkspace(
        title: String? = nil,
        cwd: String? = nil,
        agent: NiruxApp.WorkspaceAgent? = nil,
        profileID requestedProfileID: String? = nil,
        workspaceID: String = UUID().uuidString,
        initialAgentUUID: String = UUID().uuidString,
        missionID: String? = nil,
        deliveredHandover: Bool = false,
        worktreeBranch: String? = nil
    ) {
        let snapshot: NSImageView? = {
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

        let wsTitle = title ?? "ws \(workspaces.count + 1)"
        let wsCwd = cwd ?? sideEffects.homeDirectory()
        let targetProfileID = workspaceStore.targetProfileID(for: requestedProfileID)
        let workspace = WorkspaceState(
            id: workspaceID,
            title: wsTitle,
            cwd: wsCwd,
            profileID: targetProfileID,
            missionID: missionID,
            missionHandoffsEnabled: Self.currentMissionHandoffsEnabled(),
            initialAgentUUID: initialAgentUUID
        )
        wireWorkspace(workspace)
        workspaceStore.appendWorkspace(workspace)
        verticalStrip.addSubview(workspace.containerView)
        relayout(animated: false)
        updateSidebar()
        focusActiveTerminal(in: window)

        // Launch agent in the new workspace's terminal
        if let agent {
            launchAgent(agent, in: workspace, deliveredHandover: deliveredHandover, worktreeBranch: worktreeBranch)
        }

        if let snapshot {
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

    /// Startup prompt for a freshly launched agent. The handover line is
    /// only added when this very request delivered one: a handover file that
    /// merely exists in the folder (committed to the branch, left by an
    /// earlier session, shipped in a downloaded archive) is never followed.
    nonisolated static func agentStartupPrompt(
        agent: NiruxApp.WorkspaceAgent, deliveredHandover: Bool, isMission: Bool
    ) -> String? {
        var instructions: [String] = []
        if deliveredHandover {
            let handoverName = handoverFilename(for: agent)
            instructions.append("Read \(handoverName) for full context, then proceed with the next steps described there.")
        }
        if isMission {
            instructions.append(
                "This is a Nirux mission workspace. Ask the parent and wait safely with "
                + "\"$NIRUX_CLI_PATH\" --mission ask --message \"...\" "
                + "(at most \(MissionEventCLI.maxMessageLength) characters); the command output is the parent's answer. "
                + "It waits up to \(Int(MissionEventCLI.defaultWaitTimeout)) seconds, so allow it a shell-tool timeout "
                + "of at least 120 seconds. If it exits with status 3, or your shell tool stops it before it "
                + "prints anything, run the exact same command again: it resumes the same question. "
                + "Status 4 means the Mission is over; do not retry. Report the final result with "
                + "\"$NIRUX_CLI_PATH\" --mission completed --message \"...\"."
            )
        }
        return instructions.isEmpty ? nil : instructions.joined(separator: " ")
    }

    /// `worktreeBranch` is the branch read back from the checkout
    /// (`GitWorktree.currentBranch(at:)`) of a worktree workspace Nirux just
    /// opened; nil when unreadable, detached, or not a worktree workspace. It
    /// names the Claude session (see `SessionName`).
    private func launchAgent(
        _ agent: NiruxApp.WorkspaceAgent,
        in workspace: WorkspaceState,
        deliveredHandover: Bool,
        worktreeBranch: String?
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
                mode: NiruxShellView.currentClaudeLaunchMode(),
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
                mode: NiruxShellView.currentCodexLaunchMode(),
                briefFile: NiruxShellView.codexBriefFile(from: brief, launchDirectory: workspace.cwd),
                handoverPrompt: handoverPrompt
            )
        }

        sideEffects.launchAgent(col, cmd)
    }

    func focusWorkspace(_ dir: VDir) {
        let delta = dir == .up ? -1 : 1
        guard workspaceStore.selectAdjacentWorkspace(delta: delta) != nil else { return }
        refreshAfterWorkspaceSelection(animated: true)
    }

    func switchToWorkspace(_ index: Int, editorTakesKeyboard: Bool = true) {
        guard workspaceStore.selectWorkspace(at: index) else { return }
        refreshAfterWorkspaceSelection(animated: true, editorTakesKeyboard: editorTakesKeyboard)
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
        guard workspaces.indices.contains(activeWSIndex) else { return }
        workspaces[activeWSIndex].notification = nil
        quickSwitch.focusMoved()
        relayout(animated: animated)
        refreshGitContextNow(for: workspaces[activeWSIndex])
        // Headers of a workspace off screen weren't refreshed: bring
        // them (and their agent usage) up to date now, not on the next
        // heartbeat. Also refreshes the sidebar.
        refreshMetadata()
        focusActiveTerminal(in: window, editorTakesKeyboard: editorTakesKeyboard)
    }

    func selectProfile(_ profileID: String) {
        activateProfile(profileID, slideOutDirection: nil)
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

        // An empty space (spaces persist) gets a workspace when selected.
        if !workspaceStore.visibleWorkspaceIndices.isEmpty {
            refreshAfterWorkspaceSelection(animated: false)
        } else {
            addWorkspace(title: activeProfile.name, cwd: sideEffects.homeDirectory())
        }
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

    func createProfileFromActiveContext() {
        let sourceWorkspace = activeWorkspace
        let baseName = sourceWorkspace.flatMap { profileName(for: $0) } ?? "project"
        let cwd = sourceWorkspace?.focusedWorkingDirectory ?? sideEffects.homeDirectory()
        // Spaces persist: reuse an empty one of that name rather than pile up
        // "name 2", "name 3"…
        if let empty = profiles.first(where: { $0.name == baseName && workspaceStore.visibleWorkspaceIndices(in: $0.id).isEmpty }),
           workspaceStore.selectProfile(empty.id) {
            addWorkspace(title: empty.name, cwd: cwd)
            saveState()
            return
        }
        let profile = workspaceStore.createProfile(named: baseName)
        addWorkspace(title: profile.name, cwd: cwd)
        saveState()
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
        case .markActive:
            didChange = workspaceStore.setWorkspaceInactive(at: workspaceIndex, false)
            if didChange { workspaceStore.selectWorkspace(at: workspaceIndex) }
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
        case .newWorkspace:
            addWorkspace()
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
        if case .markActive = action {
            refreshGitContextNow(for: workspaces[workspaceIndex])
            refreshPRInfo(for: [workspaces[workspaceIndex]])
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

    private func profileName(for workspace: WorkspaceState) -> String {
        let name = (workspace.focusedWorkingDirectory as NSString).lastPathComponent
        return name.isEmpty ? workspace.title : name
    }

    // MARK: - Sidebar toggle

    func toggleSidebar() {
        let expanding = !isSidebarExpanded
        isSidebarExpanded = expanding
        saveState()

        if expanding {
            refreshOnboardingChecklist()
            sidebar.fadeOutRail {
                self.relayout(animated: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    // Collapsed again meanwhile: the rail stays.
                    guard let self, self.isSidebarExpanded else { return }
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

    func layoutWorkspaceStrip(_ layout: StripLayout) {
        let viewportW = layout.viewportW
        let rowH = layout.rowH
        let targetY = layout.targetY
        let animated = layout.animated

        let oldY = verticalStrip.frame.origin.y
        applyWorkspaceFrames(layout)
        for index in visibleWorkspaceIndices {
            workspaces[index].layoutAndScroll(viewportWidth: viewportW, height: rowH, animated: animated)
        }
        // Animated path: add a vertical slide over the direct frame change.
        if animated, let layer = verticalStrip.layer, oldY != targetY {
            let anim = CABasicAnimation(keyPath: "transform.translation.y")
            anim.fromValue = oldY - targetY
            anim.toValue = 0
            anim.duration = 0.3
            anim.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1)
            anim.isRemovedOnCompletion = true
            layer.add(anim, forKey: "wsSlide")
        }

        // Focus border and header icon — attention borders are managed by updateSidebar()
        let accent = Theme.Color.accent.withAlphaComponent(0.7).cgColor
        for (wsIndex, workspace) in workspaces.enumerated() {
            for (colIndex, col) in workspace.columns.enumerated() {
                let isFocus = (wsIndex == activeWSIndex && colIndex == workspace.focusedIndex)
                col.setHeaderFocused(isFocus)
                if col.view.layer?.animation(forKey: "attentionPulse") == nil {
                    col.view.layer?.cornerRadius = isFocus ? 6 : 0
                    col.view.layer?.borderWidth = isFocus ? 2 : 0
                    col.view.layer?.borderColor = isFocus ? accent : nil
                }
            }
        }
    }
}
