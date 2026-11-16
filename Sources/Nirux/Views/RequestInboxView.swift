import AppKit

/// The glass interface's inbox (docs/design/glass-interface.md): under the
/// command bar, every request waiting for the user, in the order it is
/// given (oldest first), each with its answers. It opens with the oldest
/// chosen; ↑ ↓ move the choice, and ⌘J again goes to the chosen task
/// (`chosenRequest`); Escape closes it. Answers are clicks only. The shell
/// hosts it under the command bar (`openInbox`, a `RequestPanel`) and feeds
/// it at each sidebar refresh.
final class RequestInboxView: NSView {
    static let width: CGFloat = 372
    static let headerHeight: CGFloat = 34

    /// A click on an answer: the request, the answer, its button.
    var onAnswer: ((WaitingRequest, RequestChoice, NSView) -> Void)?
    /// "Open task" on a request: the request, whose column the host
    /// brings up (a task may wait in several).
    var onOpenTask: ((WaitingRequest) -> Void)?
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
    private let content = BoardStagesFlippedView()
    private let scroll = NSScrollView()
    private let list = BoardStagesFlippedView()
    /// One card per request, reused by id.
    private(set) var cards: [String: RequestCardView] = [:]
    private var lines: [NSView] = []
    private let arming: RequestArming
    /// The choice changed: bring it into view at the next layout.
    private var revealPending = false

    /// `now`: the clock the answers' arming reads (a test's own).
    init(level: InterfaceTransparency, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        glass = GlassView(role: .floating, level: level, cornerRadius: Theme.Radius.panel)
        arming = RequestArming(now: now)
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
        // "Show scroll bars" changed: the cards take the clip's new width.
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrollerStyleChanged), name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil
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

