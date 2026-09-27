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

    /// NSAlert text prompts (New File, Rename, mission replies) run modally:
    /// Undo must stay enabled there and see the alert window as a panel.
    @MainActor
    func testUndoWorksInModalAlertPanels() {
        _ = NSApplication.shared
        XCTAssertTrue(PanelTextUndo.shared.worksWhenModal)
        XCTAssertTrue(NSAlert().window is NSPanel)
    }

    // MARK: - Workspace Context panel

    @MainActor
    private func contextConfiguration(purpose: String) -> WorkspaceContextPanelConfiguration {
        WorkspaceContextPanelConfiguration(
            title: "Workspace", cwd: "/tmp", purpose: purpose, phaseOverride: nil, effectivePhase: .active,
            lastSummary: "", lastSummaryIsManual: false, lastActivityAt: nil, nextStep: nil, blocker: nil,
            gitBranch: nil, diffStats: nil, prInfo: nil, agentStatuses: []
        )
    }

    /// The panel is reused across workspaces; undo recorded for workspace A
    /// must not replay onto B's text (it threw NSRangeException or silently
    /// corrupted B), and each editor keeps its own stack.
    @MainActor
    func testContextPanelDropsUndoFromThePreviousWorkspace() {
        _ = NSApplication.shared
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 700), styleMask: [.titled], backing: .buffered, defer: true)
        let contextPanel = WorkspaceContextPanel()
        contextPanel.show(relativeTo: host, configuration: contextConfiguration(purpose: "Workspace A purpose"))
        defer { contextPanel.purposeEditor?.window?.orderOut(nil) }

        guard let purposeUndo = contextPanel.purposeEditor?.undoManager,
              let summaryUndo = contextPanel.summaryEditor?.undoManager
        else { return XCTFail("context editors have no undo manager") }
        XCTAssertFalse(purposeUndo === summaryUndo)

        let probe = UndoProbe()
        purposeUndo.groupsByEvent = false
        purposeUndo.beginUndoGrouping()
        purposeUndo.registerUndo(withTarget: probe, selector: #selector(UndoProbe.revert(_:)), object: nil)
        purposeUndo.endUndoGrouping()
        XCTAssertTrue(purposeUndo.canUndo)
        XCTAssertFalse(summaryUndo.canUndo)

        contextPanel.show(relativeTo: host, configuration: contextConfiguration(purpose: "B"))
        XCTAssertFalse(purposeUndo.canUndo)
    }
}
