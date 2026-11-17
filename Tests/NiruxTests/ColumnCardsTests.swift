import AppKit
import XCTest
@testable import Nirux

/// Columns rest on the window as cards (depth study P1): air between and
/// around them, rounded corners, a shadow under each, and the camera keeps
/// the focused card's air in view.
@MainActor
final class ColumnCardsTests: XCTestCase {
    private let inset = WorkspaceState.columnInset
    private let gap = WorkspaceState.columnGap

    private func workspace(columns: Int, width: CGFloat = 0.5) -> WorkspaceState {
        let workspace = WorkspaceState(title: "cards", cwd: "/tmp")
        for _ in 1..<columns { workspace.addColumn() }
        for column in workspace.columns { column.widthFraction = width }
        workspace.focusedIndex = 0
        return workspace
    }

    private func strip(of workspace: WorkspaceState) throws -> NSView {
        try XCTUnwrap(workspace.columns.first?.view.superview)
    }

    func testColumnsRestAsCardsWithAirBetweenAndAround() throws {
        let workspace = workspace(columns: 2)
        workspace.layoutAndScroll(viewportWidth: 1000, height: 600, animated: false)

        let width = floor(0.5 * (1000 - inset * 2 - gap))
        XCTAssertEqual(workspace.columns.map(\.view.frame), [
            NSRect(x: inset, y: inset, width: width, height: 600 - inset * 2),
            NSRect(x: inset + width + gap, y: inset, width: width, height: 600 - inset * 2)
        ])
        for column in workspace.columns {
            let layer = try XCTUnwrap(column.view.layer)
            XCTAssertEqual(layer.cornerRadius, Theme.Radius.card)
            XCTAssertEqual(layer.cornerCurve, .continuous)
            XCTAssertTrue(layer.masksToBounds, "its content clipped to its corners")
        }
    }

    func testFitAllSharesWhatTheAirLeaves() {
        let workspace = workspace(columns: 3)
        workspace.layoutAndScroll(viewportWidth: 1000, height: 600, animated: false, fitAll: true)
        let width = floor((1000 - inset * 2 - gap * 2) / 3)
        XCTAssertEqual(workspace.columns.map(\.view.frame.width), [width, width, width])
        XCTAssertEqual(workspace.columns.last?.view.frame.minX, inset + (width + gap) * 2)
    }

    /// A hidden space's terminal is sized as it will show (`sizeTerminalOffScreen`).
    func testTheSizeGivenOffScreenIsTheSizeLaidOut() throws {
        let workspace = workspace(columns: 3, width: 0.4)
        workspace.layoutAndScroll(viewportWidth: 1000, height: 600, animated: false)
        for column in workspace.columns {
            XCTAssertEqual(workspace.size(of: column, viewportWidth: 1000, height: 600), column.view.frame.size)
        }
    }

    /// The camera brings the focused card in with its air, at either end.
    func testTheCameraKeepsTheFocusedCardsAir() throws {
        let workspace = workspace(columns: 3)
        let strip = try strip(of: workspace)

        workspace.focusedIndex = 2
        workspace.layoutAndScroll(viewportWidth: 1000, height: 600, animated: false)
        let last = try XCTUnwrap(workspace.columns.last).view.frame
        XCTAssertEqual(last.maxX + inset + strip.frame.minX, 1000, "the right edge's air in view")

        workspace.focusedIndex = 0
        workspace.layoutAndScroll(viewportWidth: 1000, height: 600, animated: false)
        XCTAssertEqual(strip.frame.minX, 0)
        XCTAssertEqual(workspace.columns[0].view.frame.minX, inset, "the left edge's air in view")
    }

