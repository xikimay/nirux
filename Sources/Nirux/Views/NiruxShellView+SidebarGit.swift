import AppKit

// MARK: - Sidebar, Git, PR, Terminal Redraw, Status Bar

extension NiruxShellView {
    func updateSidebar(snapshot: ProcessSnapshot? = nil) {
        let snapshot = snapshot ?? ProcessSnapshot()
        let processTableRead = !snapshot.isEmpty
        let now = Date().timeIntervalSince1970
        let visibleIndices = visibleWorkspaceIndices
        let parents = workspaceStore.activeParents(in: activeProfileID)
        let (foregroundProcesses, invalidatedSessionBinding) = followForegroundProcesses(snapshot: snapshot, now: now)
        let approvalHolds = releaseApprovalsNotHeld()
        let missionQuestions = missionQuestions(foreground: { foregroundProcesses[ObjectIdentifier($0)] }, now: now)
        noteMissionQuestionHandOffs(missionQuestions)
        let infos = visibleIndices.map { index in
            let workspace = workspaces[index]
            let isActive = index == activeWSIndex
            let colInfos = workspace.columns.enumerated().map { colIndex, col in
                let isUserFocused = colIndex == workspace.focusedIndex && isActive
                let foregroundProcess = foregroundProcesses[ObjectIdentifier(col)]
                // Read on screen: the question its turn ended on is seen.
                if isUserFocused, NSApp.isActive { col.pty?.noteAgentSeen() }
                let editorFile = col.editorColumn?.currentPath.map {
                    ($0 as NSString).lastPathComponent
                }
                let agentStatus = col.pty?.agentStatus(
                    foregroundProcess: foregroundProcess,
                    isUserFocused: isUserFocused,
                    processTableRead: processTableRead,
                    claudeFiredHooks: foregroundProcess.map { col.claudeHooksFired(by: $0.instance) } ?? false
                ) ?? .idle
                let permissionApproval = sidebarApproval(for: col, hold: approvalHolds[ObjectIdentifier(col)])
                return ColumnInfo(
                    index: colIndex,
                    processName: foregroundProcess?.name,
                    abbreviatedCwd: col.pty?.childCwd?.abbreviatedPath(),
                    isFocused: isUserFocused,
                    isWebView: col.isWebView,
                    webTitle: col.webViewColumn?.pageTitle,
                    terminalTitle: col.terminalTitle,
                    agentStatus: agentStatus,
                    isEditor: col.isEditor,
                    editorFileName: editorFile,
                    isProjectBoard: col.isProjectBoard,
                    isBranchReview: col.isBranchReview,
                    editorIsDirty: col.editorColumn?.isDirty ?? false,
                    agentElapsedSeconds: col.pty?.agentTurnStartedAt
                        .map { Date().timeIntervalSince($0) },
                    attentionReason: agentStatus == .needsAttention ? col.pty?.agentAttentionReason : nil,
                    permissionApproval: permissionApproval,
                    // The Project Board's rule: an approved dialog stays
                    // listed while its tool runs, the column working.
                    // A question waits even while subagents work, as the
                    // header and ⌘J say.
                    openDialog: (agentStatus == .working ? nil
                        : col.pty?.agentVisibleDialog(foreground: foregroundProcess)?.reason)
                        ?? col.pty?.agentAskedQuestion(foreground: foregroundProcess),
                    stuck: sidebarStuckState(of: col, foregroundProcess: foregroundProcess, snapshot: snapshot, now: now),
                    deferredAgent: Self.sidebarDeferredAgent(of: col),
                    missionQuestion: missionQuestions[ObjectIdentifier(col)],
                    id: col.id
                )
            }
            return WorkspaceInfo(id: workspace.id, index: index, title: workspace.title,
                          profileID: workspace.profileID, isInactive: workspace.isInactive,
                          columnCount: workspace.columns.count,
                          focusedColumn: workspace.focusedIndex,
                          gitBranch: workspace.gitBranch, notification: workspace.notification, isActive: index == activeWSIndex,
                          columns: colInfos, prInfo: workspace.prInfo, prFeedback: workspace.prFeedback?.sidebarCounts,
                          diffStats: workspace.diffStats,
                          purpose: workspace.purpose, nextStep: workspace.nextStep,
                          blocker: workspace.blocker, phase: workspace.effectivePhase,
                          lastSummary: workspace.lastSummary, lastActivityAt: workspace.lastActivityAt,
                          reviewBadges: workspace.reviewBadges,
                          mergedCleanup: mergedCleanupOffer(workspaceIndex: index),
                          isLead: workspace.isLead,
                          parentTitle: parents[index].map { workspaces[$0].title })
        }
        tickHiddenSpaceAgents(
            visibleIndices: visibleIndices, foregroundProcesses: foregroundProcesses, processTableRead: processTableRead
        )
        updateColumnHeaders(infos: infos, foregroundProcesses: foregroundProcesses, now: now)
        let profileInfos = workspaceStore.navigableProfiles.map { profile in
            let profileWorkspaces = workspaces.filter { $0.profileID == profile.id }
            return ProfileInfo(
                id: profile.id,
                name: profile.name,
                colorHex: profile.colorHex,
                isActive: profile.id == activeProfileID,
                workspaceCount: profileWorkspaces.count,
                taskCount: profileWorkspaces.filter { !$0.isInactive }.count,
                // The space on screen: what its cards say. Another one: the
                // same rule, read off its columns.
                attention: profile.id == activeProfileID
                    ? infos.compactMap(\.attention).max()
                    : profileWorkspaces.compactMap {
                        Self.attention(
                            of: $0, foregroundProcesses: foregroundProcesses, missionQuestions: missionQuestions, now: now
                        )
                    }.max()
            )
        }
        sidebar.update(profiles: profileInfos, workspaces: infos)
        // A rename or a repository added changes what an empty space says.
        refreshEmptySpaceView()
        updateSidebarAttention(infos: infos, missionQuestions: missionQuestions)
        if invalidatedSessionBinding { saveState(snapshot: snapshot) }
        refreshProjectBoards(snapshot: snapshot, now: now, foregroundProcesses: foregroundProcesses)
    }

