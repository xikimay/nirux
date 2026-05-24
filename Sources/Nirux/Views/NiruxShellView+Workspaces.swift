import AppKit

// MARK: - Workspaces & Sidebar Toggle

extension NiruxShellView {
    enum VDir { case up, down }
    enum SpaceDir { case previous, next }

    var visibleWorkspaceIndices: [Int] { workspaceStore.visibleWorkspaceIndices }

    var activeVisibleWorkspacePosition: Int? { workspaceStore.activeVisibleWorkspacePosition }

    private var activeProfile: WorkspaceProfile { workspaceStore.activeProfile }

    func addWorkspace(title: String? = nil, cwd: String? = nil, agent: NiruxApp.WorkspaceAgent? = nil) {
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
        let wsCwd = cwd ?? NSHomeDirectory()
        let workspace = WorkspaceState(title: wsTitle, cwd: wsCwd)
        workspace.profileID = activeProfileID
        workspace.onMetadataChanged = { [weak self] in self?.updateSidebar(); self?.refreshTitleBarLabels() }
        workspace.onDiffStatsClicked = { [weak self, weak workspace] in
            guard let workspace else { return }
            self?.openDiffInEditor(for: workspace)
        }
        workspaceStore.appendWorkspace(workspace)
        verticalStrip.addSubview(workspace.containerView)
        if isPilotMode { workspace.createPilotPanel() }
        relayout(animated: false)
        updateSidebar()
        focusActiveTerminal(in: window)

        // Launch agent in the new workspace's terminal
        if let agent {
            launchAgent(agent, in: workspace)
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

    private func launchAgent(_ agent: NiruxApp.WorkspaceAgent, in workspace: WorkspaceState) {
        guard let col = workspace.columns[safe: workspace.focusedIndex] else { return }
        let handoverName = Self.handoverFilename(for: agent)
        let handoverPath = workspace.cwd + "/\(handoverName)"
        let hasHandover = FileManager.default.fileExists(atPath: handoverPath)

        let cmd: String
        switch agent {
        case .claude:
            let prompt = hasHandover
                ? "Read \(handoverName) for full context, then proceed with the next steps described there."
                : nil
            cmd = NiruxShellView.claudeCommand(
                mode: NiruxShellView.currentClaudeLaunchMode(),
                handoverPrompt: prompt
            )
        case .codex:
            let prompt = hasHandover
                ? "Read \(handoverName) for full context, then proceed with the next steps described there."
                : nil
            cmd = NiruxShellView.codexCommand(
                mode: NiruxShellView.currentCodexLaunchMode(),
                handoverPrompt: prompt
            )
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            col.pty?.sendRaw("\(cmd)\n")
        }
    }

    /// Shared entry point: create a git worktree, move an optional handover file into it, and open a workspace.
    /// Used by both the `nirux://new-worktree` URL scheme and the WorktreePanel.
    func createWorktreeWorkspace(branch: String, repoRoot: String, agent: NiruxApp.WorkspaceAgent? = .claude, handoverPath: String? = nil) {
        DispatchQueue.global(qos: .userInitiated).async {
            let (path, error) = GitWorktree.create(branch: branch, repoRoot: repoRoot)
            // Move handover file into the worktree if provided
            if let path, let handoverPath, FileManager.default.fileExists(atPath: handoverPath) {
                let dest = path + "/\(Self.handoverFilename(for: agent ?? .claude))"
                try? FileManager.default.removeItem(atPath: dest)
                try? FileManager.default.moveItem(atPath: handoverPath, toPath: dest)
            }
            DispatchQueue.main.async { [weak self] in
                if let path {
                    self?.addWorkspace(title: branch, cwd: path, agent: agent)
                } else {
                    NSLog("[Worktree] Failed to create worktree for \(branch): \(error ?? "unknown")")
                }
            }
        }
    }

    nonisolated static func handoverFilename(for agent: NiruxApp.WorkspaceAgent) -> String {
        switch agent {
        case .claude: return ".claude-handover.md"
        case .codex: return ".codex-handover.md"
        }
    }

    func focusWorkspace(_ dir: VDir) {
        let delta = dir == .up ? -1 : 1
        guard workspaceStore.selectAdjacentWorkspace(delta: delta) != nil else { return }
        refreshAfterWorkspaceSelection(animated: true)
    }

    func switchToWorkspace(_ index: Int) {
        guard workspaceStore.selectWorkspace(at: index) else { return }
        refreshAfterWorkspaceSelection(animated: true)
    }

    private func refreshAfterWorkspaceSelection(animated: Bool) {
        guard workspaces.indices.contains(activeWSIndex) else { return }
        workspaces[activeWSIndex].hasNotification = false
        relayout(animated: animated)
        workspaces[activeWSIndex].detectGitBranch()
        updateSidebar()
        focusActiveTerminal(in: window)
    }

    func closeWorkspace(at index: Int) {
        guard workspaces.count > 1 else { return }

        let wsToRemove = workspaces[index]
        if let target = workspaceStore.fallbackIndexAfterClosingWorkspace(at: index) {
            workspaceStore.selectWorkspace(at: target)
        }
        relayout(animated: true)
        updateSidebar()
        focusActiveTerminal(in: window)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self else { return }
            guard let removed = self.workspaceStore.removeWorkspace(wsToRemove) else { return }

            if self.isPilotMode {
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.25
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    removed.containerView.animator().alphaValue = 0
                }, completionHandler: {
                    DispatchQueue.main.async {
                        removed.containerView.removeFromSuperview()
                    }
                })
                self.relayout(animated: true)
            } else {
                removed.containerView.removeFromSuperview()
                self.relayout(animated: false)
            }
            self.updateSidebar()
        }
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

