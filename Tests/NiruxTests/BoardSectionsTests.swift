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

    /// An anchor whose remotes git couldn't read might be the one schema 1's
    /// config belongs to: nothing is placed for good meanwhile.
    func testNothingIsPlacedForGoodWhileARemoteIsUnread() {
        var unread = context()
        unread.unread = ["/code/front/.git"]
        let entries = [Entry(slot: .legacy, config: config("acme/front"))]
        let sections = BoardSections.sections(entries, context: unread)
        XCTAssertEqual(summary(sections), ["back:acme/front:legacy", "front:none:own"], "shown where the rule puts it now")
        XCTAssertEqual(BoardSections.entries(saving: config("acme/back"), as: sections[1], in: entries, context: unread), [
            Entry(slot: .legacy, config: config("acme/front")),
            Entry(slot: .anchor(commonDir: "/code/front/.git"), config: config("acme/back"))
        ], "schema 1's config keeps no anchor")
        var edited = config("acme/front")
        edited.baseBranch = "develop"
        XCTAssertEqual(BoardSections.entries(saving: edited, as: sections[0], in: entries, context: unread),
                       [Entry(slot: .legacy, config: edited)])
        XCTAssertEqual(BoardSections.entries(saving: config("acme/back"), as: sections[1], in: [], context: unread),
                       [Entry(slot: .anchor(commonDir: "/code/front/.git"), config: config("acme/back"))],
                       "one config: written with its anchor, not left to the rule")
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
}
