import XCTest
@testable import Nirux

@MainActor
final class SidebarCollapseTests: XCTestCase {
    private func workspace(
        id: String, index: Int, isInactive: Bool, isActive: Bool = false
    ) -> WorkspaceInfo {
        WorkspaceInfo(
            id: id,
            index: index,
            title: id,
            profileID: WorkspaceProfile.defaultID,
            isInactive: isInactive,
            columnCount: 0,
            focusedColumn: 0,
            gitBranch: nil,
            notification: nil,
            isActive: isActive,
            columns: [],
            prInfo: nil,
            diffStats: nil,
            purpose: nil,
            nextStep: nil,
            blocker: nil,
            phase: isInactive ? .parked : .active,
            lastSummary: nil,
            lastActivityAt: nil
        )
    }

    func testCollapsedSectionHidesInactiveTiles() {
        let sidebar = SidebarView()
        sidebar.update(
            profiles: [],
            workspaces: [
                workspace(id: "active", index: 0, isInactive: false, isActive: true),
                workspace(id: "archived", index: 1, isInactive: true)
            ]
        )

        XCTAssertTrue(sidebar.isInactiveSectionCollapsed)
        XCTAssertEqual(sidebar.railWorkspaceInfos.map(\.id), ["active"])

        sidebar.toggleInactiveSection()
        XCTAssertEqual(sidebar.railWorkspaceInfos.map(\.id), ["active", "archived"])
    }

    private func profile(_ id: String, isActive: Bool) -> ProfileInfo {
        ProfileInfo(
            id: id, name: id, colorHex: "#7AA2F7", isActive: isActive, workspaceCount: 2, taskCount: 1, attention: nil
        )
    }

    private func cardIndices(_ sidebar: SidebarView) -> [Int] {
        sidebar.hitAreas.compactMap {
            if case .workspace(let index) = $0.region { return index }
            return nil
        }
    }

