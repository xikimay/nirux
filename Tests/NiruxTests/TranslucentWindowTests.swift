import AppKit
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

    /// Reduce transparency or Increase contrast: opaque, whatever was picked.
    func testMacOSAccessibilityKeepsTheWindowOpaque() {
        let (window, content, shell) = mainWindow(asks: { _ in .opaque })
        defer { window.close() }
        shell.interfaceTransparency = .clear
        XCTAssertTrue(window.isOpaque)
        XCTAssertFalse(content.isTranslucent)
        XCTAssertEqual(shell.layer?.backgroundColor, Theme.Color.canvas.cgColor)
    }

    /// Every kind of column is opaque under its content: a terminal before
    /// its first frame, a page still loading, never show the desktop.
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
