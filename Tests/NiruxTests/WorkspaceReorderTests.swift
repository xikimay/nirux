import XCTest
@testable import Nirux

final class WorkspaceReorderTests: XCTestCase {

    // MARK: - WorkspaceStore.moveWorkspace(at:toPosition:)

    @MainActor
    private func makeStore(titles: [String], inactive: Set<String> = []) -> WorkspaceStore {
        let store = WorkspaceStore()
        for title in titles {
            let workspace = WorkspaceState(id: title, title: title, cwd: "/tmp/\(title)")
            workspace.isInactive = inactive.contains(title)
            store.appendWorkspace(workspace, activate: false)
        }
        return store
    }

    @MainActor
    private func visibleIDs(_ store: WorkspaceStore) -> [String] {
        store.visibleWorkspaceIndices.map { store.workspaces[$0].id }
    }

    @MainActor
    func testMoveToPositionMovesDownMultipleSteps() {
        let store = makeStore(titles: ["a", "b", "c", "d"])
        XCTAssertTrue(store.moveWorkspace(at: 0, toPosition: 2))
        XCTAssertEqual(visibleIDs(store), ["b", "c", "a", "d"])
    }

    @MainActor
    func testMoveToPositionMovesUpMultipleSteps() {
        let store = makeStore(titles: ["a", "b", "c", "d"])
        XCTAssertTrue(store.moveWorkspace(at: 3, toPosition: 0))
        XCTAssertEqual(visibleIDs(store), ["d", "a", "b", "c"])
    }

    @MainActor
    func testMoveToPositionClampsToGroupEnd() {
        let store = makeStore(titles: ["a", "b", "c"])
        XCTAssertTrue(store.moveWorkspace(at: 0, toPosition: 99))
        XCTAssertEqual(visibleIDs(store), ["b", "c", "a"])
    }

    @MainActor
    func testMoveToPositionSamePositionIsNoOp() {
        let store = makeStore(titles: ["a", "b", "c"])
        XCTAssertFalse(store.moveWorkspace(at: 1, toPosition: 1))
        XCTAssertEqual(visibleIDs(store), ["a", "b", "c"])
    }

    @MainActor
    func testMoveToPositionNeverCrossesInactiveBoundary() {
        let store = makeStore(titles: ["a", "b", "c", "z"], inactive: ["z"])
        // Clamped to the end of the ACTIVE group; z stays last.
        XCTAssertTrue(store.moveWorkspace(at: 0, toPosition: 99))
        XCTAssertEqual(visibleIDs(store), ["b", "c", "a", "z"])

        // Inactive workspace reorders within its own group only.
        let store2 = makeStore(titles: ["a", "x", "y"], inactive: ["x", "y"])
        let yIndex = store2.workspaces.firstIndex { $0.id == "y" }!
        XCTAssertTrue(store2.moveWorkspace(at: yIndex, toPosition: 0))
        XCTAssertEqual(visibleIDs(store2), ["a", "y", "x"])
    }

    @MainActor
    func testMoveToPositionClampsNegativeToTop() {
        let store = makeStore(titles: ["a", "b", "c"])
        XCTAssertTrue(store.moveWorkspace(at: 2, toPosition: -5))
        XCTAssertEqual(visibleIDs(store), ["c", "a", "b"])
    }

    @MainActor
    func testMoveToPositionIgnoresOtherProfileWorkspaces() {
        // Other-profile workspaces interleaved in the store array leave
        // holes in the visible index space — positions must still map to
        // the active profile's group only.
        let store = WorkspaceStore()
        let other = WorkspaceProfile(id: "other", name: "other", colorHex: "#FF0000")
        store.replaceProfiles([WorkspaceProfile.defaultProfile, other], activeProfileID: WorkspaceProfile.defaultID)
        for (id, profileID) in [
            ("a", WorkspaceProfile.defaultID), ("x", "other"),
            ("b", WorkspaceProfile.defaultID), ("y", "other"),
            ("c", WorkspaceProfile.defaultID)
        ] {
            let workspace = WorkspaceState(id: id, title: id, cwd: "/tmp/\(id)")
            workspace.profileID = profileID
            store.appendWorkspace(workspace, activate: false)
        }
        XCTAssertEqual(visibleIDs(store), ["a", "b", "c"])

        let aIndex = store.workspaces.firstIndex { $0.id == "a" }!
        XCTAssertTrue(store.moveWorkspace(at: aIndex, toPosition: 2))
        XCTAssertEqual(visibleIDs(store), ["b", "c", "a"])
        XCTAssertEqual(store.workspaces.filter { $0.profileID == "other" }.map(\.id), ["x", "y"])
    }