        if activeWorkspace != nil {
            refreshAfterWorkspaceSelection(animated: false)
        } else {
            addWorkspace(title: activeProfile.name, cwd: NSHomeDirectory())
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
        let baseName = sourceWorkspace.flatMap { profileName(for: $0) } ?? "profile"
        let cwd = sourceWorkspace.flatMap { workspace in
            workspace.columns[safe: workspace.focusedIndex]?.pty?.childCwd
                ?? workspace.columns.first?.pty?.childCwd
                ?? workspace.cwd
        } ?? NSHomeDirectory()
        let profile = workspaceStore.createProfile(named: baseName)
        addWorkspace(title: profile.name, cwd: cwd)
        saveState()
    }

    func handleWorkspaceSidebarAction(_ action: WorkspaceSidebarAction, workspaceIndex: Int) {
        guard workspaces.indices.contains(workspaceIndex) else { return }
        let didChange: Bool
        switch action {
        case .moveUp:
            didChange = workspaceStore.moveWorkspace(at: workspaceIndex, delta: -1)
        case .moveDown:
            didChange = workspaceStore.moveWorkspace(at: workspaceIndex, delta: 1)
        case .markActive:
            didChange = workspaceStore.setWorkspaceInactive(at: workspaceIndex, false)
            if didChange { workspaceStore.selectWorkspace(at: workspaceIndex) }
        case .markInactive:
            didChange = workspaceStore.setWorkspaceInactive(at: workspaceIndex, true)
        }
        guard didChange else { return }
        relayout(animated: true)
        updateSidebar()
        focusActiveTerminal(in: window)
        saveState()
    }

    private func profileName(for workspace: WorkspaceState) -> String {
        if let cwd = workspace.columns[safe: workspace.focusedIndex]?.pty?.childCwd ?? workspace.columns.first?.pty?.childCwd {
            return (cwd as NSString).lastPathComponent
        }
        return workspace.title
    }


    // MARK: - Sidebar toggle

