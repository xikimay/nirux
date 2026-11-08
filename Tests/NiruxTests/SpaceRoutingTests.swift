import XCTest
@testable import Nirux

/// Anchors and the routing of new workspaces (docs/spaces.md, "Spaces and
/// anchors" and "Routing").
final class SpaceRoutingTests: XCTestCase {
    private static let webRepository = "/code/web/.git"

    private static func space(_ id: String, _ anchors: SpaceAnchor...) -> WorkspaceProfile {
        WorkspaceProfile(id: id, name: id, colorHex: "#9ECE6A", anchors: anchors)
    }

    private static func inWeb(_ path: String) -> FolderIdentity {
        FolderIdentity(path: path, commonDir: webRepository, topLevel: "/code/web")
    }

    private static let spaces = [
        WorkspaceProfile.defaultProfile,
        space("web", .repository(commonDir: webRepository, topLevel: nil)),
        space("ui", .folder("/code/web/packages/ui")),
        space("code", .folder("/code")),
        space("other")
    ]

    // MARK: - Routing

    func testRoutingOrderIsAnchorThenParentThenStartedFromThenGeneral() {
        func route(_ identity: FolderIdentity?, parent: String?, startedFrom: String?) -> SpaceRouting.Decision {
            SpaceRouting.route(identity: identity, parentSpaceID: parent, startedFromSpaceID: startedFrom, spaces: Self.spaces)
        }
        let outside = FolderIdentity(path: "/elsewhere", commonDir: nil, topLevel: nil)

        XCTAssertEqual(route(Self.inWeb("/code/web/src"), parent: "other", startedFrom: "other"), .init(spaceID: "web", reason: .anchor))
        XCTAssertEqual(route(outside, parent: "other", startedFrom: "ui"), .init(spaceID: "other", reason: .parent))
        XCTAssertEqual(route(outside, parent: nil, startedFrom: "ui"), .init(spaceID: "ui", reason: .startedFrom))
        XCTAssertEqual(route(nil, parent: nil, startedFrom: "ui"), .init(spaceID: "ui", reason: .startedFrom), "git too slow")
        // A request from outside names nothing; a deleted space or a stale
        // NIRUX_PROFILE_ID names a space that is gone.
        XCTAssertEqual(route(outside, parent: nil, startedFrom: nil), .init(spaceID: WorkspaceProfile.defaultID, reason: .general))
        XCTAssertEqual(route(outside, parent: "deleted", startedFrom: "gone"), .init(spaceID: WorkspaceProfile.defaultID, reason: .general))
    }

    func testTheMostSpecificAnchorWins() {
        // A folder anchor inside the repository beats the repository, in
        // the main checkout.
        XCTAssertEqual(SpaceRouting.anchoringSpace(of: Self.inWeb("/code/web/packages/ui/src"), in: Self.spaces), "ui")
        // The repository beats a folder anchor holding the whole checkout.
        XCTAssertEqual(SpaceRouting.anchoringSpace(of: Self.inWeb("/code/web"), in: Self.spaces), "web")
        // A linked worktree of the repository, outside every folder anchor
        // but the parent one: still the repository's space.
        let worktree = FolderIdentity(path: "/code/web.feat-x/src", commonDir: Self.webRepository, topLevel: "/code/web.feat-x")
        XCTAssertEqual(SpaceRouting.anchoringSpace(of: worktree, in: Self.spaces), "web")
        // Outside any repository: the deepest folder anchor.
        XCTAssertEqual(
            SpaceRouting.anchoringSpace(of: FolderIdentity(path: "/code/notes", commonDir: nil, topLevel: nil), in: Self.spaces),
            "code"
        )
        XCTAssertNil(SpaceRouting.anchoringSpace(of: FolderIdentity(path: "/tmp", commonDir: nil, topLevel: nil), in: Self.spaces))
    }

