import XCTest
@testable import Nirux

final class PRDetectTests: XCTestCase {
    func testInactiveWorkspaceNeverRefreshesGitHub() {
        XCTAssertFalse(PRDetect.shouldRefresh(isInactive: true, branch: "feature/task"))
    }

    func testActiveWorkspaceWithBranchRefreshesGitHub() {
        XCTAssertTrue(PRDetect.shouldRefresh(isInactive: false, branch: "feature/task"))
    }

    func testWorkspaceWithoutBranchDoesNotRefreshGitHub() {
        XCTAssertFalse(PRDetect.shouldRefresh(isInactive: false, branch: nil))
        XCTAssertFalse(PRDetect.shouldRefresh(isInactive: false, branch: "   "))
    }
}
