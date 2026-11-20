import AppKit
import XCTest
@testable import Nirux

/// Depth study P5: ⌥⌘↑ shows the space as a plan.
@MainActor
final class SpacePlanTests: XCTestCase {
    /// A row per workspace of the space, in the order they're listed, the
    /// first highest, each its every column frozen at one scale beside its
    /// name; the card on screen chosen; the live views hidden and no
    /// terminal drawing under it. ⌥⌘↑ again goes back.
    func testThePlanShowsEveryWorkspaceWithTheCardOnScreenChosen() throws {
        try withWorkspaces { shell, workspaces in
            var drawing: [ObjectIdentifier: Bool] = [:]
            shell.sideEffects.setSurfaceVisible = { column, visible in drawing[ObjectIdentifier(column)] = visible }
            let onScreen = try XCTUnwrap(shell.activeWorkspace)
            toggle(shell)
            let plan = try XCTUnwrap(shell.spacePlan)
            XCTAssertIdentical(plan.superview, shell.viewport)
            XCTAssertEqual(plan.rows.map(\.workspaceID), workspaces.map(\.id), "in the order they're listed")
            XCTAssertLessThan(plan.scale, 1)
            for (row, workspace) in zip(plan.rows, workspaces) {
                XCTAssertEqual(row.picture.frame.width, workspace.stripSize.width * plan.scale, accuracy: 0.5, "every column, at the plan's scale")
                XCTAssertEqual(row.cards.count, workspace.columns.count)
                XCTAssertTrue(plan.subviews.contains { ($0 as? NSTextField)?.stringValue == workspace.title }, "its name beside it")
            }
            XCTAssertGreaterThan(plan.rows[0].picture.frame.minY, plan.rows[1].picture.frame.maxY, "the first listed highest")
            XCTAssertEqual(plan.rows[plan.chosen.row].workspaceID, onScreen.id)
            XCTAssertEqual(plan.chosen.column, onScreen.focusedIndex)
            XCTAssertEqual(shell.verticalStrip.alphaValue, 0, "the live views hidden")
            XCTAssertTrue(workspaces.flatMap(\.columns).allSatisfy { drawing[ObjectIdentifier($0)] == false }, "no terminal draws")
            XCTAssertIdentical(shell.window?.firstResponder, plan, "it takes the keys")

            toggle(shell)
            XCTAssertNil(shell.spacePlan, "⌥⌘↑ again goes back")
            XCTAssertNil(plan.superview)
            XCTAssertEqual(shell.verticalStrip.alphaValue, 1)
            XCTAssertIdentical(shell.activeWorkspace, onScreen)
            XCTAssertEqual(drawing[ObjectIdentifier(try XCTUnwrap(onScreen.columns.first))], true, "the workspace on screen draws again")
        }
    }

    /// The arrows move the choice along a row and to the nearest card of the
    /// row above or below, as far as the plan's edges; Return goes there.
    func testTheArrowsMoveTheChoiceAndReturnGoesThere() throws {
        try withWorkspaces { shell, workspaces in
            toggle(shell)
            let plan = try XCTUnwrap(shell.spacePlan)
            XCTAssertEqual(plan.chosen.row, 1)
            plan.keyDown(with: try Self.key(126))
            XCTAssertEqual(plan.chosen.row, 0, "up a row")
            plan.keyDown(with: try Self.key(126))
            XCTAssertEqual(plan.chosen.row, 0, "the top row is the edge")
            for _ in 0..<5 { plan.keyDown(with: try Self.key(124)) }
            XCTAssertEqual(plan.chosen.column, workspaces[0].columns.count - 1, "the row's end is the edge")
            plan.keyDown(with: try Self.key(123))
            let column = plan.chosen.column
            XCTAssertEqual(column, workspaces[0].columns.count - 2)
            plan.keyDown(with: try Self.key(125))
            plan.keyDown(with: try Self.key(126))
            XCTAssertEqual(plan.chosen.row, 0)

            plan.keyDown(with: try Self.key(36))
            XCTAssertNil(shell.spacePlan, "Return goes there")
            XCTAssertIdentical(shell.activeWorkspace, workspaces[0])
            XCTAssertEqual(workspaces[0].focusedIndex, plan.chosen.column)
            XCTAssertEqual(shell.verticalStrip.alphaValue, 1)
        }
    }

