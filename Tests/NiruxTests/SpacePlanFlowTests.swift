import AppKit
import XCTest
@testable import Nirux

/// Depth study P5's plan through the app's own key monitor (UIFlowHarness):
/// while it shows, no key reaches the terminal under it.
@MainActor
final class SpacePlanFlowTests: XCTestCase {
    /// ↓, Return and Escape with the plan up type nothing into the hidden
    /// Claude, which a key typed once the plan went reaches. (The test
    /// process has no key window: what the monitor leaves to AppKit reaches
    /// no view here; SpacePlanTests drives the plan's own keys.)
    func testThePlansKeysNeverReachTheTerminalUnderIt() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let standIn = AgentStandIn()
            defer { standIn.remove() }
            let workspace = try XCTUnwrap(shell.activeWorkspace)
            workspace.addColumn(command: standIn.command(), agentUUID: UUID().uuidString, cwd: harness.repo)
            let column = try XCTUnwrap(workspace.columns.last)
            let pty = try XCTUnwrap(column.pty)
            harness.waitUntil("its claude") { pty.foregroundProcess(snapshot: ProcessSnapshot())?.name == "claude" }
            shell.addWorkspace(title: "other", cwd: harness.repo)
            shell.switchToWorkspace(try XCTUnwrap(shell.workspaces.firstIndex { $0 === workspace }), column: workspace.columns.count - 1)

            try harness.withApp {
                harness.press("a", keyCode: 0x00, [])
                harness.waitUntil("the terminal takes keys before the plan") { standIn.input.hasSuffix("a") }
                let beforePlan = standIn.input
                shell.toggleSpacePlan()
                harness.waitUntil("the plan") { shell.spacePlan != nil }
                XCTAssertIdentical(harness.window.firstResponder, shell.spacePlan, "it holds the keyboard")
                for key in [UIFlowHarness.Key.down, .returnKey, .escape] { harness.press(key, in: harness.window) }
                shell.toggleSpacePlan()
                harness.waitUntil("the plan gone") { shell.spacePlan == nil }
                harness.press("x", keyCode: 0x07, [])
                harness.waitUntil("the key typed after it") { standIn.input.contains("x") }
                XCTAssertEqual(standIn.input, beforePlan + "x", "none of the plan's keys")
            }
        }
    }

    /// As a dive starts, the column it goes to holds the keyboard, and a
    /// key typed during the dive reaches its terminal through the monitor.
    func testADivesKeysGoToTheColumnItGoesTo() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let standIn = AgentStandIn()
            defer { standIn.remove() }
            let workspace = try XCTUnwrap(shell.activeWorkspace)
            workspace.addColumn(command: standIn.command(), agentUUID: UUID().uuidString, cwd: harness.repo)
            let column = try XCTUnwrap(workspace.columns.last)
            let pty = try XCTUnwrap(column.pty)
            harness.waitUntil("its claude") { pty.foregroundProcess(snapshot: ProcessSnapshot())?.name == "claude" }
            shell.addWorkspace(title: "other", cwd: harness.repo)
            shell.switchToWorkspace(try XCTUnwrap(shell.workspaces.firstIndex { $0 === workspace }), column: workspace.columns.count - 1)
            shell.sideEffects.reducesMotion = { false }
            shell.sideEffects.windowShows = { _ in true }
            shell.agentLights.isDisplayAsleep = false
            shell.animatesInterface = true

            try harness.withApp {
                shell.toggleSpacePlan()
                harness.waitUntil("the plan") { shell.spacePlan != nil }
                let plan = try XCTUnwrap(shell.spacePlan)
                plan.keyDown(with: try XCTUnwrap(NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: harness.window.windowNumber,
                    context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 0x24
                )))
                XCTAssertTrue(plan.isDiving, "it dives into the card on screen")
                XCTAssertTrue((harness.window.firstResponder as? NSView)?.isDescendant(of: column.view) == true, "its column holds the keyboard")
                harness.press("x", keyCode: 0x07, [])
                harness.waitUntil("the key typed during the dive") { standIn.input.contains("x") }
                harness.waitUntil("the plan gone") { shell.spacePlan == nil }
            }
        }
    }
}
