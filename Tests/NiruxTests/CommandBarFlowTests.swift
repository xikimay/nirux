import AppKit
import XCTest
@testable import Nirux

/// The command bar in the window (docs/design/glass-interface.md, step 3.1):
/// what it follows, and where each segment goes.
@MainActor
final class CommandBarFlowTests: XCTestCase {
    /// It shows the space and the task on screen; an empty space says
    /// "Nothing open"; it counts an agent waiting for the user in another
    /// space, as ⌘J reaches it (a claude in front of its shell, its dialog
    /// on screen); once that task is on screen it shows the request in its
    /// icon, and the count leaves out the column on screen, as ⌘J does.
    func testTheBarFollowsWhatIsOnScreen() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            shell.installCommandBar(in: harness.window)
            let bar = try XCTUnwrap(shell.commandBarToolbar?.bar)
            let task = try XCTUnwrap(shell.activeWorkspace)
            @MainActor func refresh(_ snapshot: ProcessSnapshot? = nil) {
                shell.updateSidebar(snapshot: snapshot)
                bar.layoutSubtreeIfNeeded()
            }
            refresh()
            XCTAssertEqual(bar.spaceLabel.stringValue, shell.workspaceStore.activeProfile.name)
            XCTAssertEqual(bar.taskLabel.stringValue, task.title)
            XCTAssertTrue(bar.waitingBadge.isHidden, "nothing waits")

            let home = shell.activeProfileID
            let work = shell.workspaceStore.createProfile(named: "Work", select: false)
            shell.moveWorkspaceToSpace(workspaceID: task.id, profileID: work.id)
            shell.selectProfile(home)
            let pty = try XCTUnwrap(task.columns.first?.pty)
            harness.waitUntil("the task's shell") { pty.shellPID != nil }
            let shellPID = try XCTUnwrap(pty.shellPID)
            let now = Date().timeIntervalSince1970
            let claudePID: pid_t = 99_999
            let snapshot = ProcessSnapshot(entries: [
                ProcessSnapshot.Entry(
                    pid: shellPID, parentPID: 1, processGroupID: shellPID, terminalForegroundProcessGroupID: claudePID,
                    name: "zsh", startedAt: now - 8_000, arguments: ["zsh"]
                ),
                ProcessSnapshot.Entry(
                    pid: claudePID, parentPID: shellPID, processGroupID: claudePID, terminalForegroundProcessGroupID: claudePID,
                    name: "claude", startedAt: now - 7_200, arguments: ["claude"]
                ),
            ])
            for (name, offset) in [(AgentHookEvent.Name.sessionStart, 7_000.0), (.userPromptSubmit, 6_900), (.permissionRequest, 60)] {
                pty.applyAgentHook(AgentHookEvent(
                    kind: .claude, name: name, sessionID: "s", toolName: name == .permissionRequest ? "Bash" : nil,
                    toolKey: name == .permissionRequest ? "k" : nil, timestamp: now - offset
                ), isUserFocused: false)
            }
            refresh(snapshot)
            XCTAssertEqual(bar.taskLabel.stringValue, "Nothing open")
            XCTAssertFalse(bar.waitingBadge.isHidden, "an agent waits in another space")
            XCTAssertEqual(bar.waitingBadge.count, 1)

            shell.selectProfile(work.id)
            refresh(snapshot)
            XCTAssertEqual(bar.spaceLabel.stringValue, "Work")
            XCTAssertEqual(bar.taskLabel.stringValue, task.title)
            XCTAssertEqual(bar.taskIcon.icon, StateIcon(.needsYou(.command)))
            XCTAssertTrue(bar.waitingBadge.isHidden, "the agent is on screen: ⌘J has nowhere to go")
        }
    }

    /// The space segment opens the space menu under it, the task segment the
    /// task's menu (the New sheet with nothing open), the search ⌘P under
    /// the bar (a press on it while ⌘P shows closes it), the count ⌘J.
    func testEachSegmentReachesTheShell() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            var popped: [(NSMenu, NSView, NSPoint)] = []
            shell.sideEffects.popUpMenu = { menu, point, view in popped.append((menu, view, point)) }
            shell.sideEffects.windowShows = { _ in true }
            shell.installCommandBar(in: harness.window)
            let bar = try XCTUnwrap(shell.commandBarToolbar?.bar)
            harness.window.contentView?.superview?.layoutSubtreeIfNeeded()
            shell.updateSidebar()

            bar.spaceButton.performClick(nil)
            XCTAssertTrue(popped.last?.1 === bar.spaceButton)
            XCTAssertGreaterThanOrEqual(popped.last?.2.y ?? 0, bar.spaceButton.bounds.maxY, "under the segment")
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

            // Nothing open: the task segment starts one.
            let empty = shell.workspaceStore.createProfile(named: "Empty", select: false)
            shell.selectProfile(empty.id)
            shell.updateSidebar()
            bar.taskButton.performClick(nil)
            harness.waitUntil("the New sheet") { shell.newTaskPanel?.panel?.isSheet == true }
        }
    }
}
