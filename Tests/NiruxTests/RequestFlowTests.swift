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

    /// While the interface may move, the inbox comes out of the bar's badge
    /// and goes back into it, and a callout out of its rail icon, fading as
    /// a window. Whole on time: opaque, with its window's shadow. Going, it
    /// takes no click and no key. Shown again while it goes, it stays; its
    /// last growth's ends no longer apply. With Reduce motion, it shows
    /// whole and goes at once.
    func testPanelsComeOutOfTheirControlAndGoBack() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let (_, there) = try self.prepare(harness)
            self.fold(shell)
            shell.sideEffects.reducesMotion = { false }
            shell.agentLights.isDisplayAsleep = false
            shell.animatesInterface = true
            shell.updateSidebar()
            @MainActor func start(of panel: NSPanel, from control: NSView) throws -> Bool {
                let grow = try XCTUnwrap(panel.contentView?.layer?.animation(forKey: PanelGrowth.key) as? CABasicAnimation)
                let source = try XCTUnwrap(NiruxShellView.screenRect(of: control))
                let expected = CommandPalette.unfoldStart(from: PanelGrowth.origin(of: source, in: panel.frame), scale: PanelGrowth.scale)
                return CATransform3DEqualToTransform(try XCTUnwrap(grow.fromValue as? NSValue).caTransform3DValue, CATransform3DMakeAffineTransform(expected))
            }

            // xctest shows no toolbar: the badge has no window, and the inbox
            // fades in where it hangs (`testAPanelGrowsFromTheEdgeNearestItsControl`
            // places a badge).
            shell.openInbox()
            let inbox = try XCTUnwrap(shell.requestsState.inboxPanel?.panel)
            XCTAssertEqual(inbox.alphaValue, 0, "it fades in")
            XCTAssertFalse(inbox.hasShadow, "its shadow once whole")
            harness.waitUntil("whole") { inbox.alphaValue == 1 && inbox.hasShadow }

            shell.closeInbox()
            XCTAssertFalse(shell.requestsState.isInboxOpen)
            XCTAssertTrue(inbox.isVisible, "going back into the badge")
            XCTAssertTrue(inbox.ignoresMouseEvents)
            XCTAssertFalse(inbox.canBecomeKey, "the keyboard back behind it at once")
            XCTAssertFalse(inbox.isKeyWindow)
            shell.openInbox()
            XCTAssertTrue(inbox.canBecomeKey)
            harness.waitUntil("the reopened inbox is whole") { inbox.hasShadow && inbox.alphaValue == 1 }
            XCTAssertTrue(inbox.isVisible, "shown again while it went, it stays")
            XCTAssertTrue(inbox.alphaValue == 1 && inbox.hasShadow)

            // Its growth's end, due while it goes, waits for nothing.
            shell.closeInbox()
            shell.openInbox()
            shell.closeInbox()
            let rail = shell.sidebar.iconRail
            let icon = try XCTUnwrap(rail.itemViews[there.id])
            harness.waitUntil("the request icon is on screen") { NiruxShellView.screenRect(of: icon) != nil }
            rail.onRequest?(there.id, icon)
            let callout = try XCTUnwrap(shell.requestsState.calloutPanel?.panel)
            XCTAssertTrue(try start(of: callout, from: icon), "out of its icon")
            // This growth was scheduled after the inbox's last growth.
            harness.waitUntil("the callout is whole") { callout.hasShadow && callout.alphaValue == 1 }
            XCTAssertFalse(inbox.isVisible)
            XCTAssertFalse(inbox.hasShadow, "no shadow came while it went")

            // The callout closes after the inbox starts closing. Once it is
            // gone, the old close of the reopened inbox has also fallen due.
            shell.openInbox()
            rail.onRequest?(there.id, icon)
            XCTAssertFalse(shell.requestsState.isInboxOpen)
            shell.closeCallout()
            shell.sideEffects.reducesMotion = { true }
            shell.openInbox()
            XCTAssertNil(inbox.contentView?.layer?.animation(forKey: PanelGrowth.key))
            XCTAssertTrue(inbox.alphaValue == 1 && inbox.hasShadow, "its shadow at once")
            harness.waitUntil("the callout gone") { !callout.isVisible }
            XCTAssertTrue(inbox.isVisible)
            shell.closeInbox()
            XCTAssertFalse(inbox.isVisible, "at once")
        }
    }

    /// An icon scrolled out of the rail is no source: the callout fades
    /// rather than going back into nothing.
    func testAControlOutOfSightIsNoSource() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let (_, there) = try self.prepare(harness)
            self.fold(shell)
            shell.updateSidebar()
            let icon = try XCTUnwrap(shell.sidebar.iconRail.itemViews[there.id])
            harness.waitUntil("its icon laid out in the rail") { NiruxShellView.screenRect(of: icon) != nil }
            let list = try XCTUnwrap(icon.superview)
            let out = NSView(frame: NSRect(x: 0, y: list.bounds.maxY + 400, width: 20, height: 20))
            list.addSubview(out)
            XCTAssertNotNil(out.rectOnScreen)
            XCTAssertNil(NiruxShellView.screenRect(of: out))
        }
    }

    /// A panel grows from the point of its edge nearest its control: a badge
    /// above it, its top edge; an icon at its left, its left edge.
    func testAPanelGrowsFromTheEdgeNearestItsControl() {
        let panel = NSRect(x: 100, y: 100, width: 400, height: 300)
        XCTAssertEqual(PanelGrowth.origin(of: NSRect(x: 300, y: 410, width: 60, height: 22), in: panel), NSPoint(x: 230, y: 300))
        XCTAssertEqual(PanelGrowth.origin(of: NSRect(x: 60, y: 200, width: 28, height: 28), in: panel), NSPoint(x: 0, y: 114))
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
