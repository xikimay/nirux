import AppKit

/// The glass of the glass interface (docs/design/glass-interface.md):
/// `NSGlassEffectView` on macOS 26 and later, a frosted `NSVisualEffectView`
/// on macOS 14 and 15, a solid fill at Opaque. Content goes in
/// `contentView`, clipped to the rounded shape. Nothing shows one yet.
///
/// The tints are provisional: offscreen renders can't show the glass (the
/// window server draws it), so they get tuned with the user on a demo at the
/// end of phase 2. The frost blends within the window; the translucent
/// window (plan step 4.2) moves the chrome to blending behind it, and a
/// floating glass in a window of its own (⌘P if it stays a panel) needs the
/// same and no layer shadow: step 2.4 adds that if it does.
final class GlassView: NSView {
    enum Role: Sendable {
        /// The sidebar, the command bar, the rail: it follows the level.
        case chrome
        /// What floats over the work (the inbox, a callout, ⌘P under the
        /// bar): a thick background at every level, no glass on glass, and
        /// the floating shadow.
        case floating
    }

    /// How the glass is drawn.
    enum Backing: Equatable, Sendable {
        case solid, glass, frosted
    }

    let role: Role
    /// Where callers put what the glass holds: above the glass, or inside
    /// macOS 26's glass, which adapts it to what shows through.
    let contentView = NSView()

    /// The level the user picked. The view draws it made opaque where macOS
    /// asks (Reduce transparency, Increase contrast), and follows those
    /// settings as they change.
    var level: InterfaceTransparency {
        didSet { if level != oldValue { update() } }
    }

    var cornerRadius: CGFloat {
        didSet { if cornerRadius != oldValue { update() } }
    }

    /// Turns the picked level into the one to draw: macOS's settings as they
    /// are now, unless a test says otherwise (CI's runners reduce
    /// transparency).
    private let resolveLevel: @MainActor (InterfaceTransparency) -> InterfaceTransparency

    private(set) var backing: Backing?
    private var backingView: NSView?
    private var tintView: NSView?
    /// Casts the floating shadow, masked to outside the shape so that it
    /// never shows through the translucent glass.
    private let shadowLayer = CALayer()
    private let shadowMask = CAShapeLayer()

    init(
        role: Role, level: InterfaceTransparency, cornerRadius: CGFloat,
        resolveLevel: @escaping @MainActor (InterfaceTransparency) -> InterfaceTransparency = { $0.effectiveNow() }
    ) {
        self.role = role
        self.level = level
        self.cornerRadius = cornerRadius
        self.resolveLevel = resolveLevel
        super.init(frame: .zero)
        wantsLayer = true
        contentView.wantsLayer = true
        contentView.layer?.masksToBounds = true
        contentView.layer?.cornerCurve = .continuous
        contentView.autoresizingMask = [.width, .height]
        addSubview(contentView)
        shadowMask.fillRule = .evenOdd
        shadowLayer.mask = shadowMask
        layer?.insertSublayer(shadowLayer, at: 0)
        update()
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(accessibilityDisplayOptionsChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil
        )
    }

    @objc private func accessibilityDisplayOptionsChanged(_ notification: Notification) {
        update()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Solid at Opaque; otherwise the glass where macOS has it, the frost
    /// where it doesn't.
    static func backing(for level: InterfaceTransparency, hasGlass: Bool) -> Backing {
        guard level.usesGlass else { return .solid }
        return hasGlass ? .glass : .frosted
    }

    /// Opacity of the tint over the glass: the chrome lets more through as
    /// the level rises, what floats stays thick. Opaque is a solid fill.
    static func tintAlpha(for level: InterfaceTransparency, role: Role) -> CGFloat {
        switch (role, level) {
        case (_, .opaque): return 1
        case (.floating, _): return 0.88
        case (.chrome, .tinted): return 0.62
        case (.chrome, .glass): return 0.42
        case (.chrome, .clear): return 0.24
        }
    }

    /// The colour the tint is laid in, from `Theme`.
    static func tintColor(for role: Role) -> NSColor {
        role == .floating ? Theme.Color.raised : Theme.Color.base
    }

    private static var hasGlass: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }

    /// Rebuilds the backing only when its kind changes; a new tint, style or
    /// radius is applied in place.
    private func update() {
        let wanted = Self.backing(for: resolveLevel(level), hasGlass: Self.hasGlass)
        if wanted != backing { rebuild(wanted) }
        applyStyle()
        applyShape()
    }