    func testFolderAnchorsCompareWholePathComponents() {
        XCTAssertTrue(SpaceRouting.contains("/a/web", "/a/web"))
        XCTAssertTrue(SpaceRouting.contains("/a/web", "/a/web/src"))
        XCTAssertTrue(SpaceRouting.contains("/a/web/", "/a/web/src"))
        XCTAssertFalse(SpaceRouting.contains("/a/web", "/a/web2"))
        XCTAssertFalse(SpaceRouting.contains("/a/web", "/a"))
        XCTAssertTrue(SpaceRouting.contains("/", "/a"))
    }

    // MARK: - Identity

    /// The main checkout and a linked worktree share one identity, reached
    /// through a symlink too; a folder in no repository has none.
    @MainActor
    func testARepositoryHasOneIdentityAcrossItsWorktreesAndSymlinks() throws {
        let created = FileManager.default.temporaryDirectory.appendingPathComponent("nirux-identity-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: created, withIntermediateDirectories: true)
        // Resolved (/private/var/…), as identities are.
        let root = try XCTUnwrap(created.realPath)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let repo = root + "/repo"
        try FileManager.default.createDirectory(atPath: repo + "/src", withIntermediateDirectories: true)
        try "x\n".write(toFile: repo + "/README.md", atomically: true, encoding: .utf8)
        try UIFlowHarness.git(["init", "-q", "-b", "main"], at: repo)
        try UIFlowHarness.git(["add", "README.md"], at: repo)
        try UIFlowHarness.git(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "init"], at: repo)
        try UIFlowHarness.git(["worktree", "add", "-q", "-b", "feat", root + "/repo.feat"], at: repo)
        try FileManager.default.createSymbolicLink(atPath: root + "/link", withDestinationPath: repo)
        try FileManager.default.createDirectory(atPath: root + "/plain", withIntermediateDirectories: true)

        let main = try XCTUnwrap(FolderIdentity.identify(repo + "/src", timeout: 10))
        let linked = try XCTUnwrap(FolderIdentity.identify(root + "/repo.feat", timeout: 10))
        let viaLink = try XCTUnwrap(FolderIdentity.identify(root + "/link", timeout: 10))

        XCTAssertEqual(main.commonDir, repo + "/.git")
        XCTAssertEqual(linked.commonDir, main.commonDir)
        XCTAssertEqual(viaLink.commonDir, main.commonDir)
        XCTAssertEqual(viaLink.path, repo)
        XCTAssertEqual(linked.topLevel, root + "/repo.feat")
        // Named after the main checkout, wherever it was picked from.
        XCTAssertEqual(linked.anchor, SpaceAnchor(kind: .gitRepository(commonDir: repo + "/.git"), name: "repo"))
        XCTAssertEqual(linked.anchor.folder, repo)

        let plain = try XCTUnwrap(FolderIdentity.identify(root + "/plain", timeout: 10))
        XCTAssertNil(plain.commonDir)
        XCTAssertEqual(plain.anchor, .folder(root + "/plain"))
        XCTAssertNil(FolderIdentity.identify(root + "/missing", timeout: 10))
    }

    // MARK: - Anchors

