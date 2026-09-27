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
        // Russian: the Cmd key table types "z"; without Cmd the key types "я".
        XCTAssertTrue(passes(editor: true, "z", .command, ignoringModifiers: "я", keyCode: 0x06))
        // Dvorak-QWERTY⌘: QWERTY while Cmd is held, Dvorak's ";" otherwise.
        XCTAssertTrue(passes(editor: true, "z", .command, ignoringModifiers: ";", keyCode: 0x06))
        // A layout without a Latin Cmd table: fall back to the ANSI Z key.
        XCTAssertTrue(passes(editor: true, "я", .command, keyCode: 0x06))
        // AZERTY: the key at the ANSI Z position types "w" — that is Cmd+W.
        XCTAssertFalse(passes(editor: false, "w", .command, keyCode: 0x06))
    }

    /// Cmd+W closes the active editor tab on every layout, not the column.
    func testCloseTabLetterMatchesAcrossLayouts() {
        func typesW(_ characters: String, _ ignoring: String, _ keyCode: UInt16) -> Bool {
            WebContentKeyRouting.typesLetter(
                "w", ansiKeyCode: 0x0D, characters: characters, charactersIgnoringModifiers: ignoring, keyCode: keyCode
            )
        }
        XCTAssertTrue(typesW("w", "w", 0x0D))
        XCTAssertTrue(typesW("w", "ц", 0x0D)) // Russian
        XCTAssertTrue(typesW("w", ",", 0x0D)) // Dvorak-QWERTY⌘
        XCTAssertTrue(typesW("w", "w", 0x06)) // AZERTY: W sits at the ANSI Z position
        XCTAssertFalse(typesW("z", "z", 0x0D)) // AZERTY: Z sits at the ANSI W position
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

    /// Edit > Find in Terminal and Find Next/Previous act on terminal
    /// columns only; Monaco's find widget and web pages keep the chords.
    func testFindChordsReachWebContentInEditorAndBrowser() {
        for editor in [true, false] {
            XCTAssertTrue(passes(editor: editor, "f", .command))
            XCTAssertTrue(passes(editor: editor, "g", .command))
            XCTAssertTrue(passes(editor: editor, "G", [.command, .shift]))
            // Russian: the Cmd key table types the Latin letter.
            XCTAssertTrue(passes(editor: editor, "f", .command, ignoringModifiers: "а", keyCode: 0x03))
            XCTAssertTrue(passes(editor: editor, "п", .command, keyCode: 0x05))
        }
    }

    func testFindChordNeighboursStillReachTheMenu() {
        for editor in [true, false] {
            XCTAssertFalse(passes(editor: editor, "F", [.command, .shift]), "Search Workspace")
            XCTAssertFalse(passes(editor: editor, "f", [.command, .control]), "Enter Full Screen")
        }
    }

    func testMenuChordsAreNotPassedThrough() {
        XCTAssertFalse(passes(editor: true, "s", [.command, .control]))
        XCTAssertFalse(passes(editor: true, "e", .command))
        XCTAssertFalse(passes(editor: false, "t", .command))
    }
}
