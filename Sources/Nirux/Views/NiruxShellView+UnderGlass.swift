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

    /// No line marks the edge of a rail that floats.
    func showDivider() {
        divider.isHidden = railFloats
    }

    /// The columns of `workspace` slide for `duration`. Meanwhile the
    /// viewport's layer reaches under the sidebar, its content where it lay,
    /// and the workspace leaves its cards unclipped. Only the layer: the
    /// view, its frame and its clicks stay put.
    func passUnderRail(_ workspace: WorkspaceState, for duration: CFTimeInterval) {
        let reach = viewport.frame.minX - sidebar.frame.minX
        guard railFloats, agentLightsMayMove, reach > 0, let layer = viewport.layer else { return }
        endUnderGlass()
        let generation = underGlassGeneration
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        Self.reach(layer, by: reach)
        workspace.containerView.layer?.masksToBounds = false
        CATransaction.commit()
        ColumnState.afterCommit(duration) { [weak self] in
            guard let self, underGlassGeneration == generation else { return }
            closeUnderRail(generation)
        }
    }

    /// The work's edge sweeps back to the rail's, its content still; then
    /// the workspace clips its cards again.
    private func closeUnderRail(_ generation: Int) {
        guard let layer = viewport.layer else { return }
        let reached = [("position", NSValue(point: layer.position)), ("bounds", NSValue(rect: layer.bounds))]
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        Self.reach(layer, by: layer.bounds.minX)
        CATransaction.commit()
        let curve = CAMediaTimingFunction(name: .easeInEaseOut)
        for (key, value) in reached {
            let edge = CABasicAnimation(keyPath: key)
            edge.fromValue = value
            edge.duration = Self.underGlassClose
            edge.timingFunction = curve
            layer.add(edge, forKey: "underGlass." + key)
        }
        ColumnState.afterCommit(Self.underGlassClose) { [weak self] in
            guard let self, underGlassGeneration == generation else { return }
            endUnderGlass()
        }
    }

    /// At rest: the viewport's layer where its view lies, every workspace
    /// clipping its cards, and no pass left to end.
    func endUnderGlass() {
        underGlassGeneration += 1
        guard let layer = viewport.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for key in Self.underGlassKeys { layer.removeAnimation(forKey: key) }
        if layer.bounds.minX < 0 { Self.reach(layer, by: layer.bounds.minX) }
        for workspace in workspaces where workspace.containerView.layer?.masksToBounds == false {
            workspace.containerView.layer?.masksToBounds = true
        }
        CATransaction.commit()
    }

    /// `layer`'s left edge `distance` further left (back when negative),
    /// what it holds where it was.
    private static func reach(_ layer: CALayer, by distance: CGFloat) {
        var frame = layer.frame
        frame.origin.x -= distance
        frame.size.width += distance
        layer.frame = frame
        layer.bounds.origin.x -= distance
    }
}
