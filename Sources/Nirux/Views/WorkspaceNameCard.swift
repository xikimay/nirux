import AppKit

/// The card a workspace switch shows in the middle of the viewport: the
/// workspace's name and its state's dot, and one dot per workspace of the
/// space, the one on screen in the accent color. It shows while the view
/// moves and a moment after, then leaves (see
/// `NiruxShellView.announceWorkspaceSwitch`). Decoration: it never takes
/// the keyboard, a click or VoiceOver's focus.
final class WorkspaceNameCard: NSView {
    struct Content: Equatable {
        /// The workspace it names: a card never stays over another one.
        let workspaceID: String
        let name: String
        /// The workspace's state: green while it works, amber when it waits
        /// on the user, red when it broke, else grey.
        let state: NSColor
        /// Its place among the space's workspaces, from 0.
        let position: Int
        let count: Int
        /// The space's longest name: the card's width, so that going
        /// through workspaces it doesn't jump with each name.
        var widestName: String = ""
    }

    /// More workspaces than this: "3 of 30" instead of the dots.
    static let maxDots = 20
    /// The card keeps this width at least.
    static let minWidth: CGFloat = 240
    static let fadeIn: CFTimeInterval = 0.15
    static let fadeOut: CFTimeInterval = 0.2
    static let showKey = "show"
    static let hideKey = "hide"

    private static let paddingX: CGFloat = 22
    private static let paddingY: CGFloat = 14
    private static let rowGap: CGFloat = 9
    private static let stateDot: CGFloat = 9
    private static let positionDot: CGFloat = 6
    private static let positionGap: CGFloat = 6

