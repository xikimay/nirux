import AppKit
import CoreVideo
import GhosttyTerminal
import XCTest
@testable import Nirux

/// Ghostty builds no surface with vsync while no display is active (a locked
/// Mac, its screen off), and the terminal's output is lost until it has one:
/// a column's terminal is built without vsync then
/// (`ColumnState.matchTerminalVsyncToDisplays`). The bootstrap turns vsync
/// off in every test terminal; these tests clear its line, and fake the
/// displays' state.
@MainActor
final class TerminalVsyncTests: XCTestCase {
    /// A display coming back never replaces the surface: its screen and
    /// scrollback would go.
    func testATerminalBuiltWhileNoDisplayIsActiveGetsAndKeepsItsSurfaceWithoutVsync() {
        let saved = TerminalAppearance.appendedLines
        TerminalAppearance.appendedLines = []
        defer { TerminalAppearance.appendedLines = saved }
        let window = makeWindow()
        defer { window.close() }

        var displayActive = false
        let column = makeColumn(in: window) { displayActive }
        layOut(column)
        waitUntil { column.terminalSurfaceWasBuilt }
        let controller = column.terminalView?.controller
        let config = controller?.renderedConfig ?? ""
        XCTAssertTrue(config.hasSuffix(TerminalAppearance.vsyncOffLine + "\n"), config)
        let session = column.pty?.terminalSession
        session?.receive("printed while away\r\n")
        waitUntil { session.flatMap(TerminalScreenText.read)?.contains("printed while away") == true }

        displayActive = true
        layOut(column, height: 280)
        column.terminalView?.layoutSubtreeIfNeeded()

        XCTAssertTrue(column.terminalView?.controller === controller)
        XCTAssertTrue(session.flatMap(TerminalScreenText.read)?.contains("printed while away") == true)
    }

    /// Decided as the surface is built, not as the column is made: a
    /// terminal sized once a display is back gets vsync.
    func testATerminalBuiltOnceADisplayIsBackGetsVsync() throws {
        try XCTSkipUnless(Displays.anyActive(), "a surface with vsync needs an active display")
        let saved = TerminalAppearance.appendedLines
        TerminalAppearance.appendedLines = []
        defer { TerminalAppearance.appendedLines = saved }
        let window = makeWindow()
        defer { window.close() }

        var displayActive = false
        let column = makeColumn(in: window) { displayActive }
        XCTAssertEqual(column.terminalHasVsync, false)

        displayActive = true
        layOut(column)
        waitUntil { column.terminalSurfaceWasBuilt }
        XCTAssertEqual(column.terminalHasVsync, true)
        let config = column.terminalView?.controller?.renderedConfig ?? ""
        XCTAssertFalse(config.contains(TerminalAppearance.vsyncOffLine), config)
    }

    /// Ghostty creates vsync's display link from the active displays: a
    /// surface with vsync can be built exactly when `Displays` says one is
    /// active, display asleep or not.
    func testDisplaysAgreeWithGhosttysDisplayLink() {
        var link: CVDisplayLink?
        let canLink = CVDisplayLinkCreateWithActiveCGDisplays(&link) == kCVReturnSuccess
        XCTAssertEqual(Displays.anyActive(), canLink)
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

    /// A terminal column in `window`, not sized yet. No shell runs in it:
    /// its output would land among the test's.
    private func makeColumn(in window: NSWindow, displays: @escaping () -> Bool) -> ColumnState {
        let launch = DeferredAgentLaunch(agent: .claude(resume: .session("s1"), mode: .default), title: nil, lastStatus: nil)
        let column = ColumnState(cwd: "/tmp", deferredAgent: launch)
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
