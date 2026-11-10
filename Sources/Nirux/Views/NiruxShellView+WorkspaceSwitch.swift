import AppKit

/// What the shell keeps of a workspace switch while it plays.
@MainActor
final class WorkspaceSwitchState {
    /// The workspaces whose terminals stay drawn until the slide ends: the
    /// ones the slide shows on its way, so none goes blank while seen.
    var keepsDrawn: Set<String> = []
    /// A slide plays.
    var isSliding = false
    /// A ⌘↑ ⌘↓ is being handled: its relayout keeps the card, whose words
    /// are about to change.
    var isAnnouncing = false
    /// The space the strip showed at its last layout: a strip of another
    /// space doesn't slide in from this one's place.
    var shownSpaceID: String?
    /// Takes the card away at the user's first key, click or scroll once
    /// the view stopped, while the card shows.
    var inputMonitor: Any?
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

    /// Where the strip slides from, against its new place: so that the
    /// workspace that was on screen starts where it was seen. `shownOffset`
    /// is how far off its old place the strip showed (a slide playing);
    /// `leavingWas` and `leavingIs` are that workspace's place in the strip
    /// before and after (nil: it left the list). A workspace that stays on
    /// screen, the list changing around it (a row moved, archived), starts
    /// where it is: no slide.
    nonisolated static func workspaceSlideStart(
        oldY: CGFloat, targetY: CGFloat, shownOffset: CGFloat, leavingWas: CGFloat?, leavingIs: CGFloat?
    ) -> CGFloat {
        guard let leavingWas, let leavingIs else { return oldY + shownOffset - targetY }
        return (oldY + leavingWas + shownOffset) - (targetY + leavingIs)
    }

    /// The workspace on screen before a relayout, and its place in the
    /// strip then (see `slideWorkspaceStrip`).
    func workspaceOnScreenBeforeLayout() -> (workspace: WorkspaceState, y: CGFloat)? {
        guard let id = workspaceSwitch.shownWorkspaceID,
              let workspace = workspaces.first(where: { $0.id == id && !$0.containerView.isHidden })
        else { return nil }
        return (workspace, workspace.containerView.frame.origin.y)
    }

    /// The strip moves from `oldY` to its new place (already set) after a
    /// relayout: by a slide, when the interface may move. `leaving` is
    /// the workspace that was on screen and its place in the strip then:
    /// it stays drawn until the slide ends.
    func slideWorkspaceStrip(from oldY: CGFloat, leaving: (workspace: WorkspaceState, y: CGFloat)?, animated: Bool) {
        let state = workspaceSwitch
        let targetY = verticalStrip.frame.origin.y
        state.shownWorkspaceID = activeWorkspace?.id
        let sameSpace = state.shownSpaceID == nil || state.shownSpaceID == activeProfileID
        state.shownSpaceID = activeProfileID
        // The strip didn't move (a relayout for something else): a slide
        // that plays carries on.
        guard oldY != targetY, let layer = verticalStrip.layer else { return }
        // A slide still plays (its own end not reached yet).
        let isRetarget = state.isSliding && layer.animation(forKey: Self.workspaceSlideKey) != nil
        let shownOffset = isRetarget ? state.shownStripOffset(layer) : 0
        let stillListed = leaving.flatMap { $0.workspace.containerView.isHidden ? nil : $0.workspace }
        let start = Self.workspaceSlideStart(
            oldY: oldY, targetY: targetY, shownOffset: shownOffset,
            leavingWas: stillListed == nil ? nil : leaving?.y, leavingIs: stillListed?.containerView.frame.origin.y
        )
        // A relayout that isn't animated (the status bar, a task started
        // in the background) doesn't cut a slide that plays: it goes on
        // from where it is.
        let slides = animated
        _ = sameSpace
        guard slides, agentLightsMayMove, abs(start) > 0.5 else {
            layer.removeAnimation(forKey: Self.workspaceSlideKey)
            endWorkspaceSlide()
            return
        }
        state.keepsDrawn = []
        state.isSliding = true
        let slide = CABasicAnimation(keyPath: "transform.translation.y")
        slide.fromValue = start
        slide.toValue = 0
        slide.duration = Self.workspaceSlideDuration
        // Taken on mid-way, it keeps going rather than starting again from
        // rest: a held key doesn't make the strip stutter.
        slide.timingFunction = isRetarget
            ? CAMediaTimingFunction(controlPoints: 0, 0, 0.25, 1)
            : CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1)
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

    /// The workspaces other than the one on screen that a slide shows on
    /// its way, from `start` off the strip's place `targetY` back to it.
    func workspacesShown(slidingFrom start: CGFloat, to targetY: CGFloat) -> Set<String> {
        let height = viewport.bounds.height
        // The part of the strip in view at an offset: from -(targetY +
        // offset), the viewport's height up.
        let low = -(targetY + max(start, 0))
        let high = -(targetY + min(start, 0)) + height
        return Set(workspaces.filter { workspace in
            guard workspace !== activeWorkspace, !workspace.containerView.isHidden else { return false }
            let frame = workspace.containerView.frame
            return frame.maxY > low + 0.5 && frame.minY < high - 0.5
        }.map(\.id))
    }

