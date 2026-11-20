import AppKit

/// What the shell keeps of a workspace switch while it plays.
@MainActor
final class WorkspaceSwitchState {
    /// The workspace a switch leaves, its terminals drawn until the switch
    /// ends: it shows under the one chosen.
    var keepsDrawn: Set<String> = []
    /// A switch plays.
    var isSwitching = false
    /// A ⌘↑ ⌘↓ is being handled: its relayout keeps the card, whose words
    /// are about to change.
    var isAnnouncing = false
    /// The space the strip showed at its last layout: a strip of another
    /// space doesn't slide in from this one's place.
    var shownSpaceID: String?
    /// Takes the card away at the user's first key, click or scroll once
    /// the view stopped, while the card shows.
    var inputMonitor: Any?
    /// The workspace on screen at the last layout: the one a switch leaves.
    var shownWorkspaceID: String?
    /// The floors a switch shows while it plays (`playFloors`): the
    /// workspace it leaves and the one it lands on.
    var floors: (leaving: String, arriving: String)?
    /// Tells a pending end of a switch, or of the card, whether it still
    /// applies.
    var switchGeneration = 0
    var cardGeneration = 0
    /// Runs the delays; tests pass a clock they advance by hand.
    var schedule: MainActorSchedule = mainQueueSchedule
}

// MARK: - A workspace switch (study N1, its floors from study P3)

/// The workspace chosen comes on screen as a floor. Going down the list
/// (⌘↓), it rises from below over the one on screen, which steps back under
/// a shade; going up (⌘↑), the one on screen leaves downwards and uncovers
/// it, coming forward out of the shade. Only translations: no text scales.
/// A card in the middle of the viewport names the workspace, with its state
/// and its place in the list. A new switch while one plays ends it at once.
/// Nothing of this plays while the interface may not move
/// (`agentLightsMayMove`), into another space, or when the workspace that
/// was on screen left the list: the workspace shows at once.
extension NiruxShellView {
    static let workspaceSwitchDuration: CFTimeInterval = 0.44
    static let floorsKey = "floors"
    static let floorsShadeName = "nirux.floors.shade"
    /// How far the floor underneath steps back, against the viewport's
    /// height, and how dark its shade gets.
    static let floorsRecede: CGFloat = 0.06
    static let floorsShade: Float = 0.62
    /// How long the card stays once the switch is over.
    static let workspaceCardHold: CFTimeInterval = 0.6

    /// The workspace on screen before a relayout (see
    /// `playWorkspaceSwitch`).
    func workspaceOnScreenBeforeLayout() -> WorkspaceState? {
        guard let id = workspaceSwitch.shownWorkspaceID else { return nil }
        return workspaces.first { $0.id == id && !$0.containerView.isHidden }
    }

    /// After a relayout, the strip at its new place: the workspace chosen
    /// comes on screen as a floor (`playFloors`), when the interface may
    /// move. `leaving` is the workspace that was on screen. A relayout that
    /// keeps the same workspace on screen lets floors that play go on.
    func playWorkspaceSwitch(leaving: WorkspaceState?, animated: Bool) {
        let state = workspaceSwitch
        state.shownWorkspaceID = activeWorkspace?.id
        let sameSpace = state.shownSpaceID == nil || state.shownSpaceID == activeProfileID
        state.shownSpaceID = activeProfileID
        guard let arriving = activeWorkspace, let leaving, leaving !== arriving else { return keepFloors() }
        // Floors that play end here; what stays drawn passes to the next
        // ones with no sync between, which would turn their surfaces off and
        // on.
        removeFloors()
        guard animated, sameSpace, agentLightsMayMove, !leaving.containerView.isHidden else { return endWorkspaceSwitch() }
        playFloors(from: leaving, to: arriving)
    }

