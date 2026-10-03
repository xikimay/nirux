import AppKit

/// The collapsed sidebar: a 52 pt rail, the project on top, a tile per
/// workspace (its initials, its state), "+" at the bottom.
enum SidebarRailMetrics {
    static let width: CGFloat = 52
    static let tileSize: CGFloat = 32
    /// From the sidebar's left edge, whatever its width: tiles stay put
    /// while the sidebar animates between its two widths.
    static let tileX = (width - tileSize) / 2
    static let tileGap: CGFloat = 6
    static let topPadding = Theme.Space.md
    static let bottomPadding: CGFloat = 10
    static let separatorWidth: CGFloat = 20
    static let separatorMargin = Theme.Space.xs
    static let badgeSize: CGFloat = 10
    /// How far the state badge sticks out of the tile's corner.
    static let badgeOverhang: CGFloat = 3
    static let badgeRing: CGFloat = 2
    static let tooltipGap = Theme.Space.sm
    static let tooltipMaxWidth: CGFloat = 260
}

/// A tile's letters: the first letter of the first two words ("Fix login
/// rate limit" → "FL"). A branch drops its type ("feat/crash-report" →
/// "CR"); one word gives its first two letters ("main" → "MA"). A repeat
/// takes a number: "CR2".
enum SidebarRailInitials {
    static func initials(for titles: [String]) -> [String] {
        var used: Set<String> = []
        return titles.map { title in
            let base = initials(of: title)
            var candidate = base
            var number = 2
            while used.contains(candidate) {
                candidate = "\(base)\(number)"
                number += 1
            }
            used.insert(candidate)
            return candidate
        }
    }

    static func initials(of title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.split(separator: "/").last.map(String.init) ?? trimmed
        let words = words(in: name)
        let letters: [Character]
        switch words.count {
        case 0: letters = Array(trimmed.prefix(1))
        case 1: letters = Array(words[0].prefix(2))
        default: letters = [words[0].first, words[1].first].compactMap { $0 }
        }
        let result = String(letters).uppercased()
        return result.isEmpty ? "?" : result
    }

    /// Runs of letters and digits; "CelticFantasy" is two words.
    private static func words(in text: String) -> [String] {
        var words: [String] = []
        var current = ""
        var previousIsLower = false
        for character in text {
            guard character.isLetter || character.isNumber else {
                if !current.isEmpty { words.append(current) }
                current = ""
                previousIsLower = false
                continue
            }
            if character.isUppercase, previousIsLower, !current.isEmpty {
                words.append(current)
                current = ""
            }
            current.append(character)
            previousIsLower = character.isLowercase
        }
        if !current.isEmpty { words.append(current) }
        return words
    }
}

/// How a rail tile looks.
struct SidebarRailTileStyle {
    var fill: NSColor
    var border: NSColor?
    var borderWidth: CGFloat = 1
    var isDashed = false
    var textColor: NSColor
    /// Under the pointer: brighter, unless the color says something.
    var hoverTextColor = Theme.Color.textPrimary
    var font: NSFont = Theme.Font.captionEmphasized
    /// The state badge in the corner; nil shows none.
    var badge: NSColor?
    var breathes = false

    /// The card's rule (`cardState`): amber only for a wait on the user.
    static func workspace(state: SidebarCardState, isSelected: Bool, isInactive: Bool) -> SidebarRailTileStyle {
        var style = SidebarRailTileStyle(
            fill: isInactive ? .clear : Theme.Color.surface,
            border: Theme.Color.line,
            textColor: isInactive ? Theme.Color.textTertiary : Theme.Color.textSecondary
        )
        switch state {
        case .waiting:
            style.fill = Theme.Color.tint(Theme.Color.waiting, 0.16)
            style.border = Theme.Color.waiting.withAlphaComponent(0.55)
            style.textColor = Theme.Color.waiting
            style.badge = Theme.Color.waiting
        case .error:
            style.border = Theme.Color.error.withAlphaComponent(0.5)
            style.textColor = Theme.Color.error
            style.badge = Theme.Color.error
        case .working:
            style.badge = Theme.Color.working
            style.breathes = true
        case .done:
            style.badge = Theme.Color.done
        case .idle:
            break
        }
        if isSelected {
            style.border = Theme.Color.accent
            style.borderWidth = 1.5
            if state != .waiting, state != .error { style.textColor = Theme.Color.textPrimary }
        }
        if state == .waiting || state == .error { style.hoverTextColor = style.textColor }
        return style
    }

    /// The project, in its color.
    static func project(color: NSColor) -> SidebarRailTileStyle {
        SidebarRailTileStyle(
            fill: color.withAlphaComponent(0.16), border: nil, textColor: color, hoverTextColor: color, font: Theme.Font.title
        )
    }

