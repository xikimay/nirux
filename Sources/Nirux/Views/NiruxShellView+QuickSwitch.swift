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
    /// The column the last ⌘J landed on, until the focus moves: a press
    /// from there goes on to the next agent.
    private(set) var lastJump: UUID?
    /// "No agent is waiting on you" (see `showTransientHint`).
    var hint: TransientHintView?

    /// The user moved the focus (or ⌘J did, which then notes where it
    /// landed): back on that column by hand, a press starts over at the
    /// longest wait.
    func focusMoved() { lastJump = nil }

    func noteJump(to column: UUID?) { lastJump = column }
}

// MARK: - Quick switcher (⌘P workspaces) and Next Waiting Agent (⌘J)

extension NiruxShellView {
    /// The sections ⌘P lists after its commands: the workspaces. Another
    /// kind of row (past sessions…) joins with a section of its own here.
    func paletteSections() -> [PaletteSection] {
        let snapshot = ProcessSnapshot()
        let now = Date().timeIntervalSince1970
        return [workspacePaletteSection(snapshot: snapshot, now: now)]
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
                    showsSpace: profiles.count > 1,
                    agent: .summary(waits: waits, isWorking: isWorking)
                )
            }
    }

    static let workspacesPaletteSectionTitle = "Workspaces"

    func workspacePaletteSection(snapshot: ProcessSnapshot, now: TimeInterval) -> PaletteSection {
        let rows = quickSwitchWorkspaces(snapshot: snapshot, now: now).map { workspace in
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
        return PaletteSection(title: Self.workspacesPaletteSectionTitle, rows: rows)
    }

    /// A workspace picked in ⌘P comes on screen. An inactive one stays
    /// inactive: the sidebar lists it alone under the folded INACTIVE
    /// header, which stays folded (#50).
    func openWorkspace(id: String) {
        guard let index = workspaces.firstIndex(where: { $0.id == id && !$0.isClosing }) else { return }
        switchToWorkspace(index)
    }

    // MARK: - Next Waiting Agent

    static let noWaitingAgentHint = "No agent is waiting on you"

    /// Next Waiting Agent (⌘J): to the agent blocked on the user the
    /// longest, then on to the next one at each press (see
    /// `WaitingAgentQueue.next`), whatever its workspace or space. With
    /// none, a hint says so, without a beep.
    func jumpToNextWaitingAgent() {
        let snapshot = ProcessSnapshot()
        let now = Date().timeIntervalSince1970
        let queue = WaitingAgentQueue.collect(from: workspaces) { self.quickSwitch.agentWait($0, snapshot, now) }
        let current = activeWorkspace.flatMap { $0.columns[safe: $0.focusedIndex] }?.id
        // ⌘J with the palette open: the hint would show under it.
        if commandPalette?.isVisible == true { commandPalette?.dismiss() }
        guard let next = WaitingAgentQueue.next(from: current, lastJump: quickSwitch.lastJump, in: queue),
              let workspace = workspaces.first(where: { $0.id == next.workspaceID }),
              let columnIndex = workspace.columns.firstIndex(where: { $0.id == next.columnID }) else {
            quickSwitch.noteJump(to: nil)
            showTransientHint(Self.noWaitingAgentHint)
            return
        }
        focusWorkspace(id: workspace.id, column: columnIndex)
        // After: going there moved the focus.
        quickSwitch.noteJump(to: next.columnID)
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
