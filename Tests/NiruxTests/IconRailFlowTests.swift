import AppKit
import XCTest
@testable import Nirux

/// The icon rail in the window (docs/design/glass-interface.md, step 3.2):
/// its buttons reach the shell, a narrow window folds the sidebar, and a
/// new task's sheet folds onto its icon.
@MainActor
final class IconRailFlowTests: XCTestCase {
    private func fold(_ shell: NiruxShellView) {
        if shell.isSidebarExpanded { shell.toggleSidebar() }
        XCTAssertFalse(shell.sidebar.isExpanded, "folded")
    }

    private func press(_ round: RailRoundButton) throws {
        func find(_ view: NSView) -> NSButton? { (view as? NSButton) ?? view.subviews.lazy.compactMap(find).first }
        try XCTUnwrap(find(round)).performClick(nil)
    }

    /// The Board opens the space's Board; the archived tasks unfold the
    /// sidebar with the archived list open.
    func testTheRailsButtonsReachTheShell() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            self.fold(shell)
            let rail = shell.sidebar.iconRail
            XCTAssertFalse(rail.isHidden)
            try self.press(rail.boardButton)
            XCTAssertTrue(shell.activeWorkspace?.columns.contains(where: \.isProjectBoard) == true, "the Board opened")

            let repo = try XCTUnwrap(shell.activeWorkspace)
            shell.addWorkspace(title: "parked", cwd: harness.worktree)
            let parked = try XCTUnwrap(shell.activeWorkspace)
            let parkedIndex = try XCTUnwrap(shell.workspaces.firstIndex { $0 === parked })
            harness.perform(["Organize", "Archive"], in: shell.sidebar.workspaceActionMenu(workspaceIndex: parkedIndex, columnIndex: nil))
            shell.switchToWorkspace(try XCTUnwrap(shell.workspaces.firstIndex { $0 === repo }))
            shell.updateSidebar()
            XCTAssertTrue(parked.isInactive)
            XCTAssertEqual(rail.content.archivedCount, 1)
            XCTAssertFalse(rail.content.tasks.contains { $0.id == parked.id }, "folded, the archived list has nowhere to show")

            try self.press(rail.archivedButton)
            XCTAssertTrue(shell.isSidebarExpanded)
            harness.waitUntil("the cards to come in") { shell.sidebar.isExpanded }
            XCTAssertFalse(shell.sidebar.isInactiveSectionCollapsed, "the archived list is open")
            XCTAssertNotNil(shell.sidebar.rowFrame(workspaceID: parked.id), "and lists the archived task")
        }
    }

    /// Below 900 pt the sidebar folds at once, and unfolds back when the
    /// window widens: the saved choice stays the user's. Unfolded while
    /// narrow, it stays until the window crosses the width again; folded
    /// by the user, widening leaves it folded.
    func testANarrowWindowFoldsTheSidebar() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let window = harness.window
            @MainActor func resize(_ width: CGFloat) { window.setContentSize(NSSize(width: width, height: 800)) }
            if !shell.isSidebarExpanded { shell.toggleSidebar() }
            harness.waitUntil("the sidebar to unfold") { shell.sidebar.isExpanded }

            resize(800)
            XCTAssertFalse(shell.sidebar.isExpanded, "narrow: folded")
            XCTAssertEqual(shell.sidebar.frame.width, SidebarView.foldedWidth)
            XCTAssertTrue(shell.sidebarFold.chosenExpanded, "the saved choice")
            resize(1200)
            XCTAssertTrue(shell.sidebar.isExpanded, "wide again: unfolded")
            XCTAssertEqual(shell.sidebar.frame.width, 260)

            resize(800)
            shell.toggleSidebar()
            harness.waitUntil("the sidebar to unfold while narrow") { shell.sidebar.isExpanded }
            resize(700)
            XCTAssertTrue(shell.sidebar.isExpanded, "narrower still: the user's choice holds")
            resize(1200)
            resize(800)
            XCTAssertFalse(shell.sidebar.isExpanded, "narrow again: folded")

            resize(1200)
            shell.toggleSidebar()
            XCTAssertFalse(shell.sidebar.isExpanded)
            resize(800)
            resize(1200)
            XCTAssertFalse(shell.sidebar.isExpanded, "folded by the user: it stays folded")
            XCTAssertFalse(shell.sidebarFold.chosenExpanded)
        }
    }

    /// Folded, the ⌘N sheet's picture folds toward the new task's icon,
    /// which opens as it lands.
    func testTheSheetsPictureLandsOnTheNewTasksIcon() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            shell.sideEffects.windowShows = { _ in true }
            shell.sideEffects.reducesMotion = { false }
            shell.agentLights.isDisplayAsleep = false
            self.fold(shell)
            shell.applyAgentLights()
            shell.updateSidebar()
            let workspace = try XCTUnwrap(shell.activeWorkspace)
            let rail = shell.sidebar.iconRail
            let icon = shell.convert(try XCTUnwrap(rail.iconFrame(of: workspace.id)), from: rail)

            let context = try XCTUnwrap(CGContext(
                data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            let sheet = NSRect(x: 420, y: 280, width: 440, height: 260)
            shell.pendingTaskSheet = TaskSheetPicture(image: try XCTUnwrap(context.makeImage()), frame: sheet)
            shell.playTaskBirth(of: workspace)

            let ghosts = { (shell.layer?.sublayers ?? []).filter { $0.name == NiruxShellView.taskBirthGhostName } }
            let fold = try XCTUnwrap(ghosts().first?.animation(forKey: "fold") as? CAAnimationGroup)
            let move = try XCTUnwrap(fold.animations?.compactMap { $0 as? CABasicAnimation }.first { $0.keyPath == "position" })
            XCTAssertEqual((move.toValue as? NSValue)?.pointValue, NSPoint(x: icon.midX, y: icon.midY), "onto its icon")
            let born = try XCTUnwrap(rail.itemViews[workspace.id]?.layer)
            XCTAssertNotNil(born.animation(forKey: SidebarView.birthKey), "the icon opens as it lands")
            harness.waitUntil("the ghost to go") { ghosts().isEmpty }
        }
    }
}
