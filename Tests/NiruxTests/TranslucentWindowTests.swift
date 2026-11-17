import AppKit
import GhosttyTerminal
import XCTest
@testable import Nirux

/// The translucent window (docs/design/glass-interface.md, 4.2): above
/// Opaque the window lets the desktop through its frost, the canvas and the
/// sidebar let it show, the chrome draws the level, and the columns stay
/// opaque. CI's runners reduce transparency, so the tests say what macOS
/// asks. Windows are laid out, never shown.
@MainActor
final class TranslucentWindowTests: XCTestCase {
    private func mainWindow(asks: @escaping @MainActor (InterfaceTransparency) -> InterfaceTransparency = { $0 })
        -> (NSWindow, MainWindowContent, NiruxShellView) {
        _ = NSApplication.shared
        let window = NiruxApp.makeMainWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800))
        window.isReleasedWhenClosed = false
        let shell = NiruxShellView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        shell.stopHeartbeat()
        shell.sideEffects.drawnTransparency = asks
        let content = MainWindowContent(shell: shell)
        window.contentView = content
        shell.installCommandBar(in: window)
        shell.interfaceTransparency = .opaque
        shell.applyInterfaceTransparency()
        window.contentView?.superview?.layoutSubtreeIfNeeded()
        return (window, content, shell)
    }

    func testTheWindowLetsTheDesktopThroughAboveOpaque() throws {
        let (window, content, shell) = mainWindow()
        defer { window.close() }
        XCTAssertTrue(window.isOpaque, "Opaque: the window as before")
        XCTAssertFalse(content.isTranslucent)
        XCTAssertEqual(shell.layer?.backgroundColor, Theme.Color.canvas.cgColor)
        XCTAssertLessThanOrEqual(shell.frame.maxY, window.contentLayoutRect.maxY, "the shell below the toolbar")
        XCTAssertEqual(shell.frame.height, window.contentLayoutRect.height)

        shell.interfaceTransparency = .glass
        XCTAssertFalse(window.isOpaque)
        XCTAssertEqual(window.backgroundColor, .clear)
        XCTAssertTrue(content.isTranslucent)
        XCTAssertEqual(shell.layer?.backgroundColor?.alpha, 0, "the canvas lets the frost show")
        XCTAssertEqual(shell.sidebar.layer?.backgroundColor?.alpha, 0, "and the sidebar")
        XCTAssertEqual(shell.sidebar.iconRail.level, .glass, "the chrome draws the level")
        XCTAssertEqual(shell.commandBarToolbar?.bar.level, .glass)
        let inbox = RequestInboxView(level: .glass)
        shell.requestsState.inbox = inbox

        shell.interfaceTransparency = .opaque
        XCTAssertEqual(inbox.level, .opaque, "the inbox, kept once made, follows")
        XCTAssertTrue(window.isOpaque)
        XCTAssertEqual(shell.sidebar.layer?.backgroundColor, Theme.Color.base.cgColor)
    }

    /// Reduce transparency or Increase contrast: opaque, whatever was picked,
    /// the window and its chrome alike (one resolver).
    func testMacOSAccessibilityKeepsTheWindowOpaque() throws {
        let (window, content, shell) = mainWindow(asks: { _ in .opaque })
        defer { window.close() }
        shell.interfaceTransparency = .clear
        XCTAssertTrue(window.isOpaque)
        XCTAssertFalse(content.isTranslucent)
        XCTAssertEqual(shell.layer?.backgroundColor, Theme.Color.canvas.cgColor)
        let bar = try XCTUnwrap(shell.commandBarToolbar?.bar)
        XCTAssertEqual(bar.resolveLevel(.clear), .opaque, "the bar draws what the window does")
        XCTAssertEqual(shell.sidebar.iconRail.resolveLevel(.clear), .opaque, "and the rail")
    }

    // MARK: - Terminals (4.3)

    /// 60 to 100 %, by fives; below 100 % the terminal's override sets the
    /// background's opacity and a minimum contrast, unless the user's
    /// Ghostty config sets its own; at 100 %, none.
    func testTheTerminalsOpacityAndItsOverride() {
        XCTAssertEqual(TerminalOpacity.clamped(0.3), 0.6)
        XCTAssertEqual(TerminalOpacity.clamped(0.62), 0.6, "an exact step, saved as such")
        XCTAssertEqual(TerminalOpacity.clamped(0.82), 0.8)
        XCTAssertEqual(TerminalOpacity.clamped(1.4), 1)
        XCTAssertEqual(TerminalOpacity.configuration(1, userSetsContrast: false), TerminalConfiguration())
        let translucent = TerminalConfiguration().backgroundOpacity(0.8).custom("background-opacity-cells", "true")
        XCTAssertEqual(TerminalOpacity.configuration(0.8, userSetsContrast: false), translucent.minimumContrast(3))
        XCTAssertEqual(TerminalOpacity.configuration(0.8, userSetsContrast: true), translucent, "a TUI's own cells too")
        XCTAssertTrue(TerminalOpacity.setsContrast("font-size = 14\nminimum-contrast = 1.1\n"))
        XCTAssertFalse(TerminalOpacity.setsContrast(TerminalConfigBuilder.render([])))
        XCTAssertTrue(TerminalOpacity.setsContrast(.generated("minimum-contrast = 1.1")), "the terminal's own config")
        XCTAssertFalse(TerminalOpacity.setsContrast(.none))
    }

    /// "80%" is 80% over the desktop's blur: the column's own frost under
    /// the terminal, nothing of the window between them (no canvas fill, no
    /// window tint), at any interface level; only once the terminal draws,
    /// and on screen. At 100% the column is opaque again; a column without a
    /// terminal never changes.
    func testATranslucentTerminalLiesOnTheDesktopsBlurAlone() throws {
        _ = NSApplication.shared
        let column = ColumnState(cwd: NSTemporaryDirectory())
        column.showTerminalOpacity(0.8, onScreen: true)
        XCTAssertNil(column.terminalFrost, "before its first frame, the opaque fill")
        XCTAssertEqual(column.view.layer?.backgroundColor?.alpha, 1)
        column.surfaceChanged(attached: true)
        let frost = try XCTUnwrap(column.terminalFrost)
        XCTAssertIdentical(column.view.subviews.first, frost, "under everything in the column")
        XCTAssertEqual(frost.blendingMode, .behindWindow)
        let between = column.view.layer?.backgroundColor?.alpha ?? 0
        XCTAssertEqual(1 - (1 - between) * (1 - 0.8), 0.8, accuracy: 0.001, "composed at the terminal's opacity")
        XCTAssertEqual(column.terminalView?.controller?.terminalConfiguration, TerminalOpacity.configuration(0.8, userSetsContrast: false))
        XCTAssertNil(column.terminalView?.controller?.lastConfigurationIssue, "libghostty takes every key")

        column.showTerminalOpacity(0.8, onScreen: false)
        XCTAssertNil(column.terminalFrost, "off screen, no blur to compute")
        column.showTerminalOpacity(1, onScreen: true)
        XCTAssertNil(column.terminalFrost)
        XCTAssertEqual(column.view.layer?.backgroundColor?.alpha, 1)
        XCTAssertEqual(column.terminalView?.controller?.terminalConfiguration, TerminalConfiguration())

        // A terminal whose own Ghostty config sets a minimum contrast keeps it.
        let own = ColumnState(cwd: NSTemporaryDirectory())
        own.terminalView?.controller = TerminalController(
            configSource: .generated(TerminalConfigBuilder.render([]) + "minimum-contrast = 1.1\n"), theme: TerminalTheme()
        )
        own.showTerminalOpacity(0.8, onScreen: true)
        XCTAssertEqual(own.terminalView?.controller?.terminalConfiguration, TerminalOpacity.configuration(0.8, userSetsContrast: true))

        let page = ColumnState(url: "about:blank")
        page.showTerminalOpacity(0.6, onScreen: true)
        XCTAssertNil(page.terminalFrost)
        XCTAssertEqual(page.view.layer?.backgroundColor?.alpha, 1)
    }

    /// The shell gives every terminal the opacity, one opened later too; the
    /// window lets the desktop through at interface Opaque; Reduce
    /// transparency keeps the terminals opaque.
    func testTheShellsTerminalsFollowTheOpacity() throws {
        let (window, _, shell) = mainWindow()
        defer { window.close() }
        let first = try XCTUnwrap(shell.activeWorkspace?.columns.first)
        shell.terminalOpacity = 0.8
        XCTAssertEqual(first.terminalOpacity, 0.8)
        XCTAssertFalse(window.isOpaque, "at interface Opaque too")
        let content = try XCTUnwrap(window.contentView as? MainWindowContent)
        XCTAssertEqual(content.backdropOpacity, 1, "the title bar's strip keeps the canvas")
        shell.addColumn()
        XCTAssertEqual(shell.activeWorkspace?.columns.last?.terminalOpacity, 0.8, "a column opened since")
        shell.sideEffects.drawnTransparency = { _ in .opaque }
        shell.applyInterfaceTransparency()
        XCTAssertEqual(first.terminalOpacity, 1, "macOS asks for opaque")
        XCTAssertTrue(window.isOpaque)
    }

    /// Every kind of column is opaque under its content: a terminal before
    /// its first frame, a page still loading, never show the desktop (a
    /// terminal below 100 % aside).
    func testEveryColumnIsOpaque() {
        _ = NSApplication.shared
        let shell = NiruxShellView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        shell.stopHeartbeat()
        let columns = [
            ColumnState(cwd: NSTemporaryDirectory()),
            ColumnState(url: "about:blank"),
            ColumnState(editorWorkspaceCwd: NSTemporaryDirectory()),
            ColumnState(projectBoard: shell.makeProjectBoard(projectID: WorkspaceProfile.defaultID, offersSettings: false))
        ]
        for column in columns {
            XCTAssertEqual(column.view.layer?.backgroundColor?.alpha, 1, "\(type(of: column.view))")
        }
    }
}
