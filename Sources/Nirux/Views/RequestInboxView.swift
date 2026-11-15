import AppKit

/// The glass interface's inbox (docs/design/glass-interface.md): under the
/// command bar, every request waiting for the user, in the order it is
/// given (oldest first), each with its answers. ⌘J or the badge opens it
/// with the oldest chosen; ↑ ↓ move the choice, and ⌘J again goes to the
/// chosen task (`chosenRequest`); Escape closes it. Answers are clicks only.
/// Built, not shown yet: phase 3 hosts it and feeds it.
final class RequestInboxView: NSView {
    static let width: CGFloat = 372
    static let headerHeight: CGFloat = 34

    /// A click on an answer: the request, the answer, its button.
    var onAnswer: ((WaitingRequest, RequestChoice, NSView) -> Void)?
    /// A request only the terminal answers: its task, by id.
    var onOpenTask: ((String) -> Void)?
    var onClose: (() -> Void)?

    var level: InterfaceTransparency {
        get { glass.level }
        set { glass.level = newValue }
    }

    private(set) var requests: [WaitingRequest] = []
    private(set) var chosenID: String?
    var chosenRequest: WaitingRequest? { requests.first { $0.id == chosenID } }

    private let glass: GlassView
    let titleLabel = NSTextField(labelWithString: "Waiting for you")
    let countLabel = NSTextField(labelWithString: "")
    let key = KeyCap("⌘J")
    private let headerLine = NSView()
    let emptyLabel = NSTextField(labelWithString: "No agent waits for you")
    /// Everything on the glass, counting y down.
    private let content = FlippedInboxView()
    private let scroll = NSScrollView()
    private let list = FlippedInboxView()
    /// One card per request, reused by id.
    private(set) var cards: [String: RequestCardView] = [:]
    private var lines: [NSView] = []
    let arming: RequestArming

