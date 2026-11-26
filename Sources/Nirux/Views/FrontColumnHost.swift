import AppKit

/// What lies over a workspace's row while its front editor column is up
/// (`WorkspaceState.front`): a shade dimming the row, whose click sends
/// the column back, and the column's shadow. It takes no click while the
/// column is down.
@MainActor
final class FrontColumnHost: NSView {
    private let shade = FrontShadeView()
    private let cardShadow = ColumnShadowView(frame: .zero)
    private(set) var isShown = false
    private var fades = 0
    static let fadeKey = "frontFade"
    /// Gets a click on the shade, in this view's coordinates.
    var onShadeClick: (NSPoint) -> Void = { _ in }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        shade.wantsLayer = true
        shade.layer?.backgroundColor = Theme.Color.frontShade.cgColor
        shade.onClick = { [weak self] point in
            guard let self else { return }
            self.onShadeClick(self.convert(point, from: self.shade))
        }
        cardShadow.show(.floating, animated: false)
        for view in [shade, cardShadow] {
            view.isHidden = true
            addSubview(view)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { isShown ? super.hitTest(point) : nil }

    /// The column's view, above the shade and its shadow.
    func addFront(_ view: NSView) { addSubview(view) }

    /// The shade spans the host; the shadow lies under the column's `frame`.
    func place(front frame: NSRect) {
        shade.frame = bounds
        cardShadow.frame = frame
    }

    /// Up, the shade and the shadow show and the shade takes the row's
    /// clicks; down, they fade out, then hide on time.
    func setShown(_ shown: Bool, duration: CFTimeInterval?) {
        isShown = shown
        fades += 1
        let fade = fades
        for view in [shade, cardShadow] {
            let from = view.isHidden ? 0 : view.layer?.presentation()?.opacity ?? Float(view.alphaValue)
            view.layer?.removeAnimation(forKey: Self.fadeKey)
            if shown { view.isHidden = false }
            view.alphaValue = shown ? 1 : 0
            guard let duration, let layer = view.layer else { continue }
            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = from
            animation.toValue = shown ? 1 : 0
            animation.duration = duration
            layer.add(animation, forKey: Self.fadeKey)
        }
        guard !shown else { return }
        guard let duration else { return hideIfStill(fade) }
        ColumnState.afterCommit(duration) { [weak self] in self?.hideIfStill(fade) }
    }

    private func hideIfStill(_ fade: Int) {
        guard fades == fade else { return }
        shade.isHidden = true
        cardShadow.isHidden = true
    }
}

/// The shade over the row: a click on it goes to the host.
private final class FrontShadeView: NSView {
    var onClick: (NSPoint) -> Void = { _ in }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onClick(convert(event.locationInWindow, from: nil))
    }
}
