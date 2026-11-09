import XCTest
@testable import Nirux

/// Which repository each config of board.json belongs to, and what Save
/// writes (docs/spaces.md, S12): schema 1's one config goes to the anchor
/// whose remotes name its repository, else to the default repository
/// anchor, and the file stays schema 1 while that rule places it on the
/// default repository, as an older Nirux reads it.
final class BoardSectionsTests: XCTestCase {
    private typealias Entry = BoardConfigStore.Entry

    private let front = SpaceAnchor(kind: .gitRepository(commonDir: "/code/front/.git"), name: "front")
    private let back = SpaceAnchor(kind: .gitRepository(commonDir: "/code/back/.git"), name: "back", isDefault: true)
    private let docs = SpaceAnchor.folder("/code/docs")

    private func config(_ repository: String) -> BoardConfig {
        BoardConfig(repository: repository, baseBranch: "main", requiredChecks: ["test"], postMergeWorkflow: .noWorkflow)
    }

    private func context(remotes: [String: [String]] = [:]) -> BoardSections.Context {
        BoardSections.Context(
            anchors: [docs, front, back],
            remotes: remotes.mapValues { $0.compactMap(GitHubRepository.init(ownerAndName:)) }
        )
    }

    private func summary(_ sections: [BoardSections.Section]) -> [String] {
        sections.map { "\($0.name ?? "-"):\($0.config?.repository ?? "none"):\($0.slot == .legacy ? "legacy" : "own")" }
    }

    func testRepositoryAnchorsOnlyTheDefaultFirst() {
        XCTAssertEqual(BoardSections.repositoryAnchors([docs, front, back]).map(\.name), ["back", "front"])
        XCTAssertEqual(BoardSections.repositoryAnchors([docs]), [])
    }

    func testTheLegacyConfigGoesToTheAnchorWhoseRemoteNamesIt() {
        let entries = [Entry(slot: .legacy, config: config("acme/front"))]
        // An SSH host alias spells github.com another way: owner and name count.
        let named = context(remotes: ["/code/front/.git": ["acme/front"], "/code/back/.git": ["acme/back"]])
        XCTAssertEqual(summary(BoardSections.sections(entries, context: named)), ["back:none:own", "front:acme/front:legacy"])

        // No remote names it: the default repository anchor.
        XCTAssertEqual(summary(BoardSections.sections(entries, context: context())), ["back:acme/front:legacy", "front:none:own"])
    }

    func testAnAnchorWithItsOwnConfigDoesntTakeTheLegacyOne() {
        let entries = [
            Entry(slot: .legacy, config: config("acme/web")),
            Entry(slot: .anchor(commonDir: "/code/back/.git"), config: config("acme/back"))
        ]
        XCTAssertEqual(summary(BoardSections.sections(entries, context: context())), ["back:acme/back:own", "front:acme/web:legacy"])
    }

    func testASpaceWithoutRepositoryAnchorsHasItsOneSection() {
        let entries = [Entry(slot: .legacy, config: config("acme/web"))]
        let sections = BoardSections.sections(entries, context: BoardSections.Context(anchors: [docs]))
        XCTAssertEqual(summary(sections), ["-:acme/web:legacy"])
        XCTAssertEqual(sections.first?.id, "legacy")
        XCTAssertEqual(summary(BoardSections.sections([], context: BoardSections.Context())), ["-:none:legacy"])
    }

    // MARK: - Saving

    func testEditingTheOneConfigKeepsSchema1() {
        let entries = [Entry(slot: .legacy, config: config("acme/web"))]
        let section = BoardSections.sections(entries, context: context())[0]
        var edited = config("acme/web")
        edited.baseBranch = "develop"
        XCTAssertEqual(BoardSections.entries(saving: edited, as: section, in: entries, context: context()),
                       [Entry(slot: .legacy, config: edited)])
    }

