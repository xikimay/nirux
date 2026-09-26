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
        keyCode: UInt16 = 0
    ) -> Bool {
        WebContentKeyRouting.passesToWebContent(
            isEditor: editor,
            charactersIgnoringModifiers: characters,
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

    func testWordWrapChordStillReachesTheMenu() {
        XCTAssertFalse(passes(editor: true, "z", [.command, .option]))
        XCTAssertFalse(passes(editor: true, "z", [.command, .control]))
    }

    func testCommandPOpensTheFilePickerOnlyInTheEditor() {
        XCTAssertTrue(passes(editor: true, "p", .command))
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
