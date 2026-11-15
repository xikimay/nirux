import AppKit

/// The rail's callout (docs/design/glass-interface.md): a click on an amber
/// icon shows that task's request beside it, with its answers (the inbox's
/// card, the rows' answers), "Open task", and how many more wait (⌘J).
/// Escape or a click elsewhere closes it. Built, not shown yet: phase 3
/// hosts it at the icon `IconRail.onRequest` gives.
final class RequestCalloutView: NSView {
    static let width: CGFloat = 330

    /// A click on an answer: the request, the answer, its button.
    var onAnswer: ((WaitingRequest, RequestChoice, NSView) -> Void)?
    var onOpenTask: ((String) -> Void)?
    var onClose: (() -> Void)?

    var level: InterfaceTransparency {
        get { glass.level }
        set { glass.level = newValue }
    }

    private(set) var request: WaitingRequest?
    private let glass: GlassView
    private let content = FlippedCalloutView()
    let card = RequestCardView(trailing: .openTask)
    /// "1 more · ⌘J".
    let moreLabel = NSTextField(labelWithString: "")
    let arming: RequestArming

    init(level: InterfaceTransparency, arming: RequestArming = RequestArming()) {
        glass = GlassView(role: .floating, level: level, cornerRadius: Theme.Radius.panel)
        self.arming = arming
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 120))
        glass.autoresizingMask = [.width, .height]
        glass.frame = bounds
        addSubview(glass)
        content.frame = glass.contentView.bounds
        content.autoresizingMask = [.width, .height]
        glass.contentView.addSubview(content)
        moreLabel.font = Theme.Font.caption
        moreLabel.textColor = Theme.Color.textTertiary
        content.addSubview(card)
        content.addSubview(moreLabel)
        card.onAnswer = { [weak self] choice, button in
            guard let self, let request = self.request else { return }
            self.onAnswer?(request, choice, button)
        }
        card.canAnswer = { [weak self] choice in
            guard let self, let id = self.request?.id else { return false }
            return self.arming.isArmed(RequestInboxView.armingKey(id, choice))
        }
        card.onOpenTask = { [weak self] in
            guard let self, let taskID = self.request?.taskID else { return }
            self.onOpenTask?(taskID)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows `request`, and how many other requests wait.
    func show(_ request: WaitingRequest, othersWaiting: Int) {
        self.request = request
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
        let cardHeight = card.fittingHeight(width: bounds.width)
        card.frame = NSRect(x: 0, y: 0, width: bounds.width, height: cardHeight)
        card.needsLayout = true
        card.layoutSubtreeIfNeeded()
        moreLabel.frame = NSRect(
            x: RequestCardView.padding, y: cardHeight - Theme.Space.xs,
            width: bounds.width - 2 * RequestCardView.padding, height: 16
        )
        guard let id = request?.id else { return arming.refresh([:]) }
        arming.refresh(card.answerButtons.reduce(into: [:]) { frames, entry in
            frames[RequestInboxView.armingKey(id, entry.key)] = convert(entry.value.bounds, from: entry.value)
        })
    }

    // MARK: - Keys

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == "\u{1b}" { onClose?() } else { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) { onClose?() }
}

private final class FlippedCalloutView: NSView {
    override var isFlipped: Bool { true }
}