    /// Every column's foreground process, shown or not, and what follows
    /// from it before statuses are read: session bindings of a replaced
    /// agent, stuck agents (the one in another space is the one nobody
    /// watches). True when a binding changed and state must be saved.
    private func followForegroundProcesses(
        snapshot: ProcessSnapshot,
        now: TimeInterval
    ) -> ([ObjectIdentifier: ForegroundProcess], Bool) {
        var foregroundProcesses: [ObjectIdentifier: ForegroundProcess] = [:]
        var invalidatedSessionBinding = false
        for workspace in workspaces {
            for column in workspace.columns {
                let foregroundProcess = column.pty?.foregroundProcess(snapshot: snapshot)
                if let foregroundProcess {
                    foregroundProcesses[ObjectIdentifier(column)] = foregroundProcess
                }
                if column.invalidateAgentSessionsIfProcessChanged(
                    foregroundProcess: foregroundProcess
                ) {
                    invalidatedSessionBinding = true
                }
                refreshStuckAgent(
                    column, in: workspace,
                    foregroundProcess: foregroundProcess, snapshot: snapshot, now: now
                )
            }
        }
        closeEndedAgentSessions(now: now)
        return (foregroundProcesses, invalidatedSessionBinding)
    }

    /// The terminal headers show their agent as the sidebar reads it, and
    /// what blocks it on the user as ⌘J does.
    private func updateColumnHeaders(
        infos: [WorkspaceInfo], foregroundProcesses: [ObjectIdentifier: ForegroundProcess], now: TimeInterval
    ) {
        for info in infos {
            guard let workspace = workspaces[safe: info.index] else { continue }
            for column in info.columns {
                guard let state = workspace.columns[safe: column.index], state.pty != nil else { continue }
                let wait = state.pty?.agentBlockedWait(now: now, foreground: foregroundProcesses[ObjectIdentifier(state)])
                state.updateHeaderAgentState(column, wait: wait, now: now)
            }
        }
    }