    /// Escape goes back as it was; a click on a card goes to it.
    func testEscapeGoesBackAndAClickGoesToTheCard() throws {
        try withWorkspaces { shell, workspaces in
            let onScreen = try XCTUnwrap(shell.activeWorkspace)
            let focused = onScreen.focusedIndex
            toggle(shell)
            let first = try XCTUnwrap(shell.spacePlan)
            first.keyDown(with: try Self.key(126))
            first.keyDown(with: try Self.key(53))
            XCTAssertNil(shell.spacePlan)
            XCTAssertIdentical(shell.activeWorkspace, onScreen, "as it was, wherever the choice moved")
            XCTAssertEqual(onScreen.focusedIndex, focused)

            toggle(shell)
            let plan = try XCTUnwrap(shell.spacePlan)
            let card = try XCTUnwrap(plan.rows.last?.cards.first)
            let window = try XCTUnwrap(shell.window)
            let click = try XCTUnwrap(NSEvent.mouseEvent(
                with: .leftMouseDown, location: plan.convert(NSPoint(x: card.midX, y: card.midY), to: nil), modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ))
            let content = try XCTUnwrap(window.contentView)
            XCTAssertIdentical(content.hitTest(content.convert(click.locationInWindow, from: nil)), plan, "the plan takes the click")
            plan.mouseDown(with: click)
            XCTAssertNil(shell.spacePlan)
            XCTAssertIdentical(shell.activeWorkspace, workspaces.last)
            XCTAssertEqual(workspaces.last?.focusedIndex, 0)
        }
    }

    /// A change to what the plan shows closes it, which would show what no
    /// longer is: a move, a new size, a workspace it doesn't list. A layout
    /// that changes nothing, or a new name, leaves it. Closed by a layout,
    /// it gives the keyboard back to the column on screen. An empty space
    /// has no plan.
    func testAChangeToWhatItShowsClosesThePlan() throws {
        try withWorkspaces { shell, workspaces in
            toggle(shell)
            shell.relayout(animated: false)
            XCTAssertNotNil(shell.spacePlan, "a layout that changes nothing")
            workspaces[0].title = "renamed"
            shell.relayout(animated: true)
            XCTAssertNotNil(shell.spacePlan, "a new name")
            let onScreen = try XCTUnwrap(shell.activeWorkspace)
            shell.focusColumn(onScreen.focusedIndex == 0 ? .right : .left)
            XCTAssertNil(shell.spacePlan, "a move")
            XCTAssertEqual(shell.verticalStrip.alphaValue, 1)

            toggle(shell)
            shell.setFrameSize(NSSize(width: shell.frame.width - 100, height: shell.frame.height))
            shell.relayout(animated: false)
            XCTAssertNil(shell.spacePlan, "a new size")
            let focused = try XCTUnwrap(onScreen.columns[safe: onScreen.focusedIndex])
            XCTAssertTrue((shell.window?.firstResponder as? NSView)?.isDescendant(of: focused.view) == true, "the keyboard back")

            toggle(shell)
            shell.addWorkspace(title: "background", cwd: NSTemporaryDirectory(), activate: false)
            shell.relayout(animated: false)
            XCTAssertNil(shell.spacePlan, "a workspace it doesn't list")

            shell.workspaceStore.createProfile(named: "Empty", select: true)
            shell.relayout(animated: false)
            toggle(shell)
            XCTAssertNil(shell.spacePlan, "an empty space")
        }
    }

