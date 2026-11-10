import AppKit
import XCTest
@testable import Nirux

/// Only the space on screen is laid out: a terminal whose shell starts in
/// another one gets the size it will have on screen all the same, so it has
/// a surface that parses what it prints at once (see
/// `NiruxShellView.sizeTerminalOffScreen`).
@MainActor
final class HiddenSpaceTerminalTests: XCTestCase {
    /// A task its Lead starts while the user views another space.
    func testATerminalStartedInAnotherSpaceParsesWhatItPrints() throws {
        try UIFlowHarness.run { harness in
            let (_, task) = try Self.hiddenTask(in: harness)
            let session = try XCTUnwrap(task.columns.first?.pty?.terminalSession)

            session.receive("printed in another space\r\n")
            harness.waitUntil("the text in the hidden terminal") {
                TerminalScreenText.read(session)?.contains("printed in another space") == true
            }
        }
    }

    /// An agent waiting to resume runs nothing, so it gets no size off
    /// screen; once its shell starts there (Resume All Agents), it does.
    func testAnAgentResumedInAnotherSpaceGetsASurface() throws {
        try UIFlowHarness.run { harness in
            let (shell, task) = try Self.hiddenTask(in: harness)
            task.addColumn(
                deferredAgent: DeferredAgentLaunch(agent: .claude(resume: .session("s1"), mode: .default), title: nil, lastStatus: nil),
                agentUUID: UUID().uuidString, cwd: harness.repo
            )
            let column = try XCTUnwrap(task.columns.first(where: \.isAwaitingResume))
            shell.relayout(animated: false)
            XCTAssertTrue(column.view.frame.isEmpty)

            // A real shell start, running nothing an agent would.
            shell.sideEffects.startRestoredAgent = { column, _ in column.startShell(command: "true") }
            XCTAssertTrue(shell.resumeAllDeferredAgents())
            harness.waitUntil("the resumed agent's surface") { column.hasSurface }
        }
    }

    /// A hidden terminal follows the window's size, as its PTY would on
    /// screen; the workspace's other columns aren't laid out off screen.
    func testOnlyHiddenTerminalsAreSizedAndTheyFollowTheWindow() throws {
        try UIFlowHarness.run { harness in
            let (_, task) = try Self.hiddenTask(in: harness)
            task.addColumn(webViewURL: "about:blank")
            let terminal = try XCTUnwrap(task.columns.first { $0.terminalView != nil })
            let browser = try XCTUnwrap(task.columns.first { $0.webViewColumn != nil })
            harness.waitUntil("the hidden terminal's surface") { terminal.hasSurface }
            let width = terminal.view.frame.width
            XCTAssertTrue(browser.view.frame.isEmpty)

            harness.window.setContentSize(NSSize(width: harness.window.frame.width - 300, height: harness.window.frame.height))
            harness.waitUntil("the hidden terminal narrower") { terminal.view.frame.width < width }
            XCTAssertTrue(browser.view.frame.isEmpty)
        }
    }

    /// A task workspace in a space not on screen, whose shell starts 0.5 s
    /// after it opens.
    private static func hiddenTask(in harness: UIFlowHarness) throws -> (NiruxShellView, WorkspaceState) {
        let shell = harness.shell
        let side = shell.workspaceStore.createProfile(named: "side", select: false)
        shell.addWorkspace(title: "task", cwd: harness.repo, profileID: side.id, activate: false)
        XCTAssertNotEqual(shell.activeProfileID, side.id)
        return (shell, try XCTUnwrap(shell.workspaces.first { $0.title == "task" }))
    }
}