    /// The other spaces' columns tick too, unfocused: the space dots, the
    /// Dock badge and keep-awake read their status, which would otherwise
    /// stay frozen from when the space was last on screen — an agent
    /// without hooks "working" long after it went quiet.
    private func tickHiddenSpaceAgents(
        visibleIndices: [Int],
        foregroundProcesses: [ObjectIdentifier: ForegroundProcess],
        processTableRead: Bool
    ) {
        let visible = Set(visibleIndices)
        for (index, workspace) in workspaces.enumerated() where !visible.contains(index) {
            for column in workspace.columns {
                let foregroundProcess = foregroundProcesses[ObjectIdentifier(column)]
                _ = column.pty?.agentStatus(
                    foregroundProcess: foregroundProcess,
                    isUserFocused: false,
                    processTableRead: processTableRead,
                    claudeFiredHooks: foregroundProcess.map { column.claudeHooksFired(by: $0.instance) } ?? false
                )
            }
        }
    }

    /// `WorkspaceInfo.attention` for a workspace of another space, which
    /// has no card: what blocks its agents (a dialog on screen, a failed
    /// turn, an exit mid-turn), their attention, and what happened while
    /// the user was away.
    private static func attention(
        of workspace: WorkspaceState,
        foregroundProcesses: [ObjectIdentifier: ForegroundProcess],
        missionQuestions: [ObjectIdentifier: SidebarMissionQuestion],
        now: TimeInterval
    ) -> AttentionSignal? {
        var signals: [AttentionSignal] = []
        for column in workspace.columns {
            if missionQuestions[ObjectIdentifier(column)]?.handOff != nil { signals.append(.waiting) }
            guard let pty = column.pty else { continue }
            let status = pty.cachedAgentState
            if let wait = pty.agentBlockedWait(now: now, foreground: foregroundProcesses[ObjectIdentifier(column)]),
               wait.reason.signal != .waiting || status != .working {
                signals.append(wait.reason.signal)
            }
            if status == .needsAttention { signals.append(AttentionSignal.of(pty.agentAttentionReason)) }
        }
        if let notification = workspace.notification { signals.append(notification) }
        return signals.max()
    }

    private func updateSidebarAttention(infos: [WorkspaceInfo], missionQuestions: [ObjectIdentifier: SidebarMissionQuestion]) {
        // Dock badge: workspaces currently waiting for attention.
        let attentionCount = workspaces.filter { workspace in
            workspace.hasNotification
                || workspace.columns.contains { column in
                    Self.countsInDockBadge(
                        agentState: column.pty?.cachedAgentState, reason: column.pty?.agentAttentionReason,
                        isQuietTurnEnd: column.pty?.isQuietTurnEnd ?? false,
                        missionQuestion: missionQuestions[ObjectIdentifier(column)]
                    )
                }
        }.count
        NiruxNotifier.shared.updateDockBadge(attentionCount: attentionCount)
        // Same source, the other way: agents still working.
        updateKeepAwake()

        if let workspace = activeWorkspace,
           let wsInfo = infos.first(where: { $0.index == activeWSIndex }) {
            columnIndicator.update(
                columnCount: workspace.columns.count, focusedIndex: workspace.focusedIndex,
                columnSignals: wsInfo.columns.map(\.offScreenAttention)
            )

            // Horizontal edge glow: a column left/right of the focused one
            // waits on the user or broke.
            let focused = workspace.focusedIndex
            edgeGlowLeft.show(Self.alert(in: wsInfo.columns.enumerated().filter { $0.offset < focused }.map(\.element)))
            edgeGlowRight.show(Self.alert(in: wsInfo.columns.enumerated().filter { $0.offset > focused }.map(\.element)))
        } else {
            // An empty space: no columns to point at.
            columnIndicator.update(columnCount: 0, focusedIndex: 0)
            edgeGlowLeft.show(nil)
            edgeGlowRight.show(nil)
        }

        // Vertical edge glow: a workspace above/below the active one
        let activePosition = infos.firstIndex { $0.index == activeWSIndex } ?? 0
        edgeGlowTop.show(Self.alert(in: infos.prefix(activePosition).flatMap(\.columns)))
        edgeGlowBottom.show(Self.alert(in: infos.dropFirst(activePosition + 1).flatMap(\.columns)))

        updateAttentionBorders(infos: infos)
    }

