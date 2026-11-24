import XCTest
@testable import Nirux

/// What a Lead and a task may do to their own space and workspace with the
/// space tools (SpaceToolCaller).
final class SpaceToolCallerTests: XCTestCase {
    private let lead = SpaceToolCaller.lead(workspaceID: "lead", spaceID: "ops")
    private let task = SpaceToolCaller(workspaceID: "fix", spaceID: "ops", isLead: false, anchorKey: "repo-key")
    private let subtask = SpaceToolCaller(workspaceID: "child", spaceID: "ops", isLead: false, parentTaskID: "fix")
    private let ops = WorkspaceProfile(id: "ops", name: "Ops", colorHex: "#7AA2F7")

    /// Only a Lead organizes a space's tasks, its own.
    func testOnlyALeadLeadsItsOwnSpace() {
        XCTAssertTrue(lead.leads("ops"))
        XCTAssertFalse(lead.leads("docs"))
        XCTAssertFalse(task.leads("ops"))
    }

    /// A Lead's space goes with its Lead; a task's, with the task moving out.
    func testATaskMayDeleteItsOwnSpaceALeadMayNot() {
        XCTAssertEqual(lead.deletionRefusal(of: ops), "“Ops” is your own space: you can't delete it.")
        XCTAssertNil(task.deletionRefusal(of: ops))
    }

    func testASubtaskMovesOnlyWithItsTask() {
        XCTAssertNotNil(subtask.moveRefusal(moving: ["child"]))
        XCTAssertNil(subtask.moveRefusal(moving: ["fix", "child"]))
        XCTAssertNil(subtask.moveRefusal(moving: ["other"]))
        XCTAssertNil(task.moveRefusal(moving: ["fix"]))
    }

    func testATasksRepositoryStaysInItsSpace() {
        let own = SpaceAnchor(kind: .gitRepository(commonDir: "/repo/.git"), name: "repo", isDefault: true)
        let other = SpaceAnchor(kind: .gitRepository(commonDir: "/api/.git"), name: "api", isDefault: false)
        let mine = SpaceToolCaller(workspaceID: "fix", spaceID: "ops", isLead: false, anchorKey: own.key)
        XCTAssertNotNil(mine.anchorLossRefusal([other, own], from: "ops"))
        XCTAssertNil(mine.anchorLossRefusal([other], from: "ops"))
        XCTAssertNil(mine.anchorLossRefusal([own], from: "docs"))
        XCTAssertNil(lead.anchorLossRefusal([own], from: "ops"))
    }

    func testACallerThatMovedHearsWhereItIs() {
        let general = WorkspaceProfile(id: WorkspaceProfile.defaultID, name: "General", colorHex: "#7AA2F7")
        XCTAssertNil(task.movedNote(moved: ["other"], to: general, tasksManageSpacesThere: true))
        XCTAssertEqual(task.movedNote(moved: ["fix"], to: general, tasksManageSpacesThere: true),
                       "You moved too: you are in “General” (space:default) now.")
        XCTAssertEqual(task.movedNote(moved: ["fix"], to: ops, tasksManageSpacesThere: false),
                       "You moved too: you are in “Ops” (space:ops) now, whose tasks can't manage spaces: these tools refuse your calls from now on.")
    }
}
