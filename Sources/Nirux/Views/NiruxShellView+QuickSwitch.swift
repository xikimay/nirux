import AppKit

/// What the quick switcher (⌘P's workspace rows) and Next Waiting Agent
/// (⌘J) keep on the shell.
@MainActor
final class QuickSwitchState {
    /// What blocks a column's agent on the user, given a process snapshot
    /// and the time (see `AgentWait`). Tests set their own: a blocked
    /// agent needs a real `claude` in front.
    var agentWait: @MainActor (ColumnState, ProcessSnapshot, TimeInterval) -> AgentWait? = { column, snapshot, now in
        column.pty?.agentBlockedWait(now: now, foreground: column.pty?.foregroundProcess(snapshot: snapshot))
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
                        badge: folded.attention.map { PaletteBadge(text: $0, tone: folded.hasFailure ? .failure : .waiting) }
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
            .map { workspaces[$0] }
            .filter { !$0.isClosing }
            .map { workspace in
                let space = profiles.first { $0.id == workspace.profileID } ?? WorkspaceProfile.defaultProfile
                let waits = workspace.columns.compactMap { quickSwitch.agentWait($0, snapshot, now) }
                let isWorking = workspace.columns.contains { $0.pty?.cachedAgentState == .working }
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
                    agent: .summary(waits: waits, isWorking: isWorking)
                )
            }
    }

    static let otherSpacesPaletteSectionTitle = "Other Spaces"

    private func workspacePaletteRow(_ workspace: QuickSwitchWorkspace, now: TimeInterval) -> PaletteAction {
        PaletteAction(
            icon: .dot(NSColor.niruxColor(hex: workspace.spaceColorHex) ?? Theme.Color.accent),
            title: workspace.title,
            subtitle: workspace.subtitle(folderDisplay: workspace.folder.abbreviatedPath()),
            shortcut: nil,
            ranking: workspace.candidate,
            badge: workspace.agent.map { PaletteBadge($0, now: now) },
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

    /// Next Waiting Agent (⌘J): to the agent blocked on the user that
    /// they have not seen yet, the longest wait first, then on through
    /// every other one at each press (see `WaitingAgentQueue.next`),
    /// whatever its workspace or space. With
    /// none, a hint says so, without a beep.
    func jumpToNextWaitingAgent() {
        let snapshot = ProcessSnapshot()
        let now = Date().timeIntervalSince1970
        let queue = WaitingAgentQueue.collect(from: workspaces) { self.quickSwitch.agentWait($0, snapshot, now) }
        let current = activeWorkspace.flatMap { $0.columns[safe: $0.focusedIndex] }?.id
        // ⌘J with the palette open: the hint would show under it.
        if commandPalette?.isVisible == true { commandPalette?.dismiss() }
        // The walk goes on while the user stays where its last press
        // landed; else it starts where they are.
        let walk = current != nil && current == quickSwitch.walk.last && !ZZ("walk-never-continues") ? quickSwitch.walk
            : ZZ("walk-starts-empty") ? [] : current.map { [$0] } ?? []
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
        hint.show(text, topCenteredIn: viewport.frame)
    }
}

extension PaletteBadge {
    init(_ state: QuickSwitchAgentState, now: TimeInterval) {
        let tone: Tone
        switch state {
        case .working: tone = .working
        case .waiting: tone = .waiting
        case .failed: tone = .failure
        }
        self.init(text: state.label(now: now), tone: tone)
    }
}
