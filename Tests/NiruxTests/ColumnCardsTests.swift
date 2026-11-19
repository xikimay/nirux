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
            let start = try XCTUnwrap(handle.onDragStart?())
            XCTAssertEqual(workspace.focusedIndex, 0)
            XCTAssertEqual(layers.map(\.borderWidth), [EdgeGlowView.focusRingWidth, 1])
            XCTAssertTrue(shell.window?.firstResponder === workspace.columns[0].terminalView, "the keyboard")
            handle.onDrag?(start, -30)
            XCTAssertEqual(layers.map(\.borderWidth), [EdgeGlowView.focusRingWidth, 1])
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
            XCTAssertNil(added.view.layer?.animation(forKey: WorkspaceState.cardPassKey))

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
            shell.passCard(card, to: 1, alpha: 1, duration: 0.02, curve: CAMediaTimingFunction(name: .linear)) { ends.append("first") }
            shell.passCard(card, to: NiruxShellView.closeScale, alpha: 1, duration: 0.3, curve: CAMediaTimingFunction(name: .linear)) { ends.append("second") }
            waitUntil("the second's end", timeout: 2) { !ends.isEmpty }
            wait(0.05)
            XCTAssertEqual(ends, ["second"], "the first's end never came")
            XCTAssertNil(card.view.layer?.animation(forKey: WorkspaceState.cardPassKey))

            shell.addColumn()
            let resized = try XCTUnwrap(workspace.columns[safe: workspace.focusedIndex])
            XCTAssertNotNil(resized.view.layer?.animation(forKey: WorkspaceState.cardPassKey))
            resized.widthFraction = 0.3
            shell.relayout(animated: false)
            XCTAssertNil(resized.view.layer?.animation(forKey: WorkspaceState.cardPassKey), "resized: in place at once")
        }
    }

    /// The scale a card's pass goes from and to.
    @MainActor private func scales(of column: ColumnState) throws -> (from: CGFloat, to: CGFloat) {
        let pass = try XCTUnwrap(column.view.layer?.animation(forKey: WorkspaceState.cardPassKey) as? CAAnimationGroup)
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
                ((view?.layer?.animation(forKey: WorkspaceState.cardGlideKey) as? CABasicAnimation)?.fromValue as? NSNumber).map { CGFloat($0.doubleValue) }
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
            waitUntil("in", timeout: 2) { !workspace.columns.contains(where: \.isArriving) }
            workspace.focusedIndex = 0
            let moved = workspace.columns[0], passed = workspace.columns[1]
            @MainActor func shades(of column: ColumnState) -> [CALayer] {
                column.view.layer?.sublayers?.filter { $0.animation(forKey: NiruxShellView.liftKey) != nil } ?? []
            }

            shell.moveColumn(.right)
            XCTAssertTrue(workspace.columns[1] === moved)
            let rise = try XCTUnwrap(moved.view.layer?.animation(forKey: NiruxShellView.liftKey) as? CAKeyframeAnimation)
            XCTAssertEqual(rise.values as? [CGFloat], [0, NiruxShellView.liftHeight, 0], "it rises on its way")
            XCTAssertEqual(moved.view.layer?.zPosition, 1, "over the other")
            XCTAssertEqual(moved.shadow?.layer?.zPosition, 1, "its shadow over the other")
            XCTAssertNotNil(moved.shadow?.layer?.animation(forKey: NiruxShellView.liftKey))
            let dimmed = shades(of: passed)
            XCTAssertEqual(dimmed.count, 1, "the other dims under it")
            XCTAssertEqual(passed.view.layer?.zPosition, 0)

            waitUntil("flat again", timeout: 2) { moved.view.layer?.zPosition == 0 }
            XCTAssertEqual(moved.shadow?.layer?.zPosition, 0)
            XCTAssertTrue(dimmed.allSatisfy { $0.superlayer == nil }, "its shade gone")
            XCTAssertEqual(moved.lifts, 0)

            shell.sideEffects.reducesMotion = { true }
            shell.moveColumn(.left)
            XCTAssertTrue(workspace.columns[0] === moved)
            XCTAssertEqual(moved.view.layer?.zPosition, 0, "Reduce motion: it simply moves")
            XCTAssertTrue(shades(of: passed).isEmpty)
        }
    }

    /// A double-click resets the width and leaves no drag behind it.
    func testADoubleClickOnAHandleLeavesNoDragBehind() {
        let handle = ColumnResizeHandle(frame: NSRect(x: 0, y: 0, width: 9, height: 100))
        var drags = 0
        handle.onDragStart = { (100, 500, 0) }
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
