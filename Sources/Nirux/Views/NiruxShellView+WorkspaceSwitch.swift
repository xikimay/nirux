import AppKit

/// What the shell keeps of a workspace switch while it plays.
@MainActor
final class WorkspaceSwitchState {
    /// The workspaces whose terminals stay drawn until the slide ends: the
    /// ones the strip is leaving, so they don't go blank while seen.
    var keepsDrawn: Set<String> = []
    /// The workspace the strip showed when it last settled or started a
    /// slide.
    var shownWorkspaceID: String?
    /// Tells a pending end of slide, or of the card, whether it still
    /// applies.
    var slideGeneration = 0
    var cardGeneration = 0
    /// Runs the delays; tests pass a clock they advance by hand.
    var schedule: MainActorSchedule = mainQueueSchedule
    /// Where the strip is on screen, against its place, while it slides
    /// (its presentation layer's offset); tests say.
    var shownStripOffset: (CALayer) -> CGFloat = { layer in
        (layer.presentation()?.value(forKeyPath: "transform.translation.y") as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0
    }
}

// MARK: - A workspace switch (study N1)

/// The strip slides to the workspace chosen, and a card in the middle of
/// the viewport names it, with its state and its place in the list. A
/// new switch while one plays takes the strip on from where it is on
/// screen and changes the card's words: a held key or quick presses never
/// queue anything. Nothing of this plays while the interface may not move
/// (`agentLightsMayMove`): the workspace shows at once, as it did.
extension NiruxShellView {
    static let workspaceSlideKey = "wsSlide"
    static let workspaceSlideDuration: CFTimeInterval = 0.3
    /// How long the card stays once the strip settled.
    static let workspaceCardHold: CFTimeInterval = 0.6

    /// Where the strip slides from, against its new place: from where it
    /// is on screen (`shownOffset` off its old place, while a slide plays),
    /// not from where the last slide was headed.
    nonisolated static func workspaceSlideStart(oldY: CGFloat, targetY: CGFloat, shownOffset: CGFloat) -> CGFloat {
        oldY + shownOffset - targetY
    }

    /// The strip moves from `oldY` to its new place (already set) after a
    /// selection: by a slide, when the interface may move. The workspace
    /// it leaves stays drawn until the slide ends.
    func slideWorkspaceStrip(from oldY: CGFloat, animated: Bool) {
        let state = workspaceSwitch
        let targetY = verticalStrip.frame.origin.y
        let leaving = state.shownWorkspaceID
        state.shownWorkspaceID = activeWorkspace?.id
        // The strip didn't move (a relayout for something else): a slide
        // that plays carries on.
        guard oldY != targetY, let layer = verticalStrip.layer else { return }
        let shownOffset = layer.animation(forKey: Self.workspaceSlideKey) != nil ? state.shownStripOffset(layer) : 0
        let start = Self.workspaceSlideStart(oldY: oldY, targetY: targetY, shownOffset: shownOffset)
        guard animated, agentLightsMayMove, abs(start) > 0.5 else {
            layer.removeAnimation(forKey: Self.workspaceSlideKey)
            endWorkspaceSlide()
            return
        }
        if let leaving, leaving != activeWorkspace?.id { state.keepsDrawn.insert(leaving) }
        let slide = CABasicAnimation(keyPath: "transform.translation.y")
        slide.fromValue = start
        slide.toValue = 0
        slide.duration = Self.workspaceSlideDuration
        slide.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1)
        // In place of the one running, if any: never one after another.
        layer.add(slide, forKey: Self.workspaceSlideKey)
        state.slideGeneration += 1
        let generation = state.slideGeneration
        // Not on the animation's completion, which a window out of view may
        // never report.
        state.schedule(Self.workspaceSlideDuration) { [weak self] in
            guard let self, self.workspaceSwitch.slideGeneration == generation else { return }
            self.endWorkspaceSlide()
        }
    }

    /// The strip settled: only the workspace on screen draws its terminals.
    func endWorkspaceSlide() {
        workspaceSwitch.slideGeneration += 1
        guard !workspaceSwitch.keepsDrawn.isEmpty else { return }
        workspaceSwitch.keepsDrawn = []
        syncTerminalOcclusion()
    }

    /// Whether the terminals of `workspace` draw: the workspace on screen,
    /// and one the strip is leaving, until it has left.
    func drawsTerminals(of workspace: WorkspaceState, isActive: Bool) -> Bool {
        isActive || workspaceSwitch.keepsDrawn.contains(workspace.id)
    }

    /// The user switched workspaces (⌘↑ ⌘↓, the palette, a notification):
    /// the card names the workspace on screen, while the strip moves and a
    /// moment after. Not for a click on its own row: the user knows where
    /// they go.
    func announceWorkspaceSwitch() {
        guard agentLightsMayMove, let workspace = activeWorkspace,
              let position = activeVisibleWorkspacePosition else {
            workspaceNameCard.hide(animated: false)
            return
        }
        let info = sidebar.lastInfos.first { $0.id == workspace.id }
        let content = WorkspaceNameCard.Content(
            name: workspace.title, state: info.map(Self.cardStateColor) ?? Theme.Color.idle,
            position: position, count: visibleWorkspaceIndices.count
        )
        workspaceNameCard.show(content, centredIn: viewport.frame.insetBy(dx: 24, dy: 24), animated: true)
        let state = workspaceSwitch
        state.cardGeneration += 1
        let generation = state.cardGeneration
        state.schedule(Self.workspaceSlideDuration + Self.workspaceCardHold) { [weak self] in
            guard let self, self.workspaceSwitch.cardGeneration == generation else { return }
            self.workspaceNameCard.hide(animated: self.agentLightsMayMove)
        }
    }

    /// The card's dot: what waits on the user or broke, else work, else
    /// grey. Amber only for a wait on the user.
    static func cardStateColor(_ info: WorkspaceInfo) -> NSColor {
        if let signal = info.attention, signal != .finished { return SidebarRenderer.color(for: signal) }
        return info.columns.contains { $0.agentStatus == .working } ? Theme.Color.working : Theme.Color.idle
    }
}
