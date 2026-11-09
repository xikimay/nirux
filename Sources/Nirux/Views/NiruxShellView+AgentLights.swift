import AppKit

/// What the shell keeps of the agents' lights between two refreshes.
@MainActor
final class AgentLightState {
    /// What the lights show, as of the last sidebar refresh.
    var plan = AgentLightPlan()
    var turnEnds = TurnEndSweeps()
    /// Between the screens' sleep and wake notifications.
    var isDisplayAsleep = CGDisplayIsAsleep(CGMainDisplayID()) != 0
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
            && sideEffects.windowShows(window)
    }

    func wireAgentLights() {
        for glow in [edgeGlowLeft, edgeGlowRight, edgeGlowTop, edgeGlowBottom] {
            glow.onClick = { [weak self] target in self?.goToAgent(target) }
        }
        // What decides whether lights move, beside the window's occlusion
        // (see `viewDidMoveToWindow`) and the layout.
        let center = NSWorkspace.shared.notificationCenter
        for (name, isAsleep) in [
            (NSWorkspace.screensDidSleepNotification, true), (NSWorkspace.screensDidWakeNotification, false)
        ] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.agentLights.isDisplayAsleep = isAsleep
                    self?.applyAgentLights()
                }
            }
        }
        center.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyAgentLights() }
        }
    }

    /// From a sidebar refresh, which already runs several times a second
    /// while an agent works: a light that doesn't change is left as it is.
    func updateAgentLights(infos: [WorkspaceInfo], now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        let active = activeWorkspace
        agentLights.plan = AgentLightPlan.make(infos: infos, activeIndex: activeWSIndex) { column in
            active.map { self.showsColumn(column.index, of: $0) } ?? false
        }
        let ended = agentLights.turnEnds.update(columns: infos.flatMap(\.columns), now: now)
        applyAgentLights(sweeping: ended)
    }

    /// Shows the plan as it stands. Also when only what may move changed:
    /// a relayout (the columns in view, the focused one), the window
    /// covered or back, the display asleep, Reduce motion, the setting.
    /// Lights breathe and pulse only for the columns in the viewport of
    /// the workspace on screen.
    func applyAgentLights(sweeping ended: Set<UUID> = []) {
        let plan = agentLights.plan
        let moves = agentLightsMayMove
        for workspace in workspaces {
            let isOnScreen = workspace === activeWorkspace
            for (index, column) in workspace.columns.enumerated() {
                let light = column.isClosing ? nil : plan.columns[column.id]
                let isInView = isOnScreen && workspace.isColumnInViewport(index)
                let sweeps = moves && isInView && ended.contains(column.id)
                guard light != nil || column.light != nil || sweeps else { continue }
                let view = workspace.light(for: column)
                view.show(light, moving: moves && isInView, soft: isOnScreen && index == workspace.focusedIndex)
                if sweeps { view.sweep() }
            }
        }
        for (glow, alert) in [
            (edgeGlowLeft, plan.left), (edgeGlowRight, plan.right), (edgeGlowTop, plan.top), (edgeGlowBottom, plan.bottom)
        ] {
            glow.show(
                alert.map { .alert($0.signal) }, moving: moves,
                target: alert.map { EdgeGlowView.Target(workspaceID: $0.workspaceID, columnID: $0.columnID, text: $0.text) }
            )
        }
        columnIndicator.pulses = moves
    }

    /// The user is back in the app and every attention was cleared: the
    /// waits' and errors' lights go at once, without the process scan a
    /// sidebar refresh costs. A dialog still open lights up again at the
    /// next refresh.
    func clearAgentAlertLights() {
        agentLights.plan.clearAlerts()
        applyAgentLights()
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

    /// A click on an edge's glow or its pill: to the agent it stands for,
    /// if it is still there.
    private func goToAgent(_ target: EdgeGlowView.Target) {
        guard let workspace = workspaces.first(where: { $0.id == target.workspaceID && !$0.isClosing }) else { return }
        let column = target.columnID.flatMap { id in workspace.columns.firstIndex { $0.id == id && !$0.isClosing } }
        focusWorkspace(id: workspace.id, column: column)
    }
}