    func testASecondConfigPlacesTheFirstOneExplicitly() {
        let entries = [Entry(slot: .legacy, config: config("acme/web"))]
        let sections = BoardSections.sections(entries, context: context())
        XCTAssertEqual(BoardSections.entries(saving: config("acme/front"), as: sections[1], in: entries, context: context()), [
            Entry(slot: .anchor(commonDir: "/code/back/.git"), config: config("acme/web")),
            Entry(slot: .anchor(commonDir: "/code/front/.git"), config: config("acme/front"))
        ])
    }

    /// One config schema 1 would give to another anchor, or that isn't the
    /// default repository's: written with its anchor, so it stays where the
    /// user put it, and an older Nirux, which reads schema 1 as the default
    /// repository's, leaves it alone.
    func testOneConfigTheRuleWouldMoveIsWrittenWithItsAnchor() {
        let sections = BoardSections.sections([], context: context())
        let front = sections[1]
        XCTAssertEqual(BoardSections.entries(saving: config("acme/front"), as: front, in: [], context: context()),
                       [Entry(slot: .anchor(commonDir: "/code/front/.git"), config: config("acme/front"))])
        let named = context(remotes: ["/code/front/.git": ["acme/front"], "/code/back/.git": ["acme/back"]])
        XCTAssertEqual(BoardSections.entries(saving: config("acme/front"), as: front, in: [], context: named),
                       [Entry(slot: .anchor(commonDir: "/code/front/.git"), config: config("acme/front"))],
                       "its remote names it, but it isn't the default repository")
        XCTAssertEqual(BoardSections.entries(saving: config("acme/back"), as: sections[0], in: [], context: named),
                       [Entry(slot: .legacy, config: config("acme/back"))], "the default repository's: schema 1")

        // The default's config renamed to a repository another anchor's remote names.
        let entries = [Entry(slot: .legacy, config: config("acme/web"))]
        let owner = BoardSections.sections(entries, context: named)[0]
        XCTAssertEqual(owner.name, "back")
        XCTAssertEqual(BoardSections.entries(saving: config("acme/front"), as: owner, in: entries, context: named),
                       [Entry(slot: .anchor(commonDir: "/code/back/.git"), config: config("acme/front"))])
    }

    /// Schema 1's config was the anchor's that its remote names: once that
    /// one has its own, no other anchor takes the old one.
    func testTheLegacyConfigGoesNowhereElseOnceItsAnchorHasItsOwn() {
        let named = context(remotes: ["/code/front/.git": ["acme/front"]])
        let entries = [
            Entry(slot: .legacy, config: config("acme/front")),
            Entry(slot: .anchor(commonDir: "/code/front/.git"), config: config("acme/front-v2"))
        ]
        XCTAssertEqual(summary(BoardSections.sections(entries, context: named)), ["back:none:own", "front:acme/front-v2:own"])
    }

    /// An anchor whose remotes git couldn't read might name the one config
    /// saved: it is written with its anchor, not left to the rule. (Board
    /// Settings refuses to save while schema 1's config waits for a place.)
    func testOneConfigIsWrittenWithItsAnchorWhileARemoteIsUnread() {
        var unread = context()
        unread.unread = ["/code/front/.git"]
        let back = BoardSections.sections([], context: unread)[0]
        XCTAssertEqual(back.name, "back")
        XCTAssertEqual(BoardSections.entries(saving: config("acme/back"), as: back, in: [], context: unread),
                       [Entry(slot: .anchor(commonDir: "/code/back/.git"), config: config("acme/back"))])
        XCTAssertEqual(BoardSections.entries(saving: config("acme/back"), as: back, in: [], context: context()),
                       [Entry(slot: .legacy, config: config("acme/back"))], "with every remote read: schema 1")
    }

    func testTwoAnchorsWithOneNameAreToldApart() {
        let other = SpaceAnchor(kind: .gitRepository(commonDir: "/elsewhere/front/.git"), name: "front")
        let sections = BoardSections.sections([], context: BoardSections.Context(anchors: [front, other, back]))
        let names = BoardSections.displayNames(sections)
        XCTAssertEqual(sections.map { names[$0.id] }, ["back", "front (/code/front)", "front (/elsewhere/front)"])
    }

