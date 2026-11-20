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
                shell.toggleSpacePlan()
                harness.waitUntil("the plan") { shell.spacePlan != nil }
                XCTAssertIdentical(harness.window.firstResponder, shell.spacePlan, "it holds the keyboard")
                for key in [UIFlowHarness.Key.down, .returnKey, .escape] { harness.press(key, in: harness.window) }
                shell.toggleSpacePlan()
                XCTAssertNil(shell.spacePlan)
                harness.press("x", keyCode: 0x07, [])
                harness.waitUntil("the key typed after it") { standIn.input.contains("x") }
                XCTAssertEqual(standIn.input, "x", "none of the plan's keys")
            }
        }
    }
}
