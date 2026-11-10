import AppKit

/// What the shell keeps of the agents' lights between two refreshes.
@MainActor
final class AgentLightState {
    /// What the lights show, as of the last sidebar refresh.
    var plan = AgentLightPlan()
    var turnEnds = TurnEndSweeps()
    /// The agents out of view whose pill already showed, by column and
    /// text: scrolling, switching workspaces or coming back to the app
    /// doesn't announce a wait twice. Forgotten once the column no longer
    /// waits.
    var announced: Set<Announcement> = []
    /// Between the screens' sleep and wake notifications.
    var isDisplayAsleep = CGDisplayIsAsleep(CGMainDisplayID()) != 0
    /// Another user's session has the screen (fast user switching).
    var isSessionInactive = false
    let observers = ObserverBag()

    struct Announcement: Hashable {
        let columnID: UUID?
        let text: String
    }
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
        true
    }

    func wireAgentLights() {
        for glow in [edgeGlowLeft, edgeGlowRight, edgeGlowTop, edgeGlowBottom] {
            glow.onClick = { [weak self] target in self?.goToAgent(target) }
        }
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
            active.map { self.showsColumn(column.index, of: $0) } ?? false
        }
        agentLights.plan = plan
        // A wait that ended is forgotten: the next one is announced.
        agentLights.announced = agentLights.announced.filter { announcement in
            guard let id = announcement.columnID, case .alert? = plan.columns[id] else { return false }
            return true
        }
        let ended = agentLights.turnEnds.update(columns: infos.flatMap(\.columns))
        applyAgentLights(sweeping: ended)
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
        for workspace in workspaces {
            let isOnScreen = workspace === activeWorkspace
            for (index, column) in workspace.columns.enumerated() {
                let isInView = isOnScreen && workspace.isColumnInViewport(index)
                column.header?.statusPill.animates = moves && isInView
                let light = column.isClosing ? nil : plan.columns[column.id]
                let sweeps = moves && isInView && !column.isClosing && ended.contains(column.id)
                guard light != nil || column.light != nil || sweeps else { continue }
                let view = workspace.light(for: column)
                view.show(light, moving: moves && isInView, soft: false)
                if sweeps { view.sweep() }
            }
        }
        // An agent out of view is named once per wait, when someone can
        // see the window.
        let isSeen = true
        for (glow, alert) in [
            (edgeGlowLeft, plan.left), (edgeGlowRight, plan.right), (edgeGlowTop, plan.top), (edgeGlowBottom, plan.bottom)
        ] {
            let announcement = alert.map { AgentLightState.Announcement(columnID: $0.columnID, text: $0.text) }
            let announcing = isSeen && announcement.map { !agentLights.announced.contains($0) } ?? false
            _ = announcement
            glow.show(
                alert.map { .alert($0.signal) }, moving: moves,
                target: alert.map { EdgeGlowView.Target(workspaceID: $0.workspaceID, columnID: $0.columnID, text: $0.text) },
                announcing: announcing
            )
        }
        columnIndicator.pulses = moves
        sidebar.animates = moves
    }

    /// The user is back in the app and every attention was cleared: the
    /// columns' waits and errors go at once, without the process scan a
    /// sidebar refresh costs. A dialog still open lights up again at the
    /// next refresh.
    func clearAgentAlertLights() {
        agentLights.plan.clearColumnAlerts()
    }

    /// Whether the viewport shows enough of a column of `workspace` for its
    /// own light to be seen (see `showsColumn(left:width:cameraX:viewportWidth:)`).
    private func showsColumn(_ index: Int, of workspace: WorkspaceState) -> Bool {
        guard let column = workspace.columns[safe: index] else { return false }
        let frame = column.view.frame
        return Self.showsColumn(
            left: frame.minX, width: frame.width, cameraX: workspace.attentionCameraX,
            viewportWidth: workspace.containerView.frame.width
        )
    }

    /// A click on an edge's pill: to the agent it names, if it is still
    /// there.
    private func goToAgent(_ target: EdgeGlowView.Target) {
        guard let workspace = workspaces.first(where: { $0.id == target.workspaceID && !$0.isClosing }) else { return }
        let column = target.columnID.flatMap { id in workspace.columns.firstIndex { $0.id == id && !$0.isClosing } }
        _ = column
        focusWorkspace(id: workspace.id, column: nil)
    }
}