    /// Whether a column counts in the Dock badge: its agent waits on the
    /// user. Not a Claude turn end that hasn't alerted (its verdict is on
    /// its way, or it found the turn done), nor a Mission child that ended
    /// its turn to wait on its parent.
    static func countsInDockBadge(
        agentState: AgentStatus?,
        reason: AgentAttentionReason?,
        isQuietTurnEnd: Bool,
        missionQuestion: SidebarMissionQuestion?
    ) -> Bool {
        if missionQuestion?.handOff != nil { return true }
        guard agentState == .needsAttention, !isQuietTurnEnd else { return false }
        return missionQuestion == nil || reason?.isTurnEnd != true
    }

    /// The most urgent wait or error among `columns` while the user looks
    /// elsewhere; a finished turn doesn't glow.
    private static func alert(in columns: [ColumnInfo]) -> AttentionSignal? {
        columns.compactMap(\.offScreenAttention).filter { $0 != .finished }.max()
    }

    /// A pulsing border on columns that wait on the user (amber) or broke
    /// (red); a finished turn gets none.
    private func updateAttentionBorders(infos: [WorkspaceInfo]) {
        let infoByIndex = Dictionary(uniqueKeysWithValues: infos.map { ($0.index, $0) })
        for (wsIndex, workspace) in workspaces.enumerated() {
            for (colIndex, col) in workspace.columns.enumerated() {
                let signal = infoByIndex[wsIndex]?.columns[safe: colIndex]
                    .flatMap { Self.alert(in: [$0]) }
                let colLayer = col.view.layer
                if let signal {
                    let color = SidebarRenderer.color(for: signal)
                    let attentionBorder = color.cgColor
                    // A wait that turns into an error pulses red from then on.
                    if colLayer?.borderColor != attentionBorder { colLayer?.removeAnimation(forKey: "attentionPulse") }
                    colLayer?.cornerRadius = 6
                    colLayer?.borderWidth = 2
                    colLayer?.borderColor = attentionBorder
                    if colLayer?.animation(forKey: "attentionPulse") == nil {
                        let pulse = CABasicAnimation(keyPath: "borderColor")
                        pulse.fromValue = attentionBorder
                        pulse.toValue = color.withAlphaComponent(0.15).cgColor
                        pulse.duration = 0.6
                        pulse.autoreverses = true
                        pulse.repeatCount = .infinity
                        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                        colLayer?.add(pulse, forKey: "attentionPulse")
                    }
                } else if colLayer?.animation(forKey: "attentionPulse") != nil {
                    colLayer?.removeAnimation(forKey: "attentionPulse")
                    // Restore focus border if this is the focused column
                    let isFocus = (wsIndex == activeWSIndex && colIndex == workspace.focusedIndex)
                    let accent = Theme.Color.accent.withAlphaComponent(0.7).cgColor
                    colLayer?.cornerRadius = isFocus ? 6 : 0
                    colLayer?.borderWidth = isFocus ? 2 : 0
                    colLayer?.borderColor = isFocus ? accent : nil
                }
            }
        }
    }

