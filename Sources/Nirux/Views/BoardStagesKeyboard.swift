import AppKit

// MARK: - The Board from the keyboard (docs/design/board-stages.md, section 7)

/// Full Keyboard Access on the Board: Tab stops on each line and each
/// "Merged today" entry, as on any control; Space or Return opens the
/// task; Control-Return, macOS's own key for it, shows the menu.
@MainActor
enum BoardStagesKeyboard {
    /// Tab stops on every control (System Settings › Keyboard). The tests
    /// give their own.
    static var isFullAccess: () -> Bool = { NSApp.isFullKeyboardAccessEnabled }

    enum Key: Equatable {
        /// Space or Return: as a click.
        case press
        /// Control-Return: the menu.
        case menu
        case other
    }

    static func key(_ event: NSEvent) -> Key {
        let flags = event.modifierFlags.intersection([.shift, .control, .option, .command])
        switch event.keyCode {
        case 49: return flags.isEmpty ? .press : .other
        case 36, 76: return flags.isEmpty ? .press : flags == .control ? .menu : .other
        default: return .other
        }
    }

    /// The focus ring's shape: the view's bounds, rounded.
    static func ring(_ bounds: NSRect) -> NSBezierPath {
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 1), xRadius: 5, yRadius: 5)
    }
}