    /// A removed anchor's config stays in the file: adding the repository
    /// back brings it back.
    func testAConfigOfARemovedAnchorIsKept() {
        let gone = Entry(slot: .anchor(commonDir: "/code/gone/.git"), config: config("acme/gone"))
        let sections = BoardSections.sections([gone], context: context())
        XCTAssertEqual(summary(sections), ["back:none:own", "front:none:own"])
        XCTAssertEqual(BoardSections.entries(saving: config("acme/back"), as: sections[0], in: [gone], context: context()),
                       [gone, Entry(slot: .anchor(commonDir: "/code/back/.git"), config: config("acme/back"))])
    }

    /// Each repository anchor without a config of its own reads where its
    /// pull requests live, whatever its branch pushes to: the remote gh's
    /// set-default marked, else upstream, github, origin, then the others,
    /// by its fetch URL, spelled as the URL does, with the branch
    /// `<remote>/HEAD` points to. A bare repository and a git dir apart
    /// from its checkout too; an SSH alias as ssh resolves it (answered
    /// here in its place); another host, named; no remote; a checkout
    /// gone or not a repository. An anchor with a config reads nothing.
    func testEachAnchorWithoutAConfigReadsWhereItsPullRequestsLive() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("nirux-remotes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = try XCTUnwrap(base.path.realPath)
        let git = BoardConfigSuggestionsTests.git
        let make = { (name: String, remote: String?) in
            try BoardConfigSuggestionsTests.makeRepository(at: root + "/" + name, remote: remote)
        }
        // Pushes to a fork, its pull requests in origin: a triangular setup.
        try make("triangle", "https://github.com/Acme/App.git")
        _ = try git(["remote", "add", "fork", "git@github.com:me/app.git"], root + "/triangle")
        _ = try git(["config", "remote.pushDefault", "fork"], root + "/triangle")
        _ = try git(["config", "branch.main.pushRemote", "fork"], root + "/triangle")
        _ = try git(["remote", "set-url", "--push", "origin", "git@github.com:me/app.git"], root + "/triangle")
        // A clone of a fork: its pull requests in upstream.
        try make("fork", "https://github.com/me/fork.git")
        _ = try git(["remote", "add", "upstream", "https://github.com/acme/real.git"], root + "/fork")
        _ = try git(["update-ref", "refs/remotes/upstream/trunk", "HEAD"], root + "/fork")
        _ = try git(["symbolic-ref", "refs/remotes/upstream/HEAD", "refs/remotes/upstream/trunk"], root + "/fork")
        // gh's set-default wins over upstream.
        try make("marked", "https://github.com/acme/origin.git")
        _ = try git(["remote", "add", "upstream", "https://github.com/acme/upstream.git"], root + "/marked")
        _ = try git(["remote", "add", "chosen", "https://github.com/acme/chosen.git"], root + "/marked")
        _ = try git(["config", "remote.chosen.gh-resolved", "base"], root + "/marked")
        _ = try git(["init", "-q", "-b", "main", "--separate-git-dir=" + root + "/apart.git", root + "/apart"], root)
        _ = try git(["remote", "add", "origin", "https://github.com/acme/apart.git"], root + "/apart")
        _ = try git(["clone", "-q", "--bare", root + "/fork", root + "/bare.git"], root)
        _ = try git(["remote", "set-url", "origin", "https://github.com/acme/bare.git"], root + "/bare.git")
        try make("alias", "git@github-work:acme/alias.git")
        try make("lab", "git@lab-work:acme/lab.git")
        try make("slow", "git@slow-host:acme/slow.git")
        try make("docs", nil)
        try make("saved", "https://github.com/acme/saved.git")
        try FileManager.default.createDirectory(atPath: root + "/plain/.git", withIntermediateDirectories: true)
        let anchor = { (gitDir: String) in SpaceAnchor(kind: .gitRepository(commonDir: root + "/" + gitDir), name: gitDir) }
        let names = [
            "triangle/.git", "fork/.git", "marked/.git", "apart.git", "bare.git", "alias/.git", "lab/.git",
            "slow/.git", "docs/.git", "saved/.git", "plain/.git", "gone/.git"
        ]
        let context = BoardSections.Context(anchors: names.map(anchor))
        let entries = [Entry(slot: .anchor(commonDir: root + "/saved/.git"), config: config("acme/saved"))]
        let aliases: @Sendable (String) -> Bool? = { host in
            ["github-work": true, "lab-work": false][host] ?? nil
        }
        XCTAssertEqual(BoardSections.readBaseRemotes(BoardSections.sections(entries, context: context), resolveAlias: aliases), [
            root + "/triangle/.git": .gitHub(repository: "Acme/App", baseBranch: "main", remote: "origin"),
            root + "/fork/.git": .gitHub(repository: "acme/real", baseBranch: "trunk", remote: "upstream"),
            root + "/marked/.git": .gitHub(repository: "acme/chosen", baseBranch: nil, remote: "chosen"),
            root + "/apart.git": .gitHub(repository: "acme/apart", baseBranch: nil, remote: "origin"),
            root + "/bare.git": .gitHub(repository: "acme/bare", baseBranch: nil, remote: "origin"),
            root + "/alias/.git": .gitHub(repository: "acme/alias", baseBranch: "main", remote: "origin"),
            root + "/lab/.git": .notGitHub(host: "lab-work", remote: "origin"),
            root + "/slow/.git": .unread,
            root + "/docs/.git": .noRemote,
            root + "/plain/.git": .notARepository,
            root + "/gone/.git": .notARepository
        ])
    }