    /// Shows `requests` in their order, each once, reusing each card by its
    /// request's id. The choice stays on its request; a choice whose request
    /// went falls to the first one after it still listed (else the nearest
    /// before), and the list stays where it is.
    func show(_ requests: [WaitingRequest]) {
        var seen = Set<String>()
        let requests = requests.filter { seen.insert($0.id).inserted }
        guard requests != self.requests else { return }
        let before = self.requests.map(\.id)
        self.requests = requests
        for (id, card) in cards where !seen.contains(id) {
            card.removeFromSuperview()
            cards[id] = nil
        }
        for request in requests {
            (cards[request.id] ?? makeCard(id: request.id)).show(request)
        }
        // The same requests in the same order (a wait ticking): the cards
        // and their lines stay where they are, a hover with them.
        if requests.map(\.id) != before {
            let count = max(requests.count - 1, 0)
            while lines.count < count {
                let line = NSView()
                line.wantsLayer = true
                line.layer?.backgroundColor = Theme.Color.line.cgColor
                lines.append(line)
            }
            lines.removeLast(lines.count - count)
            // VoiceOver reads the cards in their views' order.
            list.subviews = requests.compactMap { cards[$0.id] } + lines
        }
        countLabel.stringValue = "\(requests.count)"
        emptyLabel.isHidden = !requests.isEmpty
        let count = requests.count
        setAccessibilityLabel(count == 0 ? "No agent waits for you" : "\(count) \(count == 1 ? "request" : "requests") waiting for you")
        needsLayout = true
        if !seen.contains(chosenID ?? ""), let gone = before.firstIndex(of: chosenID ?? "") {
            chosenID = before[(gone + 1)...].first(where: seen.contains) ?? before[..<gone].last(where: seen.contains)
                ?? requests.first?.id
        } else if !seen.contains(chosenID ?? "") {
            chosenID = requests.first?.id
        }
        markChoice()
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
            self.onOpenTask?(request)
        }
        cards[id] = card
        return card
    }

    static func armingKey(_ requestID: String, _ choice: RequestChoice) -> String { "\(requestID)\u{1F}\(choice.key)" }

    /// Chooses the request with `id`, and brings it into view.
    func choose(_ id: String?) {
        chosenID = id
        markChoice()
        revealPending = id != nil
        needsLayout = true
    }

    private func markChoice() {
        for (cardID, card) in cards {
            card.isChosen = cardID == chosenID
            card.setAccessibilitySelected(cardID == chosenID)
        }
    }

    /// ↑ ↓: the choice moves, and stops at either end.
    func moveChoice(by step: Int) {
        guard let index = requests.firstIndex(where: { $0.id == chosenID }) else { return choose(requests.first?.id) }
        choose(requests[min(max(index + step, 0), requests.count - 1)].id)
    }

    /// The host shows the inbox (⌘J, the badge): the oldest chosen, and
    /// every answer waits again before it takes a click. Moving it needs no
    /// call: the answers that slid on screen wait again by themselves.
    func opened() {
        choose(requests.first?.id)
        restartArming()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        RequestArming.observeMoves(of: window, by: self, selector: #selector(windowMoved))
        if window != nil { restartArming() }
    }

    /// Moved in its window, or its window moved: the next layout finds which
    /// answers slid on screen (a resize from the top moves none of them).
    override func setFrameOrigin(_ newOrigin: NSPoint) {
        let moved = newOrigin != frame.origin
        super.setFrameOrigin(newOrigin)
        if moved { needsLayout = true }
    }

    @objc private func windowMoved() { needsLayout = true }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        restartArming()
    }

    /// Every answer waits again before it takes a click.
    func restartArming() { arming.restartAll() }

    // MARK: - Layout

    /// Its height for its requests at `Self.width`, scrolling past `maximum`.
    func fittingHeight(maximum: CGFloat) -> CGFloat {
        let list = requests.isEmpty ? 44 : listHeight(width: Self.width)
        return min(Self.headerHeight + 1 + list, maximum)
    }

    private func listHeight(width: CGFloat) -> CGFloat {
        requests.reduce(CGFloat(0)) { $0 + (cards[$1.id]?.fittingHeight(width: width) ?? 0) } + CGFloat(max(requests.count - 1, 0))
    }

    /// The cards' width: the scroll view's, less a legacy scroller when they
    /// overflow (the system's "Show scroll bars" decides; AppKit sets each
    /// scroll view's style from it).
    private func cardWidth() -> CGFloat {
        let full = scroll.frame.width
        guard listHeight(width: full) > scroll.frame.height else { return full }
        return NSScrollView.contentSize(
            forFrameSize: scroll.frame.size, horizontalScrollerClass: nil, verticalScrollerClass: NSScroller.self,
            borderType: .noBorder, controlSize: .regular, scrollerStyle: scroll.scrollerStyle
        ).width
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

        let cardWidth = cardWidth()
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
                frames[Self.armingKey(request.id, choice)] = RequestArming.place(of: button, in: list)
            }
            y += cardHeight
        }
        list.frame = NSRect(x: 0, y: 0, width: cardWidth, height: max(y, scroll.frame.height))
        arming.refresh(frames)
        if revealPending, let id = chosenID, let card = cards[id] {
            revealPending = false
            list.scrollToVisible(card.frame)
        }
    }

    @objc private func listScrolled() { arming.restartAll() }

    @objc private func scrollerStyleChanged() { needsLayout = true }

    // MARK: - Keys

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.specialKey {
        case .upArrow?: moveChoice(by: -1)
        case .downArrow?: moveChoice(by: 1)
        default:
            if event.charactersIgnoringModifiers == "\u{1b}" { escapeIsDown = true } else { super.keyDown(with: event) }
        }
    }

    /// Escape closes it on its release: the keyboard then goes back to a
    /// terminal, which a held key's repeats must not reach.
    private var escapeIsDown = false

    override func keyUp(with event: NSEvent) {
        guard event.charactersIgnoringModifiers == "\u{1b}", escapeIsDown else { return super.keyUp(with: event) }
        escapeIsDown = false
        onClose?()
    }

    /// ⌘. and the key bindings' Escape.
    override func cancelOperation(_ sender: Any?) { onClose?() }
}
