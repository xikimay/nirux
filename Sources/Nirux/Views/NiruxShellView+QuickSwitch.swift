import AppKit

/// What the quick switcher (⌘P's workspace rows) and Next Waiting Agent
/// (⌘J) keep on the shell.
@MainActor
final class QuickSwitchState {
    /// What blocks a column's agent on the user, given a process snapshot,
    /// the time and the stuck-agent setting's threshold (see `AgentWait`).
    /// Tests set their own: a blocked agent needs a real `claude` in front.
    var agentWait: @MainActor (ColumnState, ProcessSnapshot, TimeInterval, TimeInterval?) -> AgentWait? = {
        column, snapshot, now, waitThreshold in
        guard let pty = column.pty,
              let wait = pty.agentBlockedWait(
                  now: now, waitThreshold: waitThreshold, foreground: pty.foregroundProcess(snapshot: snapshot)
              ),
              wait.blocks(whileStatus: pty.cachedAgentState) else { return nil }
        return wait
    }
    /// The column the user last moved to, then each one ⌘J landed on
    /// since, in order: a press goes on to one the walk hasn't visited.
    private(set) var walk: [UUID] = []
    /// "No agent is waiting on you" (see `showTransientHint`).
    var hint: TransientHintView?

    /// The user moved the focus (or ⌘J did, which then notes where it
    /// landed): a press starts a new walk.
    func focusMoved() { walk = [] }

    func noteWalk(_ columns: [UUID]) { walk = columns }

    /// The walk as it goes on from `current`, the column on screen: on while
    /// the user stays where its last step landed, else from there.
    func walk(from current: UUID?) -> [UUID] {
        current != nil && current == walk.last ? walk : current.map { [$0] } ?? []
    }
}

// MARK: - Quick switcher (⌘P workspaces) and Next Waiting Agent (⌘J)

extension NiruxShellView {
    /// The sections ⌘P lists beside its actions: the active space's
    /// workspaces and past sessions, above the actions when nothing is
    /// typed, and the other spaces' workspaces, ranked with the active
    /// space's and folded unless they hold the best match (see
    /// `PaletteRanking.list`).
    func paletteSections() -> [PaletteSection] {
        let snapshot = ProcessSnapshot()
        let now = Date().timeIntervalSince1970
        let workspaces = quickSwitchWorkspaces(snapshot: snapshot, now: now)
        let here = workspaces.filter { !$0.isInOtherSpace }
        let elsewhere = workspaces.filter(\.isInOtherSpace)
        return [
            PaletteSection(
                title: workspaceStore.activeProfile.name,
                rows: here.map { workspacePaletteRow($0, now: now) },
                leadsWhenEmpty: true
            ),
            PaletteSection(
                title: Self.otherSpacesPaletteSectionTitle,
                rows: elsewhere.map { workspacePaletteRow($0, now: now) },
                ranksWithPrevious: true,
                folds: true,
                fold: PaletteFold { indices in
                    let folded = QuickSwitchWorkspace.folded(indices.map { elsewhere[$0] })
                    return PaletteFold.Summary(
                        title: folded.title,
                        subtitle: folded.subtitle,
                        badge: folded.attention.map { PaletteBadge(text: $0, tone: folded.hasFailure ? .failure : .waiting(.question)) }
                    )
                }
            ),
            // After the workspaces: at equal standing a query lists a
            // workspace above a session, as it always did.
            sessionsPaletteSection(snapshot: snapshot, now: now)
        ]
    }

    /// Every workspace of every space, the current space's first, each
    /// space in sidebar order.
    func quickSwitchWorkspaces(snapshot: ProcessSnapshot, now: TimeInterval) -> [QuickSwitchWorkspace] {
        let spaces = [activeProfileID] + profiles.map(\.id).filter { $0 != activeProfileID }
        let current = activeWorkspace
        return spaces.flatMap { workspaceStore.visibleWorkspaceIndices(in: $0) }
            .filter { !workspaces[$0].isClosing }
            .map { index in
                let workspace = workspaces[index]
                let space = profiles.first { $0.id == workspace.profileID } ?? WorkspaceProfile.defaultProfile
                let waits = workspace.columns.compactMap { quickSwitch.agentWait($0, snapshot, now, stuckAgentWaitThreshold) }
                let isWorking = workspace.columns.contains { $0.pty?.cachedAgentState == .working }
                var agent = QuickSwitchAgentState.summary(waits: waits, isWorking: isWorking)
                // Its badge's glyph is its row's: one source for why it waits.
                if case .waiting(let since, _)? = agent, case .needsYou(let reason) = rowIcon(of: index, snapshot: snapshot, now: now).kind {
                    agent = .waiting(since: since, reason: reason)
                }
                return QuickSwitchWorkspace(
                    id: workspace.id,
                    title: workspace.title,
                    branch: workspace.gitBranch,
                    spaceName: space.name,
                    spaceColorHex: space.colorHex,
                    folder: workspace.cwd,
                    isInactive: workspace.isInactive,
                    isCurrent: workspace === current,
                    isInOtherSpace: workspace.profileID != activeProfileID,
                    agent: agent
                )
            }
    }

