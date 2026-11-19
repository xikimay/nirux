import AppKit
import XCTest
@testable import Nirux

/// Columns rest on the window as cards (depth study P1): air between and
/// around them, rounded corners, a shadow under each, and the camera brings
/// the focused card to the middle, its air in view at the strip's ends.
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
        let start = try XCTUnwrap(handle.onDragStart?())
        handle.onDrag?(start, 300)
        XCTAssertEqual(workspace.columns[0].view.frame.width - before, 300, accuracy: 1)
    }

    /// Cards that don't fill the viewport lie in its middle, as a first
    /// terminal at half its width does. Dragging an edge then widens the
    /// card on both sides, and the edge stays under the pointer.
    func testCardsThatDontFillTheViewportLieInItsMiddle() throws {
        let workspace = workspace(columns: 1)
        let strip = try strip(of: workspace)
        workspace.layoutAndScroll(viewportWidth: 1000, height: 600, animated: false)
        let card = try XCTUnwrap(workspace.columns.first).view
        let left = card.frame.minX + strip.frame.minX
        XCTAssertEqual(left, 1000 - (card.frame.maxX + strip.frame.minX), accuracy: 1, "as much air on each side")
        XCTAssertGreaterThan(left, inset)

        let handle = try XCTUnwrap(strip.subviews.compactMap { $0 as? ColumnResizeHandle }.first)
        let start = try XCTUnwrap(handle.onDragStart?())
        let edge = card.frame.maxX + strip.frame.minX
        handle.onDrag?(start, 100)
        XCTAssertEqual(card.frame.maxX + strip.frame.minX - edge, 100, accuracy: 1, "the edge under the pointer")
        XCTAssertEqual(card.frame.minX + strip.frame.minX, left - 100, accuracy: 1, "the other edge as far the other way")
        // Past filling the viewport, it follows the pointer as far.
        handle.onDrag?(start, 300)
        XCTAssertEqual(card.frame.maxX + strip.frame.minX - edge, 300, accuracy: 1)
        handle.onDragEnd?()

        // Two halves fill it: nothing to centre.
        workspace.addColumn()
        for column in workspace.columns { column.widthFraction = 0.5 }
        workspace.layoutAndScroll(viewportWidth: 1000, height: 600, animated: false)
        XCTAssertEqual(strip.frame.minX, 0)
    }

    /// On a strip wider than the viewport, scrolled to its end, a dragged
    /// edge stays under the pointer: the camera holds where the drag found
    /// it, and goes back where the strip wants it once let go.
    func testADraggedEdgeStaysUnderThePointerWhereverTheCameraIs() throws {
        let workspace = workspace(columns: 2, width: 0.75)
        workspace.focusedIndex = 1
        workspace.layoutAndScroll(viewportWidth: 1000, height: 600, animated: false)
        let strip = try strip(of: workspace)
        XCTAssertLessThan(strip.frame.minX, -400, "scrolled to the last card")
        let card = workspace.columns[1].view
        let handle = try XCTUnwrap(strip.subviews.compactMap { $0 as? ColumnResizeHandle }.last)
        let start = try XCTUnwrap(handle.onDragStart?())
        let edge = card.frame.maxX + strip.frame.minX
        handle.onDrag?(start, -100)
        XCTAssertEqual(card.frame.maxX + strip.frame.minX - edge, -100, accuracy: 1)
        handle.onDrag?(start, -40)
        XCTAssertEqual(card.frame.maxX + strip.frame.minX - edge, -40, accuracy: 1)

        handle.onDragEnd?()
        XCTAssertEqual(card.frame.maxX + strip.frame.minX, 1000 - inset, accuracy: 1, "the camera back at the end")
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

    /// Past the viewport, the camera brings the focused card to its middle,
    /// and stops at the strip's ends; one wider than the viewport shows
    /// from its left edge.
    func testTheCameraBringsTheFocusedCardToTheMiddle() throws {
        let workspace = workspace(columns: 4)
        let strip = try strip(of: workspace)
        workspace.focusedIndex = 1
        workspace.layoutAndScroll(viewportWidth: 1000, height: 600, animated: false)
        XCTAssertEqual(workspace.columns[1].view.frame.midX + strip.frame.minX, 500, accuracy: 1)

        workspace.columns[3].widthFraction = 0.2
        workspace.focusedIndex = 2
        workspace.layoutAndScroll(viewportWidth: 1000, height: 600, animated: false)
        XCTAssertEqual(workspace.columns[3].view.frame.maxX + inset + strip.frame.minX, 1000, accuracy: 1, "the last card's air against the edge")

        workspace.columns[2].widthFraction = 1.5
        workspace.layoutAndScroll(viewportWidth: 1000, height: 600, animated: false)
        XCTAssertEqual(workspace.columns[2].view.frame.minX + strip.frame.minX, inset, accuracy: 1)
    }

    /// A camera held for a card (a click focused it, its edge grabbed)
    /// stays where it is while that card has the focus; once the focus
    /// moves on, or the hold is let go, it goes where the strip wants it.
    func testAHeldCameraStaysWhileItsCardHasTheFocus() throws {
        let workspace = workspace(columns: 4)
        let strip = try strip(of: workspace)
        workspace.layoutAndScroll(viewportWidth: 1000, height: 600, animated: false)
        workspace.holdCamera(for: 1)
        workspace.focusedIndex = 1
        workspace.layoutAndScroll(viewportWidth: 1000, height: 600, animated: false)
        XCTAssertEqual(strip.frame.minX, 0)

        workspace.focusedIndex = 2
        workspace.layoutAndScroll(viewportWidth: 1000, height: 600, animated: false)
        XCTAssertEqual(workspace.columns[2].view.frame.midX + strip.frame.minX, 500, accuracy: 1, "a keyboard move")

        workspace.focusedIndex = 1
        workspace.layoutAndScroll(viewportWidth: 1000, height: 600, animated: false)
        XCTAssertEqual(workspace.columns[1].view.frame.midX + strip.frame.minX, 500, accuracy: 1, "and back")
    }

    /// A click's hold stays within the strip, should the strip shrink
    /// meanwhile; a drag's holds through a focus moved mid-drag, until let
    /// go.
    func testAHoldStaysWithinTheStripAndADragsThroughAFocusMove() throws {
        let workspace = workspace(columns: 4)
        let strip = try strip(of: workspace)
        workspace.focusedIndex = 3
        workspace.layoutAndScroll(viewportWidth: 1000, height: 600, animated: false)
        workspace.holdCamera(for: 3)
        workspace.columns[0].widthFraction = 0.2
        workspace.columns[1].widthFraction = 0.2
        workspace.layoutAndScroll(viewportWidth: 1000, height: 600, animated: false)
        XCTAssertEqual(workspace.columns[3].view.frame.maxX + inset + strip.frame.minX, 1000, accuracy: 1, "no empty space past the end")
        workspace.heldCamera = nil
        workspace.columns[0].widthFraction = 0.5
        workspace.columns[1].widthFraction = 0.5
        workspace.layoutAndScroll(viewportWidth: 1000, height: 600, animated: false)

        let handle = strip.subviews.compactMap { $0 as? ColumnResizeHandle }[3]
        let start = try XCTUnwrap(handle.onDragStart?())
        handle.onDrag?(start, -40)
        let held = strip.frame.minX
        workspace.focusedIndex = 1
        workspace.layoutAndScroll(viewportWidth: 1000, height: 600, animated: false)
        XCTAssertEqual(strip.frame.minX, held, "a focus moved mid-drag")
        handle.onDragEnd?()
        XCTAssertEqual(workspace.columns[1].view.frame.midX + strip.frame.minX, 500, accuracy: 1)
    }

    /// A double-click sets the card back to half even when a neighbour has
    /// run out: the other pays the rest.
    func testADoubleClickLetsTheOtherNeighbourPayTheRest() throws {
        let workspace = workspace(columns: 4)
        let strip = try strip(of: workspace)
        workspace.columns[1].widthFraction = WorkspaceState.minWidthFraction
        workspace.columns[2].widthFraction = 0.3
        workspace.focusedIndex = 2
        workspace.layoutAndScroll(viewportWidth: 1000, height: 600, animated: false)
        let before = workspace.columns.map(\.view.frame.width)
        strip.subviews.compactMap { $0 as? ColumnResizeHandle }[2].onReset?()
        XCTAssertEqual(workspace.columns[2].view.frame.width, floor(0.5 * (1000 - inset * 2 + gap) - gap), accuracy: 1)
        XCTAssertEqual(workspace.columns[1].view.frame.width, before[1])
    }

    /// A double-click on an edge sets the focused card back to half, by the
    /// same share as a drag, and leaves the focus where it is.
    func testADoubleClickOnAnEdgeSetsTheCardBackToHalf() throws {
        let workspace = workspace(columns: 4, width: 0.4)
        let strip = try strip(of: workspace)
        workspace.focusedIndex = 2
        workspace.layoutAndScroll(viewportWidth: 1000, height: 600, animated: false)
        let before = workspace.columns.map(\.view.frame.width), left = strip.frame.minX
        let handle = strip.subviews.compactMap { $0 as? ColumnResizeHandle }[1]
        func event(_ type: NSEvent.EventType, clicks: Int, x: CGFloat = 0) -> NSEvent {
            NSEvent.mouseEvent(
                with: type, location: NSPoint(x: x, y: 0), modifierFlags: [], timestamp: 0, windowNumber: 0,
                context: nil, eventNumber: 0, clickCount: clicks, pressure: 1
            )!
        }
        handle.mouseDown(with: event(.leftMouseDown, clicks: 1))
        handle.mouseDragged(with: event(.leftMouseDragged, clicks: 1, x: 1))
        handle.mouseUp(with: event(.leftMouseUp, clicks: 1))
        XCTAssertEqual(workspace.columns.map(\.view.frame.width), before, "a click's jitter resizes nothing")
        handle.mouseDown(with: event(.leftMouseDown, clicks: 2))
        XCTAssertEqual(workspace.focusedIndex, 2)
        let widths = workspace.columns.map(\.view.frame.width)
        let half = floor(0.5 * (1000 - inset * 2 + gap) - gap)
        XCTAssertEqual(widths[2], half, accuracy: 1)
        XCTAssertEqual(widths[1] - before[1], (before[2] - half) / 2, accuracy: 1)
        XCTAssertEqual(widths[3] - before[3], (before[2] - half) / 2, accuracy: 1)
        XCTAssertEqual(strip.frame.minX, left, accuracy: 1)
    }

    /// Only the focused card's edges show: its left one is its neighbour's
    /// handle, and grabbing it leaves the focus where it is.
    func testOnlyTheFocusedCardsEdgesShow() throws {
        let workspace = workspace(columns: 4)
        let handles = try strip(of: workspace).subviews.compactMap { $0 as? ColumnResizeHandle }
        workspace.focusedIndex = 1
        workspace.layoutAndScroll(viewportWidth: 1000, height: 600, animated: false)
        XCTAssertEqual(handles.map(\.isHidden), [false, false, true, true])
        XCTAssertNotNil(handles[0].onDragStart?())
        XCTAssertNil(handles[2].onDragStart?())
        XCTAssertEqual(workspace.focusedIndex, 1)

        workspace.focusedIndex = 3
        workspace.layoutAndScroll(viewportWidth: 1000, height: 600, animated: false)
        XCTAssertEqual(handles.map(\.isHidden), [true, true, false, false])
    }

    /// A card centred between two neighbours grows on both sides from
    /// either edge, the edge under the pointer: its neighbours pay alike,
    /// and the strip doesn't move, while dragging or let go.
    func testACentredCardGrowsOnBothSides() throws {
        let workspace = workspace(columns: 4)
        let strip = try strip(of: workspace)
        workspace.columns[3].widthFraction = 0.43
        workspace.focusedIndex = 1
        workspace.layoutAndScroll(viewportWidth: 1000, height: 600, animated: false)
        let handles = strip.subviews.compactMap { $0 as? ColumnResizeHandle }
        let before = workspace.columns.map(\.view.frame.width), left = strip.frame.minX
        let card = workspace.columns[1].view
        let edge = card.frame.maxX + strip.frame.minX

        let start = try XCTUnwrap(handles[1].onDragStart?())
        handles[1].onDrag?(start, 40)
        let widths = workspace.columns.map(\.view.frame.width)
        XCTAssertEqual(widths[1] - before[1], 80, accuracy: 1)
        XCTAssertEqual(widths[0] - before[0], -40, accuracy: 1)
        XCTAssertEqual(widths[2] - before[2], -40, accuracy: 1)
        XCTAssertEqual(widths[3], before[3])
        XCTAssertEqual(workspace.columns[3].widthFraction, 0.43, "untouched, its fraction as it was")
        XCTAssertEqual(card.frame.maxX + strip.frame.minX - edge, 40, accuracy: 1, "the edge under the pointer")
        XCTAssertEqual(card.frame.midX + strip.frame.minX, 500, accuracy: 1)
        handles[1].onDragEnd?()
        XCTAssertEqual(strip.frame.minX, left, accuracy: 1, "nothing glides once let go")

        let fromLeft = try XCTUnwrap(handles[0].onDragStart?())
        handles[0].onDrag?(fromLeft, 40)
        XCTAssertEqual(card.frame.width - widths[1], -80, accuracy: 1, "its left edge in")
        XCTAssertEqual(card.frame.midX + strip.frame.minX, 500, accuracy: 1)
        handles[0].onDragEnd?()

        // It grows up to the viewport's width, centred.
        let wide = try XCTUnwrap(handles[1].onDragStart?())
        handles[1].onDrag?(wide, 400)
        XCTAssertEqual(card.frame.width, 1000 - inset * 2, accuracy: 1)
        XCTAssertEqual(card.frame.midX + strip.frame.minX, 500, accuracy: 1, "centred at its widest")
        let held = strip.frame.minX
        handles[1].onDragEnd?()
        XCTAssertEqual(strip.frame.minX, held, accuracy: 1, "nothing glides")
    }

    /// A neighbour that runs out pays what it can, and the other pays on:
    /// the dragged edge stays under the pointer.
    func testANeighbourThatRunsOutLeavesTheOtherToPay() throws {
        let workspace = workspace(columns: 4)
        let strip = try strip(of: workspace)
        workspace.columns[1].widthFraction = 0.25
        workspace.focusedIndex = 2
        workspace.layoutAndScroll(viewportWidth: 1000, height: 600, animated: false)
        let handles = strip.subviews.compactMap { $0 as? ColumnResizeHandle }
        let card = workspace.columns[2].view
        XCTAssertEqual(card.frame.midX + strip.frame.minX, 500, accuracy: 1)
        let before = workspace.columns.map(\.view.frame.width), edge = card.frame.maxX + strip.frame.minX
        let start = try XCTUnwrap(handles[2].onDragStart?())
        handles[2].onDrag?(start, 200)
        let widths = workspace.columns.map(\.view.frame.width)
        XCTAssertEqual(widths[1], floor(WorkspaceState.minWidthFraction * (1000 - inset * 2 + gap) - gap), accuracy: 1, "down to the minimum")
        XCTAssertEqual(widths[3] - before[3], -200, accuracy: 1)
        XCTAssertEqual(card.frame.maxX + strip.frame.minX - edge, 200, accuracy: 1)
        XCTAssertEqual(widths.reduce(0, +), before.reduce(0, +), accuracy: 2, "the strip as wide")
    }

    /// A focus moved during a drag leaves the drag's card where it is.
    func testAFocusMovedDuringADragEndsIt() throws {
        let workspace = workspace(columns: 4)
        let strip = try strip(of: workspace)
        workspace.focusedIndex = 1
        workspace.layoutAndScroll(viewportWidth: 1000, height: 600, animated: false)
        let handle = strip.subviews.compactMap { $0 as? ColumnResizeHandle }[1]
        let start = try XCTUnwrap(handle.onDragStart?())
        workspace.focusedIndex = 3
        workspace.layoutAndScroll(viewportWidth: 1000, height: 600, animated: false)
        let before = workspace.columns.map(\.view.frame.width)
        handle.onDrag?(start, 60)
        XCTAssertEqual(workspace.columns.map(\.view.frame.width), before)
    }

    /// A card not centred never takes more than the maximum width, nor its
    /// neighbour more than it gives.
    func testWidthsStayWithinTheirRange() throws {
        let workspace = workspace(columns: 2)
        let strip = try strip(of: workspace)
        workspace.columns[0].widthFraction = 1.6
        workspace.columns[1].widthFraction = 1
        workspace.layoutAndScroll(viewportWidth: 1000, height: 600, animated: false)
        let before = workspace.columns.map(\.view.frame.width)
        let handle = strip.subviews.compactMap { $0 as? ColumnResizeHandle }[0]
        let start = try XCTUnwrap(handle.onDragStart?())
        handle.onDrag?(start, 600)
        XCTAssertEqual(workspace.columns[0].widthFraction, WorkspaceState.maxWidthFraction, accuracy: 0.01)
        XCTAssertEqual(workspace.columns.map(\.view.frame.width).reduce(0, +), before.reduce(0, +), accuracy: 2)
    }

    /// A card not centred (at the strip's ends, or at the side of cards that
    /// fit) takes from the neighbour across the dragged edge alone.
    func testACardNotCentredTakesFromTheNeighbourAcrossTheEdge() throws {
        let workspace = workspace(columns: 4)
        let strip = try strip(of: workspace)
        workspace.focusedIndex = 3
        workspace.layoutAndScroll(viewportWidth: 1000, height: 600, animated: false)
        let handles = strip.subviews.compactMap { $0 as? ColumnResizeHandle }
        let before = workspace.columns.map(\.view.frame.width), left = strip.frame.minX
        let start = try XCTUnwrap(handles[2].onDragStart?())
        handles[2].onDrag?(start, -40)
        let widths = workspace.columns.map(\.view.frame.width)
        XCTAssertEqual(widths[3] - before[3], 40, accuracy: 1)
        XCTAssertEqual(widths[2] - before[2], -40, accuracy: 1)
        XCTAssertEqual(Array(widths[0...1]), Array(before[0...1]))
        handles[2].onDragEnd?()
        XCTAssertEqual(strip.frame.minX, left, accuracy: 1)

        // Grown past the viewport's width, it keeps its edge under the
        // pointer until let go.
        workspace.columns[2].widthFraction = 1
        workspace.layoutAndScroll(viewportWidth: 1000, height: 600, animated: false)
        let card = workspace.columns[3].view
        let edge = card.frame.minX + strip.frame.minX
        let wide = try XCTUnwrap(handles[2].onDragStart?())
        handles[2].onDrag?(wide, -560)
        XCTAssertGreaterThan(card.frame.width, 1000)
        XCTAssertEqual(card.frame.minX + strip.frame.minX - edge, -560, accuracy: 1)
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

            // Grabbing the focused card's left edge, its neighbour's handle,
            // leaves the focus, the accent and the keyboard where they are.
            let strip = try strip(of: workspace)
            let handle = try XCTUnwrap(strip.subviews.compactMap { $0 as? ColumnResizeHandle }.first)
            let start = try XCTUnwrap(handle.onDragStart?())
            XCTAssertEqual(workspace.focusedIndex, 1)
            handle.onDrag?(start, -30)
            XCTAssertEqual(layers.map(\.borderWidth), [1, EdgeGlowView.focusRingWidth])
        }
    }

    /// A click during a slide stops the strip where it shows, so that what
    /// lies under the pointer stays there.
    func testAClickDuringASlideStopsTheStripWhereItShows() throws {
        try withShell { shell in
            let workspace = try XCTUnwrap(shell.activeWorkspace)
            for _ in 0..<3 { workspace.addColumn() }
            for column in workspace.columns { column.widthFraction = 0.5 }
            workspace.focusedIndex = 0
            shell.relayout(animated: false)
            let strip = try strip(of: workspace), start = strip.frame.minX
            workspace.focusedIndex = 1
            shell.relayout(animated: true)
            let target = strip.frame.minX
            func shown() -> CGFloat {
                strip.frame.minX + CGFloat((strip.layer?.presentation()?.value(forKeyPath: "transform.translation.x") as? NSNumber)?.doubleValue ?? 0)
            }
            waitUntil("on its way", timeout: 2) { abs(shown() - start) > 20 && abs(shown() - target) > 20 }
            let midway = shown()
            workspace.holdCamera(for: 1)
            XCTAssertEqual(strip.frame.minX, midway, accuracy: 3)
            XCTAssertNil(strip.layer?.animation(forKey: "colSlide"))
        }
    }

    /// The strip glides when a column comes or goes, from where it shows: a
    /// lone card aside for a second one, the one left back to the middle.
    func testTheStripGlidesAsideAndBack() throws {
        try withShell { shell in
            let workspace = try XCTUnwrap(shell.activeWorkspace)
            let strip = try strip(of: workspace)
            let centred = strip.frame.minX
            XCTAssertGreaterThan(centred, inset, "a lone half lies in the middle")

            shell.addColumn()
            XCTAssertEqual(strip.frame.minX, 0, "two halves fill the viewport")
            let aside = try XCTUnwrap(strip.layer?.animation(forKey: "colSlide") as? CABasicAnimation)
            XCTAssertEqual(try XCTUnwrap(aside.fromValue as? NSNumber).doubleValue, Double(centred), accuracy: 1, "from where it showed")
            XCTAssertEqual(aside.toValue as? NSNumber, 0)

            shell.finishColumnClose(try XCTUnwrap(workspace.columns.last), in: workspace)
            XCTAssertEqual(strip.frame.minX, centred, accuracy: 1)
            let back = try XCTUnwrap(strip.layer?.animation(forKey: "colSlide") as? CABasicAnimation)
            XCTAssertEqual(try XCTUnwrap(back.fromValue as? NSNumber).doubleValue, Double(-centred), accuracy: 1)
        }
    }

    /// A new column comes in, then is in on time: its shadow and light
    /// follow whether or not the animation reports its end. With Reduce
    /// motion, or before it has a size, it is in at once.
    func testANewColumnIsInOnTimeAndAtOnceWhenNothingMayMove() throws {
        try withShell { shell in
            shell.sideEffects.reducesMotion = { false }
            shell.agentLights.isDisplayAsleep = false
            shell.animatesInterface = true
            let workspace = try XCTUnwrap(shell.activeWorkspace)
            shell.addColumn()
            let added = try XCTUnwrap(workspace.columns[safe: workspace.focusedIndex])
            XCTAssertTrue(added.isArriving)
            XCTAssertEqual(added.shadow?.isHidden, true)
            waitUntil("in, on time", timeout: 2) { !added.isArriving }
            XCTAssertEqual(added.shadow?.isHidden, false)

            shell.sideEffects.reducesMotion = { true }
            shell.addColumn()
            let still = try XCTUnwrap(workspace.columns[safe: workspace.focusedIndex])
            XCTAssertFalse(still.isArriving, "Reduce motion: in at once")
            XCTAssertEqual(still.view.alphaValue, 1)

            shell.sideEffects.reducesMotion = { false }
            let column = ColumnState(cwd: "/tmp")
            shell.arrive(column, in: workspace)
            XCTAssertFalse(column.isArriving, "no size yet: nothing to scale about")
        }
    }

    /// A new card comes in from the front, over its neighbours, then lies
    /// among them; a closed one recedes as it fades, and goes on time. With
    /// Reduce motion a closed one only fades.
    func testACardComesFromTheFrontAndRecedes() throws {
        try withShell { shell in
            shell.sideEffects.reducesMotion = { false }
            shell.agentLights.isDisplayAsleep = false
            shell.animatesInterface = true
            let workspace = try XCTUnwrap(shell.activeWorkspace)
            @MainActor func scales(of column: ColumnState) throws -> (from: CGFloat, to: CGFloat) {
                try self.scales(of: column)
            }

            shell.addColumn()
            let added = try XCTUnwrap(workspace.columns[safe: workspace.focusedIndex])
            let start = try scales(of: added)
            XCTAssertEqual(start.from, NiruxShellView.arrivalScale, "from the front")
            XCTAssertEqual(start.to, 1)
            XCTAssertEqual(added.view.layer?.zPosition, 1, "over its neighbours")
            let handles = try strip(of: workspace).subviews.compactMap { $0 as? ColumnResizeHandle }
            XCTAssertTrue(handles.allSatisfy { ($0.layer?.zPosition ?? 0) > 1 }, "under the handles, which take its clicks")
            waitUntil("in, on time", timeout: 2) { !added.isArriving }
            XCTAssertEqual(added.view.layer?.zPosition, 0, "among them")
            XCTAssertNil(added.view.layer?.animation(forKey: ColumnState.passKey))

            shell.closeActiveColumn()
            let end = try scales(of: added)
            XCTAssertEqual(end.from, 1, accuracy: 0.001)
            XCTAssertEqual(end.to, NiruxShellView.closeScale, "it recedes")
            XCTAssertEqual(added.view.alphaValue, 0, "as it fades")
            waitUntil("gone, on time", timeout: 2) { !workspace.columns.contains { $0 === added } }

            shell.addColumn()
            let still = try XCTUnwrap(workspace.columns[safe: workspace.focusedIndex])
            waitUntil("in", timeout: 2) { !still.isArriving }
            shell.sideEffects.reducesMotion = { true }
            shell.closeActiveColumn()
            XCTAssertEqual(try scales(of: still).to, 1, "Reduce motion: no recede")
            XCTAssertEqual(still.view.alphaValue, 0)
            waitUntil("gone", timeout: 2) { !workspace.columns.contains { $0 === still } }
        }
    }

    /// ⌘W while a card arrives: it recedes from where it shows, and the
    /// arrival's end leaves its recede alone until it goes. A card that
    /// changes size mid-way is in place at once.
    func testACardClosedWhileArrivingRecedesFromWhereItShows() throws {
        try withShell { shell in
            shell.sideEffects.reducesMotion = { false }
            shell.agentLights.isDisplayAsleep = false
            shell.animatesInterface = true
            let workspace = try XCTUnwrap(shell.activeWorkspace)
            @MainActor func wait(_ seconds: TimeInterval) {
                let end = Date().addingTimeInterval(seconds)
                waitUntil("\(seconds) s", timeout: seconds + 2) { Date() >= end }
            }

            shell.addColumn()
            let added = try XCTUnwrap(workspace.columns[safe: workspace.focusedIndex])
            wait(NiruxShellView.arrivalDuration / 2)
            shell.closeActiveColumn()
            let recede = try self.scales(of: added)
            XCTAssertGreaterThan(recede.from, 1, "from where it shows, still nearer")
            XCTAssertEqual(recede.to, NiruxShellView.closeScale)
            XCTAssertFalse(added.isArriving)
            XCTAssertEqual(added.view.layer?.zPosition, 0, "behind its neighbours again")
            // Past the arrival's end, until it goes, the recede stays.
            var kept = true
            waitUntil("gone", timeout: 2) {
                guard workspace.columns.contains(where: { $0 === added }) else { return true }
                if (try? self.scales(of: added).to) != NiruxShellView.closeScale { kept = false }
                return false
            }
            XCTAssertTrue(kept, "the arrival's end left its recede alone")

            // One pass takes a card from another: the first's end never
            // comes, whenever the two were due.
            let card = try XCTUnwrap(workspace.columns.first)
            var ends: [String] = []
            card.pass(to: 1, alpha: 1, duration: 0.02, curve: CAMediaTimingFunction(name: .linear)) { ends.append("first") }
            card.pass(to: NiruxShellView.closeScale, alpha: 1, duration: 0.3, curve: CAMediaTimingFunction(name: .linear)) { ends.append("second") }
            waitUntil("the second's end", timeout: 2) { !ends.isEmpty }
            wait(0.05)
            XCTAssertEqual(ends, ["second"], "the first's end never came")
            XCTAssertNil(card.view.layer?.animation(forKey: ColumnState.passKey))

            shell.addColumn()
            let resized = try XCTUnwrap(workspace.columns[safe: workspace.focusedIndex])
            XCTAssertNotNil(resized.view.layer?.animation(forKey: ColumnState.passKey))
            resized.widthFraction = 0.3
            shell.relayout(animated: false)
            XCTAssertNil(resized.view.layer?.animation(forKey: ColumnState.passKey), "resized: in place at once")
        }
    }

    /// A card closed while it glides keeps its glide under its recede: the
    /// two compose on its layer, neither cancels the other.
    func testAGlideAndAPassOnOneCardCompose() throws {
        try withShell { shell in
            shell.sideEffects.reducesMotion = { false }
            shell.agentLights.isDisplayAsleep = false
            shell.animatesInterface = true
            let workspace = try XCTUnwrap(shell.activeWorkspace)
            shell.addColumn()
            waitUntil("in", timeout: 2) { !workspace.columns.contains(where: \.isArriving) }
            workspace.focusedIndex = 0
            let pushed = workspace.columns[1]
            shell.addColumn()
            XCTAssertNotNil(pushed.view.layer?.animation(forKey: ColumnState.glideKey))
            workspace.focusedIndex = try XCTUnwrap(workspace.columns.firstIndex { $0 === pushed })
            shell.closeActiveColumn()
            XCTAssertNotNil(pushed.view.layer?.animation(forKey: ColumnState.glideKey), "its glide goes on")
            let pass = try XCTUnwrap(pushed.view.layer?.animation(forKey: ColumnState.passKey) as? CAAnimationGroup)
            let scaling = try XCTUnwrap(pass.animations?.compactMap { $0 as? CABasicAnimation }.first { $0.keyPath == "transform" })
            XCTAssertTrue(scaling.isAdditive, "the recede adds to the glide rather than replacing it")
        }
    }

    /// The scale a card's pass goes from and to.
    @MainActor private func scales(of column: ColumnState) throws -> (from: CGFloat, to: CGFloat) {
        let pass = try XCTUnwrap(column.view.layer?.animation(forKey: ColumnState.passKey) as? CAAnimationGroup)
        let move = try XCTUnwrap(pass.animations?.compactMap { $0 as? CABasicAnimation }.first { $0.keyPath == "transform" })
        let from = try XCTUnwrap(move.fromValue as? NSValue).caTransform3DValue
        let to = try XCTUnwrap(move.toValue as? NSValue).caTransform3DValue
        return (from.m11, to.m11)
    }

    /// A card a new one comes before glides aside from where it showed, its
    /// shadow with it, and back once the new one went. With Reduce motion
    /// it is simply there.
    func testANeighbourGlidesAsideAndBack() throws {
        try withShell { shell in
            shell.sideEffects.reducesMotion = { false }
            shell.agentLights.isDisplayAsleep = false
            shell.animatesInterface = true
            let workspace = try XCTUnwrap(shell.activeWorkspace)
            @MainActor func glide(of view: NSView?) -> CGFloat? {
                ((view?.layer?.animation(forKey: ColumnState.glideKey) as? CABasicAnimation)?.fromValue as? NSNumber).map { CGFloat($0.doubleValue) }
            }
            shell.addColumn()
            waitUntil("in", timeout: 2) { !workspace.columns.contains(where: \.isArriving) }
            workspace.focusedIndex = 0
            let neighbour = workspace.columns[1]
            let before = neighbour.view.frame.minX

            shell.addColumn()
            let pushed = before - neighbour.view.frame.minX
            XCTAssertLessThan(pushed, 0, "pushed aside")
            XCTAssertEqual(try XCTUnwrap(glide(of: neighbour.view)), pushed, accuracy: 1, "from where it showed")
            XCTAssertEqual(try XCTUnwrap(glide(of: neighbour.shadow)), pushed, accuracy: 1, "its shadow with it")
            let added = workspace.columns[1]
            XCTAssertNil(glide(of: added.view), "the new card comes from the front instead")
            waitUntil("in", timeout: 2) { !added.isArriving }

            shell.closeActiveColumn()
            waitUntil("gone", timeout: 2) { !workspace.columns.contains { $0 === added } }
            XCTAssertEqual(neighbour.view.frame.minX, before, accuracy: 1)
            XCTAssertEqual(try XCTUnwrap(glide(of: neighbour.view)), -pushed, accuracy: 1, "back")

            neighbour.view.layer?.removeAllAnimations()
            shell.sideEffects.reducesMotion = { true }
            workspace.focusedIndex = 0
            shell.addColumn()
            XCTAssertNil(glide(of: neighbour.view), "Reduce motion: there at once")
        }
    }

    /// A moved card passes over the one it swaps with: it rises on its way,
    /// its shadow over the other, which dims under it a moment; then both
    /// lie flat again. With Reduce motion it simply moves.
    func testAMovedCardPassesOverItsNeighbour() throws {
        try withShell { shell in
            shell.sideEffects.reducesMotion = { false }
            shell.agentLights.isDisplayAsleep = false
            shell.animatesInterface = true
            let workspace = try XCTUnwrap(shell.activeWorkspace)
            shell.addColumn()
            waitUntil("in and flat", timeout: 2) {
                workspace.columns.allSatisfy { !$0.isArriving && $0.view.layer?.zPosition == 0 }
            }
            workspace.focusedIndex = 0
            let moved = workspace.columns[0], passed = workspace.columns[1]

            shell.moveColumn(.right)
            XCTAssertTrue(workspace.columns[1] === moved)
            let rise = try XCTUnwrap(moved.view.layer?.animation(forKey: ColumnState.liftKey) as? CAKeyframeAnimation)
            XCTAssertEqual(rise.values as? [CGFloat], [0, ColumnState.liftHeight, 0], "it rises on its way")
            XCTAssertEqual(moved.view.layer?.zPosition, 1, "over the other")
            XCTAssertEqual(moved.shadow?.layer?.zPosition, 1, "its shadow over the other")
            XCTAssertNotNil(moved.shadow?.layer?.animation(forKey: ColumnState.liftKey))
            let shade = try XCTUnwrap(passed.passShadeView, "the other dims under it")
            XCTAssertNotNil(shade.layer?.animation(forKey: ColumnState.liftKey))
            XCTAssertTrue(passed.view.subviews.last === shade, "over its content")
            XCTAssertEqual(passed.view.layer?.zPosition, 0)

            waitUntil("flat again", timeout: 2) { moved.view.layer?.zPosition == 0 }
            XCTAssertEqual(moved.shadow?.layer?.zPosition, 0)
            waitUntil("its shade gone", timeout: 2) { passed.passShadeView == nil }
            XCTAssertNil(shade.superview)
            XCTAssertEqual(moved.lifts, 0)

            shell.sideEffects.reducesMotion = { true }
            shell.moveColumn(.left)
            XCTAssertTrue(workspace.columns[0] === moved)
            XCTAssertEqual(moved.view.layer?.zPosition, 0, "Reduce motion: it simply moves")
            XCTAssertNil(passed.passShadeView)
        }
    }

    /// A held ⇧⌘→: each step lifts the card on from the height it shows,
    /// and a card passed twice dims under one shade, its size even when it
    /// changes, gone with the last pass.
    func testARepeatedMoveLiftsOnAndShadesOnce() throws {
        try withShell { shell in
            shell.sideEffects.reducesMotion = { false }
            shell.agentLights.isDisplayAsleep = false
            shell.animatesInterface = true
            let workspace = try XCTUnwrap(shell.activeWorkspace)
            shell.addColumn()
            shell.addColumn()
            waitUntil("in", timeout: 2) { !workspace.columns.contains(where: \.isArriving) }
            workspace.focusedIndex = 0
            let moved = workspace.columns[0], twice = workspace.columns[2]

            shell.moveColumn(.right)
            waitUntil("on its way up", timeout: 2) { (moved.view.layer?.presentation()?.transform.m42 ?? 0) > 1 }
            shell.moveColumn(.right)
            let rise = try XCTUnwrap(moved.view.layer?.animation(forKey: ColumnState.liftKey) as? CAKeyframeAnimation)
            XCTAssertGreaterThan(try XCTUnwrap((rise.values as? [CGFloat])?.first), 0.5, "on from the height it shows")

            shell.moveColumn(.left)
            XCTAssertEqual(twice.view.subviews.filter { $0 is PassShadeView }.count, 1, "passed twice, one shade")
            twice.widthFraction = 0.3
            shell.relayout(animated: false)
            XCTAssertEqual(try XCTUnwrap(twice.passShadeView).frame, twice.view.bounds, "its size")
            waitUntil("its shade gone", timeout: 2) { twice.passShadeView == nil }
            XCTAssertFalse(twice.view.subviews.contains { $0 is PassShadeView })
        }
    }

    /// A card's depth follows its state alone: over its neighbours while it
    /// arrives or a move lifts it, an arrival ending mid-lift included;
    /// never while it goes, and a going card takes no lift.
    func testACardsDepthFollowsItsState() throws {
        try withShell { shell in
            let workspace = try XCTUnwrap(shell.activeWorkspace)
            shell.addColumn()
            let card = workspace.columns[0], other = workspace.columns[1]
            let depths = { card.cardLayers.map(\.zPosition) }
            XCTAssertEqual(card.cardLayers.count, card.light == nil ? 2 : 3)
            card.isArriving = true
            card.lifts = 1
            card.updateDepth()
            XCTAssertEqual(Set(depths()), [1])
            card.isArriving = false
            card.updateDepth()
            XCTAssertEqual(Set(depths()), [1], "its arrival over, still lifted")
            card.isClosing = true
            card.updateDepth()
            XCTAssertEqual(Set(depths()), [0], "going")
            card.lift(over: other)
            XCTAssertEqual(card.lifts, 1, "a going card takes no lift")
            XCTAssertNil(other.passShadeView)
            card.lifts = 0
            card.isClosing = false
            card.updateDepth()
            XCTAssertEqual(Set(depths()), [0])
        }
    }

    /// Where a card shows reads its glide alone, not its pass's scale about
    /// the middle.
    func testWhereACardShowsLeavesItsPassOut() throws {
        try withShell { shell in
            let workspace = try XCTUnwrap(shell.activeWorkspace)
            let card = try XCTUnwrap(workspace.columns.first)
            card.pass(from: (0.5, 1), to: 0.5, alpha: 1, duration: 5, curve: CAMediaTimingFunction(name: .linear)) {}
            waitUntil("held at half its size", timeout: 2) { (card.view.layer?.presentation()?.transform.m11 ?? 1) < 0.6 }
            XCTAssertEqual(card.shownPlace.x, card.view.frame.minX, accuracy: 0.5)
            card.view.layer?.removeAnimation(forKey: ColumnState.passKey)
        }
    }

    /// A double-click resets the width and leaves no drag behind it.
    func testADoubleClickOnAHandleLeavesNoDragBehind() {
        let handle = ColumnResizeHandle(frame: NSRect(x: 0, y: 0, width: 9, height: 100))
        var drags = 0
        handle.onDragStart = { ([100], 500, 0, 0, false) }
        handle.onDrag = { _, _ in drags += 1 }
        handle.onReset = {}
        func event(_ type: NSEvent.EventType, clicks: Int) -> NSEvent {
            NSEvent.mouseEvent(
                with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                context: nil, eventNumber: 0, clickCount: clicks, pressure: 1
            )!
        }
        handle.mouseDown(with: event(.leftMouseDown, clicks: 1))
        handle.mouseUp(with: event(.leftMouseUp, clicks: 1))
        handle.mouseDown(with: event(.leftMouseDown, clicks: 2))
        handle.mouseDragged(with: event(.leftMouseDragged, clicks: 2))
        XCTAssertEqual(drags, 0)
    }

    /// A card's shadow hides while the card comes or goes: the fading card
    /// would show it. The layout decides, even one that comes mid-fade.
    func testAShadowHidesWhileItsCardComesOrGoes() throws {
        try withShell { shell in
            shell.sideEffects.reducesMotion = { false }
            shell.agentLights.isDisplayAsleep = false
            shell.animatesInterface = true
            let workspace = try XCTUnwrap(shell.activeWorkspace)
            shell.addColumn()
            let added = try XCTUnwrap(workspace.columns[safe: workspace.focusedIndex])
            XCTAssertEqual(added.shadow?.isHidden, true, "the new card fades in")
            shell.relayout(animated: false)
            XCTAssertEqual(added.shadow?.isHidden, true, "a layout mid-fade keeps it hidden")
            waitUntil("the card in", timeout: 2) { !added.isArriving }
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
