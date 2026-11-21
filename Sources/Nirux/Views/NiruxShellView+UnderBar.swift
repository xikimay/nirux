import AppKit

/// Depth study P6, its second part (docs/design/glass-interface.md): the
/// command bar is an island of macOS's glass over the work. While floors
/// play (a workspace switch), what moves passes under it: the viewport
/// reaches up under the title band, which a frost like the window's covers
/// but for the bar, so only the bar shows the work passing, through its
/// glass. At rest nothing lies under it.
extension NiruxShellView {
    /// In macOS's own glass (26 and later, which refracts what passes under
    /// it), above Opaque.
    var barFloats: Bool {
        sideEffects.drawsGlass() && drawnTransparency.usesGlass
    }

    /// The title band over the shell and the bar in it, in the shell's
    /// coordinates; nil without the bar over the band (no toolbar, or full
    /// screen's own toolbar window).
    var titleBand: (band: NSRect, bar: NSRect)? {
        guard let window, let content = window.contentView, let bar = commandBarToolbar?.bar, bar.window === window, !bar.isHiddenOrHasHiddenAncestor else { return nil }
        let shell = convert(bounds, to: nil)
        let height = content.convert(content.bounds, to: nil).maxY - shell.maxY
        guard height > 0 else { return nil }
        let band = convert(NSRect(x: shell.minX, y: shell.maxY, width: shell.width, height: height), from: nil)
        let barFrame = convert(bar.bounds, from: bar)
        guard band.intersects(barFrame) else { return nil }
        return (band, barFrame)
    }

    /// Floors start to play: the work passes under the bar until they end
    /// (`endUnderBar`, from `removeFloors`). Every row but theirs turns
    /// clear meanwhile, so that only what moves shows under the bar.
    func passUnderBar(_ floors: [WorkspaceState]) {
        endUnderBar()
        guard barFloats, agentLightsMayMove, let place = titleBand else { return }
        let cover = TitleBandCover(frame: place.band, level: drawnTransparency)
        titleBandCover = cover
        addSubview(cover)
        for workspace in workspaces where !floors.contains(where: { $0 === workspace }) { workspace.containerView.alphaValue = 0 }
        reachUnderBar(place)
    }

    /// After a layout while floors play: the pass goes on as long as the bar
    /// floats and the interface may move.
    func keepUnderBar() {
        guard titleBandCover != nil else { return }
        guard barFloats, agentLightsMayMove, let place = titleBand else { return endUnderBar() }
        reachUnderBar(place)
    }

    /// The viewport's top up to the band's (its frame alone: what it holds,
    /// laid out from its bottom, stays), the cover over the band, open
    /// where the bar lies.
    private func reachUnderBar(_ place: (band: NSRect, bar: NSRect)) {
        titleBandCover?.frame = place.band
        titleBandCover?.open(NSRect(origin: NSPoint(x: place.bar.minX - place.band.minX, y: place.bar.minY - place.band.minY), size: place.bar.size))
        let reach = place.band.maxY - viewport.frame.maxY
        if reach > 0 { viewport.frame.size.height += reach }
    }

    /// At rest: the viewport's top at the shell's, no cover, every row
    /// shown.
    func endUnderBar() {
        guard let cover = titleBandCover else { return }
        titleBandCover = nil
        cover.removeFromSuperview()
        let reach = viewport.frame.maxY - bounds.maxY
        if reach > 0 { viewport.frame.size.height -= reach }
        for workspace in workspaces where workspace.containerView.alphaValue == 0 { workspace.containerView.alphaValue = 1 }
    }
}

/// The window's frost over the title band, open where the command bar lies:
/// while the work reaches under the band, only the bar shows it.
final class TitleBandCover: NSView {
    private let frost = NSVisualEffectView()
    private let tint = Tint()
    /// Where the bar lies, left open.
    private(set) var opening = NSRect.zero

    init(frame: NSRect, level: InterfaceTransparency) {
        super.init(frame: frame)
        MainWindowContent.makeDesktopFrost(frost, in: bounds)
        tint.frame = bounds
        tint.autoresizingMask = [.width, .height]
        show(level)
        for view in [frost, tint] { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ level: InterfaceTransparency) {
        tint.color = Theme.Color.canvas.withAlphaComponent(GlassView.tintAlpha(for: level, role: .chrome))
    }

    /// `bar`, in this view, left open: a capsule, as the bar is.
    func open(_ bar: NSRect) {
        guard bar != opening || frost.maskImage?.size != bounds.size else { return }
        opening = bar
        let shape = Self.shape(of: bounds.size, open: bar)
        frost.maskImage = NSImage(size: bounds.size, flipped: false) { _ in
            NSColor.black.setFill()
            shape.fill()
            return true
        }
        tint.shape = shape
    }

    /// The band less the bar's capsule.
    private static func shape(of size: NSSize, open bar: NSRect) -> NSBezierPath {
        let shape = NSBezierPath(rect: NSRect(origin: .zero, size: size))
        shape.append(NSBezierPath(roundedRect: bar, xRadius: bar.height / 2, yRadius: bar.height / 2))
        shape.windingRule = .evenOdd
        return shape
    }

    /// The canvas at the level's alpha, as the window's own tint.
    private final class Tint: NSView {
        var color = NSColor.clear { didSet { if color != oldValue { needsDisplay = true } } }
        var shape: NSBezierPath? { didSet { needsDisplay = true } }

        override func draw(_ dirtyRect: NSRect) {
            color.setFill()
            shape?.fill()
        }
    }
}
