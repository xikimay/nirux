import XCTest
import AppKit
import WebKit
@testable import Nirux

/// Locks the menu bar's key equivalents: no chord bound twice, the standard
/// macOS items present, every chord the command palette can display bound in
/// the menu, and no Nirux action swallowed by an AppKit class.
final class MenuShortcutTests: XCTestCase {

    // MARK: - Helpers

    @MainActor
    private func menuItems() -> [NSMenuItem] {
        flatten(NiruxApp().makeMainMenu())
    }

    @MainActor
    private func flatten(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item in [item] + (item.submenu.map(flatten) ?? []) }
    }

    @MainActor
    private func chord(of item: NSMenuItem) -> KeyChord? {
        guard !item.keyEquivalent.isEmpty else { return nil }
        return KeyChord(item.keyEquivalent, item.keyEquivalentModifierMask)
    }

    @MainActor
    private func items(withAction action: Selector) -> [NSMenuItem] {
        menuItems().filter { $0.action == action }
    }

    // MARK: - Conflicts

    @MainActor
    func testNoTwoMenuItemsShareAChord() {
        var seen: [KeyChord: String] = [:]
        for item in menuItems() {
            guard let chord = chord(of: item) else { continue }
            if let other = seen[chord] {
                XCTFail("\(chord.display) is bound to both \"\(other)\" and \"\(item.title)\"")
            }
            seen[chord] = item.title
        }
    }

    @MainActor
    func testEveryPaletteChordIsBoundInTheMenu() {
        let bound = Set(menuItems().compactMap(chord(of:)))
        for shortcut in NiruxShortcuts.allCases {
            XCTAssertTrue(
                bound.contains(shortcut.chord),
                "\(shortcut.chord.display) (\(shortcut)) can show in the palette but no menu item binds it"
            )
        }
    }

    /// A nil-target item resolves through the responder chain; if the key
    /// window or a view answers the selector first, the item turns disabled
    /// and its chord silently dies (this happened to `toggleSidebar:`).
    @MainActor
    func testNiruxMenuActionsAreNotAnsweredByAppKitResponders() {
        let responders: [AnyClass] = [NSWindow.self, NSPanel.self, NSView.self, NSTextView.self, WKWebView.self, NSApplication.self]
        for item in menuItems() {
            guard item.target == nil, let action = item.action, NiruxApp.instancesRespond(to: action) else { continue }
            for responder in responders {
                XCTAssertFalse(
                    responder.instancesRespond(to: action),
                    "\(responder) answers \(action), so \"\(item.title)\" never reaches NiruxApp"
                )
            }
        }
    }

    // MARK: - Standard macOS items

    @MainActor
    func testUndoAndRedoTargetPanelTextFields() {
        let undo = items(withAction: #selector(PanelTextUndo.undo(_:)))
        let redo = items(withAction: #selector(PanelTextUndo.redo(_:)))
        XCTAssertEqual(undo.compactMap(chord(of:)), [KeyChord("z")])
        XCTAssertEqual(redo.compactMap(chord(of:)), [KeyChord("z", [.command, .shift])])
        XCTAssertTrue(undo.allSatisfy { $0.target === PanelTextUndo.shared })
        XCTAssertTrue(redo.allSatisfy { $0.target === PanelTextUndo.shared })
    }

    @MainActor
    func testWindowAndFullScreenItems() {
        let minimize = items(withAction: #selector(NSWindow.performMiniaturize(_:)))
        let fullScreen = items(withAction: #selector(NSWindow.toggleFullScreen(_:)))
        XCTAssertEqual(minimize.compactMap(chord(of:)), [KeyChord("m")])
        XCTAssertEqual(fullScreen.compactMap(chord(of:)), [KeyChord("f", [.command, .control])])
        XCTAssertEqual(items(withAction: #selector(NSWindow.performZoom(_:))).count, 1)
        // setupMenus hands this submenu to NSApp.windowsMenu.
        let windowMenu = NiruxApp().makeMainMenu().item(withTag: NiruxApp.windowMenuTag)?.submenu
        XCTAssertTrue(windowMenu?.items.contains { $0.action == #selector(NSWindow.performMiniaturize(_:)) } == true)
    }

    // MARK: - Nirux chords

    /// ⌘S belongs to Monaco's save; no menu item may take it back.
    @MainActor
    func testToggleSidebarUsesControlCommandSAndLeavesCommandSFree() {
        let sidebar = items(withAction: #selector(NiruxApp.toggleWorkspaceSidebar(_:)))
        XCTAssertEqual(sidebar.compactMap(chord(of:)), [KeyChord("s", [.command, .control])])
        XCTAssertFalse(menuItems().contains { chord(of: $0) == KeyChord("s") })
    }

    @MainActor
    func testCommandPaletteAnswersCommandPAndShiftCommandP() {
        let palette = items(withAction: #selector(NiruxApp.showCommandPalette(_:)))
        XCTAssertEqual(Set(palette.compactMap(chord(of:))), [KeyChord("p"), KeyChord("p", [.command, .shift])])
        XCTAssertEqual(palette.filter(\.isAlternate).compactMap(chord(of:)), [KeyChord("p", [.command, .shift])])
    }

    @MainActor
    func testTerminalFindUsesTheStandardFindChords() {
        let find = items(withAction: #selector(NiruxApp.showTerminalFind(_:)))
        let next = items(withAction: #selector(NiruxApp.findNextInTerminal(_:)))
        let previous = items(withAction: #selector(NiruxApp.findPreviousInTerminal(_:)))
        XCTAssertEqual(find.compactMap(chord(of:)), [KeyChord("f")])
        XCTAssertEqual(next.compactMap(chord(of:)), [KeyChord("g")])
        XCTAssertEqual(previous.compactMap(chord(of:)), [KeyChord("g", [.command, .shift])])
    }

    /// Cmd+Arrow moves the caret while text has the keyboard;
    /// Control+Cmd+Arrow navigates from there.
    @MainActor
    func testColumnAndWorkspaceNavigationAlsoAnswersControlCommandArrows() {
        let navigation: [(Selector, String)] = [
            (#selector(NiruxApp.focusLeft(_:)), "\u{F702}"),
            (#selector(NiruxApp.focusRight(_:)), "\u{F703}"),
            (#selector(NiruxApp.workspaceUp(_:)), "\u{F700}"),
            (#selector(NiruxApp.workspaceDown(_:)), "\u{F701}")
        ]
        for (action, arrow) in navigation {
            let matching = items(withAction: action)
            XCTAssertEqual(matching.compactMap(chord(of:)), [KeyChord(arrow), KeyChord(arrow, [.command, .control])], "\(action)")
            XCTAssertEqual(matching.map(\.isAlternate), [false, true], "\(action)")
        }
    }

    @MainActor
    func testRenameWorkspaceHasNoChord() {
        let rename = items(withAction: #selector(NiruxApp.renameWorkspace(_:)))
        XCTAssertEqual(rename.count, 1)
        XCTAssertNil(rename.first.flatMap(chord(of:)))
    }

    // MARK: - KeyChord

    func testChordDisplayUsesMacModifierOrder() {
        XCTAssertEqual(NiruxShortcuts.toggleSidebar.chord.display, "⌃⌘S")
        XCTAssertEqual(NiruxShortcuts.commandPaletteAlternate.chord.display, "⇧⌘P")
        XCTAssertEqual(NiruxShortcuts.webInspector.chord.display, "⌥⌘I")
        XCTAssertEqual(NiruxShortcuts.settings.chord.display, "⌘,")
        XCTAssertEqual(KeyChord("x", [.command, .shift, .option, .control]).display, "⌃⌥⇧⌘X")
    }

    /// AppKit reads an uppercase key equivalent as Shift+key.
    func testUppercaseKeyImpliesShift() {
        XCTAssertEqual(KeyChord("P"), KeyChord("p", [.command, .shift]))
        XCTAssertEqual(KeyChord("P").display, "⇧⌘P")
    }
}
