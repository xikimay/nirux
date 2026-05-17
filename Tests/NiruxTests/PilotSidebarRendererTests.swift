import XCTest
import AppKit
@testable import Nirux

@MainActor
final class PilotSidebarRendererTests: XCTestCase {

    // MARK: - formatDiffStats

    func testFormatDiffStatsTypicalGitOutput() {
        let raw = "2 files changed, 42 insertions(+), 8 deletions(-)"
        XCTAssertEqual(PilotSidebarRenderer.formatDiffStats(raw), "2 files, +42 -8")
    }

    func testFormatDiffStatsInsertionsOnly() {
        let raw = "1 file changed, 10 insertions(+)"
        XCTAssertEqual(PilotSidebarRenderer.formatDiffStats(raw), "1 files, +10")
    }

    func testFormatDiffStatsDeletionsOnly() {
        let raw = "3 files changed, 5 deletions(-)"
        XCTAssertEqual(PilotSidebarRenderer.formatDiffStats(raw), "3 files, -5")
    }

    func testFormatDiffStatsEmptyReturnsRaw() {
        XCTAssertEqual(PilotSidebarRenderer.formatDiffStats(""), "")
    }

    func testFormatDiffStatsGarbageReturnsRaw() {
        XCTAssertEqual(PilotSidebarRenderer.formatDiffStats("nothing to parse"), "nothing to parse")
    }

    // MARK: - prStateDisplay

    func testPrStateDisplayDraft() {
        let pullRequest = makePR(state: "OPEN", isDraft: true)
        let (text, _) = PilotSidebarRenderer.prStateDisplay(pullRequest)
        XCTAssertEqual(text, "draft")
    }

    func testPrStateDisplayOpen() {
        let pullRequest = makePR(state: "OPEN", isDraft: false)
        let (text, _) = PilotSidebarRenderer.prStateDisplay(pullRequest)
        XCTAssertEqual(text, "open")
    }

    func testPrStateDisplayMerged() {
        let pullRequest = makePR(state: "MERGED", isDraft: false)
        let (text, _) = PilotSidebarRenderer.prStateDisplay(pullRequest)
        XCTAssertEqual(text, "merged")
    }

    func testPrStateDisplayClosed() {
        let pullRequest = makePR(state: "CLOSED", isDraft: false)
        let (text, _) = PilotSidebarRenderer.prStateDisplay(pullRequest)
        XCTAssertEqual(text, "closed")
    }

    // MARK: - ciStatusDisplay

    func testCIStatusDisplayShortStyleUsesCompactLabels() {
        let (_, _, text) = PilotSidebarRenderer.ciStatusDisplay("SUCCESS", style: .short)
        XCTAssertEqual(text, "passed")
    }

    func testCIStatusDisplayLongStyleUsesVerboseLabels() {
        let (_, _, text) = PilotSidebarRenderer.ciStatusDisplay("SUCCESS", style: .long)
        XCTAssertEqual(text, "checks passed")
    }

    func testCIStatusDisplayFailureColorsRed() {
        let (dot, color, _) = PilotSidebarRenderer.ciStatusDisplay("FAILURE", style: .short)
        XCTAssertEqual(dot, "✗")
        XCTAssertEqual(color, .systemRed)
    }

    func testCIStatusDisplayUnknownStateLowercased() {
        let (_, _, text) = PilotSidebarRenderer.ciStatusDisplay("WEIRD_THING", style: .short)
        XCTAssertEqual(text, "weird_thing")
    }

    // MARK: - reviewDecisionDisplay

    func testReviewDecisionDisplayConflictTakesPrecedence() {
        let result = PilotSidebarRenderer.reviewDecisionDisplay(
            reviewDecision: "APPROVED", mergeable: "CONFLICTING"
        )
        XCTAssertEqual(result?.text, "conflict")
    }

