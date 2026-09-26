import XCTest
import AppKit
@testable import Nirux

/// Which Cmd-chords an editor or browser column hands to its WebView rather
/// than to the menu bar.
final class WebContentKeyRoutingTests: XCTestCase {
    private func passes(
        editor: Bool,
        _ characters: String,
        _ modifiers: NSEvent.ModifierFlags,
        ignoringModifiers: String? = nil,
        keyCode: UInt16 = 0
    ) -> Bool {
        WebContentKeyRouting.passesToWebContent(
            isEditor: editor,
            characters: characters,
            charactersIgnoringModifiers: ignoringModifiers ?? characters,
            keyCode: keyCode,
            modifierFlags: modifiers
        )
    }

    func testUndoAndRedoReachWebContentInEditorAndBrowser() {
        for editor in [true, false] {
            XCTAssertTrue(passes(editor: editor, "z", .command))
            // charactersIgnoringModifiers keeps Shift, so Redo arrives as "Z".
            XCTAssertTrue(passes(editor: editor, "Z", [.command, .shift]))
            XCTAssertTrue(passes(editor: editor, "z", [.command, .capsLock, .numericPad]))
        }
    }

    /// A disabled Undo item still swallows Cmd+Z, so the pass-through must
    /// recognise Z on every layout the menu does.
    func testUndoIsRecognisedOnOtherKeyboardLayouts() {
        // Russian: the Z key types "я"; AppKit matches it by key position.
        XCTAssertTrue(passes(editor: true, "я", .command, keyCode: 0x06))
        // Dvorak-QWERTY⌘: QWERTY while Cmd is held, Dvorak otherwise.
        XCTAssertTrue(passes(editor: true, "z", .command, ignoringModifiers: ";", keyCode: 0x2C))
        // AZERTY: the key at the ANSI Z position types "w" — that is Cmd+W.
        XCTAssertFalse(passes(editor: false, "w", .command, keyCode: 0x06))
    }

    func testWordWrapChordStillReachesTheMenu() {
        XCTAssertFalse(passes(editor: true, "z", [.command, .option]))
        XCTAssertFalse(passes(editor: true, "z", [.command, .control]))
    }

    func testCommandPOpensTheFilePickerOnlyInTheEditor() {
        XCTAssertTrue(passes(editor: true, "p", .command))
        XCTAssertTrue(passes(editor: true, "з", .command, keyCode: 0x23))
        XCTAssertFalse(passes(editor: false, "p", .command))
        // Shift+Cmd+P must reach the menu so the palette opens in the editor.
        XCTAssertFalse(passes(editor: true, "P", [.command, .shift]))
    }

    func testCommandOptionReturnStaysWithMonaco() {
        XCTAssertTrue(passes(editor: true, "\r", [.command, .option], keyCode: 0x24))
        XCTAssertFalse(passes(editor: false, "\r", [.command, .option], keyCode: 0x24))
    }

    func testMenuChordsAreNotPassedThrough() {
        XCTAssertFalse(passes(editor: true, "s", [.command, .control]))
        XCTAssertFalse(passes(editor: true, "e", .command))
        XCTAssertFalse(passes(editor: false, "t", .command))
    }
}
