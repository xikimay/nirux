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
            shell.toggleSpacePlan()
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

            shell.toggleSpacePlan()
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
            shell.toggleSpacePlan()
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
            shell.toggleSpacePlan()
            let first = try XCTUnwrap(shell.spacePlan)
            first.keyDown(with: try Self.key(126))
            first.keyDown(with: try Self.key(53))
            XCTAssertNil(shell.spacePlan)
            XCTAssertIdentical(shell.activeWorkspace, onScreen, "as it was, wherever the choice moved")
            XCTAssertEqual(onScreen.focusedIndex, focused)

            shell.toggleSpacePlan()
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

    /// A user's move or a new size closes the plan, which would show what no
    /// longer is; a layout that changes nothing leaves it. An empty space
    /// has no plan.
    func testAMoveOrANewSizeClosesThePlan() throws {
        try withWorkspaces { shell, _ in
            shell.toggleSpacePlan()
            shell.relayout(animated: false)
            XCTAssertNotNil(shell.spacePlan, "a layout that changes nothing")
            shell.focusColumn(.right)
            XCTAssertNil(shell.spacePlan, "a move")
            XCTAssertEqual(shell.verticalStrip.alphaValue, 1)

            shell.toggleSpacePlan()
            shell.setFrameSize(NSSize(width: shell.frame.width - 100, height: shell.frame.height))
            shell.relayout(animated: false)
            XCTAssertNil(shell.spacePlan, "a new size")

            shell.workspaceStore.createProfile(named: "Empty", select: true)
            shell.relayout(animated: false)
            shell.toggleSpacePlan()
            XCTAssertNil(shell.spacePlan, "an empty space")
        }
    }

    /// Fingers closing on the work past a quarter of their span, within one
    /// pinch, show the plan; opening them in it goes to the card under them,
    /// else to the chosen one.
    func testAPinchShowsThePlanAndAnotherGoesToTheCardUnderIt() throws {
        try withWorkspaces { shell, workspaces in
            shell.pinched(by: -0.2, began: true)
            shell.pinched(by: -0.1, began: true)
            XCTAssertNil(shell.spacePlan, "not that far within one pinch")
            shell.pinched(by: -0.2, began: false)
            let plan = try XCTUnwrap(shell.spacePlan, "past a quarter")

            plan.pinched(by: 0.1, began: true, at: .zero)
            XCTAssertNotNil(shell.spacePlan, "not that far")
            let card = try XCTUnwrap(plan.rows.last?.cards.first)
            plan.pinched(by: 0.2, began: false, at: NSPoint(x: card.midX, y: card.midY))
            XCTAssertNil(shell.spacePlan)
            XCTAssertIdentical(shell.activeWorkspace, workspaces.last, "the card under the fingers")

            shell.pinched(by: -0.3, began: true)
            let again = try XCTUnwrap(shell.spacePlan)
            again.keyDown(with: try Self.key(126))
            let chosen = again.rows[again.chosen.row].workspaceID
            XCTAssertNotEqual(chosen, workspaces.last?.id)
            again.pinched(by: 0.3, began: true, at: .zero)
            XCTAssertEqual(shell.activeWorkspace?.id, chosen, "away from any card, the chosen one")
        }
    }

    // MARK: - Helpers

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
            try body(shell, listed)
        }
    }
}