    /// Fingers closing on the work past a quarter of their span, within one
    /// pinch, show the plan, closing on while its workspaces draw; opening
    /// them in it goes to the card under them, else to the chosen one.
    func testAPinchShowsThePlanAndAnotherGoesToTheCardUnderIt() throws {
        try withWorkspaces { shell, workspaces in
            shell.pinched(by: -0.2, began: true)
            shell.pinched(by: -0.1, began: true)
            XCTAssertTrue(shell.planDrawing.isEmpty, "not that far within one pinch")
            shell.pinched(by: -0.2, began: false)
            shell.pinched(by: -0.1, began: false)
            settle(shell)
            let plan = try XCTUnwrap(shell.spacePlan, "past a quarter, closing on")

            plan.pinched(by: 0.1, began: true, at: .zero)
            XCTAssertNotNil(shell.spacePlan, "not that far")
            let card = try XCTUnwrap(plan.rows.last?.cards.first)
            plan.pinched(by: 0.2, began: false, at: NSPoint(x: card.midX, y: card.midY))
            XCTAssertNil(shell.spacePlan)
            XCTAssertIdentical(shell.activeWorkspace, workspaces.last, "the card under the fingers")

            shell.pinched(by: -0.3, began: true)
            settle(shell)
            let again = try XCTUnwrap(shell.spacePlan)
            again.keyDown(with: try Self.key(126))
            let chosen = again.rows[again.chosen.row].workspaceID
            XCTAssertNotEqual(chosen, workspaces.last?.id)
            again.pinched(by: 0.3, began: true, at: .zero)
            XCTAssertEqual(shell.activeWorkspace?.id, chosen, "away from any card, the chosen one")
        }
    }

    /// However many workspaces, every row shows whole; one closing has none.
    /// An archived one reads as the rail would show it.
    func testEveryRowShowsHoweverManyWorkspaces() throws {
        try withWorkspaces { shell, workspaces in
            shell.window?.setContentSize(NSSize(width: 1200, height: 320))
            for index in 0..<7 { shell.addWorkspace(title: "more \(index)", cwd: NSTemporaryDirectory(), activate: false) }
            let closing = try XCTUnwrap(shell.workspaces.last)
            closing.isClosing = true
            workspaces[2].isInactive = true
            shell.relayout(animated: false)
            shell.updateSidebar(snapshot: ProcessSnapshot())
            toggle(shell)
            let plan = try XCTUnwrap(shell.spacePlan)
            let listed = shell.visibleWorkspaceIndices.map { shell.workspaces[$0] }.filter { !$0.isClosing }
            XCTAssertEqual(plan.rows.map(\.workspaceID), listed.map(\.id), "every one but the one closing")
            XCTAssertGreaterThan(listed.count, 8)
            XCTAssertTrue(plan.rows.allSatisfy { plan.bounds.contains($0.picture.frame) }, "each whole")
            let icons = plan.subviews.compactMap { $0 as? StateIconView }
            XCTAssertEqual(icons.filter { $0.label != nil }.count, plan.rows.count, "each with its initials, as the rail names it")
        }
    }

    /// ⌥⌘→ or a new workspace closes the plan before freezing what shows:
    /// the work leaves, not the plan over it.
    func testASpaceSwitchOrANewWorkspaceLeavesThePlanOutOfItsPicture() throws {
        try withWorkspaces { shell, _ in
            let first = shell.activeProfileID
            shell.workspaceStore.createProfile(named: "Second", select: true)
            shell.addWorkspace(title: "second space", cwd: NSTemporaryDirectory())
            shell.selectProfile(first)
            shell.relayout(animated: false)
            shell.sideEffects.reducesMotion = { false }
            shell.agentLights.isDisplayAsleep = false
            shell.animatesInterface = true

            toggle(shell)
            var ring = Theme.Radius.column * (try XCTUnwrap(shell.spacePlan)).scale + 4
            shell.focusSpace(.next)
            XCTAssertNil(shell.spacePlan)
            let leaving = try XCTUnwrap(shell.crossingPictures.first)
            XCTAssertFalse(Self.holdsRing(leaving.content, radius: ring), "the work leaves, not the plan")

            shell.selectProfile(first)
            shell.relayout(animated: false)
            toggle(shell)
            ring = Theme.Radius.column * (try XCTUnwrap(shell.spacePlan)).scale + 4
            shell.addWorkspace(title: "new", cwd: NSTemporaryDirectory())
            XCTAssertNil(shell.spacePlan)
            let slide = try XCTUnwrap(shell.viewport.subviews.compactMap { $0 as? FrozenView }.first)
            XCTAssertFalse(Self.holdsRing(slide.content, radius: ring), "nor under a new workspace")
        }
    }