    func clearAllAgentAttention() {
        // Called from `didBecomeActiveNotification`. Must stay cheap — the
        // full `updateSidebar()` does a `sysctl(KERN_PROC_ALL)` plus a
        // `proc_pidinfo` per column, and on resume that can land in the same
        // tick as Metal restoring every Ghostty surface, freezing the UI for
        // seconds when many agents are running. Just clear the flags and the
        // attention borders directly; the next heartbeat (2s) refreshes the
        // sidebar with fresh process info.
        NiruxNotifier.shared.updateDockBadge(attentionCount: 0)
        NiruxNotifier.shared.clearDelivered()
        for (wsIndex, workspace) in workspaces.enumerated() {
            workspace.notification = nil
            for (colIndex, col) in workspace.columns.enumerated() {
                col.pty?.clearAgentAttention()
                let colLayer = col.view.layer
                guard colLayer?.animation(forKey: "attentionPulse") != nil else { continue }
                colLayer?.removeAnimation(forKey: "attentionPulse")
                let isFocus = (wsIndex == activeWSIndex && colIndex == workspace.focusedIndex)
                let accent = Theme.Color.accent.withAlphaComponent(0.7).cgColor
                colLayer?.cornerRadius = isFocus ? 6 : 0
                colLayer?.borderWidth = isFocus ? 2 : 0
                colLayer?.borderColor = isFocus ? accent : nil
            }
        }
    }

    private static let flashOverlayID = NSUserInterfaceItemIdentifier("nirux.focusFlashOverlay")

