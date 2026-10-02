import AppKit

/// A key equivalent the way AppKit matches it: an uppercase key implies
/// Shift, so the key is stored lowercased with Shift added to the modifiers.
struct KeyChord: Hashable, Sendable {
    let key: String
    let modifiers: NSEvent.ModifierFlags

    init(_ key: String, _ modifiers: NSEvent.ModifierFlags = .command) {
        let lowercased = key.lowercased()
        var modifiers = modifiers.intersection([.command, .option, .control, .shift])
        if lowercased != key { modifiers.insert(.shift) }
        self.key = lowercased
        self.modifiers = modifiers
    }

    /// macOS menu order: ⌃ ⌥ ⇧ ⌘, then the key.
    var display: String {
        var result = ""
        if modifiers.contains(.control) { result += "\u{2303}" }
        if modifiers.contains(.option) { result += "\u{2325}" }
        if modifiers.contains(.shift) { result += "\u{21E7}" }
        if modifiers.contains(.command) { result += "\u{2318}" }
        return result + key.uppercased()
    }

    // Written out because NSEvent.ModifierFlags is Equatable but not Hashable.
    static func == (lhs: KeyChord, rhs: KeyChord) -> Bool {
        lhs.key == rhs.key && lhs.modifiers.rawValue == rhs.modifiers.rawValue
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(key)
        hasher.combine(modifiers.rawValue)
    }
}

/// Chords that the menu bar binds and the command palette displays. Palette
/// rows can only show a case of this enum, and a test checks every case is
/// bound in the menu, so a row never advertises a chord that does nothing.
enum NiruxShortcuts: CaseIterable {
    case commandPalette
    /// In an editor column Monaco keeps ⌘P for its file picker, so ⇧⌘P
    /// (VS Code's palette chord) reaches the palette there.
    case commandPaletteAlternate
    case newTerminal
    case newWorkspace
    case openBrowser
    case closeColumn
    case cycleWidth
    case webInspector
    case searchWorkspace
    case searchEverywhere
    case toggleEditorDiff
    case toggleSidebar
    case nextWaitingAgent
    case settings

    var chord: KeyChord {
        switch self {
        case .commandPalette: KeyChord("p")
        case .commandPaletteAlternate: KeyChord("p", [.command, .shift])
        case .newTerminal: KeyChord("t")
        case .newWorkspace: KeyChord("n")
        case .openBrowser: KeyChord("b")
        case .closeColumn: KeyChord("w")
        case .cycleWidth: KeyChord("e")
        case .webInspector: KeyChord("i", [.command, .option])
        case .searchWorkspace: KeyChord("f", [.command, .shift])
        case .searchEverywhere: KeyChord("f", [.command, .option])
        case .toggleEditorDiff: KeyChord("d", [.command, .shift])
        case .toggleSidebar: KeyChord("s", [.command, .control])
        case .nextWaitingAgent: KeyChord("j")
        case .settings: KeyChord(",")
        }
    }

    // Used by the sidebar's context menu and shortcut hints.
    static let newWorkspaceKey = newWorkspace.chord.key
    static let newTerminalDisplay = newTerminal.chord.display
    static let newWorkspaceDisplay = newWorkspace.chord.display
}