    @MainActor
    func testMoveToPositionWithInterleavedInactiveStoreOrder() {
        // Store order interleaves the groups; visible order regroups them.
        let store = makeStore(titles: ["x", "a", "y"], inactive: ["x", "y"])
        XCTAssertEqual(visibleIDs(store), ["a", "x", "y"])

        let yIndex = store.workspaces.firstIndex { $0.id == "y" }!
        XCTAssertTrue(store.moveWorkspace(at: yIndex, toPosition: 0))
        XCTAssertEqual(visibleIDs(store), ["a", "y", "x"])
    }

    @MainActor
    func testMoveToPositionKeepsActiveWorkspaceByID() {
        let store = makeStore(titles: ["a", "b", "c"])
        store.selectWorkspace(id: "b")
        XCTAssertTrue(store.moveWorkspace(at: 1, toPosition: 0))
        XCTAssertEqual(store.activeWorkspace?.id, "b")
        XCTAssertEqual(store.activeWorkspaceIndex, 0)
    }

    // MARK: - SidebarDragMath

    func testInsertionSlotMapsCursorToGaps() {
        // Row midpoints top → bottom in AppKit coords (y grows upward).
        let midYs: [CGFloat] = [300, 200, 100]
        XCTAssertEqual(SidebarDragMath.insertionSlot(forY: 350, rowMidYs: midYs), 0)
        XCTAssertEqual(SidebarDragMath.insertionSlot(forY: 250, rowMidYs: midYs), 1)
        XCTAssertEqual(SidebarDragMath.insertionSlot(forY: 150, rowMidYs: midYs), 2)
        XCTAssertEqual(SidebarDragMath.insertionSlot(forY: 50, rowMidYs: midYs), 3)
    }

    func testTargetPositionAdjacentSlotsAreNoOps() {
        XCTAssertNil(SidebarDragMath.targetPosition(slot: 1, draggedPosition: 1))
        XCTAssertNil(SidebarDragMath.targetPosition(slot: 2, draggedPosition: 1))
        XCTAssertNil(SidebarDragMath.targetPosition(slot: 0, draggedPosition: 0))
        XCTAssertNil(SidebarDragMath.targetPosition(slot: 1, draggedPosition: 0))
    }

    func testInsertionSlotMidpointTieAndSingleRow() {
        // Strict >: a cursor exactly at a row's midpoint belongs to the
        // slot below that row.
        XCTAssertEqual(SidebarDragMath.insertionSlot(forY: 200, rowMidYs: [300, 200, 100]), 1)
        // Single-row group: both slots exist (and both are no-ops).
        XCTAssertEqual(SidebarDragMath.insertionSlot(forY: 500, rowMidYs: [200]), 0)
        XCTAssertEqual(SidebarDragMath.insertionSlot(forY: 50, rowMidYs: [200]), 1)
    }

    func testTargetPositionAccountsForRemoval() {
        XCTAssertEqual(SidebarDragMath.targetPosition(slot: 0, draggedPosition: 1), 0)
        XCTAssertEqual(SidebarDragMath.targetPosition(slot: 3, draggedPosition: 1), 2)
        XCTAssertEqual(SidebarDragMath.targetPosition(slot: 3, draggedPosition: 0), 2)
        XCTAssertEqual(SidebarDragMath.targetPosition(slot: 0, draggedPosition: 2), 0)
    }
}
