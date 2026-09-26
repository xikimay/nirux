import AppKit

/// Cmd-chords that an editor or browser column hands to its WebView instead
/// of the menu bar. The key interceptor sends every other Cmd-chord in those
/// columns to the menu first, because WKWebView's performKeyEquivalent would
/// otherwise swallow menu shortcuts such as Cmd+Arrow.
enum WebContentKeyRouting {
    static func passesToWebContent(
        isEditor: Bool,
        charactersIgnoringModifiers characters: String?,
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags
    ) -> Bool {
        let modifiers = modifierFlags.intersection([.command, .option, .control, .shift])
        let key = characters?.lowercased()

        // Cmd+Z / Shift+Cmd+Z: Monaco keeps its own undo stack and web apps
        // handle undo in JavaScript. Edit > Undo/Redo only serves panel text
        // fields (PanelTextUndo), so the menu must not take these first.
        if key == "z", modifiers == [.command] || modifiers == [.command, .shift] {
            return true
        }
        guard isEditor else { return false }

        // Cmd+P: Monaco rebinds it to the workspace file picker. The command
        // palette stays reachable in the editor through Shift+Cmd+P.
        if key == "p", modifiers == [.command] {
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
}
