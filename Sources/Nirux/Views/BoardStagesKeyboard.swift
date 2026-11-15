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

    /// A line or an entry takes the keyboard from the keyboard only: a
    /// click on it takes none, as a button's doesn't (the click gives the
    /// keyboard to the Board's column), so it draws no ring.
    static func takesKeyboard() -> Bool {
        guard isFullAccess() else { return false }
        let pointerPresses: Set<NSEvent.EventType> = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        return currentEvent().map { !pointerPresses.contains($0.type) } ?? true
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
        if took { scrollToVisible(bounds) }
        return took
    }
}