    func testReviewDecisionDisplayApproved() {
        let result = PilotSidebarRenderer.reviewDecisionDisplay(
            reviewDecision: "APPROVED", mergeable: "MERGEABLE"
        )
        XCTAssertEqual(result?.text, "approved")
        XCTAssertEqual(result?.dot, "✓")
    }

    func testReviewDecisionDisplayReturnsNilForNoDecision() {
        XCTAssertNil(PilotSidebarRenderer.reviewDecisionDisplay(reviewDecision: nil, mergeable: nil))
        XCTAssertNil(PilotSidebarRenderer.reviewDecisionDisplay(reviewDecision: "", mergeable: nil))
    }

    // MARK: - attributedColumn

    func testAttributedColumnFocusedShowsArrow() {
        let column = makeColumn(isFocused: true, processName: "zsh")
        let attr = PilotSidebarRenderer.attributedColumn(column)
        XCTAssertTrue(attr.string.contains("▸"))
        XCTAssertTrue(attr.string.contains("zsh"))
    }

    func testAttributedColumnUnfocusedOmitsArrow() {
        let column = makeColumn(isFocused: false, processName: "zsh")
        let attr = PilotSidebarRenderer.attributedColumn(column)
        XCTAssertFalse(attr.string.contains("▸"))
    }

    func testAttributedColumnWebViewUsesTitle() {
        let column = makeColumn(isFocused: false, processName: nil, isWebView: true, webTitle: "GitHub")
        let attr = PilotSidebarRenderer.attributedColumn(column)
        XCTAssertTrue(attr.string.contains("GitHub"))
    }

    func testAttributedColumnWebViewWithoutTitleFallsBackToWeb() {
        let column = makeColumn(isFocused: false, processName: nil, isWebView: true, webTitle: nil)
        let attr = PilotSidebarRenderer.attributedColumn(column)
        XCTAssertTrue(attr.string.contains("web"))
    }

    func testAttributedColumnShellFallback() {
        let column = makeColumn(isFocused: false, processName: nil)
        let attr = PilotSidebarRenderer.attributedColumn(column)
        XCTAssertTrue(attr.string.contains("shell"))
    }

    // MARK: - makeAgentDot

    func testMakeAgentDotReturnsNilForIdle() {
        let dot = PilotSidebarRenderer.makeAgentDot(
            status: .idle, x: 0, yOffset: 100, rowHeight: 14, size: 8
        )
        XCTAssertNil(dot)
    }

    func testMakeAgentDotReturnsViewForWorking() {
        let dot = PilotSidebarRenderer.makeAgentDot(
            status: .working, x: 20, yOffset: 100, rowHeight: 14, size: 8
        )
        XCTAssertNotNil(dot)
        XCTAssertEqual(dot?.frame.width, 8)
        XCTAssertEqual(dot?.frame.height, 8)
        XCTAssertNotNil(dot?.layer?.animation(forKey: "pulse"))
    }

    func testMakeAgentDotReturnsViewForNeedsAttention() {
        let dot = PilotSidebarRenderer.makeAgentDot(
            status: .needsAttention, x: 20, yOffset: 100, rowHeight: 14, size: 8
        )
        XCTAssertNotNil(dot)
    }

    // MARK: - Test helpers

    private func makePR(state: String, isDraft: Bool) -> PRInfo {
        PRInfo(
            number: 1, state: state, isDraft: isDraft, ciStatus: nil,
            failedCheckUrl: nil, reviewDecision: nil, mergeable: nil,
            url: "https://example.test/pr/1", additions: nil, deletions: nil, changedFiles: nil
        )
    }

    private func makeColumn(
        isFocused: Bool, processName: String?,
        isWebView: Bool = false, webTitle: String? = nil
    ) -> ColumnInfo {
        ColumnInfo(
            index: 0, processName: processName, abbreviatedCwd: nil,
            isFocused: isFocused, isWebView: isWebView, webTitle: webTitle,
            terminalTitle: nil, agentStatus: .idle,
            isEditor: false, editorFileName: nil
        )
    }
}