    /// After a relayout that keeps the workspace on screen: floors that play
    /// go on, the one beneath under it; unless the workspace they bring is
    /// no longer on screen, or the one beneath was hidden (moved, archived).
    private func keepFloors() {
        guard let floors = workspaceSwitch.floors else { return }
        guard floors.arriving == activeWorkspace?.id,
              workspaces.contains(where: { $0.id == floors.leaving && !$0.containerView.isHidden })
        else { return endWorkspaceSwitch() }
        placeFloorUnderneath()
        keepUnderBar()
    }

    /// The floors of a switch from `leaving` to `arriving`, both in the
    /// strip at their places: the one on top lies on a plate, so that
    /// nothing of the other shows through its air; the other lies under it,
    /// where the one chosen is, and stays drawn until the end.
    private func playFloors(from leaving: WorkspaceState, to arriving: WorkspaceState) {
        guard let leavingLayer = leaving.containerView.layer, let arrivingLayer = arriving.containerView.layer else { return }
        let state = workspaceSwitch
        let height = viewport.bounds.height
        // Down the list: the one chosen lies lower in the strip.
        let down = arriving.containerView.frame.minY < leaving.containerView.frame.minY
        let (top, bottom) = down ? (arrivingLayer, leavingLayer) : (leavingLayer, arrivingLayer)
        state.floors = (leaving.id, arriving.id)
        state.keepsDrawn = [leaving.id]
        state.isSwitching = true
        top.zPosition = 1
        top.backgroundColor = Theme.Color.canvas.cgColor
        placeFloorUnderneath()

        let shade = CALayer()
        shade.name = Self.floorsShadeName
        shade.frame = bottom.bounds
        shade.backgroundColor = Theme.Color.base.cgColor
        shade.opacity = 0
        bottom.addSublayer(shade)
        let rest = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
        let recede = height * Self.floorsRecede
        if down {
            arrivingLayer.add(Self.floorMove(from: -height, to: 0, curve: rest), forKey: Self.floorsKey)
            leavingLayer.add(Self.floorMove(from: 0, to: recede, curve: rest), forKey: Self.floorsKey)
            shade.add(Self.floorShade(from: 0, to: Self.floorsShade, curve: rest), forKey: Self.floorsKey)
        } else {
            let away = CAMediaTimingFunction(controlPoints: 0.45, 0, 0.2, 1)
            leavingLayer.add(Self.floorMove(from: 0, to: -height, curve: away), forKey: Self.floorsKey)
            arrivingLayer.add(Self.floorMove(from: recede, to: 0, curve: rest), forKey: Self.floorsKey)
            shade.add(Self.floorShade(from: Self.floorsShade, to: 0, curve: rest), forKey: Self.floorsKey)
        }
        passUnderBar([leaving, arriving])
        state.switchGeneration += 1
        let generation = state.switchGeneration
        // Not on the animation's completion, which a window out of view may
        // never report.
        state.schedule(Self.workspaceSwitchDuration) { [weak self] in
            guard let self, self.workspaceSwitch.switchGeneration == generation else { return }
            self.endWorkspaceSwitch()
        }
    }

    /// A floor's way, added to where it lies: it holds its end until the
    /// switch is over.
    private static func floorMove(from: CGFloat, to: CGFloat, curve: CAMediaTimingFunction) -> CABasicAnimation {
        let move = CABasicAnimation(keyPath: "transform.translation.y")
        move.isAdditive = true
        move.fromValue = from
        move.toValue = to
        return holding(move, curve: curve)
    }

    private static func floorShade(from: Float, to: Float, curve: CAMediaTimingFunction) -> CABasicAnimation {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from
        fade.toValue = to
        return holding(fade, curve: curve)
    }

    private static func holding(_ animation: CABasicAnimation, curve: CAMediaTimingFunction) -> CABasicAnimation {
        animation.duration = workspaceSwitchDuration
        animation.timingFunction = curve
        animation.fillMode = .forwards
        animation.isRemovedOnCompletion = false
        return animation
    }

