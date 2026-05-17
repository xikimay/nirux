import AppKit

/// Converts NSEvent key events to raw bytes for the PTY.
/// Handles all modifier combinations correctly:
///   Option+key → ESC prefix (Meta/Alt)
///   Ctrl+key → control character
///   Option+Backspace → ESC + DEL (delete word)
///   Cmd+Backspace → \x15 (kill line)
enum KeyMapper {

    static func bytesForEvent(_ event: NSEvent) -> Data {
        let keyCode = event.keyCode
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasOption = mods.contains(.option)
        let hasCtrl = mods.contains(.control)
        let hasShift = mods.contains(.shift)
        let hasCmd = mods.contains(.command)

        // Cmd+key: only handle specific terminal combos, rest goes to menu
        if hasCmd {
            return cmdKeyBytes(keyCode: keyCode) ?? Data()
        }

        // Special keys (Enter, Tab, Backspace, arrows, etc.)
        if let special = specialKeyBytes(keyCode: keyCode) {
            return resolveSpecialKey(special, keyCode: keyCode, shift: hasShift, ctrl: hasCtrl, option: hasOption)
        }

        // Ctrl+key → control characters
        if hasCtrl, let ctrlData = ctrlKeyBytes(event: event, hasOption: hasOption) {
            return ctrlData
        }

        // Option+regular key → just send the character (no ESC prefix)
        // ESC prefix breaks Claude Code (interprets ESC as "cancel input")
        // Option+special keys (arrows, backspace) already handled above with proper CSI encoding
        if hasOption, !hasCtrl, let chars = event.charactersIgnoringModifiers, !chars.isEmpty {
            return Data(chars.utf8)
        }

        return regularCharBytes(event: event)
    }

    // MARK: - Resolve special key with optional modifiers

    private static func resolveSpecialKey(_ special: Data, keyCode: UInt16, shift: Bool, ctrl: Bool, option: Bool) -> Data {
        if let modified = modifiedSpecialKey(keyCode: keyCode, shift: shift, ctrl: ctrl, option: option) {
            return modified
        }
        if option {
            return Data([0x1B]) + special
        }
        return special
    }

    // MARK: - Ctrl+key helper

    private static func ctrlKeyBytes(event: NSEvent, hasOption: Bool) -> Data? {
        guard let chars = event.charactersIgnoringModifiers, let keyChar = chars.first else { return nil }
        guard let ctrlByte = controlCharacter(for: keyChar) else { return nil }
        return hasOption ? Data([0x1B, ctrlByte]) : Data([ctrlByte])
    }

    // MARK: - Regular character bytes

    private static func regularCharBytes(event: NSEvent) -> Data {
        guard let chars = event.characters, !chars.isEmpty else { return Data() }
        // Filter macOS Private Use Area function key characters
        if chars.count == 1, let scalar = chars.unicodeScalars.first,
           (0xF700...0xF8FF).contains(scalar.value) {
            return Data()
        }
        return Data(chars.utf8)
    }

    // MARK: - Special keys (dictionary lookup)

    private static let specialKeyTable: [UInt16: Data] = {
        let esc = { (seq: String) -> Data in Data([0x1B] + Array(seq.utf8)) }
        return [
            0x24: Data([0x0D]),  // Enter → \r
            0x4C: Data([0x0D]),  // Numpad Enter → \r
            0x30: Data([0x09]),  // Tab → \t
            0x33: Data([0x7F]),  // Backspace → DEL
            0x75: esc("[3~"),      // Forward Delete
            0x35: Data([0x1B]), // Escape
            // Arrows
            0x7B: esc("[D"),       // Left
            0x7C: esc("[C"),       // Right
            0x7D: esc("[B"),       // Down
            0x7E: esc("[A"),       // Up
            // Navigation
            0x73: esc("[H"),       // Home
            0x77: esc("[F"),       // End
            0x74: esc("[5~"),      // Page Up
            0x79: esc("[6~"),      // Page Down
            // Function keys
            0x7A: esc("OP"),       // F1
            0x78: esc("OQ"),       // F2
            0x63: esc("OR"),       // F3
            0x76: esc("OS"),       // F4
            0x60: esc("[15~"),     // F5
            0x61: esc("[17~"),     // F6
            0x62: esc("[18~"),     // F7
            0x64: esc("[19~"),     // F8
            0x65: esc("[20~"),     // F9
            0x6D: esc("[21~"),     // F10
            0x67: esc("[23~"),     // F11
            0x6F: esc("[24~")     // F12
        ]
    }()

