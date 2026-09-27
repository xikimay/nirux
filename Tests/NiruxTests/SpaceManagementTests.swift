import XCTest
@testable import Nirux

/// Spaces that persist (see ProjectStore): selection, deletion, moves, colors.
final class SpaceManagementTests: XCTestCase {
    @MainActor
    func testProjectsFileMarkerRoundTripsAndOlderStateDecodesWithoutIt() throws {
        var state = PersistedState(workspaces: [], activeWorkspaceIndex: 0)
        state.projectsFileVersion = 1
        let decoded = try JSONDecoder().decode(PersistedState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded.projectsFileVersion, 1)

        let older = try JSONDecoder().decode(
            PersistedState.self, from: Data(#"{"workspaces": [], "activeWorkspaceIndex": 0}"#.utf8)
        )
        XCTAssertNil(older.projectsFileVersion)
    }

    @MainActor
    func testKeyboardSpaceCyclingSkipsEmptySpaces() {
        let store = WorkspaceStore()
        let empty = WorkspaceProfile(id: "empty", name: "empty", colorHex: "#E0AF68")
        let work = WorkspaceProfile(id: "work", name: "work", colorHex: "#9ECE6A")
        store.replaceProfiles([WorkspaceProfile.defaultProfile, empty, work], activeProfileID: WorkspaceProfile.defaultID)
        let first = WorkspaceState(id: "main", title: "main", cwd: "/tmp/main")
        let second = WorkspaceState(id: "w", title: "w", cwd: "/tmp/w")
        second.profileID = work.id
        store.appendWorkspace(first)
        store.appendWorkspace(second)
        store.selectWorkspace(id: "main")

        XCTAssertEqual(store.selectAdjacentProfile(delta: 1)?.id, work.id)
        XCTAssertEqual(store.selectAdjacentProfile(delta: 1)?.id, WorkspaceProfile.defaultID)
    }

    @MainActor
    func testNewSpacesTakeAColorNoSpaceUses() {
        let store = WorkspaceStore()
        let green = WorkspaceProfile(id: "g", name: "g", colorHex: WorkspaceProfile.palette[1].hex)
        store.replaceProfiles([WorkspaceProfile.defaultProfile, green], activeProfileID: nil)

        XCTAssertEqual(store.createProfile(named: "new").colorHex, WorkspaceProfile.palette[2].hex)
    }

    @MainActor
    func testMovingTheActiveWorkspaceSelectsANeighbourOrFollowsIt() {
        let store = WorkspaceStore()
        let work = WorkspaceProfile(id: "work", name: "Work", colorHex: "#9ECE6A")
        let home = WorkspaceProfile(id: "home", name: "Home", colorHex: "#E0AF68")
        store.replaceProfiles([WorkspaceProfile.defaultProfile, work, home], activeProfileID: nil)
        for id in ["a", "b", "c"] {
            let workspace = WorkspaceState(id: id, title: id, cwd: "/tmp/\(id)")
            workspace.profileID = work.id
            store.appendWorkspace(workspace)
        }
        let other = WorkspaceState(id: "m", title: "m", cwd: "/tmp/m")
        store.appendWorkspace(other, activate: false)

        store.selectWorkspace(id: "c")
        XCTAssertTrue(store.moveWorkspace(at: store.workspaces.firstIndex { $0.id == "c" }!, toProfile: home.id))
        XCTAssertEqual(store.activeWorkspace?.id, "b", "its neighbour in the space it left")
        XCTAssertEqual(store.activeProfileID, work.id)

        // Moving the last workspace of a space: the selection follows it.
        store.selectWorkspace(id: "c")
        XCTAssertTrue(store.moveWorkspace(at: store.workspaces.firstIndex { $0.id == "c" }!, toProfile: work.id))
        XCTAssertEqual(store.activeWorkspace?.id, "c")
        XCTAssertEqual(store.activeProfileID, work.id)

        store.selectWorkspace(id: "a")
        for id in ["a", "b", "c"] {
            XCTAssertTrue(store.moveWorkspace(at: store.workspaces.firstIndex { $0.id == id }!, toProfile: home.id))
        }
        // Each move of the active one selected a neighbour, until none was left.
        XCTAssertEqual(store.activeProfileID, home.id)
        XCTAssertEqual(store.activeWorkspace?.id, "c")
        // Moved workspaces go to the end of their new space.
        XCTAssertEqual(store.visibleWorkspaceIndices(in: home.id).map { store.workspaces[$0].id }, ["a", "b", "c"])
    }

    @MainActor
    func testDeletingASpaceMovesItsWorkspacesToTheDefaultSpace() {
        let store = WorkspaceStore()
        let work = WorkspaceProfile(id: "work", name: "Work", colorHex: "#9ECE6A")
        store.replaceProfiles([WorkspaceProfile.defaultProfile, work], activeProfileID: work.id)
        let first = WorkspaceState(id: "a", title: "a", cwd: "/tmp/a")
        first.profileID = work.id
        let second = WorkspaceState(id: "b", title: "b", cwd: "/tmp/b")
        second.profileID = work.id
        store.appendWorkspace(first)
        store.appendWorkspace(second)

        XCTAssertFalse(store.deleteProfile(id: WorkspaceProfile.defaultID))
        XCTAssertTrue(store.deleteProfile(id: work.id))

        XCTAssertEqual(store.profiles.map(\.id), [WorkspaceProfile.defaultID])
        XCTAssertEqual(store.workspaces.map(\.profileID), [WorkspaceProfile.defaultID, WorkspaceProfile.defaultID])
        XCTAssertEqual(store.activeProfileID, WorkspaceProfile.defaultID)
        XCTAssertEqual(store.activeWorkspace?.profileID, WorkspaceProfile.defaultID)
    }

    @MainActor
    func testWorkspaceMovesToAnotherSpaceAndSpacesCanBeRecolored() {
        let store = WorkspaceStore()
        let work = WorkspaceProfile(id: "work", name: "Work", colorHex: "#9ECE6A")
        store.replaceProfiles([WorkspaceProfile.defaultProfile, work], activeProfileID: WorkspaceProfile.defaultID)
        let stays = WorkspaceState(id: "stays", title: "stays", cwd: "/tmp/stays")
        let moves = WorkspaceState(id: "moves", title: "moves", cwd: "/tmp/moves")
        store.appendWorkspace(stays)
        store.appendWorkspace(moves)

        XCTAssertTrue(store.moveWorkspace(at: 1, toProfile: work.id))
        XCTAssertFalse(store.moveWorkspace(at: 1, toProfile: work.id), "already there")
        XCTAssertFalse(store.moveWorkspace(at: 1, toProfile: "unknown"))

        XCTAssertEqual(store.workspaces[1].profileID, work.id)
        // The current space still has a workspace, so it keeps the selection.
        XCTAssertEqual(store.activeProfileID, WorkspaceProfile.defaultID)
        XCTAssertEqual(store.activeWorkspace?.id, "stays")

        XCTAssertTrue(store.setProfileColor(id: work.id, colorHex: "#F7768E"))
        XCTAssertEqual(store.profiles.first { $0.id == work.id }?.colorHex, "#F7768E")
    }
}