    func toggleSidebar() {
        guard !isPilotMode else { return }
        let expanding = !isSidebarExpanded
        isSidebarExpanded = expanding

        if expanding {
            sidebar.fadeOutDots {
                self.relayout(animated: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    guard let self else { return }
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
        let viewportW, viewportH, totalH, rowH, gap, targetY: CGFloat
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
        sidebar.isHidden = isPilotMode
        divider.isHidden = isPilotMode
        columnIndicator.isHidden = isPilotMode
    }

    /// Compute the target frame for each workspace container and the strip
    /// that holds them, applying them either directly or via `.animator()`.
    /// Column contents are laid out separately so that animated pilot-mode
    /// resizing can slide the containers first.
    private func applyWorkspaceFrames(_ layout: StripLayout, useAnimator: Bool) {
        let stripFrame = NSRect(x: 0, y: layout.targetY, width: layout.viewportW, height: layout.totalH)
        if useAnimator {
            verticalStrip.animator().frame = stripFrame
        } else {
            verticalStrip.frame = stripFrame
        }
        let visible = visibleWorkspaceIndices
        let visibleSet = Set(visible)
        for (index, workspace) in workspaces.enumerated() {
            workspace.containerView.isHidden = !visibleSet.contains(index)
        }
        for (position, index) in visible.enumerated() {
            let workspace = workspaces[index]
            let wsY = layout.totalH - CGFloat(position + 1) * layout.rowH - CGFloat(position) * layout.gap
            let wsFrame = NSRect(x: 0, y: wsY, width: layout.viewportW, height: layout.rowH)
            if useAnimator {
                workspace.containerView.animator().frame = wsFrame
            } else {
                workspace.containerView.frame = wsFrame
            }
        }
    }

    func layoutWorkspaceStrip(_ layout: StripLayout) {
        let viewportW = layout.viewportW
        let rowH = layout.rowH
        let targetY = layout.targetY
        let animated = layout.animated

        if animated && isPilotMode {
            // Pilot mode: animate workspace containers first, then layout columns after
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                self.applyWorkspaceFrames(layout, useAnimator: true)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self else { return }
                for index in self.visibleWorkspaceIndices {
                    self.workspaces[index].layoutAndScroll(viewportWidth: viewportW, height: rowH, animated: true, pilotMode: self.isPilotMode)
                }
            }
        } else {
            let oldY = verticalStrip.frame.origin.y
            applyWorkspaceFrames(layout, useAnimator: false)
            for index in visibleWorkspaceIndices {
                workspaces[index].layoutAndScroll(viewportWidth: viewportW, height: rowH, animated: animated, pilotMode: isPilotMode)
            }
            // Normal-mode animated path: add a vertical slide over the direct frame change.
            if animated, let layer = verticalStrip.layer, oldY != targetY {
                let anim = CABasicAnimation(keyPath: "transform.translation.y")
                anim.fromValue = oldY - targetY
                anim.toValue = 0
                anim.duration = 0.3
                anim.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1)
                anim.isRemovedOnCompletion = true
                layer.add(anim, forKey: "wsSlide")
            }
        }

        // Focus border only — attention borders are managed by updateSidebar()
        let accent = NSColor.niruxAccent.withAlphaComponent(0.7).cgColor
        for (wsIndex, workspace) in workspaces.enumerated() {
            for (colIndex, col) in workspace.columns.enumerated() {
                let isFocus = (wsIndex == activeWSIndex && colIndex == workspace.focusedIndex)
                if col.view.layer?.animation(forKey: "attentionPulse") == nil {
                    let targetRadius: CGFloat = isFocus ? 6 : 0
                    let targetWidth: CGFloat = isFocus ? 2 : 0
                    let targetColor: CGColor? = isFocus ? accent : nil

                    if isPilotMode, let layer = col.view.layer {
                        let dur = 0.25
                        let timing = CAMediaTimingFunction(name: .easeInEaseOut)
                        if layer.cornerRadius != targetRadius {
                            let anim = CABasicAnimation(keyPath: "cornerRadius")
                            anim.toValue = targetRadius; anim.duration = dur; anim.timingFunction = timing
                            layer.add(anim, forKey: "cornerFade")
                        }
                        if layer.borderWidth != targetWidth {
                            let anim = CABasicAnimation(keyPath: "borderWidth")
                            anim.toValue = targetWidth; anim.duration = dur; anim.timingFunction = timing
                            layer.add(anim, forKey: "borderFade")
                        }
                        if layer.borderColor != targetColor {
                            let anim = CABasicAnimation(keyPath: "borderColor")
                            anim.toValue = targetColor; anim.duration = dur; anim.timingFunction = timing
                            layer.add(anim, forKey: "borderColorFade")
                        }
                    }

                    col.view.layer?.cornerRadius = targetRadius
                    col.view.layer?.borderWidth = targetWidth
                    col.view.layer?.borderColor = targetColor
                }
            }
        }

        updatePilotOverlays(vpW: viewportW, totalH: layout.totalH, rowH: rowH, gap: layout.gap)
    }

    // MARK: - Pilot Mode

    func togglePilotMode() {
        if isSidebarExpanded {
            sidebar.isHidden = true
            isSidebarExpanded = false
            sidebar.isExpanded = false
        }

        let snapshot = NSView(frame: bounds)
        snapshot.wantsLayer = true
        if let bitmapRep = bitmapImageRepForCachingDisplay(in: bounds) {
            cacheDisplay(in: bounds, to: bitmapRep)
            snapshot.layer?.contents = bitmapRep.cgImage
        } else {
            snapshot.layer?.backgroundColor = (layer?.backgroundColor) ?? NSColor.black.cgColor
        }
        addSubview(snapshot)

        isPilotMode.toggle()
        if isPilotMode {
            for workspace in workspaces { workspace.createPilotPanel() }
        } else {
            for workspace in workspaces { workspace.hidePilotPanel() }
        }
        relayout(animated: false)
        updateSidebar()
        focusActiveTerminal(in: window)

        if isPilotMode {
            pilotClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                self?.handlePilotClick(event) ?? event
            }
            pilotHoverMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
                self?.handlePilotHover(event)
                return event
            }
            startPilotRefresh()
        } else {
            if let monitor = pilotClickMonitor {
                NSEvent.removeMonitor(monitor)
                pilotClickMonitor = nil
            }
            if let monitor = pilotHoverMonitor {
                NSEvent.removeMonitor(monitor)
                pilotHoverMonitor = nil
            }
            stopPilotRefresh()
        }

