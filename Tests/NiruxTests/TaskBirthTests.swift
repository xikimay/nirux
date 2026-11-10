import AppKit
import XCTest
@testable import Nirux

/// A task's birth: the row that opens in the sidebar, and, from the ⌘N
/// sheet, the sheet's picture folding toward it and the column sliding in.
@MainActor
final class TaskBirthTests: UIFlowTestCase {
    private func row(_ id: String, index: Int, archived: Bool = false) -> WorkspaceInfo {
        WorkspaceInfo(
            id: id, index: index, title: id, profileID: WorkspaceProfile.defaultID, isInactive: archived, columnCount: 0,
            focusedColumn: 0, gitBranch: "feat/\(id)", notification: nil, isActive: false, columns: [], prInfo: nil,
            diffStats: nil, purpose: nil, nextStep: nil, blocker: nil, phase: archived ? .parked : .active,
            lastSummary: nil, lastActivityAt: nil
        )
    }

    /// A clock the test moves by hand.
    private final class Clock {
        var time: CFTimeInterval = 7_000
    }

    private func sidebar(_ rows: [WorkspaceInfo], expanded: Bool = true, clock: Clock = Clock()) -> SidebarView {
        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 260, height: 660))
        sidebar.clock = { clock.time }
        sidebar.isExpanded = expanded
        sidebar.update(profiles: [], workspaces: rows)
        return sidebar
    }

    private func views(in sidebar: SidebarView, with key: String) -> [NSView] {
        sidebar.expandedViews.filter { $0.layer?.animation(forKey: key) != nil }
    }

    /// The sidebar's views that lie in `frame`, itself in the sidebar's
    /// coordinates.
    private func views(in sidebar: SidebarView, inside frame: NSRect) -> [NSView] {
        sidebar.expandedViews.filter { frame.insetBy(dx: -1, dy: -1).contains(sidebar.convert($0.frame, from: $0.superview)) }
    }

    // MARK: - The row

    /// The born row comes in when its time comes, the tasks under it give
    /// way by its height, and nothing else moves: not the rows above, not
    /// what is laid out from the sidebar's bottom. A rebuild in the
    /// middle carries on from the same moment, and it is over after a
    /// while.
    func testABornRowOpensAndTheTasksUnderItGiveWay() throws {
        let rows = [row("above", index: 0), row("born", index: 1), row("under", index: 2), row("old", index: 3, archived: true)]
        let clock = Clock()
        let sidebar = sidebar(rows, clock: clock)
        XCTAssertTrue(views(in: sidebar, with: SidebarView.birthKey).isEmpty)

        let start = clock.time
        sidebar.noteBirth(workspaceID: "born", delay: 0.2)
        let born = try XCTUnwrap(sidebar.rowFrame(workspaceID: "born"))
        let above = try XCTUnwrap(sidebar.rowFrame(workspaceID: "above"))
        let under = try XCTUnwrap(sidebar.rowFrame(workspaceID: "under"))
        XCTAssertNil(sidebar.rowFrame(workspaceID: "elsewhere"))

        // Every view of the row, its labels too: unseen until it opens,
        // then in, from a little above.
        let own = views(in: sidebar, inside: born)
        XCTAssertGreaterThan(own.count, 1)
        for view in own {
            let appear = try XCTUnwrap(view.layer?.animation(forKey: SidebarView.birthKey) as? CABasicAnimation)
            XCTAssertEqual((appear.fromValue as? NSNumber)?.doubleValue, 0)
            XCTAssertEqual(appear.beginTime, start + 0.2, "when the sheet's picture lands")
            XCTAssertEqual(appear.fillMode, .backwards, "unseen until then")
            let spring = try XCTUnwrap(view.layer?.animation(forKey: SidebarView.birthSpringKey) as? CASpringAnimation)
            XCTAssertGreaterThan((spring.fromValue as? NSNumber)?.doubleValue ?? 0, 0, "from above")
            XCTAssertEqual(spring.beginTime, start + 0.2)
            XCTAssertEqual(view.alphaValue, 1, "there, if nothing plays")
        }
        // The task under it starts one row higher, where it was.
        let pushKey = SidebarView.birthPushKey("born")
        let pushed = views(in: sidebar, with: pushKey)
        XCTAssertEqual(Set(pushed.map(ObjectIdentifier.init)), Set(views(in: sidebar, inside: under).map(ObjectIdentifier.init)))
        XCTAssertFalse(pushed.isEmpty)
        let push = try XCTUnwrap(pushed.first?.layer?.animation(forKey: pushKey) as? CASpringAnimation)
        XCTAssertEqual(
            (push.fromValue as? NSNumber)?.doubleValue, Double(born.height + SidebarExpandedMetrics.workspaceGap)
        )
        XCTAssertEqual(push.beginTime, start + 0.2)
        XCTAssertEqual(push.fillMode, .backwards)
        XCTAssertTrue(push.isAdditive)
        XCTAssertTrue(views(in: sidebar, inside: above).allSatisfy { $0.layer?.animationKeys() == nil }, "the rows above stay")

        // Another change rebuilds the rows in the middle of it.
        clock.time = start + 0.6
        sidebar.update(profiles: [], workspaces: rows + [row("later", index: 4)])
        let rebuilt = try XCTUnwrap(views(in: sidebar, with: SidebarView.birthKey).first)
        XCTAssertFalse(own.contains { $0 === rebuilt }, "new views")
        XCTAssertEqual(rebuilt.layer?.animation(forKey: SidebarView.birthKey)?.beginTime, start + 0.2, "it carries on")

        // Over: a rebuild opens nothing again, and the next birth forgets it.
        clock.time = start + 0.2 + SidebarView.birthDuration + 0.1
        sidebar.update(profiles: [], workspaces: rows + [row("later", index: 4), row("more", index: 5)])
        XCTAssertTrue(sidebar.expandedViews.allSatisfy { $0.layer?.animationKeys() == nil })
        sidebar.noteBirth(workspaceID: "above")
        XCTAssertEqual(Array(sidebar.rowOpensAt.keys), ["above"], "the first one is forgotten")
    }

    /// The Archived list, unfolded, is laid out from the sidebar's bottom:
    /// a birth pushes none of it.
    func testTheArchivedListDoesntGiveWay() throws {
        let rows = [row("born", index: 0), row("under", index: 1), row("old", index: 2, archived: true)]
        let sidebar = sidebar(rows)
        sidebar.toggleInactiveSection()
        let old = try XCTUnwrap(sidebar.rowFrame(workspaceID: "old"), "the archived row is listed")
        sidebar.noteBirth(workspaceID: "born")
        let pushKey = SidebarView.birthPushKey("born")
        XCTAssertFalse(views(in: sidebar, with: pushKey).isEmpty, "the task under it does")
        XCTAssertFalse(views(in: sidebar, inside: old).isEmpty)
        XCTAssertTrue(views(in: sidebar, inside: old).allSatisfy { $0.layer?.animation(forKey: pushKey) == nil })
    }

    /// Two tasks born together (a Lead starting several): a row under
    /// both gives way to both.
    func testARowUnderTwoBirthsGivesWayToBoth() throws {
        let clock = Clock()
        let sidebar = sidebar([row("first", index: 0), row("second", index: 1), row("under", index: 2)], clock: clock)
        let start = clock.time
        sidebar.noteBirth(workspaceID: "first")
        clock.time = start + 0.1
        sidebar.noteBirth(workspaceID: "second")
        let under = views(in: sidebar, inside: try XCTUnwrap(sidebar.rowFrame(workspaceID: "under")))
        XCTAssertFalse(under.isEmpty)
        for view in under {
            XCTAssertEqual(view.layer?.animation(forKey: SidebarView.birthPushKey("first"))?.beginTime, start)
            XCTAssertEqual(view.layer?.animation(forKey: SidebarView.birthPushKey("second"))?.beginTime, start + 0.1)
        }
        // The second one opens, and gives way to the first.
        let second = views(in: sidebar, inside: try XCTUnwrap(sidebar.rowFrame(workspaceID: "second")))
        XCTAssertTrue(second.allSatisfy { $0.layer?.animation(forKey: SidebarView.birthKey) != nil })
        XCTAssertTrue(second.allSatisfy { $0.layer?.animation(forKey: SidebarView.birthPushKey("first")) != nil })
        XCTAssertTrue(second.allSatisfy { $0.layer?.animation(forKey: SidebarView.birthPushKey("second")) == nil })
    }

    /// A list taller than the sidebar scrolls: the born row opens, and no
    /// row is pushed from a place it may never have had on screen.
    func testNoRowIsPushedInAListThatScrolls() throws {
        let rows = (0..<40).map { row("task-\($0)", index: $0) }
        let sidebar = sidebar(rows)
        XCTAssertGreaterThan(sidebar.contentDocumentView.frame.height, sidebar.bounds.height, "it scrolls")
        sidebar.noteBirth(workspaceID: "task-5")
        XCTAssertFalse(views(in: sidebar, with: SidebarView.birthKey).isEmpty)
        XCTAssertTrue(views(in: sidebar, with: SidebarView.birthPushKey("task-5")).isEmpty)
    }

    /// In the rail: the born tile opens, the tile under it gives way by a
    /// tile, and "+" at the rail's bottom stays.
    func testTheRailsTilesOpenAndGiveWayToo() throws {
        let sidebar = sidebar(
            [row("born", index: 0), row("under", index: 1), row("old", index: 2, archived: true)], expanded: false
        )
        sidebar.toggleInactiveSection()
        sidebar.noteBirth(workspaceID: "born")
        let born = try XCTUnwrap(sidebar.rowFrame(workspaceID: "born"))
        let under = try XCTUnwrap(sidebar.rowFrame(workspaceID: "under"))
        let old = try XCTUnwrap(sidebar.rowFrame(workspaceID: "old"), "the archived tile is listed")
        XCTAssertFalse(views(in: sidebar, inside: born).isEmpty)
        XCTAssertTrue(views(in: sidebar, inside: born).allSatisfy { $0.layer?.animation(forKey: SidebarView.birthKey) != nil })
        let pushKey = SidebarView.birthPushKey("born")
        let pushed = Set(views(in: sidebar, with: pushKey).map(ObjectIdentifier.init))
        // Everything laid out under it, the separator and the archived
        // tiles too, so nothing opens a hole; but "+", laid out from the
        // rail's bottom, the lowest view of all.
        let frame = { (view: NSView) in sidebar.convert(view.frame, from: view.superview) }
        let laidOutUnder = sidebar.expandedViews.filter { frame($0).maxY <= born.minY + 1 }
        let add = try XCTUnwrap(laidOutUnder.min { frame($0).minY < frame($1).minY })
        let flowing = laidOutUnder.filter { $0 !== add }
        let tiles = views(in: sidebar, inside: under).count + views(in: sidebar, inside: old).count
        XCTAssertGreaterThan(flowing.count, tiles, "the separator and the Archived tile as well")
        XCTAssertEqual(pushed, Set(flowing.map(ObjectIdentifier.init)))
        XCTAssertNil(add.layer?.animation(forKey: pushKey), "\"+\" stays")
        let push = try XCTUnwrap(
            views(in: sidebar, with: pushKey).first?.layer?.animation(forKey: pushKey) as? CASpringAnimation
        )
        XCTAssertEqual((push.fromValue as? NSNumber)?.doubleValue, Double(born.height), "a tile's area holds its gap")
    }

    /// Rows that may not move open nothing: not at a birth, and not at a
    /// rebuild after one that began while they could.
    func testNoRowOpensWhileRowsMayNotMove() {
        let rows = [row("born", index: 0), row("under", index: 1)]
        let still = sidebar(rows)
        still.animates = false
        still.noteBirth(workspaceID: "born")
        XCTAssertTrue(still.rowOpensAt.isEmpty)
        XCTAssertTrue(still.expandedViews.allSatisfy { $0.layer?.animationKeys() == nil })

        let stopped = sidebar(rows)
        stopped.noteBirth(workspaceID: "born")
        XCTAssertFalse(views(in: stopped, with: SidebarView.birthKey).isEmpty)
        stopped.animates = false
        XCTAssertTrue(stopped.expandedViews.allSatisfy { $0.layer?.animationKeys() == nil }, "motion went off in the middle")
        stopped.animates = true
        XCTAssertFalse(views(in: stopped, with: SidebarView.birthKey).isEmpty, "and back: it carries on")
    }

    // MARK: - In the shell

    /// The interface may move (or not, with Reduce motion), whatever the
    /// machine the test runs on.
    private func prepare(_ shell: NiruxShellView, reducesMotion: Bool = false) {
        shell.sideEffects.windowShows = { _ in true }
        shell.sideEffects.reducesMotion = { reducesMotion }
        shell.agentLights.isDisplayAsleep = false
        shell.sidebar.isExpanded = true
        // The sidebar learns whether its rows may move.
        shell.applyAgentLights()
        // Whatever earlier workspaces left over the viewport: a fade never
        // ends in a window that isn't on screen.
        shell.viewport.subviews.filter { $0 is NSImageView }.forEach { $0.removeFromSuperview() }
    }

    private func picture(at frame: NSRect) throws -> TaskSheetPicture {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        return TaskSheetPicture(image: try XCTUnwrap(context.makeImage()), frame: frame)
    }

    private func openSheet(in harness: UIFlowHarness) throws -> NewTaskPanel {
        harness.runPaletteCommand("New…")
        harness.waitUntil("the sheet") { harness.shell.newTaskPanel?.panel?.isSheet == true }
        let sheet = try XCTUnwrap(harness.shell.newTaskPanel)
        harness.waitUntil("the repository's info") { sheet.info != nil }
        return sheet
    }

    private func ghosts(in shell: NiruxShellView) -> [CALayer] {
        (shell.layer?.sublayers ?? []).filter { $0.name == NiruxShellView.taskBirthGhostName }
    }

    private func pictures(in shell: NiruxShellView) -> [NSView] {
        shell.viewport.subviews.filter { $0 is NSImageView }
    }

    /// The sheet's picture folds from where the sheet was toward the
    /// task's row, which opens as it lands. Without a sheet (a task its
    /// Lead starts) nothing folds and the row opens at once.
    func testTheSheetsPictureFoldsTowardTheRowWhichOpensAsItLands() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            self.prepare(shell)
            shell.updateSidebar()
            let workspace = try XCTUnwrap(shell.activeWorkspace)
            let row = shell.convert(try XCTUnwrap(shell.sidebar.rowFrame(workspaceID: workspace.id)), from: shell.sidebar)

            // The sidebar's clock stands still: a slow rebuild on a busy
            // machine can't hide a delay.
            shell.sidebar.clock = { 3_000 }
            shell.playTaskBirth(of: workspace)
            XCTAssertEqual(shell.sidebar.rowOpensAt[workspace.id], 3_000, "no sheet: nothing to wait for")
            XCTAssertTrue(self.ghosts(in: shell).isEmpty)

            let sheet = NSRect(x: 420, y: 280, width: 440, height: 260)
            shell.pendingTaskSheet = try self.picture(at: sheet)
            shell.playTaskBirth(of: workspace)
            XCTAssertNil(shell.pendingTaskSheet, "used once")
            XCTAssertEqual(
                try XCTUnwrap(shell.sidebar.rowOpensAt[workspace.id]), 3_000 + NiruxShellView.taskBirthRowDelay, accuracy: 0.001,
                "as the picture lands"
            )
            XCTAssertEqual(self.ghosts(in: shell).count, 1)
            let ghost = try XCTUnwrap(self.ghosts(in: shell).first)
            XCTAssertEqual(ghost.frame, sheet, "where the sheet was")
            XCTAssertNotNil(ghost.contents)
            XCTAssertEqual(ghost.opacity, 0, "gone unless its fold runs")
            let fold = try XCTUnwrap(ghost.animation(forKey: "fold") as? CAAnimationGroup)
            let move = try XCTUnwrap(fold.animations?.compactMap { $0 as? CABasicAnimation }.first { $0.keyPath == "position" })
            XCTAssertEqual((move.fromValue as? NSValue)?.pointValue, NSPoint(x: sheet.midX, y: sheet.midY))
            XCTAssertEqual((move.toValue as? NSValue)?.pointValue, NSPoint(x: row.midX, y: row.midY), "toward its row")

            harness.waitUntil("the ghost to go") { self.ghosts(in: shell).isEmpty }
        }
    }

    /// A workspace that slides in comes from the right edge in a workspace
    /// switch's time, over a picture of what was on screen that fades
    /// away under it: nothing stale stays beside its column. One opened
    /// in the background slides nothing.
    func testANewTasksColumnSlidesInOverAPictureThatFadesAway() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            self.prepare(shell)

            shell.addWorkspace(title: "slides", cwd: harness.repo, slidesIn: true)
            let workspace = try XCTUnwrap(shell.activeWorkspace)
            XCTAssertEqual(workspace.title, "slides")
            let slide = try XCTUnwrap(
                workspace.containerView.layer?.animation(forKey: NiruxShellView.taskBirthSlideKey) as? CABasicAnimation
            )
            XCTAssertEqual((slide.fromValue as? NSNumber)?.doubleValue, Double(shell.viewport.bounds.width), "from the right edge")
            XCTAssertEqual((slide.toValue as? NSNumber)?.doubleValue, 0)
            XCTAssertEqual(slide.duration, NiruxShellView.taskBirthSlideDuration)
            XCTAssertEqual(slide.beginTime, 0, "at once: the terminal is seen as soon as before")
            XCTAssertEqual(self.pictures(in: shell).count, 1)
            let backdrop = try XCTUnwrap(self.pictures(in: shell).first)
            let strip = try XCTUnwrap(shell.viewport.subviews.firstIndex(of: shell.verticalStrip))
            XCTAssertLessThan(try XCTUnwrap(shell.viewport.subviews.firstIndex(of: backdrop)), strip, "under the column")
            XCTAssertEqual(backdrop.alphaValue, 0, "gone unless its fade runs")
            let fade = try XCTUnwrap(backdrop.layer?.animation(forKey: NiruxShellView.taskBirthBackdropKey) as? CABasicAnimation)
            XCTAssertEqual((fade.fromValue as? NSNumber)?.doubleValue, 1, "seen at first")
            XCTAssertEqual((fade.toValue as? NSNumber)?.doubleValue, 0)
            XCTAssertLessThanOrEqual(fade.duration, slide.duration, "no later than the column lands")

            shell.addWorkspace(title: "background", cwd: harness.repo, activate: false, slidesIn: true)
            let background = try XCTUnwrap(shell.workspaces.last)
            XCTAssertEqual(background.title, "background")
            XCTAssertNil(background.containerView.layer?.animation(forKey: NiruxShellView.taskBirthSlideKey))
            XCTAssertEqual(self.pictures(in: shell).count, 1, "nor a picture")

            harness.waitUntil("the picture to go") { self.pictures(in: shell).isEmpty }
        }
    }

    /// Start in the sheet, end to end: the sheet closes, its picture
    /// folds, the row opens and the column slides in.
    func testStartFoldsTheSheetOpensTheRowAndSlidesTheColumnIn() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            _ = try NewTaskFlowTests.anchoredSpace(harness)
            self.prepare(shell)

            let sheet = try self.openSheet(in: harness)
            sheet.descriptionView.string = "Born with a fold"
            sheet.descriptionView.didChangeText()
            sheet.startAction(nil)
            harness.waitUntil("the task's workspace") { shell.workspaces.contains { $0.title == "Born with a fold" } }
            let workspace = try XCTUnwrap(shell.workspaces.first { $0.title == "Born with a fold" })

            XCTAssertNil(shell.newTaskPanel, "the sheet itself is closed")
            XCTAssertNil(shell.pendingTaskSheet)
            XCTAssertNotNil(shell.sidebar.rowOpensAt[workspace.id])
            let ghost = try XCTUnwrap(self.ghosts(in: shell).first)
            XCTAssertNotNil(ghost.animation(forKey: "fold"))
            XCTAssertGreaterThan(ghost.frame.width, 200, "the sheet's picture, at its size")
            XCTAssertGreaterThan(ghost.frame.height, 100)
            XCTAssertNotNil(workspace.containerView.layer?.animation(forKey: NiruxShellView.taskBirthSlideKey))
            XCTAssertEqual(self.pictures(in: shell).count, 1)

            harness.waitUntil("the picture and the ghost to go") {
                self.pictures(in: shell).isEmpty && self.ghosts(in: shell).isEmpty
            }
        }
    }

    /// With Reduce motion (or animations off) each step refuses by
    /// itself, whatever the others would do: no picture of the sheet, no
    /// fold nor row opening for a picture that would be there, no slide
    /// for a workspace asked to slide in.
    func testNothingMovesAtBirthWhileTheInterfaceMayNot() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            _ = try NewTaskFlowTests.anchoredSpace(harness)

            // The sheet's picture is taken while the interface may move…
            self.prepare(shell)
            let sheet = try self.openSheet(in: harness)
            shell.takeTaskSheetPicture(of: sheet)
            XCTAssertEqual(shell.pendingTaskSheet?.frame.size, sheet.panel?.frame.size)
            // …and not while it may not.
            self.prepare(shell, reducesMotion: true)
            shell.takeTaskSheetPicture(of: sheet)
            XCTAssertNil(shell.pendingTaskSheet)
            sheet.dismiss()

            let workspace = try XCTUnwrap(shell.activeWorkspace)
            shell.pendingTaskSheet = try self.picture(at: NSRect(x: 420, y: 280, width: 440, height: 260))
            // Even if the sidebar took its rows for free to move.
            shell.sidebar.animates = true
            shell.playTaskBirth(of: workspace)
            XCTAssertNil(shell.pendingTaskSheet)
            XCTAssertTrue(self.ghosts(in: shell).isEmpty)
            XCTAssertTrue(shell.sidebar.rowOpensAt.isEmpty)

            shell.addWorkspace(title: "as before", cwd: harness.repo, slidesIn: true)
            let added = try XCTUnwrap(shell.activeWorkspace)
            XCTAssertEqual(added.title, "as before")
            XCTAssertNil(added.containerView.layer?.animation(forKey: NiruxShellView.taskBirthSlideKey))
            let strip = try XCTUnwrap(shell.viewport.subviews.firstIndex(of: shell.verticalStrip))
            XCTAssertEqual(self.pictures(in: shell).count, 1, "the old fade")
            XCTAssertTrue(
                self.pictures(in: shell).allSatisfy { (shell.viewport.subviews.firstIndex(of: $0) ?? 0) > strip },
                "over the workspace"
            )
        }
    }
}