    /// The floor a switch leaves, laid where the one chosen is while it
    /// plays, its shade over the whole floor beneath; again after a relayout
    /// that moves the strip or resizes the viewport meanwhile.
    private func placeFloorUnderneath() {
        guard let floors = workspaceSwitch.floors,
              let leaving = workspaces.first(where: { $0.id == floors.leaving }),
              let arriving = workspaces.first(where: { $0.id == floors.arriving })
        else { return }
        let offset = arriving.containerView.frame.minY - leaving.containerView.frame.minY
        leaving.containerView.layer?.setAffineTransform(CGAffineTransform(translationX: 0, y: offset))
        for layer in [leaving, arriving].compactMap({ $0.containerView.layer }) {
            for shade in layer.sublayers ?? [] where shade.name == Self.floorsShadeName { shade.frame = layer.bounds }
        }
    }

    /// The switch is over: the floors back in the strip, and only the
    /// workspace on screen draws its terminals.
    func endWorkspaceSwitch() {
        let state = workspaceSwitch
        state.switchGeneration += 1
        state.isSwitching = false
        removeFloors()
        guard !state.keepsDrawn.isEmpty else { return }
        state.keepsDrawn = []
        syncTerminalOcclusion()
    }

    /// The floors back in the strip: no move, no offset, no plate, no shade.
    private func removeFloors() {
        if !ZZ("notEnded") { endUnderBar() }
        guard let floors = workspaceSwitch.floors else { return }
        workspaceSwitch.floors = nil
        for workspace in workspaces where [floors.leaving, floors.arriving].contains(workspace.id) {
            guard let layer = workspace.containerView.layer else { continue }
            layer.removeAnimation(forKey: Self.floorsKey)
            layer.setAffineTransform(.identity)
            layer.zPosition = 0
            layer.backgroundColor = nil
            layer.sublayers?.filter { $0.name == Self.floorsShadeName }.forEach { $0.removeFromSuperlayer() }
        }
    }

    /// Whether the terminals of `workspace` draw: the workspace on screen,
    /// and one the strip is leaving, until it has left.
    func drawsTerminals(of workspace: WorkspaceState, isActive: Bool) -> Bool {
        // Under the space's plan, nothing draws: it shows frozen pictures,
        // taken once every workspace it lists drew.
        planDrawing.contains(workspace.id)
            || (spacePlan == nil && (isActive || workspaceSwitch.keepsDrawn.contains(workspace.id)))
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
            workspaceID: workspace.id, name: workspace.title, state: info?.stateIcon ?? StateIcon(.idle),
            position: position, count: names.count, widestName: names.max { $0.count < $1.count } ?? workspace.title
        )
        workspaceNameCard.show(content, centredIn: viewportRestFrame.insetBy(dx: 24, dy: 24), animated: true)
        let state = workspaceSwitch
        if state.inputMonitor == nil {
            state.inputMonitor = sideEffects.watchUserInput { [weak self] in self?.workspaceCardSawInput() }
        }
        state.cardGeneration += 1
        let generation = state.cardGeneration
        state.schedule(Self.workspaceSwitchDuration + Self.workspaceCardHold) { [weak self] in
            guard let self, self.workspaceSwitch.cardGeneration == generation else { return }
            self.hideWorkspaceCard(animated: self.agentLightsMayMove)
        }
    }

    /// A key, a click or a scroll while the card shows: once the view has
    /// stopped, the user reads or works there, and the card goes. During
    /// the slide (another ⌘↓) it stays.
    func workspaceCardSawInput() {
        guard workspaceNameCard.isShown, !workspaceSwitch.isSwitching else { return }
        hideWorkspaceCard(animated: agentLightsMayMove)
    }

    /// A key the app is about to handle (see `NiruxApp.setupKeyInterceptor`,
    /// which sees the terminals' keys before they are consumed). The
    /// workspace steps (⌘↑ ⌘↓, ⌃↑ ⌃↓) change the card's words instead.
    func workspaceCardSawKey(_ event: NSEvent) {
        let steps = event.modifierFlags.intersection([.command, .control]).isEmpty == false
            && [125, 126].contains(event.keyCode)
        if !steps { workspaceCardSawInput() }
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
}
