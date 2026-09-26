import XCTest
import AppKit
@testable import Nirux

/// Edit > Undo/Redo must reach a panel's text field but never the main
/// window, whose undo stack WebKit shares across every web column.
final class PanelTextUndoTests: XCTestCase {
    private final class UndoProbe: NSObject {
        var undone = false
        @objc func revert(_ sender: Any?) { undone = true }
    }

    @MainActor
    private var undoItem: NSMenuItem {
        NSMenuItem(title: "Undo", action: #selector(PanelTextUndo.undo(_:)), keyEquivalent: "z")
    }

    /// A window whose first responder is a text view with one undoable edit.
    @MainActor
    private func window(isPanel: Bool, probe: UndoProbe) -> NSWindow {
        _ = NSApplication.shared
        let frame = NSRect(x: 0, y: 0, width: 200, height: 100)
        let window = isPanel
            ? NSPanel(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: true)
            : NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        textView.allowsUndo = true
        window.contentView?.addSubview(textView)
        XCTAssertTrue(window.makeFirstResponder(textView))
        let manager = textView.undoManager
        manager?.groupsByEvent = false
        manager?.beginUndoGrouping()
        manager?.registerUndo(withTarget: probe, selector: #selector(UndoProbe.revert(_:)), object: nil)
        manager?.endUndoGrouping()
        return window
    }

    @MainActor
    func testUndoReachesTheTextViewOfAKeyPanel() {
        let probe = UndoProbe()
        let panel = window(isPanel: true, probe: probe)
        let undo = PanelTextUndo(keyWindow: { panel })

        XCTAssertTrue(undo.validateMenuItem(undoItem))
        undo.undo(nil)
        XCTAssertTrue(probe.undone)
    }

    @MainActor
    func testUndoIsInertInTheMainWindow() {
        let probe = UndoProbe()
        let mainWindow = window(isPanel: false, probe: probe)
        let undo = PanelTextUndo(keyWindow: { mainWindow })

        XCTAssertTrue(mainWindow.undoManager?.canUndo == true)
        XCTAssertFalse(undo.validateMenuItem(undoItem))
        undo.undo(nil)
        XCTAssertFalse(probe.undone)
    }

    @MainActor
    func testUndoIsInertWhenThePanelHasNoTextFocus() {
        let probe = UndoProbe()
        let panel = window(isPanel: true, probe: probe)
        panel.makeFirstResponder(nil)
        let undo = PanelTextUndo(keyWindow: { panel })

        XCTAssertFalse(undo.validateMenuItem(undoItem))
        undo.undo(nil)
        XCTAssertFalse(probe.undone)
    }
}
