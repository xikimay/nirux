import AppKit

/// Where the key interceptor sends a key when a find bar is involved: a
/// terminal's, or a browser column's. Terminal columns otherwise write every
/// key to the PTY.
enum TerminalFindKeyRouting {
    enum FieldRoute: Equatable {
        /// Plain keys (Return, Escape, arrows included) edit the field.
        case field
        /// Cmd chords try the menu first — Find Next, Copy/Paste on the
        /// field — and unmatched ones (Cmd+Backspace) reach the field.
        case menuThenField
        /// Cmd+Arrow and Shift+Cmd+Arrow move or select to the line ends.
        /// Straight to the field editor: the menu binds them to Focus and
        /// Move Column and Workspace Up/Down, which would take the keyboard
        /// away mid-edit.
        case fieldEditor
    }

    /// A key typed while a find field has the focus.
    static func routeInField(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) -> FieldRoute {
        let modifiers = modifierFlags.intersection([.command, .option, .control, .shift])
        guard modifiers.contains(.command) else { return .field }
        if WebContentKeyRouting.movesCaretToTextEdge(keyCode: keyCode, modifierFlags: modifierFlags) {
            return .fieldEditor
        }
        return .menuThenField
    }

    /// Escape with the find bar open but the terminal focused closes the
    /// bar instead of reaching the program — Ghostty binds Escape to
    /// `end_search` the same way while a search is active. Otherwise the
    /// Escape meant for the bar would interrupt a Claude Code turn.
    static func closesOpenFindBar(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) -> Bool {
        keyCode == 0x35 && modifierFlags.isDisjoint(with: [.command, .option, .control, .shift])
    }
}