    /// Every workspace the plan lists draws once before it shows: their
    /// terminals rested off screen. Asked again meanwhile, or with a
    /// workspace that didn't draw, it doesn't show.
    func testEveryListedWorkspaceDrawsOnceBeforeThePlanShows() throws {
        try withWorkspaces { shell, workspaces in
            var drawing: [ObjectIdentifier: Bool] = [:]
            shell.sideEffects.setSurfaceVisible = { column, visible in drawing[ObjectIdentifier(column)] = visible }
            shell.toggleSpacePlan()
            XCTAssertNil(shell.spacePlan, "not yet")
            XCTAssertTrue(workspaces.flatMap(\.columns).allSatisfy { drawing[ObjectIdentifier($0)] == true }, "every listed workspace draws")
            XCTAssertEqual(steps?.durations, [NiruxShellView.arrivalDelay])
            steps?.runNext()
            XCTAssertNotNil(shell.spacePlan, "once they drew")
            XCTAssertTrue(workspaces.flatMap(\.columns).allSatisfy { drawing[ObjectIdentifier($0)] == false })
            toggle(shell)

            shell.toggleSpacePlan()
            shell.toggleSpacePlan()
            steps?.runNext()
            XCTAssertNil(shell.spacePlan, "asked again meanwhile, it doesn't show")
            let onScreen = try XCTUnwrap(shell.activeWorkspace)
            XCTAssertTrue(workspaces.filter { $0 !== onScreen }.flatMap(\.columns).allSatisfy { drawing[ObjectIdentifier($0)] == false })

            shell.toggleSpacePlan()
            shell.addWorkspace(title: "fourth", cwd: NSTemporaryDirectory(), activate: false)
            steps?.runNext()
            XCTAssertNil(shell.spacePlan, "a workspace that didn't draw")
            XCTAssertTrue(shell.planDrawing.isEmpty)
        }
    }

    // MARK: - Helpers

    /// Whether `layer` or one under it is the plan's ring, by its width and radius.
    private static func holdsRing(_ layer: CALayer, radius: CGFloat) -> Bool {
        (layer.borderWidth == 2 && abs(layer.cornerRadius - radius) < 0.01) || (layer.sublayers ?? []).contains { holdsRing($0, radius: radius) }
    }

    /// The shell's timed steps, held (see `TimedSteps`).
    private var steps: TimedSteps?

    /// ⌥⌘↑, its drawing step run when the plan comes.
    private func toggle(_ shell: NiruxShellView) {
        shell.toggleSpacePlan()
        settle(shell)
    }

    /// The steps held until the plan shows, once its workspaces drew.
    private func settle(_ shell: NiruxShellView) {
        while !shell.planDrawing.isEmpty, steps?.runNext() == true {}
    }

    private static func key(_ code: UInt16) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code
        ))
    }

    /// Three workspaces in the space (three, two and one half columns), the
    /// middle one on screen; nothing moves, so no floors play.
    private func withWorkspaces(_ body: (NiruxShellView, [WorkspaceState]) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nirux-plan-\(UUID().uuidString)").path
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
            shell.sideEffects.reducesMotion = { true }
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = shell
            window.orderFront(nil)
            defer { window.close() }
            let first = try XCTUnwrap(shell.activeWorkspace)
            shell.addWorkspace(title: "second", cwd: NSTemporaryDirectory())
            let second = try XCTUnwrap(shell.activeWorkspace)
            shell.addWorkspace(title: "third", cwd: NSTemporaryDirectory())
            let third = try XCTUnwrap(shell.activeWorkspace)
            for (workspace, count) in [(first, 3), (second, 2), (third, 1)] {
                while workspace.columns.count < count { workspace.addColumn() }
                for column in workspace.columns { column.widthFraction = 0.5 }
            }
            shell.switchToWorkspace(try XCTUnwrap(shell.workspaces.firstIndex { $0 === second }))
            shell.relayout(animated: false)
            let listed = shell.visibleWorkspaceIndices.map { shell.workspaces[$0] }
            XCTAssertEqual(listed.map(\.id), [first, second, third].map(\.id))
            steps = TimedSteps(on: shell)
            try body(shell, listed)
        }
    }
}