    /// The strip settled: only the workspace on screen draws its terminals.
    func endWorkspaceSlide() {
        workspaceSwitch.slideGeneration += 1
        workspaceSwitch.isSliding = false
        guard !workspaceSwitch.keepsDrawn.isEmpty else { return }
        workspaceSwitch.keepsDrawn = []
        syncTerminalOcclusion()
    }

    /// Whether the terminals of `workspace` draw: the workspace on screen,
    /// and one the strip is leaving, until it has left.
    func drawsTerminals(of workspace: WorkspaceState, isActive: Bool) -> Bool {
        isActive || workspaceSwitch.keepsDrawn.contains(workspace.id)
    }

    /// The user moved to the workspace above or below (⌘↑ ⌘↓, see
    /// `focusWorkspace(_:)`): the card
    /// names the workspace on screen and its place, while the strip moves
    /// and a moment after, unless the user goes on meanwhile (a key, a
    /// click, a scroll). Not for a jump to a workspace the user named
    /// (its row, the palette) or that comes to them (a notification, an
    /// agent): it lands where they look, often on a question the card
    /// would cover.
    func announceWorkspaceSwitch() {
        guard agentLightsMayMove, let workspace = activeWorkspace,
              let position = activeVisibleWorkspacePosition else {
            hideWorkspaceCard(animated: false)
            return
        }
        let info = sidebar.lastInfos.first { $0.id == workspace.id }
        let names = visibleWorkspaceIndices.map { workspaces[$0].title }
        let content = WorkspaceNameCard.Content(
            workspaceID: workspace.id, name: workspace.title, state: info.map(Self.cardStateColor) ?? Theme.Color.idle,
            position: position, count: names.count, widestName: names.max { $0.count < $1.count } ?? workspace.title
        )
        workspaceNameCard.show(content, centredIn: viewport.frame.insetBy(dx: 24, dy: 24), animated: true)
        let state = workspaceSwitch
        if state.inputMonitor == nil {
            state.inputMonitor = sideEffects.watchUserInput { [weak self] in self?.workspaceCardSawInput() }
        }
        state.cardGeneration += 1
        let generation = state.cardGeneration
        state.schedule(Self.workspaceSlideDuration + Self.workspaceCardHold) { [weak self] in
            guard let self, self.workspaceSwitch.cardGeneration == generation else { return }
            self.hideWorkspaceCard(animated: self.agentLightsMayMove)
        }
    }

    /// A key, a click or a scroll while the card shows: once the view has
    /// stopped, the user reads or works there, and the card goes. During
    /// the slide (another ⌘↓) it stays.
    func workspaceCardSawInput() {
        guard workspaceNameCard.isShown, !workspaceSwitch.isSliding else { return }
        hideWorkspaceCard(animated: agentLightsMayMove)
    }

    /// A key the app is about to handle (see `NiruxApp.setupKeyInterceptor`,
    /// which sees the terminals' keys before they are consumed). The
    /// workspace steps (⌘↑ ⌘↓, ⌃↑ ⌃↓) change the card's words instead.
    func workspaceCardSawKey(_ event: NSEvent) {
        let steps = event.modifierFlags.intersection([.command, .control]).isEmpty == false
            && [125, 126].contains(event.keyCode)
        _ = steps
        workspaceCardSawInput()
    }

    func hideWorkspaceCard(animated: Bool) {
        workspaceSwitch.cardGeneration += 1
        workspaceNameCard.hide(animated: animated)
        if let monitor = workspaceSwitch.inputMonitor {
            sideEffects.stopWatchingUserInput(monitor)
            workspaceSwitch.inputMonitor = nil
        }
    }

    /// After a relayout: the card follows the viewport, and goes if the
    /// workspace on screen is no longer the one it names (a click on
    /// another row, a space switch, a close).
    func layOutWorkspaceCard(in viewportFrame: NSRect) {
        guard workspaceNameCard.isShown, let content = workspaceNameCard.content else { return }
        guard content.workspaceID == activeWorkspace?.id || workspaceSwitch.isAnnouncing else {
            return hideWorkspaceCard(animated: false)
        }
        workspaceNameCard.show(content, centredIn: viewportFrame.insetBy(dx: 24, dy: 24), animated: false)
    }

    /// The card's dot says what the workspace's row says: amber when it
    /// waits on the user, red when something broke, green while it works,
    /// else grey.
    static func cardStateColor(_ info: WorkspaceInfo) -> NSColor {
        switch info.rowSummary.mark {
        case .needsYou: return Theme.Color.waiting
        case .error: return Theme.Color.error
        case .working: return Theme.Color.working
        case .readyToMerge: return Theme.Color.idle
        case .merged: return Theme.Color.done
        default: return Theme.Color.idle
        }
    }
}
