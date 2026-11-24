import XCTest
@testable import Nirux

/// What a Lead and a task may do to their own space and workspace with the
/// space tools (SpaceToolCaller).
final class SpaceToolCallerTests: XCTestCase {
    private let own = SpaceAnchor(kind: .gitRepository(commonDir: "/repo/.git"), name: "repo", isDefault: true)
    private let lead = SpaceToolCaller.lead(workspaceID: "lead", spaceID: "ops")
    private var task: SpaceToolCaller { SpaceToolCaller(workspaceID: "fix", spaceID: "ops", isLead: false, anchorKey: own.key) }
    private let subtask = SpaceToolCaller(workspaceID: "child", spaceID: "ops", isLead: false, parentTaskID: "fix")
    private let ops = WorkspaceProfile(id: "ops", name: "Ops", colorHex: "#7AA2F7")
    private let general = WorkspaceProfile(id: WorkspaceProfile.defaultID, name: "General", colorHex: "#7AA2F7")

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

    /// A sub-task moves with its task; a task working in its space's
    /// repository, only where that repository is.
    func testATaskMovesOnlyWithItsTaskAndWhereItsRepositoryIs() {
        XCTAssertNotNil(subtask.moveRefusal(moving: ["child"], to: general))
        XCTAssertNil(subtask.moveRefusal(moving: ["fix", "child"], to: general))
        XCTAssertNil(subtask.moveRefusal(moving: ["other"], to: general))
        XCTAssertNotNil(task.moveRefusal(moving: ["fix"], to: general))
        var anchored = ops
        anchored.anchors = [own]
        XCTAssertNil(task.moveRefusal(moving: ["fix"], to: anchored))
        XCTAssertNil(task.moveRefusal(moving: ["other"], to: general))
    }

    func testATasksRepositoryStaysInItsSpace() {
        let other = SpaceAnchor(kind: .gitRepository(commonDir: "/api/.git"), name: "api", isDefault: false)
        XCTAssertNotNil(task.anchorLossRefusal([other, own], from: "ops"))
        XCTAssertNil(task.anchorLossRefusal([other], from: "ops"))
        XCTAssertNil(task.anchorLossRefusal([own], from: "docs"))
        XCTAssertNil(lead.anchorLossRefusal([own], from: "ops"))
    }

    func testACallerThatMovedHearsWhereItIs() {
        XCTAssertNil(task.movedNote(moved: ["other"], to: general, tasksManageSpacesThere: true))
        XCTAssertEqual(task.movedNote(moved: ["fix"], to: general, tasksManageSpacesThere: true),
                       "You moved too: you are in “General” (space:default) now.")
        XCTAssertEqual(task.movedNote(moved: ["fix"], to: ops, tasksManageSpacesThere: false),
                       "You moved too: you are in “Ops” (space:ops) now, whose tasks can't manage spaces: these tools refuse your calls from now on.")
    }
}
