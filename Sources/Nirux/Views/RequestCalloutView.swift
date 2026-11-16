import AppKit

/// The rail's callout (docs/design/glass-interface.md): a click on an amber
/// icon shows that task's request beside it, with its answers (the inbox's
/// card, the rows' answers), "Open task", and how many more wait (⌘J).
/// Escape or a click elsewhere closes it. The shell hosts it beside the
/// icon `IconRail.onRequest` gives (`openCallout`, a `RequestPanel`); as it
/// follows the icon, the answers that slid on screen wait again by
/// themselves.
final class RequestCalloutView: NSView {
    static let width: CGFloat = 330

    /// A click on an answer: the request, the answer, its button.
    var onAnswer: ((WaitingRequest, RequestChoice, NSView) -> Void)?
    /// "Open task": the request, whose column the host brings up.
    var onOpenTask: ((WaitingRequest) -> Void)?
    var onClose: (() -> Void)?

    var level: InterfaceTransparency {
        get { glass.level }
        set { glass.level = newValue }
    }

    private(set) var request: WaitingRequest?
    private(set) var othersWaiting = 0
    private let glass: GlassView
    private let content = BoardStagesFlippedView()
    /// Holds the card, which scrolls once the host caps the callout's
    /// height (a short window, a tall command).
    let scroll = NSScrollView()
    private let cardHolder = BoardStagesFlippedView()
    let card = RequestCardView(trailing: .openTask)
    /// "1 more · ⌘J".
    let moreLabel = NSTextField(labelWithString: "")
    private let arming: RequestArming

    /// `now`: the clock the answers' arming reads (a test's own).
    init(level: InterfaceTransparency, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        glass = GlassView(role: .floating, level: level, cornerRadius: Theme.Radius.panel)
        arming = RequestArming(now: now)
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 120))
        glass.autoresizingMask = [.width, .height]
        glass.frame = bounds
        addSubview(glass)
        content.frame = glass.contentView.bounds
        content.autoresizingMask = [.width, .height]
        glass.contentView.addSubview(content)
        moreLabel.font = Theme.Font.caption
        moreLabel.textColor = Theme.Color.textTertiary
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = cardHolder
        cardHolder.addSubview(card)
        content.addSubview(scroll)
        content.addSubview(moreLabel)
        // Scrolled, the answers moved: they wait again (the next layout).
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView
        )
        card.onAnswer = { [weak self] choice, button in
            guard let self, let request = self.request else { return }
            self.onAnswer?(request, choice, button)
        }
        card.canAnswer = { [weak self] choice in
            guard let self, let id = self.request?.id else { return false }
            return self.arming.isArmed(RequestInboxView.armingKey(id, choice))
        }
        card.onOpenTask = { [weak self] in
            guard let self, let request = self.request else { return }
            self.onOpenTask?(request)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows `request`, and how many other requests wait.
    func show(_ request: WaitingRequest, othersWaiting: Int) {
        self.request = request
        self.othersWaiting = othersWaiting
        card.show(request)
        moreLabel.stringValue = "\(othersWaiting) more · ⌘J"
        moreLabel.setAccessibilityLabel("\(othersWaiting) more waiting, Command J")
        moreLabel.isHidden = othersWaiting <= 0
        setAccessibilityLabel("Request from \(request.taskTitle)")
        needsLayout = true
    }

    /// Its height for its request.
    var fittingHeight: CGFloat {
        card.fittingHeight(width: Self.width) + (moreLabel.isHidden ? 0 : Self.moreHeight)
    }

    private static let moreHeight: CGFloat = 16 + RequestCardView.padding - Theme.Space.xs

    override func layout() {
        super.layout()
        let more = moreLabel.isHidden ? 0 : Self.moreHeight
        scroll.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - more))
        let width = scroll.contentSize.width
        let cardHeight = card.fittingHeight(width: width)
        cardHolder.frame = NSRect(x: 0, y: 0, width: width, height: max(cardHeight, scroll.contentSize.height))
        card.frame = NSRect(x: 0, y: 0, width: width, height: cardHeight)
        card.needsLayout = true
        card.layoutSubtreeIfNeeded()
        moreLabel.frame = NSRect(
            x: RequestCardView.padding, y: scroll.frame.maxY - Theme.Space.xs,
            width: bounds.width - 2 * RequestCardView.padding, height: 16
        )
        guard let id = request?.id else { return arming.refresh([:]) }
        // On screen, or from the top: the "more" line below can come and go.
        arming.refresh(card.answerButtons.reduce(into: [:]) { frames, entry in
            frames[RequestInboxView.armingKey(id, entry.key)] = RequestArming.place(of: entry.value, in: content)
        })
    }

    /// The host shows the callout: every answer waits before it takes a
    /// click.
    func opened() {
        escapeIsDown = false
        restartArming()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        RequestArming.observeMoves(of: window, by: self, selector: #selector(windowMoved))
        if window != nil { restartArming() }
    }

    /// Moved beside its icon, or its window moved: the next layout finds
    /// which answers slid on screen.
    override func setFrameOrigin(_ newOrigin: NSPoint) {
        let moved = newOrigin != frame.origin
        super.setFrameOrigin(newOrigin)
        if moved { needsLayout = true }
    }

    @objc private func windowMoved() { needsLayout = true }

    @objc private func scrolled() { needsLayout = true }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        restartArming()
    }

    /// Every answer waits again before it takes a click.
    func restartArming() { arming.restartAll() }

    // MARK: - Keys

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == "\u{1b}" { escapeIsDown = true } else { super.keyDown(with: event) }
    }

    /// Escape closes it on its release: the keyboard then goes back to a
    /// terminal, which a held key's repeats must not reach.
    private var escapeIsDown = false

    override func keyUp(with event: NSEvent) {
        guard event.charactersIgnoringModifiers == "\u{1b}", escapeIsDown else { return super.keyUp(with: event) }
        escapeIsDown = false
        onClose?()
    }

    override func cancelOperation(_ sender: Any?) { onClose?() }
}