    func testAnchorsRoundTripAndKeepWhatThisBuildCannotRead() throws {
        let json = ##"""
        [{"kind": "gitRepository", "commonDir": "/code/web/.git", "name": "web", "isDefault": true},
         {"kind": "folder", "path": "/code/docs", "name": "docs", "isDefault": false},
         {"kind": "folder", "name": "no path"},
         {"kind": "submodule", "commonDir": "/code/web/.git/modules/ui", "name": "ui"}]
        """##
        let anchors = try JSONDecoder().decode([SpaceAnchor].self, from: Data(json.utf8))

        XCTAssertEqual(anchors[0], SpaceAnchor(kind: .gitRepository(commonDir: "/code/web/.git"), name: "web", isDefault: true))
        XCTAssertEqual(anchors[1], SpaceAnchor(kind: .folder(path: "/code/docs"), name: "docs"))
        XCTAssertFalse(anchors[2].isKnown, "a folder without a path is kept, never matched")
        XCTAssertFalse(anchors[3].isKnown)
        let reencoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(anchors)) as? [[String: Any]]
        XCTAssertEqual(reencoded?[3]["kind"] as? String, "submodule")
        XCTAssertEqual(reencoded?[3]["commonDir"] as? String, "/code/web/.git/modules/ui")
        XCTAssertEqual(try JSONDecoder().decode([SpaceAnchor].self, from: JSONEncoder().encode(anchors)), anchors)
    }

    /// `state.json`'s mirror from an older build has no anchors, and a
    /// space without anchors writes none: older builds read the same thing.
    func testASpaceWithoutAnchorsIsStoredAsBefore() throws {
        let older = try JSONDecoder().decode(
            WorkspaceProfile.self, from: Data(##"{"id": "w", "name": "W", "colorHex": "#9ECE6A"}"##.utf8)
        )
        XCTAssertEqual(older.anchors, [])
        let written = try JSONSerialization.jsonObject(with: JSONEncoder().encode(older)) as? [String: Any]
        XCTAssertEqual(written.map { Set($0.keys) }, ["id", "name", "colorHex"])
    }

    func testTheDefaultFolderIsTheMainCheckoutOrTheFolder() {
        XCTAssertEqual(SpaceAnchor.repository(commonDir: "/code/web/.git", topLevel: nil).folder, "/code/web")
        // A bare repository has no main checkout to open.
        XCTAssertNil(SpaceAnchor.repository(commonDir: "/code/web.git", topLevel: nil).folder)
        XCTAssertEqual(SpaceAnchor.folder("/code/docs").folder, "/code/docs")

        var space = Self.space("s", .folder("/code/docs"), .repository(commonDir: "/code/web/.git", topLevel: nil))
        XCTAssertEqual(space.defaultFolder, "/code/docs", "the first one, when none is marked")
        space.anchors[1].isDefault = true
        XCTAssertEqual(space.defaultFolder, "/code/web")
    }

    // MARK: - One space per anchor

    @MainActor
    func testARepositoryBelongsToOneSpace() {
        let store = WorkspaceStore()
        let web = SpaceAnchor.repository(commonDir: Self.webRepository, topLevel: nil)
        let docs = SpaceAnchor.folder("/code/docs")
        store.replaceProfiles([WorkspaceProfile.defaultProfile, Self.space("a"), Self.space("b")], activeProfileID: nil)

        XCTAssertTrue(store.addAnchor(web, toProfile: "a"))
        XCTAssertTrue(store.addAnchor(docs, toProfile: "a"))
        XCTAssertEqual(store.profiles[1].anchors.map(\.isDefault), [true, false], "the first one is the default")

        // Taken by another space: the first loses it, and its next anchor
        // becomes the default.
        XCTAssertTrue(store.addAnchor(web, toProfile: "b"))
        XCTAssertEqual(store.profile(anchoring: web.key!)?.id, "b")
        XCTAssertEqual(store.profiles[1].anchors, [SpaceAnchor(kind: docs.kind, name: "docs", isDefault: true)])
        XCTAssertEqual(store.profiles[2].anchors.map(\.isDefault), [true])

        XCTAssertFalse(store.addAnchor(docs, toProfile: WorkspaceProfile.defaultID), "the default space has none")
        XCTAssertTrue(store.makeDefaultAnchor(key: docs.key!, inProfile: "a"))
        XCTAssertTrue(store.removeAnchor(key: docs.key!, fromProfile: "a"))
        XCTAssertEqual(store.profiles[1].anchors, [])

        // A file listing a repository twice (hand-edited, merged): the
        // first space keeps it.
        store.replaceProfiles(
            [WorkspaceProfile.defaultProfile, Self.space("a", web), Self.space("b", web, docs)], activeProfileID: nil
        )
        XCTAssertEqual(store.profile(anchoring: web.key!)?.id, "a")
        XCTAssertEqual(store.profiles[2].anchors, [SpaceAnchor(kind: docs.kind, name: "docs", isDefault: true)])

        // The default space has none, even from a file that gives it some:
        // it would claim them first, and no menu could remove them.
        var general = WorkspaceProfile.defaultProfile
        general.anchors = [web]
        store.replaceProfiles([general, Self.space("a", web)], activeProfileID: nil)
        XCTAssertEqual(store.profiles[0].anchors, [])
        XCTAssertEqual(store.profile(anchoring: web.key!)?.id, "a")
    }
}
