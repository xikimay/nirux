import XCTest
@testable import Nirux

/// Explain's first-use notice (docs/branch-review.md, section 4.3): what
/// goes where, under which account; once per project and account, every
/// time for an account billed per call.
final class BranchReviewExplainNoticeTests: XCTestCase {
    @MainActor
    func testTheNoticeAsksOncePerProjectAndAccount() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let workspace = try XCTUnwrap(shell.activeWorkspace)
            let project = workspace.profileID
            let review = shell.makeBranchReview(worktree: harness.repo, branch: nil)
            workspace.addBranchReviewColumn(review)
            let max = BranchReview.ExplainAccount(isLoggedIn: true, method: "claude.ai", subscription: "max", email: "a@example.test")
            XCTAssertTrue(shell.confirmExplain(for: review, account: max, files: 3))
            XCTAssertTrue(shell.confirmExplain(for: review, account: max, files: 3))
            XCTAssertEqual(harness.alerts, ["Explain this branch with Claude?"])

            // Another project asks for itself.
            workspace.profileID = "another-project"
            XCTAssertTrue(shell.confirmExplain(for: review, account: max, files: 3))
            XCTAssertTrue(shell.confirmExplain(for: review, account: max, files: 3))
            XCTAssertEqual(harness.alerts.count, 2)
            XCTAssertEqual(
                Persistence.load()?.settings?.explainNoticeAccounts, [project: max.identity, "another-project": max.identity]
            )
            workspace.profileID = project

            // Another account asks again; declined, it asks next time too.
            let other = BranchReview.ExplainAccount(isLoggedIn: true, method: "claude.ai", subscription: "pro", email: "b@example.test")
            harness.alertResponses = [.alertSecondButtonReturn]
            XCTAssertFalse(shell.confirmExplain(for: review, account: other, files: 3))
            XCTAssertTrue(shell.confirmExplain(for: review, account: other, files: 3))
            XCTAssertTrue(shell.confirmExplain(for: review, account: other, files: 3))
            XCTAssertEqual(harness.alerts.count, 4)
            XCTAssertEqual(Persistence.load()?.settings?.explainNoticeAccounts[project], other.identity)

            // Billed per call: every time, and never remembered.
            let billed = BranchReview.ExplainAccount(isLoggedIn: true, method: "api_key", subscription: nil, email: nil)
            XCTAssertTrue(shell.confirmExplain(for: review, account: billed, files: 3))
            XCTAssertTrue(shell.confirmExplain(for: review, account: billed, files: 3))
            XCTAssertEqual(harness.alerts.count, 6)
            XCTAssertEqual(Persistence.load()?.settings?.explainNoticeAccounts[project], other.identity)
        }
    }

    func testTheNoticeSaysWhatGoesWhereAndWhatItCosts() {
        let max = BranchReview.ExplainAccount(isLoggedIn: true, method: "claude.ai", subscription: "max", email: "a@example.test")
        XCTAssertEqual(
            BranchReviewController.explainNotice(account: max, files: 1),
            "Claude reads the diff of 1 file, the pull request, the handover and the commits, and a read-only copy of the "
                + "branch’s files (secrets and instruction files left out). They go to Anthropic under claude.ai, Max "
                + "(a@example.test).\n\nAbout a minute or two. It counts toward your plan’s usage limits. Nirux asks again "
                + "if the account changes."
        )
        let billed = BranchReview.ExplainAccount(isLoggedIn: true, method: "api_key", subscription: nil, email: nil)
        XCTAssertTrue(BranchReviewController.explainNotice(account: billed, files: 2).hasSuffix(
            "under api_key.\n\nAbout a minute or two. This account is billed per call: each run can cost up to $3 at API "
                + "prices, and a large branch takes several runs. Nirux asks again each time."
        ))
    }
}
