import AppKit

/// Cmd-chords that an editor or browser column hands to its WebView instead
/// of the menu bar. The key interceptor sends every other Cmd-chord in those
/// columns to the menu first, because WKWebView's performKeyEquivalent would
/// otherwise swallow menu shortcuts such as Cmd+Arrow.
enum WebContentKeyRouting {
    static func passesToWebContent(
        isEditor: Bool,
        characters: String?,
        charactersIgnoringModifiers: String?,
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags
    ) -> Bool {
        let modifiers = modifierFlags.intersection([.command, .option, .control, .shift])
        func types(_ letter: String, ansiKeyCode: UInt16) -> Bool {
            typesLetter(
                letter, ansiKeyCode: ansiKeyCode,
                characters: characters, charactersIgnoringModifiers: charactersIgnoringModifiers, keyCode: keyCode
            )
        }

        // Cmd+Z / Shift+Cmd+Z: Monaco keeps its own undo stack and web apps
        // handle undo in JavaScript. Edit > Undo/Redo only serves panel text
        // fields (PanelTextUndo), and a disabled menu item still swallows its
        // chord, so the menu must not see these first.
        if types("z", ansiKeyCode: 0x06),
           modifiers == [.command] || modifiers == [.command, .shift] {
            return true
        }
        // Cmd+F, Cmd+G, Shift+Cmd+G: Edit > Find in Terminal and Find
        // Next/Previous only act on terminal columns. Monaco's find widget
        // and web apps' own search keep these chords.
        if types("f", ansiKeyCode: 0x03), modifiers == [.command] {
            return true
        }
        if types("g", ansiKeyCode: 0x05),
           modifiers == [.command] || modifiers == [.command, .shift] {
            return true
        }
        guard isEditor else { return false }

        // Cmd+P: Monaco rebinds it to the workspace file picker. The command
        // palette stays reachable in the editor through Shift+Cmd+P.
        if types("p", ansiKeyCode: 0x23), modifiers == [.command] {
            return true
        }
        // Cmd+Opt+Return: Monaco resolves this chord itself — "Replace All"
        // while the find widget is open, else it posts the send-selection
        // bridge message. Routing it to the menu would shadow Replace All.
        if keyCode == 0x24, modifiers.contains(.option) {
            return true
        }
        return false
    }

    /// Whether a Cmd key event means `letter`, the way AppKit matches menu key
    /// equivalents. `characters` follows the layout's Cmd key table, which on
    /// Apple's non-Latin layouts (Russian, Greek, Hebrew…) and Dvorak-QWERTY⌘
    /// types the QWERTY letter even when `charactersIgnoringModifiers` does
    /// not. The ANSI key position is a last resort for layouts without a
    /// Latin Cmd table.
    static func typesLetter(
        _ letter: String,
        ansiKeyCode: UInt16,
        characters: String?,
        charactersIgnoringModifiers: String?,
        keyCode: UInt16
    ) -> Bool {
        let typed = [characters, charactersIgnoringModifiers].compactMap { $0?.lowercased() }
        if typed.contains(letter) { return true }
        let typesLatin = typed.contains { $0.unicodeScalars.allSatisfy(\.isASCII) }
        return !typesLatin && keyCode == ansiKeyCode
    }
}
