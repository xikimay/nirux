import AppKit
import GhosttyTerminal
import XCTest
@testable import Nirux

/// A closed workspace's terminal goes, and Ghostty's controller and surface
/// with it (the surface is the terminal's own): a closure, observer or list
/// that kept one would keep a renderer, its GPU memory and its threads for
/// as long as Nirux runs.
@MainActor
final class WorkspaceCloseReleaseTests: XCTestCase {
    func testClosingAWorkspaceFreesItsTerminalControllerAndSurface() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            weak var column: ColumnState?
            weak var terminal: TerminalView?
            weak var controller: TerminalController?
            // Out of the test's own autorelease pool, which drains only once
            // the test ends.
            try autoreleasepool {
                shell.addWorkspace(title: "closing", cwd: harness.repo, activate: false)
                let first = try XCTUnwrap(shell.workspaces.first { $0.title == "closing" }?.columns.first)
                column = first
                terminal = first.terminalView
                controller = first.terminalView?.controller
            }
            harness.waitUntil("the terminal's surface") { column?.hasSurface == true }

            // From the run loop, as a click closes it: its pool drains there.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let index = shell.workspaces.firstIndex(where: { $0.title == "closing" }) else { return }
                    shell.closeWorkspace(at: index)
                }
            }
            harness.waitUntil("the closed workspace's terminal and controller freed") {
                column == nil && terminal == nil && controller == nil
            }
        }
    }
}
