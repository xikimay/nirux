import AppKit

/// The glass interface's rail (docs/design/glass-interface.md): a vertical
/// glass capsule with the space's Lead, then one state icon per task in the
/// sidebar's order; under it, the archived tasks and a new task. The task on
/// screen wears a halo; a task whose agent waits for the user wears an amber
/// ring. A click on an amber icon asks for its request (the callout, plan
/// step 2.3); a double-click on it, or a click on any other icon, goes to the
/// task. Built, not shown yet: phase 3 puts it in the window.
final class IconRail: NSView {
    struct Item: Equatable {
        var id: String
        var title: String
        var icon: StateIcon
        /// The task on screen.
        var isSelected = false
    }

    struct Content: Equatable {
        /// The space's Lead, first, apart.
        var lead: Item?
        var tasks: [Item]
    }

    static let width: CGFloat = 38
    /// One icon's place, top to bottom.
    static let pitch: CGFloat = 28
    private static let iconSize: CGFloat = 15
    private static let gap = Theme.Space.sm

    /// A click on a task, or a double-click on a waiting one: go to it.
    var onSelect: ((String) -> Void)?
    /// A click on a waiting task: its request, anchored to `frame` (in the
    /// rail's coordinates).
    var onRequest: ((String, NSRect) -> Void)?
    var onArchived: (() -> Void)?
    var onNew: (() -> Void)?

    var level: InterfaceTransparency {
        get { glass.level }
        set { glass.level = newValue; archivedButton.level = newValue; newButton.level = newValue }
    }

    private(set) var content = Content(lead: nil, tasks: [])
    /// The Lead, then the tasks, top to bottom.
    private var items: [Item] { (content.lead.map { [$0] } ?? []) + content.tasks }
    private let glass: GlassView
    private let scroll = NSScrollView()
    private let list = FlippedView()
    private let separator = NSView()
    /// One view per item, reused by id.
    private(set) var itemViews: [String: RailItemView] = [:]
    let archivedButton: RailRoundButton
    let newButton: RailRoundButton

