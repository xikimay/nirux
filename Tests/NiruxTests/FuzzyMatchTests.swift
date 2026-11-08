import XCTest
@testable import Nirux

final class FuzzyMatchTests: XCTestCase {
    func testEmptyQueryMatchesEverything() {
        XCTAssertEqual(FuzzyMatch.score(query: "", candidate: "anything"), 0)
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

    func testShorterCandidatePreferred() {
        let short = FuzzyMatch.score(query: "open", candidate: "Open")!
        let long = FuzzyMatch.score(query: "open", candidate: "Open Something Quite Long Indeed")!
        XCTAssertGreaterThan(short, long)
    }
}
