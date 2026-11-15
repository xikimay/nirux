import AppKit

// MARK: - The Board from the keyboard (docs/design/board-stages.md, section 7)

/// Full Keyboard Access on the Board: Tab stops on each line and each
/// "Merged today" entry, as on any control; Space or Return opens the
/// task; Control-Return shows the menu.
@MainActor
enum BoardStagesKeyboard {
    /// Tab stops on every control (System Settings › Keyboard). The tests
    /// give their own.
    static var isFullAccess: () -> Bool = { NSApp.isFullKeyboardAccessEnabled }
    /// The event being handled. (The tests give their own.)
    static var currentEvent: () -> NSEvent? = { NSApp.currentEvent }

    /// A stop of the Board takes the keyboard from the keyboard only (a
    /// key, or no event: a change the Board made by itself), as a button
    /// does: not from a click, a drag, nor a rebuild a click's action ran.
    /// A click on a line or an entry gives the keyboard to the Board's
    /// column (`clicked`): no ring.
    static func takesKeyboard() -> Bool {
        guard isFullAccess() else { return false }
        let keys: Set<NSEvent.EventType> = [.keyDown, .keyUp, .flagsChanged]
        return currentEvent().map { keys.contains($0.type) } ?? true
    }

    /// While the Board rebuilds its views, a stop AppKit hands the keyboard
    /// to (the one it had went, or hid) doesn't scroll the list: the Board
    /// picks where it goes once done (`BoardStagesView.viewsChanged`).
    static var rebuilds = 0

    /// A stop took the keyboard: the list scrolls it into sight.
    static func tookKeyboard(_ view: NSView) {
        if rebuilds == 0 { view.scrollToVisible(view.bounds) }
    }

    /// A click on a line or an entry: whatever of the Board had the keyboard
    /// gives it to the column, as a click in a column does, so that the next
    /// Space doesn't open the line that had it.
    static func clicked(_ view: NSView) {
        guard let window = view.window, let responder = window.firstResponder as? NSView, responder !== view,
              let stages = sequence(first: view, next: \.superview).first(where: { $0 is BoardStagesView }),
              responder.isDescendant(of: stages), let column = stages.superview
        else { return }
        window.makeFirstResponder(column)
    }

    enum Key: Equatable {
        /// Space or Return: as a click.
        case press
        /// Control-Return: the menu.
        case menu
        /// A key held down, repeating: nothing more.
        case repeated
        case other
    }

    static func key(_ event: NSEvent) -> Key {
        if event.isARepeat, [49, 36, 76].contains(event.keyCode) { return .repeated }
        let flags = event.modifierFlags.intersection([.shift, .control, .option, .command])
        switch event.keyCode {
        case 49: return flags.isEmpty ? .press : .other
        case 36, 76: return flags.isEmpty ? .press : flags == .control ? .menu : .other
        default: return .other
        }
    }

    /// A key pressed on a line or an entry: Space, Return or Control-Return
    /// acts as it comes up, as a button's Space does. The repeats of a key
    /// held down land on the line then, not where the press sends the
    /// keyboard: a task's terminal, where a Return would answer its agent.
    @MainActor
    struct Held {
        private var down: (code: UInt16, key: Key)?

        /// A key going down on the view: false for one it doesn't take
        /// (its superclass's).
        mutating func keyDown(_ event: NSEvent) -> Bool {
            let key = BoardStagesKeyboard.key(event)
            switch key {
            case .press, .menu: down = (event.keyCode, key)
            case .repeated: break
            case .other: return false
            }
            return true
        }

        /// What to do as a key comes up: what it went down for on the view,
        /// once; nil for one that went down elsewhere.
        mutating func keyUp(_ event: NSEvent) -> Key? {
            guard let down, down.code == event.keyCode else { return nil }
            self.down = nil
            return down.key
        }

        /// The keyboard went elsewhere: a key coming up later went down there.
        mutating func reset() { down = nil }
    }

    /// The focus ring's shape: the view's bounds, rounded.
    static func ring(_ bounds: NSRect) -> NSBezierPath {
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 1), xRadius: 5, yRadius: 5)
    }
}

/// A button of the Board: it takes the keyboard as the lines do
/// (`BoardStagesKeyboard.takesKeyboard`), and the list scrolls it into
/// sight when it does.
@MainActor
class BoardStagesKeyButton: NSButton {
    override var acceptsFirstResponder: Bool { isEnabled && BoardStagesKeyboard.takesKeyboard() }

    override func becomeFirstResponder() -> Bool {
        let took = super.becomeFirstResponder()
        if took { BoardStagesKeyboard.tookKeyboard(self) }
        return took
    }
}

/// A line or a "Merged today" entry from the keyboard: a stop while Full
/// Keyboard Access is on and it does something (`isKeyStop`), with a
/// rounded ring; Space, Return and Control-Return act as the key comes up
/// (`BoardStagesKeyboard.Held`), on `pressed`.
@MainActor
class BoardStagesKeyView: NSView {
    /// The key that went down on it, which acts as it comes up.
    private var held = BoardStagesKeyboard.Held()

    /// It does something from the keyboard now.
    var isKeyStop: Bool { true }

    /// Space or Return (`.press`), Control-Return (`.menu`).
    func pressed(_ key: BoardStagesKeyboard.Key) {}

    override var acceptsFirstResponder: Bool { isKeyStop && BoardStagesKeyboard.takesKeyboard() }
    override var canBecomeKeyView: Bool { acceptsFirstResponder && !isHiddenOrHasHiddenAncestor }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { BoardStagesKeyboard.ring(bounds).fill() }

    override func becomeFirstResponder() -> Bool {
        let took = super.becomeFirstResponder()
        if took { BoardStagesKeyboard.tookKeyboard(self) }
        return took
    }

    override func resignFirstResponder() -> Bool {
        held.reset()
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        if !held.keyDown(event) { super.keyDown(with: event) }
    }

    override func keyUp(with event: NSEvent) {
        if let key = held.keyUp(event) { pressed(key) } else { super.keyUp(with: event) }
    }
}
