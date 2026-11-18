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
        // The viewport a resize drag lays the columns out in again.
        workspace.containerView.frame = NSRect(x: 0, y: 0, width: 1000, height: 600)
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

        let width = floor(0.5 * (1000 - inset * 2 + gap) - gap)
        XCTAssertEqual(workspace.columns.map(\.view.frame), [
            NSRect(x: inset, y: inset, width: width, height: 600 - inset * 2),
            NSRect(x: inset + width + gap, y: inset, width: width, height: 600 - inset * 2)
        ])
        for column in workspace.columns {
            XCTAssertEqual(try XCTUnwrap(column.view.layer).cornerRadius, Theme.Radius.column)
        }
        // A circular corner cuts r·(1 − 1/√2) into the diagonal: within the
        // terminal's padding, it cuts no cell.
        XCTAssertLessThanOrEqual(Theme.Radius.column * (1 - 1 / 2.0.squareRoot()), CGFloat(TerminalConfigBuilder.padding))
    }

    /// A terminal's header, its terminal and the overlays over it round the
    /// card's corners on their own layers: nothing of theirs lies in the
    /// corners its column clips.
    func testATerminalsLayersRoundTheCardsCorners() throws {
        let workspace = workspace(columns: 1)
        let column = try XCTUnwrap(workspace.columns.first)
        workspace.layoutAndScroll(viewportWidth: 1000, height: 600, animated: false)
        // The corners at the top or the bottom of the card, in a layer's
        // own y.
        func corners(_ layer: CALayer, top: Bool) -> CACornerMask {
            top == layer.contentsAreFlipped()
                ? [.layerMinXMinYCorner, .layerMaxXMinYCorner] : [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        }

        let terminal = try XCTUnwrap(column.terminalView?.layer)
        XCTAssertTrue(terminal.masksToBounds)
        XCTAssertEqual(terminal.cornerRadius, Theme.Radius.column)
        XCTAssertEqual(terminal.maskedCorners, corners(terminal, top: false))
        let header = try XCTUnwrap(column.header?.layer)
        XCTAssertEqual(header.cornerRadius, Theme.Radius.column)
        XCTAssertEqual(header.maskedCorners, corners(header, top: true))

        let overlay = ShellExitedOverlay()
        column.view.addSubview(overlay)
        overlay.frame = try XCTUnwrap(column.terminalView).frame
        overlay.layoutSubtreeIfNeeded()
        let overlayLayer = try XCTUnwrap(overlay.layer)
        XCTAssertEqual(overlayLayer.cornerRadius, Theme.Radius.column)
        XCTAssertEqual(overlayLayer.maskedCorners, corners(overlayLayer, top: false))
    }

    /// Two halves fill the viewport exactly, however many columns follow:
    /// the next card starts past its edge.
    func testTwoHalvesFillTheViewportWhateverTheCount() throws {
        for count in [2, 3, 6] {
            let workspace = workspace(columns: count)
            workspace.layoutAndScroll(viewportWidth: 1000, height: 600, animated: false)
            let frames = workspace.columns.map(\.view.frame)
            XCTAssertEqual(frames[1].maxX + inset, 1000, "\(count) columns")
            if count > 2 { XCTAssertGreaterThanOrEqual(frames[2].minX, 1000, "\(count) columns") }
        }
    }

    /// A resize handle's drag moves the column's edge with the pointer.
    func testAHandlesDragFollowsThePointer() throws {
        let workspace = workspace(columns: 3)
        workspace.layoutAndScroll(viewportWidth: 1000, height: 600, animated: false)
        let handle = try XCTUnwrap(strip(of: workspace).subviews.compactMap { $0 as? ColumnResizeHandle }.first)
        let before = workspace.columns[0].view.frame.width
        handle.onDrag?(0.5 + 300 / handle.referenceWidth)
        XCTAssertEqual(workspace.columns[0].view.frame.width - before, 300, accuracy: 1)
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

    /// The shadow stays within the air: the strip clips at the viewport's
    /// edge.
    func testTheShadowFollowsTheCardsShape() throws {
        XCTAssertLessThanOrEqual(Theme.Elevation.Level.column.reach, inset)
        let shadow = ColumnShadowView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        XCTAssertEqual(shadow.shadowOpacity, Theme.Elevation.Level.column.opacity)
        XCTAssertEqual(shadow.shadowPath?.boundingBox, NSRect(x: 0, y: 0, width: 300, height: 200))
        shadow.frame.size = NSSize(width: 120, height: 90)
        XCTAssertEqual(shadow.shadowPath?.boundingBox, NSRect(x: 0, y: 0, width: 120, height: 90))
        XCTAssertNil(shadow.hitTest(NSPoint(x: 10, y: 10)), "decoration: clicks go to what is under it")
    }

    /// A card that lets the desktop show through takes the shape out of its
    /// shadow, which would darken it; an opaque one hides it, unmasked.
    func testATranslucentCardsShadowFallsOnlyAroundIt() throws {
        let workspace = workspace(columns: 1)
        let column = try XCTUnwrap(workspace.columns.first)
        // Translucent before its first layout: its shadow is made cut out.
        column.surfaceChanged(attached: true)
        column.showTerminalOpacity(0.8, onScreen: true)
        workspace.layoutAndScroll(viewportWidth: 1000, height: 600, animated: false)
        let shadow = try XCTUnwrap(column.shadow)
        let cutOut = try XCTUnwrap(shadow.cutOutPath)
        let card = shadow.bounds
        XCTAssertFalse(cutOut.contains(CGPoint(x: card.midX, y: card.midY), using: .evenOdd), "nothing under the card")
        XCTAssertFalse(cutOut.contains(CGPoint(x: card.minX + 1, y: card.minY + Theme.Radius.column), using: .evenOdd))
        XCTAssertTrue(cutOut.contains(CGPoint(x: card.midX, y: card.minY - 2), using: .evenOdd), "the air below")
        XCTAssertTrue(cutOut.contains(CGPoint(x: card.minX + 1, y: card.minY + 1), using: .evenOdd), "the air in the corner")

        column.showTerminalOpacity(1, onScreen: true)
        XCTAssertNil(shadow.cutOutPath, "opaque again: unmasked")
        column.showTerminalOpacity(0.8, onScreen: true)
        XCTAssertNotNil(shadow.cutOutPath)
    }

    /// A translucent terminal's frost blends behind the window, which
    /// ignores the column's rounded clip: its mask holds the corners.
    func testATranslucentTerminalsFrostKeepsTheCardsCorners() throws {
        // Made before the column has a size: the corners hold once it has one.
        let column = ColumnState(cwd: "/tmp")
        column.surfaceChanged(attached: true)
        column.showTerminalOpacity(0.8, onScreen: true)
        column.view.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let frost = try XCTUnwrap(column.terminalFrost)
        let mask = try XCTUnwrap(frost.maskImage)
        XCTAssertEqual(mask.capInsets.top, GlassView.maskCorner(radius: Theme.Radius.column, in: column.view.bounds.size))
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

            // Grabbing the first column's edge focuses it as a click would:
            // the edge and the keyboard go together, before any drag.
            let strip = try strip(of: workspace)
            let handle = try XCTUnwrap(strip.subviews.compactMap { $0 as? ColumnResizeHandle }.first)
            _ = handle.onDragStart?()
            XCTAssertEqual(workspace.focusedIndex, 0)
            XCTAssertEqual(layers.map(\.borderWidth), [EdgeGlowView.focusRingWidth, 1])
            XCTAssertTrue(shell.window?.firstResponder === workspace.columns[0].terminalView, "the keyboard")
            handle.onDrag?(0.45)
            XCTAssertEqual(layers.map(\.borderWidth), [EdgeGlowView.focusRingWidth, 1])
        }
    }

    /// A card's shadow hides while the card comes or goes: the fading card
    /// would show it. The layout decides, even one that comes late.
    func testAShadowHidesWhileItsCardComesOrGoes() throws {
        try withShell { shell in
            let workspace = try XCTUnwrap(shell.activeWorkspace)
            // No room to lay the new card out as it comes: its shadow is
            // made by a later layout, mid-fade.
            shell.setFrameSize(.zero)
            shell.addColumn()
            let added = try XCTUnwrap(workspace.columns[safe: workspace.focusedIndex])
            XCTAssertEqual(added.shadow?.isHidden, true, "the new card fades in")
            shell.setFrameSize(NSSize(width: 1200, height: 800))
            shell.relayout(animated: false)
            XCTAssertEqual(added.shadow?.isHidden, true, "the new card fades in")
            added.isArriving = false
            workspace.showShadows()
            XCTAssertEqual(added.shadow?.isHidden, false, "in")

            shell.closeActiveColumn()
            XCTAssertTrue(added.isClosing)
            XCTAssertEqual(added.shadow?.isHidden, true, "the closing card fades out")
            shell.relayout(animated: false)
            XCTAssertEqual(added.shadow?.isHidden, true, "still going")
        }
    }

    /// The focused card lies a level higher, its shadow still within the
    /// air.
    func testTheFocusedLevelIsHigherWithinTheAir() {
        let higher = Theme.Elevation.Level.focusedColumn, resting = Theme.Elevation.Level.column
        XCTAssertLessThanOrEqual(higher.reach, inset)
        XCTAssertGreaterThan(higher.opacity, resting.opacity)
        XCTAssertGreaterThan(higher.drop, resting.drop)
        XCTAssertGreaterThan(higher.radius, resting.radius, "softer as it rises")
    }

    /// The lift follows the focus: it passes over a moment while the
    /// interface may move, at once when it may not.
    func testTheLiftFollowsTheFocusAndStillnessWins() throws {
        try withShell { shell in
            shell.sideEffects.reducesMotion = { false }
            shell.agentLights.isDisplayAsleep = false
            shell.animatesInterface = true
            let workspace = try XCTUnwrap(shell.activeWorkspace)
            workspace.addColumn()
            workspace.focusedIndex = 1
            shell.relayout(animated: false)
            let shadows = try workspace.columns.map { try XCTUnwrap($0.shadow) }

            workspace.focusedIndex = 0
            shell.relayout(animated: false)
            XCTAssertEqual(shadows.map(\.level), [.focusedColumn, .column])
            XCTAssertEqual(shadows.map(\.isLifting), [true, true], "one rises, the other settles")
            XCTAssertEqual(shadows[0].liftStartOpacity, Theme.Elevation.Level.column.opacity)

            // Back at once: from where it shows, mid-way.
            shadows[0].shownShadow = { _ in (0.4, 2.5, CGSize(width: 0, height: 1.5)) }
            workspace.focusedIndex = 1
            shell.relayout(animated: false)
            XCTAssertEqual(shadows[0].liftStartOpacity, 0.4)

            // Stillness cuts a lift short, and the next change is at once.
            shell.sideEffects.reducesMotion = { true }
            shell.applyAgentLights()
            XCTAssertEqual(shadows.map(\.isLifting), [false, false], "Reduce motion stops the lift")
            workspace.focusedIndex = 0
            shell.relayout(animated: false)
            XCTAssertEqual(shadows.map(\.level), [.focusedColumn, .column])
            XCTAssertEqual(shadows.map(\.isLifting), [false, false], "Reduce motion: at once")
        }
    }

    /// At once means at once: a lift on its way stops, even one heading to
    /// the level asked.
    func testAShadowShownAtOnceStopsALiftOnItsWay() {
        let shadow = ColumnShadowView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        shadow.show(.focusedColumn, animated: true)
        XCTAssertTrue(shadow.isLifting)
        shadow.show(.focusedColumn, animated: false)
        XCTAssertFalse(shadow.isLifting)
    }

    /// A translucent card's cut-out spans either level's shadow, so that a
    /// lift down ends in no hard edge.
    func testACutOutSpansEitherLevel() throws {
        let shadow = ColumnShadowView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        shadow.isCardClear = true
        let reach = max(Theme.Elevation.Level.column.reach, Theme.Elevation.Level.focusedColumn.reach)
        let span = shadow.bounds.insetBy(dx: -reach, dy: -reach)
        XCTAssertEqual(try XCTUnwrap(shadow.cutOutPath).boundingBox, span)
        shadow.show(.focusedColumn, animated: false)
        shadow.show(.column, animated: true)
        XCTAssertEqual(try XCTUnwrap(shadow.cutOutPath).boundingBox, span, "while it comes down")
    }

    /// An arriving workspace's focused card is up at once: its slide is
    /// the movement. Reached through one of its columns (a notification,
    /// ⌘P), that column is focused in the same move, once the workspace is
    /// the one chosen: it takes the keyboard and is in view.
    func testAnArrivingWorkspaceIsLiftedAtOnce() throws {
        try withShell { shell in
            shell.sideEffects.reducesMotion = { false }
            shell.agentLights.isDisplayAsleep = false
            shell.animatesInterface = true
            let folder = FileManager.default.temporaryDirectory.path
            shell.addWorkspace(title: "second", cwd: folder)
            shell.switchToWorkspace(0)
            shell.switchToWorkspace(1)
            let arrived = try XCTUnwrap(shell.activeWorkspace)
            let shadow = try XCTUnwrap(arrived.columns[safe: arrived.focusedIndex]?.shadow)
            XCTAssertEqual(shadow.level, .focusedColumn)
            XCTAssertFalse(shadow.isLifting)

            arrived.addColumn()
            arrived.focusedIndex = 0
            shell.switchToWorkspace(0)
            var focusMovedHidden = false
            let focusMoved = arrived.onFocusedColumnChanged
            arrived.onFocusedColumnChanged = {
                focusMovedHidden = focusMovedHidden || shell.activeWorkspace !== arrived
                focusMoved?()
            }
            shell.focusWorkspace(id: arrived.id, column: 1)
            XCTAssertEqual(arrived.focusedIndex, 1)
            XCTAssertFalse(focusMovedHidden, "nothing follows the focus of a workspace not chosen yet")
            let target = try XCTUnwrap(arrived.columns[safe: 1])
            XCTAssertEqual(target.shadow?.level, .focusedColumn)
            XCTAssertEqual(target.shadow?.isLifting, false, "it arrives lifted")
            XCTAssertTrue(shell.window?.firstResponder === target.terminalView, "the keyboard")
            XCTAssertTrue(arrived.showsColumn(at: 1))
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
