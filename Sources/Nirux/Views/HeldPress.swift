import AppKit

/// A press of the left button followed to its mouse-up in event tracking
/// mode, its events taken off the queue: the view under the pointer gets no
/// drag of it, and the window doesn't move from a view that lets it
/// (`mouseDownCanMoveWindow`). A task's row (SidebarView+Drag) and a
/// column's header (NiruxShellView+ColumnDrag) drag this way.
@MainActor
struct HeldPress {
    enum End { case released, cancelled, lost }

    let window: NSWindow
    /// Whether the button still holds, as the event source says. Events
    /// posted to the app move no button: tests say.
    var holds: @MainActor (NSWindow) -> Bool = HeldPress.leftButtonHolds

    static let leftButtonHolds: @MainActor (NSWindow) -> Bool = { $0.isVisible && NSEvent.pressedMouseButtons & 1 != 0 }
    /// How far the pointer goes before a press drags.
    static let dragThreshold: CGFloat = 4
    /// A drag's own ticks (`NSEvent.startPeriodicEvents`), and how many of
    /// them in a row find the press gone before it is lost: as long as the
    /// timeout.
    static let tickPeriod: TimeInterval = 0.05
    static let lostPressTicks = 5
    /// How long a wait for the next event lasts: the press notices a window
    /// that closed or a button released without a delivered mouse-up,
    /// instead of blocking the main thread forever.
    private static let eventTimeout: TimeInterval = 0.25
    private static let escapeKeyCode: UInt16 = 53
    private static let eventMask: NSEvent.EventTypeMask = [
        .leftMouseDragged, .leftMouseUp, .keyDown, .keyUp, .periodic,
        .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp, .scrollWheel
    ]

    /// Follows the press to its end, told once to `ended`. Each drag goes
    /// to `moved`, and again at each of the drag's own ticks while
    /// `isDragging`, so that autoscroll goes on while the pointer holds
    /// still. Keys go on to the app until the press drags; then Escape
    /// cancels it (the rest of the press swallowed after `ended`), and the
    /// other keys are swallowed.
    func follow(isDragging: () -> Bool, moved: (NSEvent) -> Void, ended: (End) -> Void) {
        var lastDrag: NSEvent?
        // The ticks in a row that found the press gone, its mouse-up not
        // here.
        var ticksGone = 0
        while true {
            guard let event = nextEvent() else {
                if isLost(atTimeout: true, ticksGone: &ticksGone) { return ended(.lost) }
                continue
            }
            switch event.type {
            case .leftMouseDragged:
                // Drags still come: the press holds as far as the events
                // say (events posted to the app move no button).
                ticksGone = 0
                lastDrag = event
                moved(event)
            case .periodic:
                // A drag's own ticks keep the timeout above from ever
                // coming.
                if isLost(atTimeout: false, ticksGone: &ticksGone) { return ended(.lost) }
                if isDragging(), let lastDrag { moved(lastDrag) }
            case .leftMouseUp:
                // A later press's: this one's went elsewhere.
                return ended(answersALaterPress(event) ? .lost : .released)
            case .keyDown where isDragging():
                // Other keys are swallowed while the drag is modal.
                guard event.keyCode == Self.escapeKeyCode else { break }
                ended(.cancelled)
                swallowRest()
                return
            case .keyUp where isDragging():
                break
            case .keyDown, .keyUp:
                // A press that doesn't drag must not eat typing.
                NSApp.sendEvent(event)
            default:
                break
            }
        }
    }

    /// Swallows the rest of the press. True when its mouse-up came, false
    /// when it was lost.
    @discardableResult
    func swallowRest() -> Bool {
        var ticksGone = 0
        while true {
            guard let event = nextEvent() else {
                if isLost(atTimeout: true, ticksGone: &ticksGone) { return false }
                continue
            }
            switch event.type {
            case .leftMouseUp:
                return !answersALaterPress(event)
            case .keyDown, .keyUp:
                // No drag is modal here: typing goes on.
                NSApp.sendEvent(event)
            default:
                break
            }
        }
    }

    private func nextEvent() -> NSEvent? {
        window.nextEvent(
            matching: Self.eventMask, until: Date(timeIntervalSinceNow: Self.eventTimeout), inMode: .eventTracking, dequeue: true
        )
    }

    /// At a tick of the press, whether it is lost: its mouse-up went
    /// elsewhere (a modal, another app), and the press would hold what
    /// follows it, and a drag the keyboard, until the next click.
    /// - A press made since proves this one ended.
    /// - At a timeout nothing came for as long as a mouse-up is waited
    ///   for: the button up, or the window gone, is enough.
    /// - A drag's own ticks keep that timeout from ever coming: the press
    ///   is lost once `lostPressTicks` of them in a row found it gone,
    ///   unless its mouse-up waits in the queue (the app was busy): it is
    ///   never taken ahead of the drags and keys queued before it.
    /// No clock in this: the tests' stand still.
    private func isLost(atTimeout: Bool, ticksGone: inout Int) -> Bool {
        if let press = queued(.leftMouseDown) {
            // Unless this one's mouse-up is queued before it.
            guard let mouseUp = queued(.leftMouseUp), mouseUp.timestamp <= press.timestamp else { return true }
            return false
        }
        guard !holds(window) else {
            ticksGone = 0
            return false
        }
        if atTimeout { return true }
        ticksGone += 1
        return ticksGone >= Self.lostPressTicks && queued(.leftMouseUp) == nil
    }

    /// The first event of that kind waiting in the queue, left there.
    private func queued(_ kind: NSEvent.EventTypeMask) -> NSEvent? {
        window.nextEvent(matching: kind, until: .distantPast, inMode: .eventTracking, dequeue: false)
    }

    /// A mouse-up the press just took that answers a press made after its
    /// own (the loop never takes a press): its own mouse-up was lost. The
    /// mouse-up goes back behind that press, which gets it.
    private func answersALaterPress(_ mouseUp: NSEvent) -> Bool {
        guard let press = queued(.leftMouseDown), press.timestamp < mouseUp.timestamp else { return false }
        NSApp.postEvent(mouseUp, atStart: false)
        return true
    }
}
