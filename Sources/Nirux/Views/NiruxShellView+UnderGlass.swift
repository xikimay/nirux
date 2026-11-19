import AppKit

/// Depth study P6, the glass in layers (docs/design/glass-interface.md):
/// folded, the rail is an island of macOS's glass over the work. While the
/// columns travel they pass under it, then the work's edge closes back to
/// the rail's: at rest nothing lies under the glass.
extension NiruxShellView {
    /// How long the work's edge takes to close back after a travel.
    static let underGlassClose: CFTimeInterval = 0.22
    private static let underGlassKeys = ["underGlass.position", "underGlass.bounds"]

    /// Folded, in macOS's own glass (26 and later, which refracts what
    /// passes under it; the rim of 14 and 15 would show the cards plainly),
    /// above Opaque.
    var railFloats: Bool {
        sidebar.showsRail && sideEffects.drawsGlass() && sideEffects.drawnTransparency(interfaceTransparency).usesGlass
    }

    /// Whether the rail floats may have changed: the divider follows, and a
    /// pass ends where it no longer floats.
    func railMayHaveChanged(animated: Bool) {
        showDivider(animated: animated)
        if !railFloats { endUnderGlass() }
    }

    /// No line marks the edge of a rail that floats. It fades with the
    /// sidebar's fold.
    private func showDivider(animated: Bool) {
        let opacity: Float = railFloats ? 0 : 1
        guard divider.layer?.opacity != opacity else { return }
        let shown = divider.layer?.presentation()?.opacity ?? 1 - opacity
        divider.alphaValue = CGFloat(opacity)
        guard animated, agentLightsMayMove, let layer = divider.layer else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = shown
        fade.toValue = opacity
        fade.duration = Self.chromeDuration
        layer.add(fade, forKey: "divider")
    }

    /// The columns of `workspace` slide for `duration`: they pass under the
    /// rail meanwhile.
    func passUnderRail(_ workspace: WorkspaceState, for duration: CFTimeInterval) {
        guard mayPassUnderRail(workspace) else { return }
        endUnderGlass()
        let generation = underGlassGeneration
        passingUnderRail = workspace
        reachUnderRail(workspace)
        sideEffects.afterCommit(duration) { [weak self] in
            guard let self, underGlassGeneration == generation else { return }
            closeUnderRail(generation)
        }
    }

    /// Before a layout: the viewport's layer where its view lies. A pass
    /// goes on through it (`keepUnderGlass`); a closing edge ends at once.
    func restUnderGlass() {
        guard passingUnderRail != nil, let layer = viewport.layer else { return endUnderGlass() }
        Self.reach(layer, by: layer.bounds.minX)
    }

    /// After a layout: a pass goes on as long as its workspace stays on
    /// screen and the rail floats.
    func keepUnderGlass() {
        guard let workspace = passingUnderRail else { return }
        guard workspace === activeWorkspace, mayPassUnderRail(workspace) else { return endUnderGlass() }
        reachUnderRail(workspace)
    }

    private func mayPassUnderRail(_ workspace: WorkspaceState) -> Bool {
        railFloats && agentLightsMayMove && viewport.frame.minX > sidebar.frame.minX && viewport.layer != nil
    }

    /// The viewport's layer reaches under the sidebar, what it holds where
    /// it lay, and the workspace leaves its cards unclipped. Only the
    /// layer: the view, its frame and its clicks stay put.
    private func reachUnderRail(_ workspace: WorkspaceState) {
        guard let layer = viewport.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        Self.reach(layer, by: viewport.frame.minX - sidebar.frame.minX + layer.bounds.minX)
        workspace.containerView.layer?.masksToBounds = false
        CATransaction.commit()
    }

    /// The work's edge sweeps back to the rail's, its content still; then
    /// the workspace clips its cards again.
    private func closeUnderRail(_ generation: Int) {
        guard let layer = viewport.layer, railFloats, passingUnderRail === activeWorkspace else { return endUnderGlass() }
        passingUnderRail = nil
        let reached = [("position", NSValue(point: layer.position)), ("bounds", NSValue(rect: layer.bounds))]
        Self.reach(layer, by: layer.bounds.minX)
        let curve = CAMediaTimingFunction(name: .easeInEaseOut)
        for (key, value) in reached {
            let edge = CABasicAnimation(keyPath: key)
            edge.fromValue = value
            edge.duration = Self.underGlassClose
            edge.timingFunction = curve
            layer.add(edge, forKey: "underGlass." + key)
        }
        sideEffects.afterCommit(Self.underGlassClose) { [weak self] in
            guard let self, underGlassGeneration == generation else { return }
            endUnderGlass()
        }
    }

    /// At rest: the viewport's layer where its view lies, every workspace
    /// clipping its cards, and no pass left to end.
    func endUnderGlass() {
        underGlassGeneration += 1
        passingUnderRail = nil
        guard let layer = viewport.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for key in Self.underGlassKeys { layer.removeAnimation(forKey: key) }
        Self.reach(layer, by: layer.bounds.minX)
        for workspace in workspaces where workspace.containerView.layer?.masksToBounds == false {
            workspace.containerView.layer?.masksToBounds = true
        }
        CATransaction.commit()
    }

    /// `layer`'s left edge `distance` further left (back when negative),
    /// what it holds where it was.
    private static func reach(_ layer: CALayer, by distance: CGFloat) {
        guard distance != 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var frame = layer.frame
        frame.origin.x -= distance
        frame.size.width += distance
        layer.frame = frame
        layer.bounds.origin.x -= distance
        CATransaction.commit()
    }
}
