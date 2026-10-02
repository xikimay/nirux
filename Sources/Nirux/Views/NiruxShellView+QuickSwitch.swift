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
    /// The column the last ⌘J landed on: a press from there goes on to the
    /// next agent.
    var lastJump: UUID?
    /// "No agent is waiting on you" (see `showTransientHint`).
    var hint: TransientHintView?
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
                    agent: .summary(waits: waits, isWorking: isWorking)
                )
            }
    }

    static let workspacesPaletteSectionTitle = "Workspaces"

    func workspacePaletteSection(snapshot: ProcessSnapshot, now: TimeInterval) -> PaletteSection {
        let showsSpace = profiles.count > 1
        let rows = quickSwitchWorkspaces(snapshot: snapshot, now: now).map { workspace in
            let subtitle = workspace.subtitle(folderDisplay: workspace.folder.abbreviatedPath(), showsSpace: showsSpace)
            return PaletteAction(
                icon: "●",
                title: workspace.title,
                subtitle: workspace.isInactive ? "Inactive · \(subtitle)" : subtitle,
                shortcut: nil,
                searchKeys: workspace.candidate.keys,
                badge: workspace.agent.map { PaletteBadge($0, now: now) },
                isDimmed: workspace.isInactive,
                iconColor: NSColor.niruxColor(hex: workspace.spaceColorHex) ?? .niruxAccent
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

    /// Every agent blocked on the user, in every workspace and space,
    /// longest wait first.
    func waitingAgentQueue(snapshot: ProcessSnapshot, now: TimeInterval) -> [WaitingAgent] {
        let agents = workspaces.filter { !$0.isClosing }.flatMap { workspace in
            workspace.columns.compactMap { column in
                quickSwitch.agentWait(column, snapshot, now).map {
                    WaitingAgent(workspaceID: workspace.id, columnID: column.id, wait: $0)
                }
            }
        }
        return WaitingAgentQueue.ordered(agents)
    }

    static let noWaitingAgentHint = "No agent is waiting on you"

    /// Next Waiting Agent (⌘J): to the agent blocked on the user the
    /// longest, then on to the next one at each press (see
    /// `WaitingAgentQueue.next`), whatever its workspace or space. With
    /// none, a hint says so, without a beep.
    func jumpToNextWaitingAgent() {
        let queue = waitingAgentQueue(snapshot: ProcessSnapshot(), now: Date().timeIntervalSince1970)
        let current = activeWorkspace.flatMap { $0.columns[safe: $0.focusedIndex] }?.id
        guard let next = WaitingAgentQueue.next(from: current, lastJump: quickSwitch.lastJump, in: queue),
              let workspace = workspaces.first(where: { $0.id == next.workspaceID }),
              let columnIndex = workspace.columns.firstIndex(where: { $0.id == next.columnID }) else {
            quickSwitch.lastJump = nil
            showTransientHint(Self.noWaitingAgentHint)
            return
        }
        quickSwitch.lastJump = next.columnID
        if commandPalette?.isVisible == true { commandPalette?.dismiss() }
        focusWorkspace(id: workspace.id, column: columnIndex)
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
        switch state {
        case .working: self.init(text: state.label(now: now), tone: .working)
        case .waiting: self.init(text: state.label(now: now), tone: .waiting)
        case .failed: self.init(text: state.label(now: now), tone: .failure)
        }
    }
}
