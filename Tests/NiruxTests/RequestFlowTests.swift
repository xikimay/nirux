import AppKit
import XCTest
@testable import Nirux

/// The requests in the window (docs/design/glass-interface.md, step 3.3):
/// ⌘J and the badge open the inbox while the sidebar is folded and go
/// straight to the task while it is unfolded; an amber rail icon opens its
/// callout.
@MainActor
final class RequestFlowTests: XCTestCase {
    /// Two tasks, the second's agent waiting for a permission (the test's
    /// own wait: a real one needs a `claude` in front), the first on screen.
    private func prepare(_ harness: UIFlowHarness) throws -> (here: WorkspaceState, there: WorkspaceState) {
        let shell = harness.shell
        let here = try XCTUnwrap(shell.activeWorkspace)
        shell.addWorkspace(title: "there", cwd: harness.repo)
        let there = try XCTUnwrap(shell.workspaces.last)
        let waiting = try XCTUnwrap(there.columns.first)
        let since = Date().timeIntervalSince1970 - 120
        shell.quickSwitch.agentWait = { [weak waiting] column, _, _, _ in
            column === waiting ? AgentWait(reason: .permission(tool: "Bash", summary: "npm test"), since: since) : nil
        }
        shell.focusWorkspace(id: here.id)
        shell.installCommandBar(in: harness.window)
        // A test's window may be covered by another process's: the inbox
        // opens only over a window that shows.
        shell.sideEffects.windowShows = { _ in true }
        return (here, there)
    }

    private func fold(_ shell: NiruxShellView) {
        if shell.isSidebarExpanded { shell.toggleSidebar() }
        XCTAssertFalse(shell.sidebar.isExpanded)
    }

    /// Folded, ⌘J opens the inbox in a window of its own (the key
    /// interceptor routes only the main window's keys to terminals), the
    /// request chosen; ⌘J again goes to its task. The badge does what ⌘J
    /// does; ⌘. closes the inbox; the inbox closes once no request is left.
    /// (xctest has no key window: giving the keyboard back can't be seen
    /// here.)
    func testFoldedTheInboxOpensAndJGoesOn() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let (here, there) = try self.prepare(harness)
            self.fold(shell)
            shell.updateSidebar()
            XCTAssertEqual(shell.requestsState.requests.map(\.taskID), [there.id])
            XCTAssertEqual(try XCTUnwrap(shell.commandBarToolbar?.bar).waitingBadge.count, 1, "the badge counts it")
            shell.jumpToNextWaitingAgent()
            XCTAssertTrue(shell.requestsState.isInboxOpen, "folded: the inbox")
            let inbox = try XCTUnwrap(shell.requestsState.inbox)
            XCTAssertEqual(inbox.chosenRequest?.taskID, there.id)
            XCTAssertEqual(inbox.chosenRequest?.kind, .terminal("Bash: npm test"))
            XCTAssertFalse(inbox.window === harness.window, "a window of its own")
            XCTAssertTrue(inbox.window?.firstResponder === inbox, "it has the keyboard")
            XCTAssertIdentical(shell.activeWorkspace, here, "nothing moved yet")
            shell.jumpToNextWaitingAgent()
            XCTAssertFalse(shell.requestsState.isInboxOpen)
            XCTAssertIdentical(shell.activeWorkspace, there, "⌘J again: the chosen task")

            shell.focusWorkspace(id: here.id)
            let bar = try XCTUnwrap(shell.commandBarToolbar?.bar)
            bar.waitingButton.performClick(nil)
            XCTAssertTrue(shell.requestsState.isInboxOpen, "the badge: as ⌘J")
            inbox.cancelOperation(nil)
            XCTAssertFalse(shell.requestsState.isInboxOpen)

            shell.jumpToNextWaitingAgent()
            XCTAssertTrue(shell.requestsState.isInboxOpen)
            shell.quickSwitch.agentWait = { _, _, _, _ in nil }
            shell.updateSidebar()
            XCTAssertFalse(shell.requestsState.isInboxOpen, "no request left")
        }
    }

    /// Unfolded, the requests stay in the rows: ⌘J and the badge go
    /// straight to the task.
    func testUnfoldedJGoesStraightToTheTask() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let (here, there) = try self.prepare(harness)
            if !shell.isSidebarExpanded { shell.toggleSidebar() }
            harness.waitUntil("the sidebar to unfold") { shell.sidebar.isExpanded }
            shell.jumpToNextWaitingAgent()
            XCTAssertFalse(shell.requestsState.isInboxOpen)
            XCTAssertIdentical(shell.activeWorkspace, there)
            shell.focusWorkspace(id: here.id)
            try XCTUnwrap(shell.commandBarToolbar?.bar).waitingButton.performClick(nil)
            XCTAssertFalse(shell.requestsState.isInboxOpen)
            XCTAssertIdentical(shell.activeWorkspace, there, "the badge too")
        }
    }

    /// Folded, an amber icon's click opens its task's request beside it;
    /// ⌘J over it opens the inbox instead; "Open task" goes to the task; an
    /// icon whose task asks nothing goes to the task at once.
    func testAnAmberIconOpensItsCallout() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let (here, there) = try self.prepare(harness)
            self.fold(shell)
            shell.updateSidebar()
            let rail = shell.sidebar.iconRail
            let icon = try XCTUnwrap(rail.itemViews[there.id])
            rail.onRequest?(there.id, icon)
            XCTAssertTrue(shell.requestsState.isCalloutOpen)
            let callout = try XCTUnwrap(shell.requestsState.callout)
            XCTAssertEqual(callout.request?.taskID, there.id)
            let iconOnScreen = harness.window.convertToScreen(icon.convert(icon.bounds, to: nil))
            XCTAssertGreaterThan(try XCTUnwrap(callout.window).frame.minX, iconOnScreen.maxX, "beside its icon")

            shell.jumpToNextWaitingAgent()
            XCTAssertFalse(shell.requestsState.isCalloutOpen)
            XCTAssertTrue(shell.requestsState.isInboxOpen, "⌘J over the callout: the inbox")
            shell.closeInbox()

            rail.onRequest?(there.id, icon)
            XCTAssertTrue(shell.requestsState.isCalloutOpen)
            rail.onRequest?(there.id, icon)
            XCTAssertFalse(shell.requestsState.isCalloutOpen, "its own icon again: it closes")
            rail.onRequest?(there.id, icon)
            callout.onOpenTask?(try XCTUnwrap(callout.request))
            XCTAssertFalse(shell.requestsState.isCalloutOpen)
            XCTAssertIdentical(shell.activeWorkspace, there, "Open task")

            shell.focusWorkspace(id: there.id)
            shell.updateSidebar()
            let hereIcon = try XCTUnwrap(rail.itemViews[here.id])
            rail.onRequest?(here.id, hereIcon)
            XCTAssertFalse(shell.requestsState.isCalloutOpen, "nothing to show")
            XCTAssertIdentical(shell.activeWorkspace, here, "the task, at once")
        }
    }
}