        DispatchQueue.main.async { [weak self] in
            self?.redrawAllTerminals()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.redrawAllTerminals()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                snapshot.animator().alphaValue = 0
            } completionHandler: {
                DispatchQueue.main.async {
                    snapshot.removeFromSuperview()
                }
            }
        }
    }

    /// Start the 1.5s pilot sidebar refresh. Caller is responsible for
    /// ensuring we're currently in pilot mode — this only schedules the
    /// timer, it doesn't toggle pilot mode itself.
    func startPilotRefresh() {
        guard pilotRefreshTimer == nil else { return }
        pilotRefreshTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isPilotMode else { return }
                let snap = ProcessSnapshot()
                self.updateSidebar(snapshot: snap)
            }
        }
    }

    /// Stop the pilot sidebar refresh. Idempotent.
    func stopPilotRefresh() {
        pilotRefreshTimer?.invalidate()
        pilotRefreshTimer = nil
    }

    func handlePilotClick(_ event: NSEvent) -> NSEvent? {
        guard isPilotMode else { return event }
        let windowLoc = event.locationInWindow
        let vpLoc = viewport.convert(windowLoc, from: nil)
        guard viewport.bounds.contains(vpLoc) else { return event }

        // 1. Check pilot panel clickable areas (PR links, etc.)
        for index in visibleWorkspaceIndices where workspaces[index].handlePilotPanelClick(windowPoint: windowLoc) {
            return nil
        }

        // 2. Check pilot panel column clicks (window title granularity)
        for index in visibleWorkspaceIndices {
            let workspace = workspaces[index]
            if let colIndex = workspace.handlePilotColumnClick(windowPoint: windowLoc) {
                if index != activeWSIndex {
                    workspace.focusedIndex = colIndex
                    switchToWorkspace(index)
                } else if workspace.focusedIndex != colIndex {
                    workspace.focusedIndex = colIndex
                    relayout(animated: true)
                    updateSidebar()
                    focusActiveTerminal(in: window)
                }
                return nil
            }
        }

        // 3. Check for clicks on non-active workspace containers
        for index in visibleWorkspaceIndices where index != activeWSIndex {
            let workspace = workspaces[index]
            let containerLoc = workspace.containerView.convert(windowLoc, from: nil)
            guard workspace.containerView.bounds.contains(containerLoc) else { continue }

            for (colIndex, col) in workspace.columns.enumerated() {
                let colLoc = col.view.convert(windowLoc, from: nil)
                if col.view.bounds.contains(colLoc) {
                    workspace.focusedIndex = colIndex
                    break
                }
            }
            switchToWorkspace(index)
            return nil
        }
        return event
    }

    func handlePilotHover(_ event: NSEvent) {
        guard isPilotMode else { return }
        let windowLoc = event.locationInWindow
        for index in visibleWorkspaceIndices where workspaces[index].handlePilotPanelHover(windowPoint: windowLoc) {
            NSCursor.pointingHand.set()
            return
        }
        NSCursor.arrow.set()
    }

    // MARK: - Pilot Mode Overlays

    func updatePilotOverlays(vpW: CGFloat, totalH: CGFloat, rowH: CGFloat, gap: CGFloat) {
        // Remove non-highlight overlays
        for overlay in pilotOverlays where overlay !== pilotActiveHighlight {
            overlay.removeFromSuperview()
        }
        pilotOverlays.removeAll()

        guard isPilotMode else {
            pilotActiveHighlight?.removeFromSuperview()
            pilotActiveHighlight = nil
            statusBar.clearPilotHints()
            return
        }

        // Active workspace highlight — persistent view with animated position
        let activePosition = activeVisibleWorkspacePosition ?? 0
        let wsY = totalH - CGFloat(activePosition + 1) * rowH - CGFloat(activePosition) * gap
        let targetFrame = NSRect(x: 0, y: wsY, width: vpW, height: rowH)

        if let highlight = pilotActiveHighlight {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                highlight.animator().frame = targetFrame
            }
        } else {
            let highlight = NSView(frame: targetFrame)
            highlight.wantsLayer = true
            highlight.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.03).cgColor
            highlight.layer?.cornerRadius = 8
            verticalStrip.addSubview(highlight, positioned: .below, relativeTo: verticalStrip.subviews.first)
            pilotActiveHighlight = highlight
        }
        pilotOverlays.append(pilotActiveHighlight!)

        statusBar.setPilotHints("\u{2318}\u{2191}\u{2193} workspace  \u{2318}\u{2190}\u{2192} column  \u{2318}T new  \u{2318}O exit pilot")
    }
}
