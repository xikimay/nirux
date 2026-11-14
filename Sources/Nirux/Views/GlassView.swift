import AppKit

/// The glass of the glass interface (docs/design/glass-interface.md):
/// `NSGlassEffectView` on macOS 26 and later, a frosted `NSVisualEffectView`
/// on macOS 14 and 15, a solid fill at Opaque. Content goes in
/// `contentView`. Nothing shows one yet.
///
/// The tints are provisional: offscreen renders can't show the glass (the
/// window server draws it), so they get tuned with the user on a demo at the
/// end of phase 2.
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

    /// The level to draw, already made opaque where macOS asks
    /// (`InterfaceTransparency.effectiveNow`).
    var level: InterfaceTransparency {
        didSet { if level != oldValue { rebuild() } }
    }

    var cornerRadius: CGFloat {
        didSet { if cornerRadius != oldValue { rebuild() } }
    }

    private(set) var backing: Backing = .solid
    private var backingView: NSView?
    private var tintView: NSView?

    init(role: Role, level: InterfaceTransparency, cornerRadius: CGFloat) {
        self.role = role
        self.level = level
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)
        wantsLayer = true
        contentView.autoresizingMask = [.width, .height]
        addSubview(contentView)
        rebuild()
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
        guard level.usesGlass else { return 1 }
        switch role {
        case .floating: return 0.88
        case .chrome:
            switch level {
            case .opaque: return 1
            case .tinted: return 0.62
            case .glass: return 0.42
            case .clear: return 0.24
            }
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

    private func rebuild() {
        if #available(macOS 26, *), let glass = backingView as? NSGlassEffectView { glass.contentView = nil }
        backingView?.removeFromSuperview()
        tintView?.removeFromSuperview()
        backingView = nil
        tintView = nil
        if contentView.superview !== self {
            contentView.frame = bounds
            addSubview(contentView)
        }
        backing = Self.backing(for: level, hasGlass: Self.hasGlass)
        let tint = Self.tintColor(for: role).withAlphaComponent(Self.tintAlpha(for: level, role: role))
        layer?.backgroundColor = nil
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
        switch backing {
        case .solid:
            layer?.backgroundColor = tint.cgColor
        case .glass:
            if #available(macOS 26, *) {
                let glass = NSGlassEffectView(frame: bounds)
                glass.style = level.usesClearGlass ? .clear : .regular
                glass.tintColor = tint
                glass.cornerRadius = cornerRadius
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
            frost.layer?.cornerRadius = cornerRadius
            frost.layer?.cornerCurve = .continuous
            frost.layer?.masksToBounds = true
            install(frost)
            // The frost has no tint of its own: one more layer, the same
            // shape.
            let tintLayer = NSView(frame: bounds)
            tintLayer.wantsLayer = true
            tintLayer.layer?.backgroundColor = tint.cgColor
            tintLayer.layer?.cornerRadius = cornerRadius
            tintLayer.layer?.cornerCurve = .continuous
            tintLayer.autoresizingMask = [.width, .height]
            addSubview(tintLayer, positioned: .below, relativeTo: contentView)
            tintView = tintLayer
        }
        updateShadow()
    }

    private func install(_ view: NSView) {
        view.autoresizingMask = [.width, .height]
        addSubview(view, positioned: .below, relativeTo: contentView)
        backingView = view
    }

    override func layout() {
        super.layout()
        if contentView.superview === self { contentView.frame = bounds }
        backingView?.frame = bounds
        tintView?.frame = bounds
        updateShadow()
    }

    /// The floating shadow on this unclipped view, along its rounded shape.
    /// Left to the system for macOS 26's glass, which draws its own edge.
    private func updateShadow() {
        guard role == .floating, backing != .glass else { return Theme.Elevation.removeShadow(from: self) }
        let path = CGPath(roundedRect: bounds, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        Theme.Elevation.applyFloating(to: self, path: path)
    }
}
