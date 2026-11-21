import AppKit

// MARK: - Sidebar, Git, PR, Terminal Redraw, Status Bar

extension NiruxShellView {
    func updateSidebar(snapshot: ProcessSnapshot? = nil) {
        dropTurnEndsLeftBehind()
        let snapshot = snapshot ?? ProcessSnapshot()
        let processTableRead = !snapshot.isEmpty
        let now = Date().timeIntervalSince1970
        let visibleIndices = visibleWorkspaceIndices
        let parents = workspaceStore.activeParents(in: activeProfileID)
        let (foregroundProcesses, invalidatedSessionBinding) = followForegroundProcesses(snapshot: snapshot, now: now)
        let approvalHolds = releaseApprovalsNotHeld()
        followReviewPasses(snapshot: snapshot)
        // The user is there to read: Nirux in front, and nothing the
        // catch-up card counts as away (a shell that doesn't follow the
        // system, a test's, goes by the first).
        lazy var userIsThere = sideEffects.appIsActive()
            && (!catchUpState.followsSystem || awayConditionsNow().subtracting([.appActive]).isEmpty)
        let missionQuestions = missionQuestions(foreground: { foregroundProcesses[ObjectIdentifier($0)] }, now: now)
        noteMissionQuestionHandOffs(missionQuestions)
        requestsState.handedOff = handedOffQuestions(missionQuestions)
        // Seen ones no longer handed off are forgotten.
        requestsState.seenHandedOff.formIntersection(requestsState.handedOff.values.map(\.question.questionID))
        let appIsActive = sideEffects.appIsActive()
        let built = visibleIndices.map { index in
            let workspace = workspaces[index]
            let isActive = index == activeWSIndex
            let colInfos = workspace.columns.enumerated().map { colIndex, col in
                let isUserFocused = colIndex == workspace.focusedIndex && isActive
                // Its question read on screen: its column in front, the
                // user there. Next Waiting Agent goes to it after the others.
                if isUserFocused, col.pty?.agentHasUnseenQuestion == true, userIsThere { col.pty?.noteAgentQuestionSeen() }
                // A Mission question handed to the user, read on screen the
                // same way: it stands after the waits not seen yet.
                if isUserFocused, userIsThere, let question = requestsState.handedOff[col.id]?.question {
                    requestsState.seenHandedOff.insert(question.questionID)
                }
                let foregroundProcess = foregroundProcesses[ObjectIdentifier(col)]
                let agentStatus = col.pty?.agentStatus(
                    foregroundProcess: foregroundProcess,
                    isUserFocused: isUserFocused,
                    processTableRead: processTableRead,
                    claudeFiredHooks: foregroundProcess.map { col.claudeHooksFired(by: $0.instance) } ?? false
                ) ?? .idle
                if let reason = col.pty?.takeLateSignInAlert(isUserFocused: isUserFocused && appIsActive) {
                    col.notifyAgentAttention(reason: reason)
                }
                return sidebarColumnInfo(
                    col, at: colIndex, isUserFocused: isUserFocused, agentStatus: agentStatus, foregroundProcess: foregroundProcess,
                    approvalHold: approvalHolds[ObjectIdentifier(col)], missionQuestion: missionQuestions[ObjectIdentifier(col)],
                    // The dialog the user is looking at needs no copy on
                    // its row: its one line, as for any dialog.
                    showsDialog: !(isUserFocused && appIsActive), snapshot: snapshot, now: now,
                    waitingMessages: missionWaits.shown[col.id]
                )
            }
            return sidebarWorkspaceInfo(
                at: index, columns: colInfos, isActive: isActive, parentTitle: parents[index].map { workspaces[$0].title }
            )
        }
        tickHiddenSpaceAgents(
            visibleIndices: visibleIndices, foregroundProcesses: foregroundProcesses, processTableRead: processTableRead
        )
        // What blocks each column on the user, read once for the terminal
        // headers and the other spaces' marks.
        var blockedWaits: [ObjectIdentifier: AgentWait] = [:]
        for workspace in workspaces {
            for column in workspace.columns {
                if let wait = column.pty?.agentBlockedWait(
                    now: now, waitThreshold: stuckAgentWaitThreshold, foreground: foregroundProcesses[ObjectIdentifier(column)]
                ) {
                    blockedWaits[ObjectIdentifier(column)] = wait
                }
            }
        }
        // Every Board reads its tasks before the rows draw: a row shows its
        // line's station.
        let stages = readProjectBoards(snapshot: snapshot, now: now, pass: SidebarPassReadings(
            infos: built, foregroundProcesses: foregroundProcesses, approvalHolds: approvalHolds, missionQuestions: missionQuestions
        ))
        let infos = built.map { info in
            var info = info
            info.station = taskStations[info.id]
            return info
        }
        updateColumnHeaders(infos: infos, blockedWaits: blockedWaits, now: now)
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
                        Self.attention(of: $0, blockedWaits: blockedWaits, missionQuestions: missionQuestions)
                    }.max()
            )
        }
        sidebar.catchUp = sidebarCatchUp(infos: infos)
        sidebar.navigation = sidebarNavigation
        sidebar.update(profiles: profileInfos, workspaces: infos)
        // The requests: what ⌘J would visit, through ⌘J's own queue, that
        // waits for the user's answer; the command bar counts them.
        let requested = Self.requestedAgents(
            in: waitingQueue(snapshot: snapshot, now: now), onScreen: activeWorkspace.flatMap { $0.columns[safe: $0.focusedIndex] }?.id
        )
        requestsState.requests = waitingRequests(requested, approvalHolds: approvalHolds, foregroundProcesses: foregroundProcesses)
        updateCommandBar(task: infos.first { $0.index == activeWSIndex }, waitingCount: requestsState.requests.count)
        refreshRequestPanels()
        // A rename or a repository added changes what an empty space says.
        refreshEmptySpaceView()
        updateSidebarAttention(infos: infos, missionQuestions: missionQuestions, foregroundProcesses: foregroundProcesses)
        closeStaleTurnReply()
        if invalidatedSessionBinding { saveState(snapshot: snapshot) }
        drawProjectBoards(stages, now: now)
    }

    /// A running pass ends once the process that sent its event exited (a
    /// Ctrl-Z leaves it there), it named none, or its column closed. An
    /// empty process table says nothing.
    private func followReviewPasses(snapshot: ProcessSnapshot) {
        for workspace in workspaces where !workspace.reviewsRunning.isEmpty {
            workspace.followReviewPasses { running in
                guard workspace.columns.contains(where: { $0.id == running.column }) else { return false }
                guard !snapshot.isEmpty else { return true }
                return running.emitter.map(snapshot.contains) ?? false
            }
        }
    }

    /// A column's facts for its task's row, its agent's status for this
    /// pass given: the sidebar reads it ticking the status machine, the
    /// Board the last tick's. Reads only: what the user saw is the
    /// sidebar's to note.
    func sidebarColumnInfo(
        _ col: ColumnState, at colIndex: Int, isUserFocused: Bool, agentStatus: AgentStatus,
        foregroundProcess: ForegroundProcess?, approvalHold: PermissionApprovalHold?, missionQuestion: SidebarMissionQuestion?,
        showsDialog: Bool, snapshot: ProcessSnapshot, now: TimeInterval, waitingMessages: SidebarWaitingMessages? = nil
    ) -> ColumnInfo {
        let editorFile = col.editorColumn?.currentPath.map {
            ($0 as NSString).lastPathComponent
        }
        let permissionApproval = sidebarApproval(for: col, hold: approvalHold)
        // The Project Board's rule: an approved dialog stays listed
        // while its tool runs, the column working. A question
        // waits even while subagents work, as the header and ⌘J
        // say; behind a dialog, the dialog is what waits.
        let dialog = agentStatus == .working ? nil : col.pty?.agentVisibleDialog(foreground: foregroundProcess)
        let asked = dialog == nil ? col.pty?.agentQuestion(foreground: foregroundProcess) : nil
        return ColumnInfo(
            index: colIndex,
            processName: foregroundProcess?.name,
            agentLabel: col.taskAgentSelection(foreground: foregroundProcess)?.label,
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
            openDialog: dialog?.reason ?? asked.map { .askedInReply($0.text) }
                ?? col.pty?.agentTrustPrompt(foreground: foregroundProcess).map { _ in AgentTrustPrompt.reason },
            stuck: sidebarStuckState(of: col, foregroundProcess: foregroundProcess, snapshot: snapshot, now: now),
            deferredAgent: Self.sidebarDeferredAgent(of: col),
            missionQuestion: missionQuestion,
            circling: circlingHintEnabled ? col.pty?.agentCirclingHint : nil,
            turnQuestion: Self.sidebarTurnQuestion(of: col, status: agentStatus, foreground: foregroundProcess),
            questionAskedAt: asked?.since,
            dialog: showsDialog ? dialog?.dialog : nil,
            waitingMessages: waitingMessages,
            id: col.id
        )
    }

    /// A task's row, from its columns' facts.
    func sidebarWorkspaceInfo(at index: Int, columns: [ColumnInfo], isActive: Bool, parentTitle: String?) -> WorkspaceInfo {
        let workspace = workspaces[index]
        return WorkspaceInfo(id: workspace.id, index: index, title: workspace.title,
                      profileID: workspace.profileID, isInactive: workspace.isInactive,
                      columnCount: workspace.columns.count,
                      focusedColumn: workspace.focusedIndex,
                      gitBranch: workspace.gitBranch, notification: workspace.notification, isActive: isActive,
                      columns: columns, prInfo: workspace.prInfo, prFeedback: workspace.prFeedback?.counts,
                      ciFlakyReason: workspace.ciFlakyReason,
                      diffStats: workspace.diffStats,
                      purpose: workspace.purpose, nextStep: workspace.nextStep,
                      blocker: workspace.blocker, phase: workspace.effectivePhase,
                      // A status line written before the option went off is no summary.
                      lastSummary: turnStatusEnabled || !workspace.lastSummaryIsStatus ? workspace.lastSummary : nil,
                      lastActivityAt: workspace.lastActivityAt,
                      reviewBadges: workspace.reviewBadges,
                      station: taskStations[workspace.id],
                      mergedCleanup: mergedCleanupOffer(workspaceIndex: index),
                      isLead: workspace.isLead,
                      parentTitle: parentTitle,
                      statusLine: turnStatusEnabled ? workspace.statusLine : nil,
                      turnStatusLine: turnStatusEnabled ? workspace.turnStatusLine : nil,
                      ruleProposalCount: workspace.isLead ? pendingRuleProposals(inSpace: workspace.profileID).count : 0,
                      dailyPassNote: workspace.isLead ? dailyPassNote(inSpace: workspace.profileID) : nil,
                      followUp: followUpRow(of: workspace))
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
                // A task's new folder is where an agent asks for trust; agy
                // trusts exact paths, so a new worktree asks again.
                if workspace.isFolderTask || foregroundProcess?.agent?.folderTrust == .everyFolder {
                    watchTrustPrompt(of: column, foreground: foregroundProcess, now: now)
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
    private func updateColumnHeaders(infos: [WorkspaceInfo], blockedWaits: [ObjectIdentifier: AgentWait], now: TimeInterval) {
        for info in infos {
            guard let workspace = workspaces[safe: info.index] else { continue }
            for column in info.columns {
                guard let state = workspace.columns[safe: column.index], state.pty != nil else { continue }
                state.updateHeaderAgentState(column, wait: blockedWaits[ObjectIdentifier(state)], now: now, station: info.station)
            }
        }
    }

    /// Reads the screen of an agent that may be asking whether to trust its
    /// folder (see AgentTrustPrompt).
    private func watchTrustPrompt(of column: ColumnState, foreground: ForegroundProcess?, now: TimeInterval) {
        guard let pty = column.pty, let foreground, pty.beginTrustPromptRead(foreground: foreground, now: now) else { return }
        pty.readTrustPrompt { [weak pty] shown in
            pty?.finishTrustPromptRead(shown: shown, foreground: foreground, now: Date().timeIntervalSince1970)
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
    /// has no card: what blocks its agents (`blockedWaits`: a dialog on
    /// screen, a failed turn, an exit mid-turn), their attention, and what
    /// happened while the user was away.
    private static func attention(
        of workspace: WorkspaceState,
        blockedWaits: [ObjectIdentifier: AgentWait],
        missionQuestions: [ObjectIdentifier: SidebarMissionQuestion]
    ) -> AttentionSignal? {
        var signals: [AttentionSignal] = []
        for column in workspace.columns {
            if missionQuestions[ObjectIdentifier(column)]?.handOff != nil { signals.append(.waiting) }
            guard let pty = column.pty else { continue }
            let status = pty.cachedAgentState
            if let wait = blockedWaits[ObjectIdentifier(column)], wait.blocks(whileStatus: status) {
                signals.append(wait.reason.signal)
            }
            if status == .needsAttention { signals.append(AttentionSignal.of(pty.agentAttentionReason)) }
        }
        if let notification = workspace.notification { signals.append(notification) }
        return signals.max()
    }

    private func updateSidebarAttention(
        infos: [WorkspaceInfo], missionQuestions: [ObjectIdentifier: SidebarMissionQuestion],
        foregroundProcesses: [ObjectIdentifier: ForegroundProcess]
    ) {
        // Dock badge: workspaces currently waiting for attention, an agent
        // asking to trust its folder too (no hook says it waits).
        let attentionCount = workspaces.filter { workspace in
            workspace.hasNotification
                || workspace.columns.contains { column in
                    Self.countsInDockBadge(
                        agentState: column.pty?.cachedAgentState, reason: column.pty?.agentAttentionReason,
                        isQuietTurnEnd: column.pty?.isQuietTurnEnd ?? false,
                        missionQuestion: missionQuestions[ObjectIdentifier(column)]
                    ) || column.pty?.agentTrustPrompt(foreground: foregroundProcesses[ObjectIdentifier(column)]) != nil
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
        } else {
            // An empty space: no columns to point at.
            columnIndicator.update(columnCount: 0, focusedIndex: 0)
        }

        // Each column's light, and the viewport's edges for the agents out
        // of view.
        updateAgentLights(infos: infos)
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

    func clearAllAgentAttention() {
        // Called from `didBecomeActiveNotification`. Must stay cheap — the
        // full `updateSidebar()` does a `sysctl(KERN_PROC_ALL)` plus a
        // `proc_pidinfo` per column, and on resume that can land in the same
        // tick as Metal restoring every Ghostty surface, freezing the UI for
        // seconds when many agents are running. Just clear the flags and the
        // lights of what waited; the next heartbeat (2s) refreshes the
        // sidebar with fresh process info.
        NiruxNotifier.shared.updateDockBadge(attentionCount: 0)
        NiruxNotifier.shared.clearDelivered()
        for workspace in workspaces {
            workspace.notification = nil
            for col in workspace.columns { col.pty?.clearAgentAttention() }
        }
        clearAgentAlertLights()
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
        // The column's own corners, so that its clip leaves the ring whole.
        overlay.layer?.cornerRadius = Theme.Radius.column
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
        let now = Date().timeIntervalSince1970
        var changed = false
        for appliedEvent in events {
            let event = appliedEvent.event
            if appliedEvent.claudeRestoreChanged { changed = true }
            if event.kind == .agy {
                if appliedEvent.resolution.column.captureAgySession(
                    sessionID: event.sessionID, emitterProcess: event.emitterProcess, snapshot: snapshot
                ) {
                    changed = true
                }
                continue
            }
            if event.kind == .codex,
               appliedEvent.resolution.column.captureCodexSession(
                   sessionID: event.sessionID,
                   soleInputDigest: event.soleInputDigest,
                   emitterProcess: event.emitterProcess,
                   snapshot: snapshot
               ) {
                changed = true
            }
            recordAgentSession(appliedEvent, snapshot: snapshot)
            if let entry = LoopLog.entry(of: event) {
                LoopLog.lines.appendInBackground(entry, spaceID: appliedEvent.resolution.workspace.profileID)
            }

            if appliedEvent.resolution.workspace.recordAgentHookActivity(event) {
                changed = true
            }
            // In the drain's order: a pass, then its turn's end, ends it.
            appliedEvent.resolution.workspace.noteReviewPasses(of: event, in: appliedEvent.resolution.column.id, now: now)
            recordReviewPasses(of: event, in: appliedEvent.resolution.workspace, now: now)
        }
        updateSidebar(snapshot: snapshot)
        if changed { saveState(snapshot: snapshot) }
        // After this drain: a turn that ended may have freed a Mission
        // agent's prompt for a message waiting to be typed.
        // Codex's turn end too: it may prove the thread its OSC `done` came before.
        if events.contains(where: { $0.event.kind.statusSource == .hooks && [.stop, .stopFailure, .turnComplete].contains($0.event.name) }) {
            DispatchQueue.main.async { [weak self] in self?.typeMissionMessages() }
        }
    }

    /// A turn's status line landed on its task: its row says it, and the
    /// state file keeps it.
    func turnStatusChanged() {
        updateSidebar()
        saveState()
    }

    /// The status lines on or off on the rows at once. Back on, the lines
    /// written before are forgotten: turns ended meanwhile without one.
    func setTurnStatus(enabled: Bool) {
        turnStatusEnabled = enabled
        if enabled {
            for workspace in workspaces where workspace.lastSummaryIsStatus { workspace.lastSummaryIsStatus = false }
            saveState()
        }
        updateSidebar()
    }

    /// HEAD and its branch are read in the agent's own directory, now: the
    /// workspace's git context follows its focused column, and pauses while
    /// Nirux is in the background. An event replayed at launch is skipped, since the HEAD it
    /// ran on can't be known any more.
    private func recordReviewPasses(of event: AgentHookEvent, in workspace: WorkspaceState, now: TimeInterval) {
        let passes = event.passes
        guard !passes.isEmpty, let cwd = event.cwd, now - event.timestamp < 60 else { return }
        // Only the HEAD and its branch count here; a detached HEAD has none.
        GitDetect.contextAsync(at: cwd, startFolder: nil) { [weak self, weak workspace] result in
            guard case .observed(let context) = result, let head = context.identity.head,
                  let self, let workspace,
                  workspace.recordReviewPasses(passes, head: head, branch: context.branchName, at: event.timestamp)
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
        missionWaits.checkedAt = nil
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
        case .instruction:
            // A `tell` from the CLI: the conversation it is for.
            if event.childSessionID == nil { noteConversation(of: mission, forInstruction: event.id) }
        case .question:
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
        workspace.onProgramTurnOver = { [weak self] in
            DispatchQueue.main.async { [weak self] in self?.typeMissionMessages() }
        }
        // The header follows its title immediately (no "· path" flicker);
        // the snapshot is only taken for shell titles such as "zsh".
        workspace.onColumnTitleChanged = { $0.updateHeaderTitle(snapshot: ProcessSnapshot()) }
        workspace.onFocusedColumnChanged = { [weak self, weak workspace] in
            guard let self, let workspace else { return }
            self.quickSwitch.focusMoved()
            self.refreshGitContextNow(for: workspace)
        }
        workspace.onColumnsLaidOut = { [weak self, weak workspace] in
            guard let self, let workspace, workspace === self.activeWorkspace else { return }
            self.refreshSidebarNavigation()
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
            let readStartedAt = Date().timeIntervalSince1970
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
                    if workspace.prInfo == info {
                        self?.prFollowUpCenter.readAt[workspace.id] = readStartedAt
                        self?.followUpPullRequest(of: workspace)
                    }
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

    /// Ctrl+L repaints a TUI in front (vim, htop). Not a shell, nor an
    /// agent: it redraws from SIGWINCH alone, and Ctrl+L clears its
    /// session (Claude Code rebinds it to `/clear`, Gemini CLI clears its
    /// history), so a layout change (⌘E's width cycle) wiped active ones.
    nonisolated static func repaintsWithCtrlL(_ processName: String) -> Bool {
        !Shell.isShell(processName) && CodingAgent(rawValue: processName) == nil
    }

    /// Heavy redraw: refresh every terminal surface, and Ctrl+L to the
    /// programs that need it to repaint their buffer.
    func redrawAllTerminals() {
        let snap = ProcessSnapshot()
        for workspace in workspaces {
            for col in workspace.columns {
                col.terminalView?.fitToSize()
                col.pty?.forceRedraw()
                col.terminalView?.needsDisplay = true
                if let name = col.pty?.foregroundProcessName(snapshot: snap), Self.repaintsWithCtrlL(name) {
                    col.pty?.sendRaw(Data([0x0C]))
                }
            }
        }
    }
}

extension NiruxShellView {
    /// The navigator rows' state: the Board row selected while the space's
    /// Board column shows on screen (`showsColumn`, the one definition of in
    /// view): it opens beside the agent, and a click between the two leaves
    /// both shown. Pressable while a task is open (the Board opens beside
    /// it).
    var sidebarNavigation: SidebarNavigation {
        guard let workspace = activeWorkspace, !workspace.isClosing else { return SidebarNavigation(boardShown: false, boardAvailable: false) }
        let shown = workspace.columns.indices.contains { index in
            let column = workspace.columns[index]
            return column.projectBoard != nil && !column.isClosing && workspace.showsColumn(at: index)
        }
        return SidebarNavigation(boardShown: shown, boardAvailable: true)
    }

    /// The navigator rows follow the columns in view: a Board column
    /// scrolled, resized or moved into or out of view.
    func refreshSidebarNavigation() {
        let navigation = sidebarNavigation
        // Each frame of a resize lays the columns out: most change nothing.
        guard navigation != sidebar.navigation else { return }
        sidebar.navigation = navigation
        // Not inside the layout pass: on the next turn, where nothing is
        // left to do if an update meanwhile rebuilt the rows.
        DispatchQueue.main.async { [weak self] in self?.sidebar.renderIfChanged() }
    }
}