    /// One-shot border pulse on a column — click feedback for notification
    /// click-through, which is otherwise a visual no-op when the target is
    /// already focused. Runs as an overlay so it can't
    /// clobber the focus border or the attention pulse. The overlay's model
    /// opacity is 0: if the animation never runs or is dropped (layer
    /// rebuilt, view detached mid-flash), the failure mode is an invisible
    /// view, never a stuck border — and a delayed backstop removes it even
    /// if the CATransaction completion is lost.
    func flashColumnBorder(workspaceIndex: Int, columnIndex: Int?) {
        guard let workspace = workspaces[safe: workspaceIndex] else { return }
        let colIndex = columnIndex.flatMap { workspace.columns.indices.contains($0) ? $0 : nil }
            ?? workspace.focusedIndex
        guard let col = workspace.columns[safe: colIndex] else { return }

        // A notification storm can flash the same column repeatedly —
        // never stack overlays.
        col.view.subviews.filter { $0.identifier == Self.flashOverlayID }
            .forEach { $0.removeFromSuperview() }

        let overlay = SidebarBackgroundView(frame: col.view.bounds)
        overlay.identifier = Self.flashOverlayID
        overlay.autoresizingMask = [.width, .height]
        overlay.wantsLayer = true
        overlay.layer?.cornerRadius = 6
        overlay.layer?.borderWidth = 3
        overlay.layer?.borderColor = Theme.Color.accent.cgColor
        overlay.layer?.opacity = 0
        col.view.addSubview(overlay)

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak overlay] in
            overlay?.removeFromSuperview()
        }
        let blink = CABasicAnimation(keyPath: "opacity")
        blink.fromValue = 1.0
        blink.toValue = 0.0
        blink.duration = 0.3
        blink.repeatCount = 2
        overlay.layer?.add(blink, forKey: "focusFlash")
        CATransaction.commit()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak overlay] in
            overlay?.removeFromSuperview()
        }
    }

    func applyAgentHookEvents(_ events: [AgentHookCenter.AppliedEvent]) {
        let snapshot = ProcessSnapshot()
        var changed = false
        for appliedEvent in events {
            let event = appliedEvent.event
            if appliedEvent.claudeRestoreChanged { changed = true }
            if event.kind == .codex,
               appliedEvent.resolution.column.captureCodexSession(
                   sessionID: event.sessionID,
                   emitterProcess: event.emitterProcess,
                   snapshot: snapshot
               ) {
                changed = true
            }
            recordAgentSession(appliedEvent, snapshot: snapshot)

            if appliedEvent.resolution.workspace.recordAgentHookActivity(event) {
                changed = true
            }
            recordReviewPasses(of: event, in: appliedEvent.resolution.workspace)
        }
        updateSidebar(snapshot: snapshot)
        if changed { saveState(snapshot: snapshot) }
        // After this drain: a turn that ended may have freed a Mission
        // agent's prompt for a message waiting to be typed.
        if events.contains(where: { [.stop, .stopFailure].contains($0.event.name) }) {
            DispatchQueue.main.async { [weak self] in self?.typeMissionMessages() }
        }
    }

    /// HEAD is read in the agent's own directory, now: the workspace's git
    /// context follows its focused column, and pauses while Nirux is in the
    /// background. An event replayed at launch is skipped, since the HEAD it
    /// ran on can't be known any more.
    private func recordReviewPasses(of event: AgentHookEvent, in workspace: WorkspaceState) {
        guard let passes = event.reviewPasses?.compactMap(ReviewPass.init(rawValue:)), !passes.isEmpty,
              let cwd = event.cwd,
              Date().timeIntervalSince1970 - event.timestamp < 60
        else { return }
        // Only the HEAD counts here.
        GitDetect.contextAsync(at: cwd, startFolder: nil) { [weak self, weak workspace] result in
            guard case .observed(let context) = result, let head = context.identity.head,
                  let self, let workspace,
                  workspace.recordReviewPasses(passes, head: head, at: event.timestamp)
            else { return }
            self.updateSidebar()
            self.saveState()
        }
    }

    /// MissionEventCenter delivery target, once per event (the ledger then
    /// marks it delivered). The event itself waits in the ledger to be
    /// typed into its recipient's prompt; the child's card shows a waiting
    /// question from the ledger too (`missionQuestion(for:)`).
    func handleMissionEvent(_ mission: Mission, event: MissionEvent) -> Bool {
        let workspace = workspaces.first(where: { $0.id == mission.childWorkspaceID })
        switch event.kind {
        case .acknowledged:
            return false
        case .response:
            // Answered: the question handed to the user is over.
            if workspace?.notification == .waiting { workspace?.notification = nil }
        case .completed:
            // So are its open questions.
            if workspace?.notification == .waiting { workspace?.notification = nil }
            NiruxNotifier.shared.postMissionEvent(
                workspaceID: mission.childWorkspaceID,
                workspaceTitle: workspace?.title ?? mission.branch,
                columnIndex: workspace?.columns.firstIndex(where: { $0.agentUUID == mission.childAgentUUID }),
                kind: event.kind,
                message: event.message
            )
        case .question, .instruction:
            break
        }
        updateSidebar()
        // Once the event is marked delivered: its recipient's prompt may be
        // free now.
        DispatchQueue.main.async { [weak self] in self?.typeMissionMessages() }
        return true
    }

    // MARK: - Metadata Refresh

    func wireMetadataAndGitRefresh(_ workspace: WorkspaceState) {
        workspace.onMetadataChanged = { [weak self] in self?.scheduleMetadataRefresh() }
        // The header follows its title immediately (no "· path" flicker);
        // the snapshot is only taken for shell titles such as "zsh".
        workspace.onColumnTitleChanged = { $0.updateHeaderTitle(snapshot: ProcessSnapshot()) }
        workspace.onFocusedColumnChanged = { [weak self, weak workspace] in
            guard let self, let workspace else { return }
            self.quickSwitch.focusMoved()
            self.refreshGitContextNow(for: workspace)
        }
        workspace.onGitContextChanged = { [weak self, weak workspace] in
            guard let self, let workspace else { return }
            self.gitRefresh.gitContextChanged(workspace)
            self.scheduleMetadataRefresh()
            self.refreshPRInfo(for: [workspace])
        }
    }

    /// Minimum spacing between metadata-driven refreshes. A spinning agent
    /// title fires many times per second per column; each refresh walks the
    /// whole process table.
    static let metadataRefreshInterval: TimeInterval = 0.25

    /// Coalesce sidebar/header refreshes: the first request after a quiet
    /// period runs on the next main-queue turn, later ones within the window
    /// collapse into one trailing refresh.
    func scheduleMetadataRefresh() {
        guard !isMetadataRefreshScheduled else { return }
        isMetadataRefreshScheduled = true
        let delay = max(
            0,
            lastMetadataRefreshAt + Self.metadataRefreshInterval - ProcessInfo.processInfo.systemUptime
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            // The heartbeat may have refreshed in the meantime.
            guard let self, self.isMetadataRefreshScheduled else { return }
            self.refreshMetadata()
        }
    }

    /// One process-table scan shared by the headers and the sidebar.
    func refreshMetadata(snapshot: ProcessSnapshot? = nil) {
        isMetadataRefreshScheduled = false
        lastMetadataRefreshAt = ProcessInfo.processInfo.systemUptime
        // A column that came on screen without a relayout (a dragged
        // width) resumes from here at the latest.
        scheduleDeferredAgentsOnScreen(restartingWait: false)
        // A window that came back in view (occlusion, the app's return).
        refreshStaleBranchReviewsOnScreen()
        let snapshot = snapshot ?? ProcessSnapshot()
        reviewSendPanel?.onRefresh?(snapshot)
        for workspace in workspaces { for column in workspace.columns { column.pty?.settlePromptWatchers(snapshot: snapshot) } }
        refreshHeaderTitles(snapshot: snapshot)
        updateSidebar(snapshot: snapshot)
    }

    // MARK: - Git & PR Refresh

    /// The workspace on screen is followed closely even when archived (its
    /// PR still is not: PRDetect.shouldRefresh keeps archived ones offline).
    func gitRefreshTier(for workspace: WorkspaceState) -> GitRefreshTier {
        if workspace === activeWorkspace { return .focused }
        if workspace.isInactive { return .archived }
        return .background
    }

    var gitRefreshTiers: [(workspace: WorkspaceState, tier: GitRefreshTier)] {
        workspaces.map { ($0, gitRefreshTier(for: $0)) }
    }

    func refreshGitAndPullRequests() {
        let tiers = gitRefreshTiers
        gitRefresh.tick(tiers)
        refreshPRInfo(for: gitRefresh.pullRequestsDue(tiers))
        // After the PR pass, which recomputes diff stats for what it touched.
        refreshDiffStats(for: gitRefresh.diffStatsDue(tiers))
    }

    /// Focus, a focused-column switch or an unarchive: read now instead of
    /// waiting for the throttles.
    func refreshGitContextNow(for workspace: WorkspaceState) {
        gitRefresh.refreshNow(workspace, tier: gitRefreshTier(for: workspace))
    }

    /// App activation: events that arrived while inactive were only
    /// recorded, so bring what is on screen up to date right away.
    func resumeGitRefresh() {
        gitRefresh.isSuspended = false
        for (workspace, tier) in gitRefreshTiers where tier == .focused {
            gitRefresh.refreshNow(workspace, tier: tier)
        }
    }

    func refreshPRInfo(for candidates: [WorkspaceState]) {
        for workspace in candidates {
            guard PRDetect.shouldRefresh(
                isInactive: workspace.isInactive,
                branch: workspace.gitBranch
            ), let requestedContext = workspace.gitContext else { continue }
            let branch = requestedContext.branch
            let cwd = workspace.focusedWorkingDirectory
            guard let observation = workspace.beginPullRequestObservation(for: requestedContext) else { continue }
            gitRefresh.notePullRequestRefresh(workspace)
            startDiffStatsRefresh(for: workspace, at: cwd, context: requestedContext)
            PRDetect.fetchAsync(branch: branch, cwd: cwd, startFolder: workspace.cwd) { [weak self, weak workspace] result in
                guard let workspace else { return }
                guard !workspace.isInactive else {
                    workspace.finishPullRequestObservation(observation)
                    return
                }
                guard case .success(let queriedContext, let info) = result,
                      workspace.isCurrentPullRequestObservation(observation, for: queriedContext)
                else {
                    workspace.finishPullRequestObservation(observation)
                    return
                }
                let currentCwd = workspace.focusedWorkingDirectory
                GitDetect.contextAsync(at: currentCwd, startFolder: workspace.cwd) { [weak self, weak workspace] result in
                    guard let workspace else { return }
                    guard !workspace.isInactive,
                          case .observed(let currentContext) = result,
                          currentContext == queriedContext else {
                        workspace.finishPullRequestObservation(observation)
                        return
                    }
                    let changed = workspace.applyPullRequestInfo(
                        info,
                        for: queriedContext,
                        observation: observation
                    )
                    // Even unchanged: the history may have loaded since,
                    // and the first read after launch records what is
                    // already red.
                    self?.noteSessionPullRequest(of: workspace)
                    // Every read of an open PR, changed or not: feedback
                    // moves without the PR's own fields moving.
                    if workspace.prInfo == info { self?.refreshPRFeedback(for: workspace) }
                    self?.reportNewRedChecks(in: workspace)
                    guard changed else { return }
                    self?.scheduleMetadataRefresh()
                }
            }
        }
    }

    /// `git diff --shortstat` alone, between PR refreshes: the dirty bit
    /// does not move while an agent keeps editing a dirty tree.
    func refreshDiffStats(for candidates: [WorkspaceState]) {
        for workspace in candidates {
            guard PRDetect.shouldRefresh(
                isInactive: workspace.isInactive,
                branch: workspace.gitBranch
            ), let context = workspace.gitContext else { continue }
            startDiffStatsRefresh(for: workspace, at: workspace.focusedWorkingDirectory, context: context)
        }
    }

    private func startDiffStatsRefresh(for workspace: WorkspaceState, at cwd: String, context: GitContext) {
        guard let observation = workspace.beginDiffStatsObservation(at: cwd, for: context) else { return }
        gitRefresh.noteDiffStatsRefresh(workspace)
        PRDetect.diffStatsAsync(cwd: cwd, startFolder: workspace.cwd) { [weak self, weak workspace] result in
            guard let workspace else { return }
            self?.gitRefresh.finishDiffStatsRefresh(workspace)
            guard !workspace.isInactive,
                  workspace.applyDiffStatsObservation(result, observation: observation)
            else { return }
            self?.scheduleMetadataRefresh()
        }
    }

    // MARK: - Terminal Redraw

    private static let shells: Set<String> = ["zsh", "bash", "fish", "sh", "-zsh", "-bash"]
    /// Recognized agents redraw correctly from SIGWINCH alone — Ctrl+L clears their session/screen.
    /// Claude Code rebinds Ctrl+L to `/clear` and Gemini CLI's clears its history, so
    /// broadcasting it on every layout change (e.g. Cmd+E width cycle)
    /// wiped active sessions.
    private static func redrawsFromSigwinchAlone(_ name: String) -> Bool {
        AgentStatusMachine.isRecognizedAgentProcess(name)
    }

    /// Light redraw: ask every terminal to refresh its surface and mark its
    /// view dirty. No keystrokes are sent to the TUI — use
    /// `redrawAllTerminals()` when you also need to nudge TUI apps with Ctrl+L.
    func refreshTerminalSurfaces() {
        for workspace in workspaces {
            for col in workspace.columns {
                col.terminalView?.fitToSize()
                col.pty?.forceRedraw()
                col.terminalView?.needsDisplay = true
            }
        }
    }

    /// Heavy redraw: refresh every terminal surface and additionally send
    /// Ctrl+L (0x0C) to any foreground process that isn't a plain shell or
    /// a recognized agent (vim, htop, etc.) so TUI apps repaint their buffer.
    func redrawAllTerminals() {
        let snap = ProcessSnapshot()
        for workspace in workspaces {
            for col in workspace.columns {
                col.terminalView?.fitToSize()
                col.pty?.forceRedraw()
                col.terminalView?.needsDisplay = true
                // Ctrl+L to any non-shell TUI (vim, htop, etc.)
                // Skip processes that handle SIGWINCH correctly on their own.
                if let name = col.pty?.foregroundProcessName(snapshot: snap),
                   !Self.shells.contains(name),
                   !Self.redrawsFromSigwinchAlone(name) {
                    col.pty?.sendRaw(Data([0x0C]))
                }
            }
        }
    }
}