    static var add: SidebarRailTileStyle { SidebarRailTileStyle(
        fill: .clear, border: Theme.Color.lineStrong, isDashed: true, textColor: Theme.Color.textTertiary
    ) }

    static func inactiveToggle(isUnfolded: Bool) -> SidebarRailTileStyle {
        SidebarRailTileStyle(
            fill: isUnfolded ? Theme.Color.fillPressed : .clear, border: nil, textColor: Theme.Color.textTertiary
        )
    }
}

/// One rail tile: letters or a symbol, a state badge in the corner. Its
/// frame is the tile plus the badge's overhang; clicks go through to the
/// sidebar's hit areas. VoiceOver sees a button.
final class SidebarRailTileView: NSView {
    let style: SidebarRailTileStyle
    let text: String?
    private let symbolName: String?
    /// VoiceOver's press: what a click on the tile does.
    var onPress: (() -> Void)?

    var isHovered = false {
        didSet { if oldValue != isHovered { needsDisplay = true } }
    }

    init(style: SidebarRailTileStyle, text: String? = nil, symbolName: String? = nil) {
        self.style = style
        self.text = text
        self.symbolName = symbolName
        let side = SidebarRailMetrics.tileSize + SidebarRailMetrics.badgeOverhang
        super.init(frame: NSRect(x: 0, y: 0, width: side, height: side))
        wantsLayer = true
        addBadge()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityPerformPress() -> Bool {
        guard let onPress else { return false }
        onPress()
        return true
    }

    /// The tile, without the badge's overhang, in the view's coordinates.
    static var tileRect: NSRect {
        NSRect(x: 0, y: SidebarRailMetrics.badgeOverhang, width: SidebarRailMetrics.tileSize, height: SidebarRailMetrics.tileSize)
    }

    /// Places the view so that its tile lands at `origin`.
    func place(tileOrigin origin: NSPoint) {
        setFrameOrigin(NSPoint(x: origin.x, y: origin.y - SidebarRailMetrics.badgeOverhang))
    }

    /// A view, not a bare layer: the snapshot the rail fades out with
    /// (`cacheDisplay`) keeps it.
    private func addBadge() {
        guard let color = style.badge else { return }
        let size = SidebarRailMetrics.badgeSize
        let badge = SidebarBackgroundView(frame: NSRect(
            x: SidebarRailMetrics.tileSize + SidebarRailMetrics.badgeOverhang - size, y: 0, width: size, height: size
        ))
        badge.wantsLayer = true
        badge.layer?.cornerRadius = size / 2
        badge.layer?.backgroundColor = color.cgColor
        badge.layer?.borderWidth = SidebarRailMetrics.badgeRing
        badge.layer?.borderColor = Theme.Color.base.cgColor
        badge.setAccessibilityElement(false)
        addSubview(badge)
        if style.breathes { SidebarWorkspaceCardRenderer.breathe(badge.layer) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let inset = style.borderWidth / 2
        let rect = Self.tileRect.insetBy(dx: inset, dy: inset)
        let radius = Theme.Radius.card - inset
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        style.fill.setFill()
        path.fill()
        if isHovered {
            Theme.Color.fillHover.setFill()
            path.fill()
        }
        if let border = style.border {
            border.setStroke()
            path.lineWidth = style.borderWidth
            if style.isDashed { path.setLineDash([3, 3], count: 2, phase: 0) }
            path.stroke()
        }
        let color = isHovered ? style.hoverTextColor : style.textColor
        if let symbolName, let image = SidebarRenderer.symbol(symbolName, color: color, pointSize: 13) {
            let size = image.size
            image.draw(in: NSRect(
                x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height
            ))
        } else if let text {
            let attributes: [NSAttributedString.Key: Any] = [.font: style.font, .foregroundColor: color, .kern: 0.2]
            let size = (text as NSString).size(withAttributes: attributes)
            (text as NSString).draw(
                at: NSPoint(x: Self.tileRect.midX - size.width / 2, y: Self.tileRect.midY - size.height / 2),
                withAttributes: attributes
            )
        }
    }
}

/// What a tile's tooltip says: the name, what goes on in the state's
/// color, then its specifics.
struct SidebarRailTooltip: Equatable {
    let title: String
    let detail: String?
    let detailColor: NSColor
    /// The tool and its excerpt, the question, the error.
    let note: String?

    init(title: String, detail: String? = nil, detailColor: NSColor = Theme.Color.textTertiary, note: String? = nil) {
        self.title = title
        self.detail = detail
        self.detailColor = detailColor
        self.note = note
    }
}

@MainActor
extension WorkspaceInfo {
    /// The rail tooltip: the title, then what the card's first line and
    /// chips tell ("claude needs permission · 4m", "Bash: git push").
    var railTooltip: SidebarRailTooltip {
        let age = lastActivityAt.map { SidebarView.cardAge(since: $0) }
        /// "claude needs permission", "Bash: git push".
        func asking(_ signal: AttentionSignal) -> (String, String?)? {
            guard let column = columns.first(where: { $0.attention == signal }) else { return nil }
            let what = column.attentionToolTip ?? column.attentionLabel ?? "needs you"
            let parts = what.components(separatedBy: " — ")
            let rest = parts.dropFirst().joined(separator: " — ")
            return ("\(SidebarRenderer.columnName(column)) \(parts[0])", rest.isEmpty ? nil : rest)
        }
        let state = cardState
        var detail: String?
        var note: String?
        switch state {
        case .waiting:
            let waiting = asking(.waiting)
            detail = [waiting?.0, age].compactMap { $0 }.joined(separator: " · ")
            note = waiting?.1
        case .error:
            if let error = asking(.error) {
                (detail, note) = error
            } else {
                detail = prInfo.map { "checks failed on #\($0.number)" } ?? "checks failed"
            }
        case .working:
            let working = columns.filter { $0.agentStatus == .working }
            let who = working.count == 1 ? SidebarRenderer.columnName(working[0]) : "\(working.count) agents"
            detail = (["\(who) working"] + [working.first?.elapsedDisplay].compactMap { $0 }).joined(separator: " · ")
        case .done:
            detail = prInfo.map { "#\($0.number) merged" } ?? "merged"
        case .idle:
            detail = age.map { $0 == "now" ? "idle" : "idle · \($0)" } ?? "no activity yet"
        }
        let color: NSColor = switch state {
        case .waiting: Theme.Color.waiting
        case .error: Theme.Color.error
        case .working: Theme.Color.working
        case .done: Theme.Color.done
        case .idle: Theme.Color.textTertiary
        }
        return SidebarRailTooltip(title: title, detail: detail, detailColor: color, note: note)
    }
}

/// The rail's tooltip: shown as soon as the pointer is over a tile, beside
/// the rail, over the columns.
final class SidebarRailTooltipView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let noteLabel = NSTextField(labelWithString: "")
    private static let paddingX: CGFloat = 10
    private static let paddingY: CGFloat = 7
    private static let lineGap: CGFloat = 2

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Theme.Color.raised.cgColor
        layer?.cornerRadius = Theme.Radius.card
        layer?.borderWidth = 1
        layer?.borderColor = Theme.Color.lineStrong.cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.45
        layer?.shadowRadius = 12
        layer?.shadowOffset = CGSize(width: 0, height: -8)
        for label in [titleLabel, detailLabel, noteLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            addSubview(label)
        }
        titleLabel.font = Theme.Font.title
        titleLabel.textColor = Theme.Color.textPrimary
        detailLabel.font = Theme.Font.caption
        noteLabel.font = Theme.Font.caption
        noteLabel.textColor = Theme.Color.textSecondary
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Fills the tooltip and sizes it to its text, up to the maximum width.
    func show(_ tooltip: SidebarRailTooltip) {
        titleLabel.stringValue = tooltip.title
        detailLabel.stringValue = tooltip.detail ?? ""
        detailLabel.textColor = tooltip.detailColor
        noteLabel.stringValue = tooltip.note ?? ""
        let lines = [(titleLabel, tooltip.title), (detailLabel, tooltip.detail), (noteLabel, tooltip.note)]
            .compactMap { label, text in text == nil ? nil : label }
        for label in [titleLabel, detailLabel, noteLabel] { label.isHidden = !lines.contains(label) }
        let sizes = lines.map { $0.cell?.cellSize ?? .zero }
        let textWidth = ceil(min(sizes.map(\.width).max() ?? 0, SidebarRailMetrics.tooltipMaxWidth - Self.paddingX * 2))
        let textHeight = sizes.map(\.height).reduce(0, +) + Self.lineGap * CGFloat(max(0, lines.count - 1))
        setFrameSize(NSSize(width: textWidth + Self.paddingX * 2, height: ceil(textHeight + Self.paddingY * 2)))
        var top = frame.height - Self.paddingY
        for (label, size) in zip(lines, sizes) {
            label.frame = NSRect(x: Self.paddingX, y: top - size.height, width: textWidth, height: size.height)
            top -= size.height + Self.lineGap
        }
    }
}