    private let nameLabel = NSTextField(labelWithString: "")
    private let stateView = NSView()
    private let placeLabel = NSTextField(labelWithString: "")
    private var positionDots: [NSView] = []
    private(set) var content: Content?
    private(set) var isShown = false

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.Color.raised.cgColor
        layer?.cornerRadius = Theme.Radius.panel
        layer?.borderWidth = 1
        layer?.borderColor = Theme.Color.lineStrong.cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.5
        layer?.shadowRadius = 18
        layer?.shadowOffset = CGSize(width: 0, height: -8)
        // Gone unless shown.
        alphaValue = 0
        nameLabel.font = NSFont.systemFont(ofSize: 17, weight: .semibold)
        nameLabel.textColor = Theme.Color.textPrimary
        nameLabel.lineBreakMode = .byTruncatingMiddle
        placeLabel.font = Theme.Font.caption
        placeLabel.textColor = Theme.Color.textSecondary
        stateView.wantsLayer = true
        stateView.layer?.cornerRadius = Self.stateDot / 2
        for view in [stateView, nameLabel, placeLabel] {
            view.setAccessibilityElement(false)
            addSubview(view)
        }
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }

    /// Shows `content`, centred in `area` and no wider than it: the words
    /// change at once, the card comes in only if it wasn't there.
    /// `animated`: it fades and settles in; else it is just there.
    func show(_ content: Content, centredIn area: NSRect, animated: Bool) {
        if content != self.content || area.width != configuredWidth {
            self.content = content
            configure(content, width: area.width)
        }
        layOut(centredIn: area)
        guard !isShown else { return }
        isShown = true
        let wasVisible = layer?.presentation()?.opacity ?? Float(alphaValue)
        alphaValue = 1
        layer?.removeAnimation(forKey: Self.hideKey)
        guard animated, let layer else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = wasVisible
        fade.toValue = 1
        fade.duration = Self.fadeIn
        // About its centre: an AppKit view's layer is anchored at its
        // bottom-left corner.
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        var small = CATransform3DMakeTranslation(centre.x, centre.y, 0)
        small = CATransform3DScale(small, 0.94, 0.94, 1)
        small = CATransform3DTranslate(small, -centre.x, -centre.y, 0)
        let settle = CASpringAnimation(keyPath: "transform")
        settle.fromValue = NSValue(caTransform3D: small)
        settle.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        settle.damping = 20
        settle.stiffness = 300
        settle.duration = settle.settlingDuration
        let show = CAAnimationGroup()
        show.animations = [fade, settle]
        show.duration = max(fade.duration, settle.duration)
        layer.add(show, forKey: Self.showKey)
    }

    /// Leaves: it fades out, or is gone at once.
    func hide(animated: Bool) {
        guard isShown else { return }
        isShown = false
        let wasVisible = layer?.presentation()?.opacity ?? Float(alphaValue)
        alphaValue = 0
        layer?.removeAnimation(forKey: Self.showKey)
        guard animated, let layer else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = wasVisible
        fade.toValue = 0
        fade.duration = Self.fadeOut
        layer.add(fade, forKey: Self.hideKey)
    }

    /// The dots that say where the workspace is, for tests: how many, and
    /// which one is lit.
    var dotCount: Int { positionDots.count }
    var litDot: Int? { positionDots.firstIndex { $0.layer?.backgroundColor == Theme.Color.accent.cgColor } }
    var name: String { nameLabel.stringValue }
    var place: String { placeLabel.isHidden ? "" : placeLabel.stringValue }
    var stateColor: CGColor? { stateView.layer?.backgroundColor }

    /// Its dots fit in `width`, else it says the place in words.
    private static func dotsFit(_ count: Int, in width: CGFloat) -> Bool {
        count <= maxDots
            && CGFloat(count) * positionDot + CGFloat(max(0, count - 1)) * positionGap <= width - paddingX * 2
    }

    private var configuredWidth: CGFloat = 0

    private func configure(_ content: Content, width: CGFloat) {
        configuredWidth = width
        nameLabel.stringValue = content.name
        stateView.layer?.backgroundColor = content.state.cgColor
        positionDots.forEach { $0.removeFromSuperview() }
        positionDots = []
        let usesDots = Self.dotsFit(content.count, in: width)
        placeLabel.isHidden = usesDots
        placeLabel.stringValue = "\(content.position + 1) of \(content.count)"
        guard usesDots else { return }
        positionDots = (0..<content.count).map { index in
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.cornerRadius = Self.positionDot / 2
            dot.layer?.backgroundColor = (index == content.position ? Theme.Color.accent : Theme.Color.lineStrong).cgColor
            dot.setAccessibilityElement(false)
            addSubview(dot)
            return dot
        }
    }

    private func layOut(centredIn area: NSRect) {
        let nameSize = nameLabel.fittingSize
        let maxNameWidth = max(0, area.width - Self.paddingX * 2 - Self.stateDot - 8)
        let widest = content.map { content -> CGFloat in
            let probe = NSTextField(labelWithString: content.widestName)
            probe.font = nameLabel.font
            return ceil(probe.fittingSize.width)
        } ?? 0
        // Its own name, centred; the card as wide as the longest one.
        let nameWidth = min(ceil(nameSize.width), maxNameWidth)
        let topWidth = Self.stateDot + 8 + nameWidth
        let widestTop = Self.stateDot + 8 + min(max(nameWidth, widest), maxNameWidth)
        let placeSize = placeLabel.fittingSize
        let dotsWidth = positionDots.isEmpty
            ? ceil(placeSize.width)
            : CGFloat(positionDots.count) * Self.positionDot + CGFloat(positionDots.count - 1) * Self.positionGap
        let bottomHeight = positionDots.isEmpty ? ceil(placeSize.height) : Self.positionDot
        let width = min(area.width, max(Self.minWidth, max(widestTop, dotsWidth) + Self.paddingX * 2))
        let nameHeight = ceil(nameSize.height)
        let height = Self.paddingY * 2 + nameHeight + Self.rowGap + bottomHeight
        frame = NSRect(x: area.midX - width / 2, y: area.midY - height / 2, width: width, height: height).integral
        layer?.shadowPath = CGPath(
            roundedRect: bounds, cornerWidth: Theme.Radius.panel, cornerHeight: Theme.Radius.panel, transform: nil
        )

        let topY = bounds.height - Self.paddingY - nameHeight
        let topX = (bounds.width - topWidth) / 2
        stateView.frame = NSRect(x: topX, y: topY + (nameHeight - Self.stateDot) / 2, width: Self.stateDot, height: Self.stateDot)
        nameLabel.frame = NSRect(x: topX + Self.stateDot + 8, y: topY, width: nameWidth, height: nameHeight)
        let bottomX = (bounds.width - dotsWidth) / 2
        if positionDots.isEmpty {
            placeLabel.frame = NSRect(x: bottomX, y: Self.paddingY, width: dotsWidth, height: bottomHeight)
        }
        for (index, dot) in positionDots.enumerated() {
            dot.frame = NSRect(
                x: bottomX + CGFloat(index) * (Self.positionDot + Self.positionGap), y: Self.paddingY,
                width: Self.positionDot, height: Self.positionDot
            )
        }
    }
}
