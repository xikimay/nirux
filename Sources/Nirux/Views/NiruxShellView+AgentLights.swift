import AppKit

/// What the shell keeps of the agents' lights between two refreshes.
@MainActor
final class AgentLightState {
    /// What the lights show, as of the last sidebar refresh.
    var plan = AgentLightPlan()
    /// The columns whose agent just ended its turn, and when
    /// (`agentTurnDone`), until the next refresh shows it: one sweep of
    /// light each.
    var endedTurns: [UUID: TimeInterval] = [:]
    /// Between the screens' sleep and wake notifications.
    var isDisplayAsleep = CGDisplayIsAsleep(CGMainDisplayID()) != 0
    /// Another user's session has the screen (fast user switching).
    var isSessionInactive = false
    let observers = ObserverBag()
}

/// Notification observers that go away with their owner.
final class ObserverBag: @unchecked Sendable {
    private var tokens: [(center: NotificationCenter, token: NSObjectProtocol)] = []

    func add(_ token: NSObjectProtocol, on center: NotificationCenter) {
        tokens.append((center, token))
    }

    deinit {
        for entry in tokens { entry.center.removeObserver(entry.token) }
    }
}

// MARK: - An agent's state as light (see EdgeGlowView)

extension NiruxShellView {
    static func currentAnimatesInterface() -> Bool {
        Persistence.load()?.settings?.animatesInterface ?? true
    }

    /// Whether a light may breathe or pulse at all: animations are on,
    /// macOS doesn't reduce motion, and someone can see the window. A
    /// light that may not move shows its state steady.
    var agentLightsMayMove: Bool {
        animatesInterface && !sideEffects.reducesMotion() && !agentLights.isDisplayAsleep
            && !agentLights.isSessionInactive && sideEffects.windowShows(window)
    }

    func wireAgentLights() {
        // What decides whether lights move, beside the window's occlusion
        // (see `viewDidMoveToWindow`) and the layout.
        let center = NSWorkspace.shared.notificationCenter
        let changes: [(Notification.Name, @MainActor (AgentLightState) -> Void)] = [
            (NSWorkspace.screensDidSleepNotification, { $0.isDisplayAsleep = true }),
            (NSWorkspace.screensDidWakeNotification, { $0.isDisplayAsleep = false }),
            (NSWorkspace.sessionDidResignActiveNotification, { $0.isSessionInactive = true }),
            (NSWorkspace.sessionDidBecomeActiveNotification, { $0.isSessionInactive = false }),
            // Reduce motion, read when the lights are applied.
            (NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, { _ in })
        ]
        for (name, change) in changes {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    change(self.agentLights)
                    self.applyAgentLights()
                }
            }
            agentLights.observers.add(token, on: center)
        }
    }

    /// From a sidebar refresh, which already runs several times a second
    /// while an agent works: a light that doesn't change is left as it is.
    func updateAgentLights(infos: [WorkspaceInfo]) {
        let active = activeWorkspace
        let plan = AgentLightPlan.make(infos: infos, activeIndex: activeWSIndex) { column in
            active?.showsColumn(at: column.index) ?? false
        }
        agentLights.plan = plan
        // Now or never: a sweep says the turn just ended.
        let ended = Set(agentLights.endedTurns.keys)
        agentLights.endedTurns = [:]
        applyAgentLights(sweeping: ended)
        // After the lights: the sidebar knows by now whether it may move.
        sidebar.noteTurnEnded(workspaceIDs: Set(infos.filter { info in
            info.columns.contains { column in column.id.map(ended.contains) ?? false }
        }.map(\.id)))
    }

    /// Shows the plan as it stands. Also when only what may move changed:
    /// a relayout (the columns in view, the focused one), a column closing,
    /// the window covered or back, the display asleep, another user's
    /// session, Reduce motion, the setting. Lights breathe and pulse only
    /// for the columns in the viewport of the workspace on screen, and so
    /// do their headers' dots.
    func applyAgentLights(sweeping ended: Set<UUID> = []) {
        let plan = agentLights.plan
        let moves = agentLightsMayMove
        // Stillness wins over a pass under the rail or a crossing on its way.
        if !moves {
            stillUnderGlass()
            stillSpaceCrossing()
            stillSpacePlan()
        }
        for workspace in workspaces {
            let isOnScreen = workspace === activeWorkspace
            for (index, column) in workspace.columns.enumerated() {
                // Stillness wins over a lift on its way.
                if !moves { column.shadow?.settle() }
                let isInView = isOnScreen && workspace.showsColumn(at: index)
                column.header?.statusPill.animates = moves && isInView
                // None on a card coming or going: it would draw at full size.
                let isPassing = column.isClosing || column.isArriving
                let light = isPassing ? nil : plan.columns[column.id]
                let sweeps = moves && isInView && !isPassing && ended.contains(column.id)
                guard light != nil || column.light != nil || sweeps else { continue }
                let view = workspace.light(for: column)
                view.show(light, moving: moves && isInView, soft: isOnScreen && index == workspace.focusedIndex)
                if sweeps { view.sweep() }
            }
        }
        // An agent out of view lights its edge.
        for (glow, alert) in [
            (edgeGlowLeft, plan.left), (edgeGlowRight, plan.right), (edgeGlowTop, plan.top), (edgeGlowBottom, plan.bottom)
        ] {
            glow.show(alert.map { .alert($0.signal) }, moving: moves)
        }
        columnIndicator.pulses = moves
        sidebar.animates = moves
        commandBarToolbar?.bar.lifts = moves
    }

    /// A Claude turn end got its verdict (see `AgentHookCenter`): a Mission
    /// message may go to its prompt now, and the lights follow at once
    /// rather than at the next heartbeat, which doesn't beat while Nirux
    /// is in the background: the sweep of a turn that is done, the amber
    /// of one that asks.
    func turnEndSettled() {
        typeMissionMessages()
        scheduleMetadataRefresh()
    }

    /// The agent of `column` ended its turn at `endedAt`, and it is done as
    /// far as its hooks can tell (`AgentHookCenter.onTurnDone`): its column
    /// sweeps at the refresh that follows the hook event or the verdict,
    /// if it is in view then and the turn end still stands.
    func agentTurnDone(in column: ColumnState, endedAt: TimeInterval) {
        agentLights.endedTurns[column.id] = endedAt
    }

    /// At the start of a refresh, before it reads the agents again: a turn
    /// end the agent already left behind sweeps nothing (a prompt or a
    /// tool call that came with it in the same batch of hook events, or
    /// between its verdict and this refresh). Codex's closing output only
    /// reads as work once the refresh has read it: its sweep stays.
    func dropTurnEndsLeftBehind() {
        guard !agentLights.endedTurns.isEmpty else { return }
        let columns = Dictionary(
            workspaces.flatMap(\.columns).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
        )
        agentLights.endedTurns = agentLights.endedTurns.filter { id, endedAt in
            columns[id]?.pty?.isAgentTurnDone(endedAt: endedAt) == true
        }
    }

    /// The user is back in the app and every attention was cleared: the
    /// columns' waits and errors go at once, without the process scan a
    /// sidebar refresh costs. A dialog still open lights up again at the
    /// next refresh.
    func clearAgentAlertLights() {
        agentLights.plan.clearColumnAlerts()
        applyAgentLights()
    }
}
