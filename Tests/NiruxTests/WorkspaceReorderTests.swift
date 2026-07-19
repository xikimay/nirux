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
    }

    func testTargetPositionAccountsForRemoval() {
        XCTAssertEqual(SidebarDragMath.targetPosition(slot: 0, draggedPosition: 1), 0)
        XCTAssertEqual(SidebarDragMath.targetPosition(slot: 3, draggedPosition: 1), 2)
        XCTAssertEqual(SidebarDragMath.targetPosition(slot: 3, draggedPosition: 0), 2)
        XCTAssertEqual(SidebarDragMath.targetPosition(slot: 0, draggedPosition: 2), 0)
    }
}
