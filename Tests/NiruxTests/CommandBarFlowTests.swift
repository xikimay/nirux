import AppKit
import XCTest
@testable import Nirux

/// The command bar in the window (docs/design/glass-interface.md, step 3.1):
/// what it follows, and where each segment goes.
@MainActor
final class CommandBarFlowTests: XCTestCase {
    /// It shows the space and the task on screen; an empty space says
    /// "Nothing open"; it counts an agent waiting for the user in another
    /// space, and once there shows that task's request in its icon.
    func testTheBarFollowsWhatIsOnScreen() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            shell.installCommandBar(in: harness.window)
            let bar = try XCTUnwrap(shell.commandBarToolbar?.bar)
            let task = try XCTUnwrap(shell.activeWorkspace)
            shell.updateSidebar()
            XCTAssertEqual(bar.spaceLabel.stringValue, shell.workspaceStore.activeProfile.name)
            XCTAssertEqual(bar.taskLabel.stringValue, task.title)
            XCTAssertTrue(bar.waitingBadge.isHidden, "nothing waits")

            let work = shell.workspaceStore.createProfile(named: "Work", select: false)
            shell.moveWorkspaceToSpace(workspaceID: task.id, profileID: work.id)
            let pty = try XCTUnwrap(task.columns.first?.pty)
            let now = Date().timeIntervalSince1970
            _ = pty.applyAgentHook(AgentHookEvent(kind: .claude, name: .userPromptSubmit, sessionID: "s", timestamp: now - 5), isUserFocused: false)
            _ = pty.applyAgentHook(AgentHookEvent(
                kind: .claude, name: .permissionRequest, sessionID: "s", detail: "Bash", toolName: "Bash", toolKey: "b", timestamp: now
            ), isUserFocused: false)
            shell.updateSidebar()
            XCTAssertEqual(bar.taskLabel.stringValue, "Nothing open")
            XCTAssertFalse(bar.waitingBadge.isHidden, "an agent waits in another space")
            XCTAssertEqual(bar.waitingBadge.count, 1)

            shell.selectProfile(work.id)
            shell.updateSidebar()
            XCTAssertEqual(bar.spaceLabel.stringValue, "Work")
            XCTAssertEqual(bar.taskLabel.stringValue, task.title)
            XCTAssertEqual(bar.taskIcon.icon, StateIcon(.needsYou(.command)))
            XCTAssertEqual(bar.waitingBadge.count, 1, "the same agent, now on screen")
        }
    }

    /// The space segment opens the space menu under it, the task segment the
    /// task's menu, the search ⌘P under the bar (a press on it while ⌘P
    /// shows closes it), the count ⌘J.
    func testEachSegmentReachesTheShell() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            var popped: [(NSMenu, NSView)] = []
            shell.sideEffects.popUpMenu = { menu, _, view in popped.append((menu, view)) }
            shell.sideEffects.windowShows = { _ in true }
            shell.installCommandBar(in: harness.window)
            let bar = try XCTUnwrap(shell.commandBarToolbar?.bar)
            harness.window.contentView?.superview?.layoutSubtreeIfNeeded()
            shell.updateSidebar()

            bar.spaceButton.performClick(nil)
            XCTAssertTrue(popped.last?.1 === bar.spaceButton)
            XCTAssertTrue(popped.last?.0.items.contains { $0.title == SidebarView.newSpaceTitle } == true, "the space menu")
            bar.taskButton.performClick(nil)
            XCTAssertTrue(popped.last?.1 === bar.taskButton)
            XCTAssertFalse(popped.last?.0.items.isEmpty ?? true, "the task's menu")

            bar.searchButton.performClick(nil)
            let palette = try XCTUnwrap(shell.commandPalette)
            XCTAssertTrue(palette.isVisible)
            XCTAssertNotNil(palette.glass, "under the bar, on glass")
            XCTAssertFalse(palette.glass?.isHidden ?? true)
            @MainActor func press(_ type: NSEvent.EventType) throws -> NSEvent {
                let frame = bar.searchButton.convert(bar.searchButton.bounds, to: nil)
                return try XCTUnwrap(NSEvent.mouseEvent(
                    with: type, location: NSPoint(x: frame.midX, y: frame.midY), modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: harness.window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1
                ))
            }
            XCTAssertTrue(CommandPalette.isSearchButtonPress(try press(.leftMouseDown)))
            // The release queued first: a button that took the press would
            // end its tracking on it (and open the palette again).
            NSApp.postEvent(try press(.leftMouseUp), atStart: false)
            NSApp.sendEvent(try press(.leftMouseDown))
            while let queued = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) {
                NSApp.sendEvent(queued)
            }
            XCTAssertFalse(palette.isVisible, "pressed while it showed: closed, not opened again")

            bar.waitingButton.performClick(nil)
            XCTAssertEqual(shell.quickSwitch.hint?.text, NiruxShellView.noWaitingAgentHint, "⌘J, with nobody waiting")
        }
    }
}