    private func rebuild(_ wanted: Backing) {
        // Moving the content between the glass and this view takes it out of
        // the window for a moment: keep the keyboard where it was.
        let focused = Self.focusedView(in: window).flatMap { $0.isDescendant(of: contentView) ? $0 : nil }
        defer { if let focused, focused.window != nil, focused.window?.firstResponder !== focused { focused.window?.makeFirstResponder(focused) } }
        if #available(macOS 26, *), let glass = backingView as? NSGlassEffectView { glass.contentView = nil }
        backingView?.removeFromSuperview()
        tintView?.removeFromSuperview()
        backingView = nil
        tintView = nil
        if contentView.superview !== self {
            // The glass laid it out with constraints; here it follows frames.
            contentView.translatesAutoresizingMaskIntoConstraints = true
            contentView.frame = bounds
            addSubview(contentView)
        }
        backing = wanted
        switch wanted {
        case .solid:
            break
        case .glass:
            if #available(macOS 26, *) {
                let glass = NSGlassEffectView(frame: bounds)
                install(glass)
                // Inside the glass, so that what it holds stays legible on it.
                contentView.frame = glass.bounds
                glass.contentView = contentView
            }
        case .frosted:
            let frost = NSVisualEffectView(frame: bounds)
            frost.material = role == .floating ? .popover : .sidebar
            frost.blendingMode = .withinWindow
            frost.state = .active
            frost.wantsLayer = true
            frost.layer?.masksToBounds = true
            frost.layer?.cornerCurve = .continuous
            install(frost)
            // The frost has no tint of its own: one more layer, the same
            // shape.
            let tint = NSView(frame: bounds)
            tint.wantsLayer = true
            tint.layer?.cornerCurve = .continuous
            tint.autoresizingMask = [.width, .height]
            addSubview(tint, positioned: .below, relativeTo: contentView)
            tintView = tint
        }
    }

    /// Whether the floating shadow shows (for the tests).
    var castsShadow: Bool { !shadowLayer.isHidden && shadowLayer.shadowOpacity > 0 }

    /// The view holding the keyboard: a text field rather than the field
    /// editor that edits it for the moment.
    private static func focusedView(in window: NSWindow?) -> NSView? {
        let responder = window?.firstResponder
        if let editor = responder as? NSTextView, editor.isFieldEditor, let field = editor.delegate as? NSView { return field }
        return responder as? NSView
    }

    private func install(_ view: NSView) {
        view.autoresizingMask = [.width, .height]
        addSubview(view, positioned: .below, relativeTo: contentView)
        backingView = view
    }

    private func applyStyle() {
        let level = resolveLevel(self.level)
        let tint = Self.tintColor(for: role).withAlphaComponent(Self.tintAlpha(for: level, role: role))
        layer?.backgroundColor = backing == .solid ? tint.cgColor : nil
        tintView?.layer?.backgroundColor = tint.cgColor
        if #available(macOS 26, *), let glass = backingView as? NSGlassEffectView {
            // What floats stays the thicker glass at every level.
            glass.style = role == .chrome && level.usesClearGlass ? .clear : .regular
            glass.tintColor = tint
        }
    }

    /// The rounded shape, sized to the bounds, on everything that draws it;
    /// the radius never exceeds half a side.
    private func applyShape() {
        let radius = min(cornerRadius, bounds.width / 2, bounds.height / 2)
        layer?.cornerRadius = radius
        layer?.cornerCurve = .continuous
        contentView.layer?.cornerRadius = radius
        backingView?.layer?.cornerRadius = radius
        tintView?.layer?.cornerRadius = radius
        if #available(macOS 26, *), let glass = backingView as? NSGlassEffectView { glass.cornerRadius = radius }
        updateShadow(radius: radius)
    }

    /// The floating shadow, along the shape and only outside it. Left to the
    /// system for macOS 26's glass, which draws its own edge.
    private func updateShadow(radius: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard role == .floating, backing != .glass, bounds.width > 0, bounds.height > 0 else {
            shadowLayer.isHidden = true
            return
        }
        shadowLayer.isHidden = false
        shadowLayer.frame = bounds
        let shape = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        Theme.Elevation.applyFloating(to: shadowLayer, path: shape)
        // The mask spans the shadow's reach, with the shape cut out.
        let reach = Theme.Elevation.floatingRadius * 2 + Theme.Elevation.floatingDrop
        let outside = CGMutablePath()
        outside.addRect(bounds.insetBy(dx: -reach, dy: -reach))
        outside.addPath(shape)
        shadowMask.frame = shadowLayer.bounds
        shadowMask.path = outside
    }

    override func layout() {
        super.layout()
        if contentView.superview === self { contentView.frame = bounds }
        backingView?.frame = bounds
        tintView?.frame = bounds
        applyShape()
    }

    /// A frame change without a layout pass (autoresizing, `setFrameSize`)
    /// still reshapes the corners and the shadow.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        applyShape()
    }
}