    init(level: InterfaceTransparency, arming: RequestArming = RequestArming()) {
        glass = GlassView(role: .floating, level: level, cornerRadius: Theme.Radius.panel)
        self.arming = arming
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 200))
        glass.autoresizingMask = [.width, .height]
        glass.frame = bounds
        addSubview(glass)
        content.frame = glass.contentView.bounds
        content.autoresizingMask = [.width, .height]
        glass.contentView.addSubview(content)
        titleLabel.font = Theme.Font.bodyEmphasized
        titleLabel.textColor = Theme.Color.textPrimary
        countLabel.font = Theme.Font.body
        countLabel.textColor = Theme.Color.textSecondary
        for label in [titleLabel, countLabel] {
            label.setAccessibilityElement(false)
            label.cell?.setAccessibilityElement(false)
        }
        headerLine.wantsLayer = true
        headerLine.layer?.backgroundColor = Theme.Color.line.cgColor
        emptyLabel.font = Theme.Font.body
        emptyLabel.textColor = Theme.Color.textTertiary
        emptyLabel.alignment = .center
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = list
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(listScrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView
        )
        for view in [titleLabel, countLabel, key, headerLine, emptyLabel, scroll] as [NSView] {
            content.addSubview(view)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    /// Shows `requests` in their order, reusing each card by its id. The
    /// choice stays on its request; a new inbox, or a choice whose request
    /// went, chooses the first.
    func show(_ requests: [WaitingRequest]) {
        var seen = Set<String>()
        let requests = requests.filter { seen.insert($0.id).inserted }
        guard requests != self.requests else { return }
        self.requests = requests
        for (id, card) in cards where !seen.contains(id) {
            card.removeFromSuperview()
            cards[id] = nil
        }
        for request in requests {
            let card = cards[request.id] ?? makeCard(id: request.id)
            card.show(request)
        }
        // VoiceOver reads the cards in their views' order.
        lines.forEach { $0.removeFromSuperview() }
        lines = requests.dropFirst().map { _ in
            let line = NSView()
            line.wantsLayer = true
            line.layer?.backgroundColor = Theme.Color.line.cgColor
            return line
        }
        list.subviews = requests.compactMap { cards[$0.id] } + lines
        countLabel.stringValue = "\(requests.count)"
        emptyLabel.isHidden = !requests.isEmpty
        let count = requests.count
        setAccessibilityLabel(count == 0 ? "No agent waits for you" : "\(count) \(count == 1 ? "request" : "requests") waiting for you")
        choose(requests.contains { $0.id == chosenID } ? chosenID : requests.first?.id)
        needsLayout = true
    }

    private func makeCard(id: String) -> RequestCardView {
        let card = RequestCardView(trailing: .waited)
        card.onAnswer = { [weak self] choice, button in
            guard let self, let request = self.requests.first(where: { $0.id == id }) else { return }
            self.onAnswer?(request, choice, button)
        }
        card.canAnswer = { [weak self] choice in self?.arming.isArmed(Self.armingKey(id, choice)) == true }
        card.onClick = { [weak self] in self?.choose(id) }
        card.onOpenTask = { [weak self] in
            guard let self, let request = self.requests.first(where: { $0.id == id }) else { return }
            self.onOpenTask?(request.taskID)
        }
        cards[id] = card
        return card
    }

    static func armingKey(_ requestID: String, _ choice: RequestChoice) -> String { "\(requestID)|\(choice)" }

    /// Chooses the request with `id`, and brings it into view.
    func choose(_ id: String?) {
        chosenID = id
        for (cardID, card) in cards {
            card.isChosen = cardID == id
            card.setAccessibilitySelected(cardID == id)
        }
        if let id, let card = cards[id] {
            layoutSubtreeIfNeeded()
            list.scrollToVisible(card.frame)
        }
    }

    /// ↑ ↓: the choice moves, and stops at either end.
    func moveChoice(by step: Int) {
        guard let index = requests.firstIndex(where: { $0.id == chosenID }) else { return choose(requests.first?.id) }
        choose(requests[min(max(index + step, 0), requests.count - 1)].id)
    }

    /// Its height for its requests, scrolling past `maximum`.
    func fittingHeight(maximum: CGFloat) -> CGFloat {
        let content = requests.isEmpty ? Self.headerHeight + 1 + 44 : Self.headerHeight + 1 + listHeight(width: Self.width)
        return min(content, maximum)
    }

    private func listHeight(width: CGFloat) -> CGFloat {
        requests.reduce(CGFloat(0)) { $0 + (cards[$1.id]?.fittingHeight(width: width) ?? 0) } + CGFloat(max(requests.count - 1, 0))
    }

    override func layout() {
        super.layout()
        let width = bounds.width, header = Self.headerHeight, padding = RequestCardView.padding
        let titleWidth = ceil(titleLabel.attributedStringValue.size().width) + 4
        titleLabel.frame = NSRect(x: padding, y: (header - 16) / 2, width: titleWidth, height: 16)
        countLabel.frame = NSRect(x: titleLabel.frame.maxX + Theme.Space.xs, y: (header - 16) / 2, width: 40, height: 16)
        let keyWidth = key.fittingWidth
        key.frame = NSRect(x: width - padding - keyWidth, y: (header - KeyCap.height) / 2, width: keyWidth, height: KeyCap.height)
        headerLine.frame = NSRect(x: 0, y: header, width: width, height: 1)
        scroll.frame = NSRect(x: 0, y: header + 1, width: width, height: max(0, bounds.height - header - 1))
        emptyLabel.frame = NSRect(x: padding, y: scroll.frame.midY - 8, width: width - 2 * padding, height: 16)

        let cardWidth = scroll.contentSize.width
        var y: CGFloat = 0
        var frames: [String: NSRect] = [:]
        for (index, request) in requests.enumerated() {
            guard let card = cards[request.id] else { continue }
            if index > 0 {
                lines[index - 1].frame = NSRect(x: padding, y: y, width: cardWidth - 2 * padding, height: 1)
                y += 1
            }
            let cardHeight = card.fittingHeight(width: cardWidth)
            card.frame = NSRect(x: 0, y: y, width: cardWidth, height: cardHeight)
            card.needsLayout = true
            card.layoutSubtreeIfNeeded()
            for (choice, button) in card.answerButtons {
                frames[Self.armingKey(request.id, choice)] = list.convert(button.bounds, from: button)
            }
            y += cardHeight
        }
        list.frame = NSRect(x: 0, y: 0, width: cardWidth, height: max(y, scroll.contentSize.height))
        arming.refresh(frames)
    }

    @objc private func listScrolled() { arming.restartAll() }

    // MARK: - Keys

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.specialKey {
        case .upArrow?: moveChoice(by: -1)
        case .downArrow?: moveChoice(by: 1)
        default:
            if event.charactersIgnoringModifiers == "\u{1b}" { onClose?() } else { super.keyDown(with: event) }
        }
    }

    /// ⌘. and the key bindings' Escape.
    override func cancelOperation(_ sender: Any?) { onClose?() }
}

private final class FlippedInboxView: NSView {
    override var isFlipped: Bool { true }
}