    /// The remotes in the order gh tries them for its base repository.
    func testRemotesAreTriedInGhsOrder() {
        let config = [
            "remote.zeta.url https://github.com/a/zeta.git", "remote.origin.url https://github.com/a/origin.git",
            "remote.alpha.url https://github.com/a/alpha.git", "remote.github.url https://github.com/a/github.git",
            "remote.my.dots.url https://github.com/a/dots.git", "remote.upstream.url https://github.com/a/upstream.git",
            "remote.zeta.gh-resolved base", "remote.nourl.gh-resolved base"
        ].joined(separator: "\n")
        XCTAssertEqual(GitHubBaseRemote.remotes(inConfig: config).map(\.name), ["zeta", "upstream", "github", "origin", "alpha", "my.dots"])
    }

    /// git or ssh not answering, or giving no default branch, keeps what
    /// was read before; a checkout gone, or anything else read, replaces it.
    func testAFailedRemoteReadKeepsTheOneReadBefore() {
        let known: [String: BoardSections.BaseRemote] = [
            "/a/.git": .gitHub(repository: "acme/a", baseBranch: "main", remote: "origin"),
            "/b/.git": .gitHub(repository: "acme/b", baseBranch: "main", remote: "origin"),
            "/c/.git": .gitHub(repository: "acme/c", baseBranch: "main", remote: "origin"),
            "/e/.git": .gitHub(repository: "acme/e", baseBranch: "main", remote: "origin")
        ]
        let read: [String: BoardSections.BaseRemote] = [
            "/a/.git": .unread,
            "/b/.git": .gitHub(repository: "acme/b", baseBranch: nil, remote: "origin"),
            "/c/.git": .gitHub(repository: "acme/other", baseBranch: nil, remote: "origin"),
            "/d/.git": .unread,
            "/e/.git": .notARepository
        ]
        XCTAssertEqual(ProjectBoardController.merged(read, keeping: known), [
            "/a/.git": .gitHub(repository: "acme/a", baseBranch: "main", remote: "origin"),
            "/b/.git": .gitHub(repository: "acme/b", baseBranch: "main", remote: "origin"),
            "/c/.git": .gitHub(repository: "acme/other", baseBranch: nil, remote: "origin"),
            "/d/.git": .unread,
            "/e/.git": .notARepository
        ])
    }
}