    init(level: InterfaceTransparency) {
        glass = GlassView(role: .chrome, level: level, cornerRadius: Self.width / 2)
        archivedButton = RailRoundButton(symbol: Theme.Symbol.inactiveWorkspaces, label: "Archived tasks", level: level)
        newButton = RailRoundButton(symbol: Theme.Symbol.add, label: "New task", level: level)
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 480))
        addSubview(glass)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.verticalScrollElasticity = .allowed
        scroll.documentView = list
        // VoiceOver goes through the scroll area to the tasks: a flat group
        // of buttons, as the icons are.
        scroll.setAccessibilityElement(false)
        scroll.contentView.setAccessibilityElement(false)
        glass.contentView.addSubview(scroll)
        separator.wantsLayer = true
        separator.layer?.backgroundColor = Theme.Color.lineStrong.cgColor
        list.addSubview(separator)
        archivedButton.onPress = { [weak self] in self?.onArchived?() }
        newButton.onPress = { [weak self] in self?.onNew?() }
        addSubview(archivedButton)
        addSubview(newButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    /// Shows `content`, reusing each item's view by its id.
    func show(_ content: Content) {
        guard content != self.content else { return }
        self.content = content
        let ids = Set(items.map(\.id))
        for (id, view) in itemViews where !ids.contains(id) {
            view.removeFromSuperview()
            itemViews[id] = nil
        }
        for item in items {
            let view = itemViews[item.id] ?? {
                let view = RailItemView()
                view.onPress = { [weak self] id, clicks in self?.press(id, clicks: clicks) }
                list.addSubview(view)
                itemViews[item.id] = view
                return view
            }()
            view.show(item, isLead: item.id == content.lead?.id)
        }
        separator.isHidden = content.lead == nil || content.tasks.isEmpty
        needsLayout = true
    }

    /// A waiting task's first click asks for its request and its second goes
    /// to the task (the callout closes as the task opens); any other task goes
    /// on the first click and ignores the rest.
    private func press(_ id: String, clicks: Int) {
        guard let item = items.first(where: { $0.id == id }), let view = itemViews[id] else { return }
        switch (item.icon.waitsForUser, clicks) {
        case (true, 1): onRequest?(id, convert(view.bounds, from: view))
        case (true, 2), (false, 1): onSelect?(id)
        default: break
        }
    }

    override func layout() {
        super.layout()
        let round = Self.width
        let below = 2 * (round + Self.gap)
        let capsuleHeight = max(Self.width, bounds.height - below)
        glass.frame = NSRect(x: 0, y: 0, width: Self.width, height: capsuleHeight)
        archivedButton.frame = NSRect(x: 0, y: capsuleHeight + Self.gap, width: round, height: round)
        newButton.frame = NSRect(x: 0, y: capsuleHeight + Self.gap + round + Self.gap, width: round, height: round)
        // From the capsule's own size: on macOS 26 the glass sizes its
        // content view only at its next layout pass.
        scroll.frame = NSRect(origin: .zero, size: glass.frame.size).insetBy(dx: 0, dy: Theme.Space.xs)

        var y = Theme.Space.xs
        func place(_ item: Item) {
            itemViews[item.id]?.frame = NSRect(x: 0, y: y, width: Self.width, height: Self.pitch)
            y += Self.pitch
        }
        if let lead = content.lead { place(lead) }
        if !separator.isHidden {
            separator.frame = NSRect(x: (Self.width - 18) / 2, y: y + Self.gap / 2, width: 18, height: 1)
            y += Self.gap
        }
        content.tasks.forEach(place)
        list.frame = NSRect(x: 0, y: 0, width: Self.width, height: max(y + Theme.Space.xs, scroll.contentSize.height))
    }

    /// Brings the task on screen (or the Lead) into view when the rail
    /// scrolls.
    func revealSelection() {
        guard let selected = items.first(where: \.isSelected), let view = itemViews[selected.id] else { return }
        layoutSubtreeIfNeeded()
        list.scrollToVisible(view.frame)
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

extension StateIcon {
    /// An agent of the task waits for the user: amber, and a click asks for
    /// the request rather than going to the task.
    var waitsForUser: Bool {
        if case .needsYou = kind { return true }
        return false
    }
}

/// One task on the rail: its state icon, a halo when it is on screen, an
/// amber ring while its agent waits for the user. A button for VoiceOver.
final class RailItemView: NSView {
    var onPress: ((String, Int) -> Void)?
    private(set) var item: IconRail.Item?
    let iconView = StateIconView(StateIcon(.idle), size: 15)
    /// The task on screen.
    let halo = NSView()
    /// Its agent waits for the user.
    let ring = NSView()
    private var isLead = false
    private let leadIcon = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for view in [halo, ring] {
            view.wantsLayer = true
            addSubview(view)
        }
        halo.layer?.backgroundColor = Theme.Color.fillPressed.cgColor
        ring.layer?.borderColor = Theme.Color.waiting.cgColor
        ring.layer?.borderWidth = 1.5
        addSubview(iconView)
        leadIcon.image = NSImage(systemSymbolName: Theme.Symbol.lead, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        leadIcon.contentTintColor = Theme.Color.textSecondary
        leadIcon.cell?.setAccessibilityElement(false)
        addSubview(leadIcon)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ item: IconRail.Item, isLead: Bool) {
        self.item = item
        self.isLead = isLead
        iconView.icon = item.icon
        iconView.isHidden = isLead
        leadIcon.isHidden = !isLead
        halo.isHidden = !item.isSelected
        ring.isHidden = !item.icon.waitsForUser
        let name = isLead ? "Lead" : item.title
        toolTip = "\(name) · \(item.icon.accessibilityText)"
        setAccessibilityLabel("\(name), \(item.icon.accessibilityText)")
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        func circle(_ view: NSView, diameter: CGFloat) {
            view.frame = NSRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter)
            view.layer?.cornerRadius = diameter / 2
        }
        circle(halo, diameter: bounds.height - 2)
        circle(ring, diameter: 24)
        iconView.frame.origin = NSPoint(x: center.x - iconView.frame.width / 2, y: center.y - iconView.frame.height / 2)
        leadIcon.frame = NSRect(x: center.x - 8, y: center.y - 8, width: 16, height: 16)
    }

    override func mouseUp(with event: NSEvent) {
        guard let item, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onPress?(item.id, event.clickCount)
    }

    override func mouseDown(with event: NSEvent) {}

    override func accessibilityPerformPress() -> Bool {
        guard let item else { return false }
        onPress?(item.id, 1)
        return true
    }
}

/// A round glass button under the rail: the archived tasks, a new task.
final class RailRoundButton: NSView {
    var onPress: (() -> Void)?
    var level: InterfaceTransparency {
        get { glass.level }
        set { glass.level = newValue }
    }
    private let glass: GlassView
    private let button: NiruxButton

    init(symbol: String, label: String, level: InterfaceTransparency) {
        glass = GlassView(role: .chrome, level: level, cornerRadius: IconRail.width / 2)
        button = NiruxButton(title: "", kind: .quiet)
        super.init(frame: NSRect(x: 0, y: 0, width: IconRail.width, height: IconRail.width))
        glass.frame = bounds
        glass.autoresizingMask = [.width, .height]
        addSubview(glass)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        button.imagePosition = .imageOnly
        button.contentTintColor = Theme.Color.textSecondary
        button.setAccessibilityLabel(label)
        button.target = self
        button.action = #selector(pressed)
        button.frame = bounds.insetBy(dx: Theme.Space.xs, dy: Theme.Space.xs)
        button.autoresizingMask = [.width, .height]
        glass.contentView.addSubview(button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func pressed() { onPress?() }
}
