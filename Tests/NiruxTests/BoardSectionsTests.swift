import XCTest
@testable import Nirux

/// Which repository each config of board.json belongs to, and what Save
/// writes (docs/spaces.md, S12): schema 1's one config goes to the anchor
/// whose remotes name its repository, else to the default repository
/// anchor, and the file stays schema 1 while that rule places it.
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

    /// One config schema 1 would give to another anchor: written with its
    /// anchor, so it stays where the user put it.
    func testOneConfigTheRuleWouldMoveIsWrittenWithItsAnchor() {
        let front = BoardSections.sections([], context: context())[1]
        XCTAssertEqual(BoardSections.entries(saving: config("acme/front"), as: front, in: [], context: context()),
                       [Entry(slot: .anchor(commonDir: "/code/front/.git"), config: config("acme/front"))])
        let named = context(remotes: ["/code/front/.git": ["acme/front"]])
        XCTAssertEqual(BoardSections.entries(saving: config("acme/front"), as: front, in: [], context: named),
                       [Entry(slot: .legacy, config: config("acme/front"))], "a remote names it: schema 1 places it back")

        // The default's config renamed to a repository another anchor's remote names.
        let entries = [Entry(slot: .legacy, config: config("acme/web"))]
        let owner = BoardSections.sections(entries, context: named)[0]
        XCTAssertEqual(owner.name, "back")
        XCTAssertEqual(BoardSections.entries(saving: config("acme/front"), as: owner, in: entries, context: named),
                       [Entry(slot: .anchor(commonDir: "/code/back/.git"), config: config("acme/front"))])
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
}
