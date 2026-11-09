import AppKit
import XCTest
@testable import Nirux

/// Only the space on screen is laid out: a terminal that runs in another
/// one gets the viewport's size all the same, so it has a surface and what
/// it prints is kept (see `NiruxShellView.sizeRunningTerminalsOffScreen`).
@MainActor
final class HiddenSpaceTerminalTests: XCTestCase {
    /// A task its Lead starts while the user views another space.
    func testATerminalStartedInAnotherSpaceKeepsWhatItPrints() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let side = shell.workspaceStore.createProfile(named: "side", select: false)
            shell.addWorkspace(title: "task", cwd: harness.repo, profileID: side.id, activate: false)
            XCTAssertNotEqual(shell.activeProfileID, side.id)
            let task = try XCTUnwrap(shell.workspaces.first { $0.title == "task" })
            let session = try XCTUnwrap(task.columns.first?.pty?.terminalSession)

            session.receive("printed in another space\r\n")
            harness.waitUntil("the text in the hidden terminal") {
                TerminalScreenText.read(session)?.contains("printed in another space") == true
            }

            // Shown, it keeps its surface, and the text with it.
            let taskIndex = try XCTUnwrap(shell.workspaces.firstIndex { $0 === task })
            shell.switchToWorkspace(taskIndex)
            XCTAssertEqual(shell.activeProfileID, side.id)
            XCTAssertTrue(TerminalScreenText.read(session)?.contains("printed in another space") == true)
        }
    }

    /// An agent waiting to resume prints nothing, so it gets no size off
    /// screen; Resume All Agents starting it there gives it one.
    func testAnAgentResumedInAnotherSpaceGetsASurface() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let side = shell.workspaceStore.createProfile(named: "side", select: false)
            shell.addWorkspace(title: "task", cwd: harness.repo, profileID: side.id, activate: false)
            let task = try XCTUnwrap(shell.workspaces.first { $0.title == "task" })
            task.addColumn(
                deferredAgent: DeferredAgentLaunch(agent: .claude(resume: .session("s1"), mode: .default), title: nil, lastStatus: nil),
                agentUUID: UUID().uuidString, cwd: harness.repo
            )
            let column = try XCTUnwrap(task.columns.first(where: \.isAwaitingResume))
            shell.relayout(animated: false)
            XCTAssertTrue(column.view.frame.isEmpty)

            XCTAssertTrue(shell.resumeAllDeferredAgents())
            XCTAssertEqual(harness.restoredAgentLaunches.count, 1)
            let session = try XCTUnwrap(column.pty?.terminalSession)
            session.receive("printed by the resumed agent\r\n")
            harness.waitUntil("the text in the resumed agent's terminal") {
                TerminalScreenText.read(session)?.contains("printed by the resumed agent") == true
            }
        }
    }
}
