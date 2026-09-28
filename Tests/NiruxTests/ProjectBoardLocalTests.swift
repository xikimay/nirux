import XCTest
@testable import Nirux

/// The board's local read: `git worktree list` in the project's folders,
/// in temporary repositories.
final class ProjectBoardLocalTests: XCTestCase {
    private var root: String!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("nirux-board-local-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        root = try XCTUnwrap(base.path.realPath)
    }

    override func tearDown() {
        if let root { try? FileManager.default.removeItem(atPath: root) }
        super.tearDown()
    }

    func testEachRepositoryIsListedOnceWithItsRemotesAndResolvedPaths() throws {
        let repo = root + "/widgets"
        try BoardConfigSuggestionsTests.makeRepository(at: repo, remote: "git@github.com:acme/widgets.git")
        let feature = root + "/widgets.feat"
        try BoardConfigSuggestionsTests.git(["worktree", "add", "-q", "-b", "feat", feature], at: repo)
        let gone = root + "/widgets.gone"
        try BoardConfigSuggestionsTests.git(["worktree", "add", "-q", "-b", "gone", gone], at: repo)
        try FileManager.default.removeItem(atPath: gone)
        let link = root + "/link"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: feature)
        let plain = root + "/plain"
        try FileManager.default.createDirectory(atPath: plain, withIntermediateDirectories: true)

        let snapshot = ProjectBoard.readLocal(folders: [link, repo + "/.github", plain, root + "/missing"])

        XCTAssertEqual(snapshot.repositories.count, 1, "three folders, one repository")
        let repository = try XCTUnwrap(snapshot.repositories.first)
        XCTAssertEqual(repository.remotes, [GitHubRepository(owner: "acme", name: "widgets")])
        XCTAssertEqual(repository.worktrees.map(\.path), [repo, feature, gone])
        XCTAssertEqual(repository.worktrees.map(\.branch), ["main", "feat", "gone"])
        XCTAssertEqual(repository.worktrees.map(\.isPrunable), [false, false, true], "its folder is gone")
        XCTAssertEqual(snapshot.folders[link], feature, "compared with symlinks resolved")
        XCTAssertEqual(snapshot.folders[plain], plain)
        XCTAssertEqual(snapshot.folders[root + "/missing"], root + "/missing")

        let rows = ProjectBoard.rows(ProjectBoard.Sources(
            repository: GitHubRepository(owner: "acme", name: "widgets"),
            local: snapshot.repositories,
            workspaces: [ProjectBoard.Workspace(
                id: "ws", title: "feature", folder: try XCTUnwrap(snapshot.folders[link]), isInactive: false,
                agent: ProjectBoard.Agent()
            )]
        ))
        XCTAssertEqual(rows.map(\.name), ["main", "feature"])
    }
}