    private static func specialKeyBytes(keyCode: UInt16) -> Data? {
        specialKeyTable[keyCode]
    }

    // MARK: - Cmd+key (terminal-specific, not in menus)

    private static let cmdKeyTable: [UInt16: Data] = [
        0x33: Data([0x15]) // Cmd+Backspace → Ctrl+U (kill line)
    ]

    private static func cmdKeyBytes(keyCode: UInt16) -> Data? {
        cmdKeyTable[keyCode]
    }

    // MARK: - Control characters (dictionary lookup)

    private static let controlCharTable: [UInt8: UInt8] = [
        0x5B: 0x1B, // Ctrl+[
        0x5C: 0x1C, // Ctrl+\
        0x5D: 0x1D, // Ctrl+]
        0x5E: 0x1E, // Ctrl+^
        0x5F: 0x1F, // Ctrl+_
        0x40: 0x00, // Ctrl+@
        0x20: 0x00 // Ctrl+Space
    ]

    private static func controlCharacter(for char: Character) -> UInt8? {
        guard let ascii = char.asciiValue else { return nil }
        // a-z → 0x01-0x1A
        if (0x61...0x7A).contains(ascii) { return ascii - 0x60 }
        // A-Z → 0x01-0x1A
        if (0x41...0x5A).contains(ascii) { return ascii - 0x40 }
        return controlCharTable[ascii]
    }

    // MARK: - Modified special keys (Shift/Ctrl/Option + arrows etc.)

    /// CSI letter-based keys: arrows, Home, End
    private static let csiLetterTable: [UInt16: String] = [
        0x7E: "A", // Up
        0x7D: "B", // Down
        0x7C: "C", // Right
        0x7B: "D", // Left
        0x73: "H", // Home
        0x77: "F" // End
    ]

    /// CSI numeric-based keys: Delete, PgUp, PgDn
    private static let csiNumericTable: [UInt16: String] = [
        0x75: "3", // Forward Delete
        0x74: "5", // Page Up
        0x79: "6" // Page Down
    ]

    private static func modifiedSpecialKey(keyCode: UInt16, shift: Bool, ctrl: Bool, option: Bool) -> Data? {
        // Only encode if there's a modifier beyond the base key
        guard shift || ctrl || option else { return nil }

        let mod = 1 + (shift ? 1 : 0) + (option ? 2 : 0) + (ctrl ? 4 : 0)

        // Option-only + Left/Right → readline word-motion (`ESC b` / `ESC f`).
        // macOS Terminal emits these and they match zsh/bash/readline's default
        // emacs bindings. The xterm CSI form `\e[1;3D` works in apps that
        // explicitly bind it but most shells do not, so users see literal
        // `;3D` echoed. Other modifier combos still fall through to CSI below.
        if option, !shift, !ctrl {
            if keyCode == 0x7B { return Data([0x1B, 0x62]) } // Left → ESC b
            if keyCode == 0x7C { return Data([0x1B, 0x66]) } // Right → ESC f
        }

        if let base = csiLetterTable[keyCode] {
            return esc("[1;\(mod)\(base)")
        }

        if let numBase = csiNumericTable[keyCode] {
            return esc("[\(numBase);\(mod)~")
        }

        // Shift+Tab → backtab sequence (standard ANSI, not CSI modifier format)
        if keyCode == 0x30 {
            return shift ? esc("[Z") : nil
        }

        // CSI u encoding for Shift+Enter (Kitty keyboard protocol)
        // Only when Shift is held — Option+Enter must stay as ESC+CR for readline/shells
        if shift, keyCode == 0x24 || keyCode == 0x4C {
            return esc("[13;\(mod)u")
        }

        return nil
    }

    private static func esc(_ seq: String) -> Data {
        Data([0x1B] + Array(seq.utf8))
    }
}
