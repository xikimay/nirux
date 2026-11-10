import AppKit
import XCTest
@testable import Nirux

/// A task's birth: the row that opens in the sidebar, and, from the ⌘N
/// sheet, the sheet's picture folding toward it and the column sliding in.
@MainActor
final class TaskBirthTests: UIFlowTestCase {
    private func row(_ id: String, index: Int) -> WorkspaceInfo {
        WorkspaceInfo(
            id: id, index: index, title: id, profileID: WorkspaceProfile.defaultID, isInactive: false, columnCount: 0,
            focusedColumn: 0, gitBranch: "feat/\(id)", notification: nil, isActive: false, columns: [], prInfo: nil,
            diffStats: nil, purpose: nil, nextStep: nil, blocker: nil, phase: .active, lastSummary: nil, lastActivityAt: nil
        )
    }

    private func layers(in sidebar: SidebarView, with key: String) -> [NSView] {
        sidebar.expandedViews.filter { $0.layer?.animation(forKey: key) != nil }
    }

    // MARK: - The row

    /// The born row comes in, the rows under it give way, the rows above
    /// stay; a rebuild in the middle carries on, and it is over after a
    /// moment.
    func testABornRowOpensAndPushesTheRowsUnderIt() throws {
        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 260, height: 660))
        sidebar.isExpanded = true
        let rows = [row("above", index: 0), row("born", index: 1), row("under", index: 2)]
        sidebar.update(profiles: [], workspaces: rows)
        XCTAssertTrue(layers(in: sidebar, with: SidebarView.birthKey).isEmpty)

        let now = CACurrentMediaTime()
        sidebar.noteBirth(workspaceID: "born", now: now)
        let born = try XCTUnwrap(sidebar.rowFrame(workspaceID: "born"))
        let above = try XCTUnwrap(sidebar.rowFrame(workspaceID: "above"))
        let under = try XCTUnwrap(sidebar.rowFrame(workspaceID: "under"))
        XCTAssertNil(sidebar.rowFrame(workspaceID: "elsewhere"))
        let opening = layers(in: sidebar, with: SidebarView.birthKey)
        let pushed = layers(in: sidebar, with: SidebarView.birthPushKey)
        XCTAssertFalse(opening.isEmpty)
        XCTAssertFalse(pushed.isEmpty)
        let frame = { (view: NSView) in sidebar.convert(view.frame, from: view.superview) }
        XCTAssertTrue(opening.allSatisfy { born.insetBy(dx: -1, dy: -1).contains(frame($0)) }, "its own views only")
        XCTAssertTrue(pushed.allSatisfy { frame($0).maxY <= born.minY + 1 }, "only what lies under it")
        XCTAssertTrue(pushed.contains { under.insetBy(dx: -1, dy: -1).contains(frame($0)) })
        XCTAssertFalse((opening + pushed).contains { above.insetBy(dx: -1, dy: -1).contains(frame($0)) }, "the rows above stay")

        // Another change rebuilds the rows in the middle of it.
        sidebar.update(profiles: [], workspaces: rows + [row("later", index: 3)])
        XCTAssertFalse(layers(in: sidebar, with: SidebarView.birthKey).isEmpty, "it carries on")

        sidebar.noteBirth(workspaceID: "later", now: now + SidebarView.birthDuration + 0.1)
        XCTAssertEqual(Array(sidebar.bornAt.keys), ["later"], "the first one is over")
    }

    func testNoRowOpensWhileRowsMayNotMove() {
        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 260, height: 660))
        sidebar.isExpanded = true
        sidebar.animates = false
        sidebar.update(profiles: [], workspaces: [row("born", index: 0), row("under", index: 1)])
        sidebar.noteBirth(workspaceID: "born")
        XCTAssertTrue(sidebar.bornAt.isEmpty)
        XCTAssertTrue(layers(in: sidebar, with: SidebarView.birthKey).isEmpty)
        XCTAssertTrue(layers(in: sidebar, with: SidebarView.birthPushKey).isEmpty)
    }

    // MARK: - From the sheet

    private func startTask(_ description: String, in harness: UIFlowHarness) throws -> WorkspaceState {
        harness.runPaletteCommand("New…")
        harness.waitUntil("the sheet") { harness.shell.newTaskPanel?.panel?.isSheet == true }
        let sheet = try XCTUnwrap(harness.shell.newTaskPanel)
        harness.waitUntil("the repository's info") { sheet.info != nil }
        sheet.descriptionView.string = description
        sheet.descriptionView.didChangeText()
        sheet.startAction(nil)
        harness.waitUntil("the task's workspace") { harness.shell.workspaces.contains { $0.title == description } }
        return try XCTUnwrap(harness.shell.workspaces.first { $0.title == description })
    }

    private func ghosts(in shell: NiruxShellView) -> [CALayer] {
        (shell.layer?.sublayers ?? []).filter { $0.name == NiruxShellView.taskBirthGhostName }
    }

    /// Start in the sheet: its picture folds toward the row from where the
    /// sheet was, the row opens, and the column slides in over a picture
    /// of what was on screen.
    func testStartFoldsTheSheetOpensTheRowAndSlidesTheColumnIn() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            _ = try NewTaskFlowTests.anchoredSpace(harness)
            shell.sideEffects.windowShows = { _ in true }
            shell.sideEffects.reducesMotion = { false }
            shell.agentLights.isDisplayAsleep = false

            // The space's own workspace left its picture over the viewport:
            // its fade never ends in a window that isn't on screen.
            shell.viewport.subviews.filter { $0 is NSImageView }.forEach { $0.removeFromSuperview() }

            let workspace = try startTask("Born with a fold", in: harness)
            XCTAssertNil(shell.newTaskPanel, "the sheet itself is closed")
            XCTAssertNil(shell.pendingTaskSheet)
            XCTAssertNotNil(shell.sidebar.bornAt[workspace.id])
            let ghost = try XCTUnwrap(ghosts(in: shell).first)
            XCTAssertNotNil(ghost.animation(forKey: "fold"))
            XCTAssertNotNil(ghost.contents)
            XCTAssertGreaterThan(ghost.frame.width, 200, "where the sheet was")
            XCTAssertNotNil(workspace.containerView.layer?.animation(forKey: NiruxShellView.taskBirthSlideKey))
            // What was on screen stays under the column that comes in.
            let pictures = shell.viewport.subviews.filter { $0 is NSImageView }
            XCTAssertEqual(pictures.count, 1)
            let strip = try XCTUnwrap(shell.viewport.subviews.firstIndex(of: shell.verticalStrip))
            XCTAssertLessThan(try XCTUnwrap(shell.viewport.subviews.firstIndex(of: pictures[0])), strip)

            harness.waitUntil("the picture and the ghost to go") {
                shell.viewport.subviews.allSatisfy { !($0 is NSImageView) } && self.ghosts(in: shell).isEmpty
            }
        }
    }

    /// With Reduce motion, or animations off: the sheet closes and the
    /// workspace shows, as before.
    func testNothingMovesAtBirthWhileTheInterfaceMayNot() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            _ = try NewTaskFlowTests.anchoredSpace(harness)
            shell.sideEffects.windowShows = { _ in true }
            shell.sideEffects.reducesMotion = { true }
            shell.agentLights.isDisplayAsleep = false

            let workspace = try startTask("Born without moving", in: harness)
            XCTAssertNil(shell.newTaskPanel)
            XCTAssertNil(shell.pendingTaskSheet)
            XCTAssertTrue(shell.sidebar.bornAt.isEmpty)
            XCTAssertTrue(ghosts(in: shell).isEmpty)
            XCTAssertNil(workspace.containerView.layer?.animation(forKey: NiruxShellView.taskBirthSlideKey))
        }
    }
}
