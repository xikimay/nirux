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
            hasNotification: false,
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

    func testCollapsedSectionHidesInactiveDots() {
        let sidebar = SidebarView()
        sidebar.update(
            profiles: [],
            workspaces: [
                workspace(id: "active", index: 0, isInactive: false, isActive: true),
                workspace(id: "archived", index: 1, isInactive: true)
            ]
        )

        XCTAssertTrue(sidebar.isInactiveSectionCollapsed)
        XCTAssertEqual(sidebar.dotWorkspaceInfos.map(\.id), ["active"])

        sidebar.setInactiveSectionCollapsed(false)
        XCTAssertEqual(sidebar.dotWorkspaceInfos.map(\.id), ["active", "archived"])
    }

    func testSelectedInactiveWorkspaceAutomaticallyExpandsSection() {
        let sidebar = SidebarView()
        var persistedValue: Bool?
        sidebar.onInactiveSectionCollapsedChange = { persistedValue = $0 }

        sidebar.update(
            profiles: [],
            workspaces: [workspace(id: "archived", index: 0, isInactive: true, isActive: true)]
        )

        XCTAssertFalse(sidebar.isInactiveSectionCollapsed)
        XCTAssertEqual(persistedValue, false)
        XCTAssertEqual(sidebar.dotWorkspaceInfos.map(\.id), ["archived"])
    }
}
