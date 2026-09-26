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
        let typed = [characters, charactersIgnoringModifiers].compactMap { $0?.lowercased() }

        // Cmd+Z / Shift+Cmd+Z: Monaco keeps its own undo stack and web apps
        // handle undo in JavaScript. Edit > Undo/Redo only serves panel text
        // fields (PanelTextUndo), and a disabled menu item still swallows its
        // chord, so the menu must not see these first.
        if types("z", ansiKeyCode: 0x06, typed: typed, keyCode: keyCode),
           modifiers == [.command] || modifiers == [.command, .shift] {
            return true
        }
        guard isEditor else { return false }

        // Cmd+P: Monaco rebinds it to the workspace file picker. The command
        // palette stays reachable in the editor through Shift+Cmd+P.
        if types("p", ansiKeyCode: 0x23, typed: typed, keyCode: keyCode), modifiers == [.command] {
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

    /// Whether the key event means `letter` the way AppKit matches menu key
    /// equivalents: by the typed character (`characters` follows layouts such
    /// as Dvorak-QWERTY⌘ that switch while Cmd is held), or by the ANSI key
    /// position when the layout types no Latin character (Russian, Greek…).
    private static func types(_ letter: String, ansiKeyCode: UInt16, typed: [String], keyCode: UInt16) -> Bool {
        if typed.contains(letter) { return true }
        let typesLatin = typed.contains { $0.unicodeScalars.allSatisfy(\.isASCII) }
        return !typesLatin && keyCode == ansiKeyCode
    }
}
