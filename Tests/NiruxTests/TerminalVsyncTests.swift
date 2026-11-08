import AppKit
import GhosttyTerminal
import XCTest
@testable import Nirux

/// Ghostty builds no surface with vsync while no display is active (a locked
/// Mac, its screen off), and the terminal's output is lost until it has one:
/// a column's terminal is built with vsync off then
/// (`ColumnState.matchTerminalVsyncToDisplays`). The bootstrap turns vsync
/// off in every test terminal; these tests clear its line, and fake the
/// displays' state.
@MainActor
final class TerminalVsyncTests: XCTestCase {
    func testATerminalBuiltWhileNoDisplayIsActiveGetsItsSurfaceWithoutVsync() {
        let saved = TerminalAppearance.appendedLines
        TerminalAppearance.appendedLines = []
        defer { TerminalAppearance.appendedLines = saved }
        let window = makeWindow()
        defer { window.close() }

        let column = makeColumn(in: window) { false }
        layOut(column)
        waitUntil { column.hasTerminalSurface }

        XCTAssertEqual(column.terminalHasVsync, false)
        let config = column.terminalView?.controller?.renderedConfig ?? ""
        XCTAssertTrue(config.hasSuffix(TerminalAppearance.vsyncOffLine + "\n"), config)
    }

    /// Decided as the surface is built, not as the column is made: a
    /// terminal sized only once a display is back keeps vsync.
    func testATerminalBuiltOnceADisplayIsBackKeepsVsync() {
        let saved = TerminalAppearance.appendedLines
        TerminalAppearance.appendedLines = []
        defer { TerminalAppearance.appendedLines = saved }
        let window = makeWindow()
        defer { window.close() }

        var displayActive = false
        let column = makeColumn(in: window) { displayActive }
        XCTAssertFalse(column.hasTerminalSurface, "no size, no surface")
        XCTAssertEqual(column.terminalHasVsync, false)

        displayActive = true
        layOut(column)
        XCTAssertEqual(column.terminalHasVsync, true)
        let config = column.terminalView?.controller?.renderedConfig ?? ""
        XCTAssertFalse(config.contains(TerminalAppearance.vsyncOffLine), config)
    }

    /// A built surface holds the screen and the scrollback: a display
    /// coming back never replaces it.
    func testATerminalKeepsItsSurfaceWhenADisplayComesBack() {
        let saved = TerminalAppearance.appendedLines
        TerminalAppearance.appendedLines = []
        defer { TerminalAppearance.appendedLines = saved }
        let window = makeWindow()
        defer { window.close() }

        var displayActive = false
        let column = makeColumn(in: window) { displayActive }
        layOut(column)
        waitUntil { column.hasTerminalSurface }
        let session = column.pty?.terminalSession
        session?.receive("printed while away\r\n")
        waitUntil { session.flatMap(TerminalScreenText.read)?.contains("printed while away") == true }
        let controller = column.terminalView?.controller

        displayActive = true
        layOut(column, height: 280)
        column.terminalView?.layoutSubtreeIfNeeded()

        XCTAssertTrue(column.terminalView?.controller === controller)
        XCTAssertEqual(column.terminalHasVsync, false)
        XCTAssertTrue(column.hasTerminalSurface)
        XCTAssertTrue(session.flatMap(TerminalScreenText.read)?.contains("printed while away") == true)
    }

    private func makeWindow() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        return window
    }

    /// A terminal column in `window`, not sized yet.
    private func makeColumn(in window: NSWindow, displays: @escaping () -> Bool) -> ColumnState {
        let column = ColumnState(cwd: "/tmp")
        column.isAnyDisplayActive = displays
        window.contentView?.addSubview(column.view)
        return column
    }

    private func layOut(_ column: ColumnState, width: CGFloat = 400, height: CGFloat = 300) {
        column.view.frame = NSRect(x: 0, y: 0, width: width, height: height)
        column.layoutWithHeader(width: width, height: height)
    }

    private func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(condition(), "timed out")
    }
}