    /// Each column's shadow follows it, under every column of the strip, so
    /// that it falls only on the air; it goes with its column.
    func testEachColumnsShadowLiesUnderEveryColumn() throws {
        let workspace = workspace(columns: 2)
        workspace.layoutAndScroll(viewportWidth: 1000, height: 600, animated: false)
        // A column added later still finds every shadow under it.
        workspace.addColumn()
        workspace.layoutAndScroll(viewportWidth: 1000, height: 600, animated: false)

        let strip = try strip(of: workspace)
        let shadows = try workspace.columns.map { try XCTUnwrap($0.shadow, "\($0.view.frame)") }
        XCTAssertEqual(shadows.map(\.frame), workspace.columns.map(\.view.frame))
        let lowestColumn = try XCTUnwrap(workspace.columns.compactMap { strip.subviews.firstIndex(of: $0.view) }.min())
        for shadow in shadows {
            XCTAssertTrue(shadow.superview === strip)
            XCTAssertLessThan(try XCTUnwrap(strip.subviews.firstIndex(of: shadow)), lowestColumn)
        }

        let closed = try XCTUnwrap(workspace.columns.last)
        workspace.closeColumn(at: workspace.columns.count - 1)
        XCTAssertNil(closed.shadow?.superview, "its shadow goes with it")
    }

    func testTheShadowFollowsTheCardsShape() throws {
        let shadow = ColumnShadowView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        XCTAssertEqual(shadow.shadowOpacity, Theme.Elevation.Level.column.opacity)
        XCTAssertEqual(shadow.shadowPath?.boundingBox, NSRect(x: 0, y: 0, width: 300, height: 200))
        shadow.frame.size = NSSize(width: 120, height: 90)
        XCTAssertEqual(shadow.shadowPath?.boundingBox, NSRect(x: 0, y: 0, width: 120, height: 90))
        XCTAssertNil(shadow.hitTest(NSPoint(x: 10, y: 10)), "decoration: clicks go to what is under it")
    }

    /// A translucent terminal's frost blends behind the window, which
    /// ignores the column's rounded clip: its mask holds the corners.
    func testATranslucentTerminalsFrostKeepsTheCardsCorners() throws {
        let column = ColumnState(cwd: "/tmp")
        column.view.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        column.surfaceChanged(attached: true)
        column.showTerminalOpacity(0.8, onScreen: true)
        let frost = try XCTUnwrap(column.terminalFrost)
        let mask = try XCTUnwrap(frost.maskImage)
        XCTAssertEqual(mask.capInsets.top, GlassView.maskCorner(radius: Theme.Radius.card, in: column.view.bounds.size))
    }

    /// The shell draws each card's edge: the focus in the accent, a
    /// hairline on the others.
    func testTheFocusedCardHasTheAccentEdgeTheOthersAHairline() throws {
        try withShell { shell in
            let workspace = try XCTUnwrap(shell.activeWorkspace)
            workspace.addColumn()
            workspace.focusedIndex = 1
            shell.relayout(animated: false)
            let layers = try workspace.columns.map { try XCTUnwrap($0.view.layer) }
            XCTAssertEqual(layers.map(\.borderWidth), [1, EdgeGlowView.focusRingWidth])
            XCTAssertEqual(layers[0].borderColor, Theme.Color.line.cgColor)
            XCTAssertEqual(layers[1].borderColor, Theme.Color.accent.withAlphaComponent(0.7).cgColor)
        }
    }

    private func withShell(_ body: (NiruxShellView) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nirux-cards-\(UUID().uuidString)").path
        let stateDirectory = root + "/state"
        try FileManager.default.createDirectory(atPath: stateDirectory, withIntermediateDirectories: true)
        let previousStateDirectory = ProcessInfo.processInfo.environment["NIRUX_STATE_DIR"]
        setenv("NIRUX_STATE_DIR", stateDirectory, 1)
        defer {
            if let previousStateDirectory {
                setenv("NIRUX_STATE_DIR", previousStateDirectory, 1)
            } else {
                unsetenv("NIRUX_STATE_DIR")
            }
            try? FileManager.default.removeItem(atPath: root)
        }

        _ = NSApplication.shared
        try autoreleasepool {
            let shell = NiruxShellView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
            shell.stopHeartbeat()
            shell.sideEffects.windowShows = { _ in true }
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = shell
            defer { window.close() }
            try body(shell)
        }
    }
}