    /// Landing on an inactive workspace (⌘↓ past the last active one, a
    /// notification, a launch) used to unfold the section on the next
    /// refresh. Now the folded section lists that workspace alone, and
    /// only while it is on screen.
    func testInactiveWorkspaceOnScreenIsListedAloneWhileFolded() {
        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 260, height: 660))
        sidebar.isExpanded = true
        sidebar.update(
            profiles: [],
            workspaces: [
                workspace(id: "active", index: 0, isInactive: false),
                workspace(id: "on-screen", index: 1, isInactive: true, isActive: true),
                workspace(id: "archived", index: 2, isInactive: true)
            ]
        )

        XCTAssertTrue(sidebar.isInactiveSectionCollapsed)
        XCTAssertEqual(cardIndices(sidebar), [0, 1])
        XCTAssertEqual(sidebar.railWorkspaceInfos.map(\.id), ["active", "on-screen"])

        sidebar.update(
            profiles: [],
            workspaces: [
                workspace(id: "active", index: 0, isInactive: false, isActive: true),
                workspace(id: "on-screen", index: 1, isInactive: true),
                workspace(id: "archived", index: 2, isInactive: true)
            ]
        )

        XCTAssertTrue(sidebar.isInactiveSectionCollapsed)
        XCTAssertEqual(cardIndices(sidebar), [0])
        XCTAssertEqual(sidebar.railWorkspaceInfos.map(\.id), ["active"])
    }

    /// An unfolded section must not reappear unfolded later on its own:
    /// in another space, or once a workspace is parked again.
    func testUnfoldEndsWithSpaceSwitchOrEmptySection() {
        let sidebar = SidebarView()
        let infos = [
            workspace(id: "active", index: 0, isInactive: false, isActive: true),
            workspace(id: "archived", index: 1, isInactive: true)
        ]
        sidebar.update(profiles: [profile("a", isActive: true), profile("b", isActive: false)], workspaces: infos)
        sidebar.toggleInactiveSection()
        sidebar.update(profiles: [profile("a", isActive: true), profile("b", isActive: false)], workspaces: infos)
        XCTAssertFalse(sidebar.isInactiveSectionCollapsed)

        sidebar.update(profiles: [profile("a", isActive: false), profile("b", isActive: true)], workspaces: infos)
        XCTAssertTrue(sidebar.isInactiveSectionCollapsed)

        sidebar.toggleInactiveSection()
        sidebar.update(
            profiles: [profile("a", isActive: false), profile("b", isActive: true)],
            workspaces: [workspace(id: "active", index: 0, isInactive: false, isActive: true)]
        )
        sidebar.update(profiles: [profile("a", isActive: false), profile("b", isActive: true)], workspaces: infos)
        XCTAssertTrue(sidebar.isInactiveSectionCollapsed)
    }

    /// Folding used to be refused while the workspace on screen was an
    /// inactive one, and the heartbeat unfolded it again.
    func testToggleAlwaysFlipsAndRefreshesKeepIt() {
        let sidebar = SidebarView()
        let infos = [
            workspace(id: "active", index: 0, isInactive: false),
            workspace(id: "on-screen", index: 1, isInactive: true, isActive: true)
        ]
        sidebar.update(profiles: [], workspaces: infos)

        sidebar.toggleInactiveSection()
        sidebar.update(profiles: [], workspaces: infos)
        XCTAssertFalse(sidebar.isInactiveSectionCollapsed)

        sidebar.toggleInactiveSection()
        sidebar.update(profiles: [], workspaces: infos)
        sidebar.update(profiles: [], workspaces: infos)
        XCTAssertTrue(sidebar.isInactiveSectionCollapsed)
    }

    /// The Archived row sits at the bottom, as wide as the cards; all of it
    /// toggles, and it takes the first click on a window in the background.
    func testWholeArchivedRowIsClickable() throws {
        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 260, height: 660))
        sidebar.isExpanded = true
        sidebar.update(
            profiles: [],
            workspaces: [
                workspace(id: "active", index: 0, isInactive: false, isActive: true),
                workspace(id: "archived", index: 1, isInactive: true)
            ]
        )
        let row = try XCTUnwrap(sidebar.inactiveSectionHeaderFrame)
        XCTAssertEqual(row.height, SidebarExpandedMetrics.archivedRowHeight)
        XCTAssertEqual(row.minY, SidebarExpandedMetrics.bottomPadding)
        XCTAssertEqual(row.width, 260 - SidebarExpandedMetrics.workspaceInsetX * 2)

        let document = sidebar.contentDocumentView
        let corners = [NSPoint(x: row.minX + 2, y: row.minY + 2), NSPoint(x: row.maxX - 2, y: row.maxY - 2)]
        for point in corners + [NSPoint(x: row.midX, y: row.midY)] {
            guard case .archivedToggle = sidebar.hitArea(at: point)?.region else {
                return XCTFail("\(point) on the Archived row is not clickable")
            }
            let hitView = document.hitTest(document.convert(point, to: document.superview))
            XCTAssertEqual(hitView?.acceptsFirstMouse(for: nil), true)
        }
    }

    /// Unfolding a long archive (or folding it) must leave the header where
    /// it was on screen, so the same spot folds it back.
    func testToggleKeepsTheHeaderUnderThePointer() throws {
        _ = NSApplication.shared
        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 260, height: 400))
        let window = NSWindow(contentRect: sidebar.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = sidebar
        defer { window.close() }
        sidebar.isExpanded = true
        sidebar.update(
            profiles: [],
            workspaces: (0..<12).map { workspace(id: "w\($0)", index: $0, isInactive: $0 >= 2, isActive: $0 == 0) }
        )
        sidebar.layoutSubtreeIfNeeded()

        func headerOnScreen() throws -> NSRect {
            sidebar.convert(try XCTUnwrap(sidebar.inactiveSectionHeaderFrame), from: sidebar.contentDocumentView)
        }
        let before = try headerOnScreen()
        XCTAssertTrue(sidebar.bounds.contains(before))

        sidebar.toggleInactiveSection()
        XCTAssertEqual(cardIndices(sidebar).count, 12)
        XCTAssertEqual(try headerOnScreen().minY, before.minY, accuracy: 0.5)
        // The list opens above the row, under the active cards.
        let header = try XCTUnwrap(sidebar.inactiveSectionHeaderFrame)
        let cards = sidebar.hitAreas.compactMap { area -> (Int, NSRect)? in
            if case .workspace(let index) = area.region { return (index, area.frame) }
            return nil
        }
        let lowestActive = try XCTUnwrap(cards.filter { $0.0 < 2 }.map(\.1.minY).min())
        for (index, frame) in cards where index >= 2 {
            XCTAssertGreaterThan(frame.minY, header.maxY, "w\(index)")
            XCTAssertLessThan(frame.maxY, lowestActive, "w\(index)")
        }

        sidebar.toggleInactiveSection()
        XCTAssertEqual(try headerOnScreen().minY, before.minY, accuracy: 0.5)
    }

    /// VoiceOver reaches the toggle as a button on the Archived row.
    func testArchivedRowIsAnAccessibleToggle() throws {
        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 260, height: 660))
        sidebar.isExpanded = true
        sidebar.update(
            profiles: [],
            workspaces: [
                workspace(id: "active", index: 0, isInactive: false, isActive: true),
                workspace(id: "archived", index: 1, isInactive: true)
            ]
        )
        func toggle() throws -> SidebarSectionToggleView {
            try XCTUnwrap(sidebar.contentDocumentView.subviews.lazy.compactMap { $0 as? SidebarSectionToggleView }.first {
                $0.accessibilityLabel() == "Archived, 1"
            })
        }

        XCTAssertEqual(try toggle().accessibilityRole(), .button)
        XCTAssertFalse(try toggle().isAccessibilityExpanded())
        XCTAssertTrue(try toggle().accessibilityPerformPress())
        XCTAssertFalse(sidebar.isInactiveSectionCollapsed)
        XCTAssertTrue(try toggle().isAccessibilityExpanded())
    }

    /// A click as AppKit delivers it: to the view the window hit-tests on
    /// the header row, which must hand it on to the sidebar. Dispatched by
    /// hand because a window that is never shown (CI) drops mouse events;
    /// WorkspaceUXRenderingTests sends them through a shown window.
    func testHeaderClickReachesTheSidebarEveryTime() throws {
        _ = NSApplication.shared
        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 260, height: 660))
        let window = NSWindow(contentRect: sidebar.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = sidebar
        defer { window.close() }
        sidebar.isExpanded = true
        sidebar.update(
            profiles: [],
            workspaces: [
                workspace(id: "active", index: 0, isInactive: false, isActive: true),
                workspace(id: "archived", index: 1, isInactive: true)
            ]
        )
        sidebar.layoutSubtreeIfNeeded()

        func click(atRowFraction fraction: CGFloat) throws {
            let header = try XCTUnwrap(sidebar.inactiveSectionHeaderFrame)
            let point = NSPoint(x: header.midX, y: header.minY + header.height * fraction)
            let locationInWindow = sidebar.contentDocumentView.convert(point, to: nil)
            let frameView = try XCTUnwrap(sidebar.superview)
            let hitView = try XCTUnwrap(sidebar.hitTest(frameView.convert(locationInWindow, from: nil)))
            XCTAssertTrue(hitView.acceptsFirstMouse(for: nil))
            hitView.mouseDown(with: try XCTUnwrap(NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: locationInWindow,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 0
            )))
        }

        try click(atRowFraction: 0.75) // on the label
        XCTAssertFalse(sidebar.isInactiveSectionCollapsed)
        XCTAssertEqual(cardIndices(sidebar), [0, 1])
        try click(atRowFraction: 0.15) // the band under it
        XCTAssertTrue(sidebar.isInactiveSectionCollapsed)
        XCTAssertEqual(cardIndices(sidebar), [0])
    }

    /// With nothing to show, the toggle (⌘P, VoiceOver) must not leave an
    /// unfold behind for the next workspace that gets parked.
    func testToggleWithoutInactiveWorkspacesDoesNothing() {
        let sidebar = SidebarView()
        sidebar.update(profiles: [], workspaces: [workspace(id: "active", index: 0, isInactive: false, isActive: true)])

        sidebar.toggleInactiveSection()

        XCTAssertTrue(sidebar.isInactiveSectionCollapsed)
    }

    /// Toggled from the menu or ⌘P, the header may be out of view: it is
    /// brought in so the change shows.
    func testToggleAwayFromTheHeaderBringsItIntoView() throws {
        _ = NSApplication.shared
        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 260, height: 300))
        let window = NSWindow(contentRect: sidebar.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = sidebar
        defer { window.close() }
        sidebar.isExpanded = true
        sidebar.update(
            profiles: [],
            workspaces: (0..<10).map { workspace(id: "w\($0)", index: $0, isInactive: $0 >= 8, isActive: $0 == 0) }
        )
        sidebar.layoutSubtreeIfNeeded()
        func headerIsVisible() throws -> Bool {
            let header = try XCTUnwrap(sidebar.inactiveSectionHeaderFrame)
            return sidebar.contentScrollView.contentView.bounds.contains(header)
        }
        XCTAssertFalse(try headerIsVisible())

        sidebar.toggleInactiveSection()

        XCTAssertFalse(sidebar.isInactiveSectionCollapsed)
        XCTAssertTrue(try headerIsVisible())
    }
}
