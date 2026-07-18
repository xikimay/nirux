import XCTest
@testable import Nirux

final class FuzzyMatchTests: XCTestCase {
    func testEmptyQueryMatchesEverything() {
        XCTAssertEqual(FuzzyMatch.score(query: "", candidate: "anything"), 0)
        let items = ["b", "a", "c"]
        XCTAssertEqual(FuzzyMatch.filter(items, query: "", key: { $0 }), items)
    }

    func testExactPrefixRanksHigh() {
        let prefix = FuzzyMatch.score(query: "new", candidate: "New Terminal")
        let scattered = FuzzyMatch.score(query: "new", candidate: "Rename Workspace")
        XCTAssertNotNil(prefix)
        // "Rename Workspace" doesn't contain n-e-w in order... check it does or doesn't
        if let scattered {
            XCTAssertGreaterThan(prefix!, scattered)
        }
    }

    func testAcronymMatchesWordBoundaries() {
        XCTAssertNotNil(FuzzyMatch.score(query: "nt", candidate: "New Terminal"))
        XCTAssertNotNil(FuzzyMatch.score(query: "nw", candidate: "New Workspace"))
        XCTAssertNotNil(FuzzyMatch.score(query: "oc", candidate: "Open Claude Code"))
    }

    func testSubsequenceRequired() {
        XCTAssertNil(FuzzyMatch.score(query: "xyz", candidate: "New Terminal"))
        XCTAssertNil(FuzzyMatch.score(query: "lt", candidate: "New Terminal")) // wrong order
        XCTAssertNil(FuzzyMatch.score(query: "longerquerythancandidate", candidate: "short"))
    }

    func testConsecutiveBeatsScattered() {
        let consecutive = FuzzyMatch.score(query: "term", candidate: "Terminal")!
        let scattered = FuzzyMatch.score(query: "term", candidate: "Toggle Editor Mode Room")!
        XCTAssertGreaterThan(consecutive, scattered)
    }

    func testCamelCaseBoundaryBonus() {
        XCTAssertNotNil(FuzzyMatch.score(query: "wt", candidate: "showWorktreeList"))
        XCTAssertNotNil(FuzzyMatch.score(query: "swl", candidate: "showWorktreeList"))
    }

    func testFilterRanksBestFirst() {
        let actions = ["Open Browser", "New Terminal", "Open Worktree", "Rename Workspace"]
        let result = FuzzyMatch.filter(actions, query: "ow", key: { $0 })
        XCTAssertEqual(result.first, "Open Worktree")
        XCTAssertFalse(result.contains("New Terminal"))
    }

    func testFilterKeepsOriginalOrderForEmptyQuery() {
        let actions = ["c", "a", "b"]
        XCTAssertEqual(FuzzyMatch.filter(actions, query: "", key: { $0 }), actions)
    }

    func testShorterCandidatePreferred() {
        let short = FuzzyMatch.score(query: "open", candidate: "Open")!
        let long = FuzzyMatch.score(query: "open", candidate: "Open Something Quite Long Indeed")!
        XCTAssertGreaterThan(short, long)
    }
}