    /// The icon of the workspace at `index`'s row: the sidebar's, else one
    /// built as the Board builds the rows of other spaces.
    func rowIcon(of index: Int, snapshot: ProcessSnapshot, now: TimeInterval) -> StateIcon {
        let workspace = workspaces[index]
        if let row = sidebar.lastInfos.first(where: { $0.id == workspace.id }) { return row.stateIcon }
        let isActive = index == activeWSIndex
        let columns = workspace.columns.enumerated().map { colIndex, col in
            sidebarColumnInfo(
                col, at: colIndex, isUserFocused: colIndex == workspace.focusedIndex && isActive,
                agentStatus: col.pty?.cachedAgentState ?? .idle, foregroundProcess: col.pty?.foregroundProcess(snapshot: snapshot),
                approvalHold: nil, missionQuestion: nil, showsDialog: false, snapshot: snapshot, now: now
            )
        }
        return sidebarWorkspaceInfo(at: index, columns: columns, isActive: isActive, parentTitle: nil).stateIcon
    }

    static let otherSpacesPaletteSectionTitle = "Other Spaces"

    private func workspacePaletteRow(_ workspace: QuickSwitchWorkspace, now: TimeInterval) -> PaletteAction {
        PaletteAction(
            icon: .dot(NSColor.niruxColor(hex: workspace.spaceColorHex) ?? Theme.Color.accent),
            title: workspace.title,
            subtitle: workspace.subtitle(folderDisplay: workspace.folder.abbreviatedPath()),
            shortcut: nil,
            ranking: workspace.candidate,
            badge: workspace.agent.map { PaletteBadge($0, station: taskStations[workspace.id], now: now) },
            isDimmed: workspace.isInactive
        ) { [weak self] in
            self?.openWorkspace(id: workspace.id)
        }
    }

    /// A workspace picked in ⌘P comes on screen. An archived one stays
    /// archived: the sidebar lists it alone above the folded Archived row,
    /// which stays folded (#50).
    func openWorkspace(id: String) {
        guard let index = workspaces.firstIndex(where: { $0.id == id && !$0.isClosing }) else { return }
        switchToWorkspace(index)
    }

    // MARK: - Next Waiting Agent

    static let noWaitingAgentHint = "No agent is waiting on you"

    /// Next Waiting Agent (⌘J, the command bar's badge). The sidebar
    /// folded, requests waiting: the inbox opens under the bar (over a
    /// callout, which closes), and ⌘J again goes to the request chosen in
    /// it. Else, as the sidebar unfolded, where the requests stay in the
    /// rows: to the agent blocked on the user that they have not seen yet,
    /// the longest wait first, then on through every other one at each
    /// press (see `WaitingAgentQueue.next`), whatever its workspace or
    /// space, the agents stopped on an error or exited too. With none, a
    /// hint says so, without a beep.
    func jumpToNextWaitingAgent() {
        // ⌘J with the palette open: neither the inbox nor the hint goes
        // under it.
        if commandPalette?.isVisible == true { commandPalette?.dismiss() }
        // A held ⌘J opens the inbox, or goes to its request, once.
        let isRepeat = NSApp.currentEvent.map { $0.type == .keyDown && $0.isARepeat } ?? false
        if requestsState.isInboxOpen {
            guard !isRepeat else { return }
            if let chosen = requestsState.inbox?.chosenRequest { goToRequest(chosen) } else { closeInbox() }
            return
        }
        if !sidebar.isExpanded, let window, sideEffects.windowShows(window) {
            // The requests as they are now, not at the last refresh.
            updateSidebar()
            if !requestsState.requests.isEmpty { return isRepeat ? () : openInbox() }
        }
        let snapshot = ProcessSnapshot()
        let now = Date().timeIntervalSince1970
        let queue = waitingQueue(snapshot: snapshot, now: now)
        let current = activeWorkspace.flatMap { $0.columns[safe: $0.focusedIndex] }?.id
        // The walk goes on while the user stays where its last press
        // landed; else it starts where they are.
        let walk = quickSwitch.walk(from: current)
        guard let (next, walked) = WaitingAgentQueue.next(from: current, walk: walk, in: queue),
              let workspace = workspaces.first(where: { $0.id == next.workspaceID }),
              let columnIndex = workspace.columns.firstIndex(where: { $0.id == next.columnID }) else {
            quickSwitch.noteWalk([])
            showTransientHint(Self.noWaitingAgentHint)
            return
        }
        focusWorkspace(id: workspace.id, column: columnIndex)
        // After: going there moved the focus.
        quickSwitch.noteWalk(walked)
    }

    /// A line at the top of the columns that fades by itself.
    func showTransientHint(_ text: String) {
        let hint = quickSwitch.hint ?? TransientHintView(frame: .zero)
        quickSwitch.hint = hint
        // Above whatever was added since.
        addSubview(hint, positioned: .above, relativeTo: nil)
        hint.show(text, topCenteredIn: viewportRestFrame)
    }
}

extension PaletteBadge {
    init(_ state: QuickSwitchAgentState, station: BoardStages.Station? = nil, now: TimeInterval) {
        let tone: Tone
        switch state {
        case .working: tone = .working(station)
        case .waiting(_, let reason): tone = .waiting(reason)
        case .failed: tone = .failure
        }
        self.init(text: state.label(now: now), tone: tone)
    }
}
