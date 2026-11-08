import AppKit
import XCTest
@testable import Nirux

/// docs/spaces.md, "Routing", through the shell: where new workspaces land,
/// the banner of one that lands in the default space, and the default
/// folder of a space with a repository.
@MainActor
final class SpaceRoutingFlowTests: XCTestCase {
    func testNewWorkspacesLandWhereTheirFolderBelongs() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let other = shell.workspaceStore.createProfile(named: "Other", select: false)
            @MainActor func workspace(_ title: String) -> WorkspaceState? {
                shell.workspaces.first { $0.title == title && !$0.isClosing }
            }

            // A worktree an agent asks for joins its parent's space, not the
            // one on screen (the skill always sends its parent now).
            shell.openRoutedWorkspace(title: "parent", cwd: harness.home, startedFromSpaceID: other.id)
            let parent = try XCTUnwrap(workspace("parent"))
            XCTAssertEqual(parent.profileID, other.id)
            shell.selectProfile(WorkspaceProfile.defaultID)
            shell.createWorktreeWorkspace(branch: "feat/child", repoRoot: harness.repo, agent: nil, parentWorkspaceID: parent.id)
            harness.waitUntil("the worktree's workspace") { workspace("feat/child") != nil }
            XCTAssertEqual(workspace("feat/child")?.profileID, other.id)
            XCTAssertNil(shell.spaceArrivalBanner)

            // Once a space has the repository, its worktrees go there, even
            // when a request from outside names nothing.
            let repository = try XCTUnwrap(FolderIdentity.identify(harness.repo, timeout: 10)).anchor
            let anchored = shell.workspaceStore.createProfile(named: "Anchored", anchors: [repository], select: false)
            shell.openRequestedWorkspace(title: "from outside", cwd: harness.worktree, agent: nil, requestedSpaceID: nil)
            harness.waitUntil("the request's workspace") { workspace("from outside") != nil }
            XCTAssertEqual(workspace("from outside")?.profileID, anchored.id)
            XCTAssertNil(shell.spaceArrivalBanner)

            // In no repository: the parent's space, else the space it was
            // started from.
            let notes = harness.root + "/notes"
            try FileManager.default.createDirectory(atPath: notes, withIntermediateDirectories: true)
            shell.openRoutedWorkspace(title: "child", cwd: notes, parentWorkspaceID: parent.id, startedFromSpaceID: anchored.id)
            harness.waitUntil("the child") { workspace("child") != nil }
            XCTAssertEqual(workspace("child")?.profileID, other.id)
            shell.openRoutedWorkspace(title: "started", cwd: notes, startedFromSpaceID: anchored.id)
            harness.waitUntil("the started one") { workspace("started") != nil }
            XCTAssertEqual(workspace("started")?.profileID, anchored.id)

            // From outside, in no repository: the default space, and a
            // banner that says so.
            shell.openRequestedWorkspace(title: "stray", cwd: notes, agent: nil, requestedSpaceID: nil)
            harness.waitUntil("the stray workspace") { workspace("stray") != nil }
            let stray = try XCTUnwrap(workspace("stray"))
            XCTAssertEqual(stray.profileID, WorkspaceProfile.defaultID)
            let banner = try XCTUnwrap(shell.spaceArrivalBanner)
            XCTAssertIdentical(banner.superview, shell)
            XCTAssertEqual(banner.workspaceID, stray.id)
            XCTAssertTrue(banner.message.hasPrefix("“stray” opened in "), banner.message)
            XCTAssertEqual(shell.spaceArrivalMoveMenu(workspaceID: stray.id)?.items.map(\.title), ["Other", "Anchored"])
            let anchorMenu = try XCTUnwrap(shell.spaceArrivalAnchorMenu(workspaceID: stray.id))
            XCTAssertEqual(anchorMenu.items.filter { !$0.isSeparatorItem }.map(\.title), ["Other", "Anchored", "New Space…"])

            // "Anchor to…" Other: in no repository, the folder joins Other
            // once the user agrees, so does the workspace, and the other
            // workspaces in that folder are offered, unchecked when they
            // aren't in the default space.
            anchorMenu.performActionForItem(at: 0)
            XCTAssertNil(shell.spaceArrivalBanner)
            harness.waitUntil("the stray workspace to move") { stray.profileID == other.id }
            XCTAssertTrue(harness.alerts.contains("“notes” isn’t in a git repository"))
            XCTAssertEqual(shell.profiles.first { $0.id == other.id }?.anchors, [
                SpaceAnchor(kind: .folder(path: notes), name: "notes", isDefault: true)
            ])
            harness.waitUntil("the offer") { harness.alerts.last == "Move workspaces to “Other”?" }
            XCTAssertEqual(workspace("started")?.profileID, anchored.id, "offered unchecked")

            // A plain new workspace of a space with a repository opens in
            // its main checkout.
            shell.addWorkspace(title: "plain", profileID: anchored.id)
            XCTAssertEqual(workspace("plain")?.cwd, harness.repo)
        }
    }
}
