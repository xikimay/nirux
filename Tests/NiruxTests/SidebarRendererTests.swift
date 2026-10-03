import XCTest
import AppKit
@testable import Nirux

@MainActor
final class SidebarRendererTests: XCTestCase {

    // MARK: - formatDiffStats

    func testFormatDiffStatsTypicalGitOutput() {
        let raw = "2 files changed, 42 insertions(+), 8 deletions(-)"
        XCTAssertEqual(SidebarRenderer.formatDiffStats(raw), "2 files, +42 -8")
    }

    func testFormatDiffStatsInsertionsOnly() {
        let raw = "1 file changed, 10 insertions(+)"
        XCTAssertEqual(SidebarRenderer.formatDiffStats(raw), "1 files, +10")
    }

    func testFormatDiffStatsDeletionsOnly() {
        let raw = "3 files changed, 5 deletions(-)"
        XCTAssertEqual(SidebarRenderer.formatDiffStats(raw), "3 files, -5")
    }

    func testFormatDiffStatsEmptyReturnsRaw() {
        XCTAssertEqual(SidebarRenderer.formatDiffStats(""), "")
    }

    func testFormatDiffStatsGarbageReturnsRaw() {
        XCTAssertEqual(SidebarRenderer.formatDiffStats("nothing to parse"), "nothing to parse")
    }

    // MARK: - shortDuration

    func testShortDurationSeconds() {
        XCTAssertEqual(SidebarRenderer.shortDuration(0), "0s")
        XCTAssertEqual(SidebarRenderer.shortDuration(42), "42s")
        XCTAssertEqual(SidebarRenderer.shortDuration(59.9), "59s")
    }

    func testShortDurationMinutes() {
        XCTAssertEqual(SidebarRenderer.shortDuration(60), "1m")
        XCTAssertEqual(SidebarRenderer.shortDuration(732), "12m")
        XCTAssertEqual(SidebarRenderer.shortDuration(3599), "59m")
    }

    func testShortDurationHours() {
        XCTAssertEqual(SidebarRenderer.shortDuration(3600), "1h00m")
        XCTAssertEqual(SidebarRenderer.shortDuration(3920), "1h05m")
        XCTAssertEqual(SidebarRenderer.shortDuration(7384), "2h03m")
    }

    func testShortDurationNegativeClampsToZero() {
        XCTAssertEqual(SidebarRenderer.shortDuration(-5), "0s")
    }

    // MARK: - Attention reason

    private func column(_ status: AgentStatus, reason: AgentAttentionReason?) -> ColumnInfo {
        ColumnInfo(
            index: 0, processName: "claude", abbreviatedCwd: nil, isFocused: false,
            isWebView: false, webTitle: nil, terminalTitle: nil, agentStatus: status,
            isEditor: false, editorFileName: nil, attentionReason: reason
        )
    }

    func testRowSaysWhyTheAgentWaits() {
        let waiting = column(.needsAttention, reason: .permission(tool: "Bash", summary: "git push\u{1B}[2J"))
        XCTAssertTrue(SidebarRenderer.attributedColumn(waiting).string.hasSuffix("claude · permission · Bash"))
        XCTAssertEqual(
            SidebarRenderer.attentionTooltip(for: waiting), "needs permission — Bash: git push[2J"
        )
        let done = column(.needsAttention, reason: .turnFinished)
        XCTAssertTrue(SidebarRenderer.attributedColumn(done).string.hasSuffix("claude · done"))
        XCTAssertEqual(SidebarRenderer.attentionTooltip(for: done), "finished its turn")
        XCTAssertNil(SidebarRenderer.attentionTooltip(for: column(.idle, reason: nil)))
    }

    /// The dot stays orange for any attention (like the glows and
    /// borders); the label tells a blocked agent from a finished turn.
    func testBlockedAndFinishedLabelsDiffer() {
        let blocked = SidebarRenderer.attentionTextColor(for: .permission(tool: "Bash", summary: nil))
        let question = SidebarRenderer.attentionTextColor(for: .question(nil))
        let done = SidebarRenderer.attentionTextColor(for: .turnFinished)
        XCTAssertEqual(blocked, question)
        XCTAssertNotEqual(blocked, done)
    }

    func testReasonChangeRerendersTheRow() {
        XCTAssertNotEqual(
            column(.needsAttention, reason: .turnFinished),
            column(.needsAttention, reason: .permission(tool: "Bash", summary: nil))
        )
    }

    // MARK: - Agent notification text

    func testNotificationSaysWhatIsAsked() {
        let text = NiruxNotifier.attentionText(
            processName: "✳ Fix login",
            workspaceTitle: "checkout",
            reason: .permission(tool: "Bash", summary: "rm -rf build\n\u{1B}]0;x\u{07}")
        )
        XCTAssertEqual(text.title, "✳ Fix login needs permission")
        XCTAssertEqual(text.subtitle, "checkout")
        XCTAssertEqual(text.body, "Bash: rm -rf build ]0;x")

        let plan = NiruxNotifier.attentionText(
            processName: "claude", workspaceTitle: "ws", reason: .permission(tool: "ExitPlanMode", summary: nil)
        )
        XCTAssertEqual(plan, NiruxNotifier.AttentionText(title: "claude needs plan approval", subtitle: "", body: "ws"))

        let generic = NiruxNotifier.attentionText(processName: "\u{1B}", workspaceTitle: "ws", reason: nil)
        XCTAssertEqual(generic, NiruxNotifier.AttentionText(title: "Agent needs you", subtitle: "", body: "ws"))

        let long = NiruxNotifier.attentionText(
            processName: "claude", workspaceTitle: "ws", reason: .question(String(repeating: "why ", count: 200))
        )
        XCTAssertEqual(long.body.count, 200)
    }

    // MARK: - prStateDisplay

    func testPrStateDisplayDraft() {
        let pullRequest = makePR(state: "OPEN", isDraft: true)
        let (text, _) = SidebarRenderer.prStateDisplay(pullRequest)
        XCTAssertEqual(text, "draft")
    }

    func testPrStateDisplayOpen() {
        let pullRequest = makePR(state: "OPEN", isDraft: false)
        let (text, _) = SidebarRenderer.prStateDisplay(pullRequest)
        XCTAssertEqual(text, "open")
    }

    func testPrStateDisplayMerged() {
        let pullRequest = makePR(state: "MERGED", isDraft: false)
        let (text, _) = SidebarRenderer.prStateDisplay(pullRequest)
        XCTAssertEqual(text, "merged")
    }

    func testPrStateDisplayClosed() {
        let pullRequest = makePR(state: "CLOSED", isDraft: false)
        let (text, _) = SidebarRenderer.prStateDisplay(pullRequest)
        XCTAssertEqual(text, "closed")
    }

    // MARK: - ciStatusDisplay

    func testCIStatusDisplaySuccessSaysPassed() {
        let (_, _, text) = SidebarRenderer.ciStatusDisplay("SUCCESS")
        XCTAssertEqual(text, "passed")
    }

    func testCIStatusDisplayFailureColorsRed() {
        let (dot, color, _) = SidebarRenderer.ciStatusDisplay("FAILURE")
        XCTAssertEqual(dot, "✗")
        XCTAssertEqual(color, .systemRed)
    }

    func testCIStatusDisplayUnknownStateLowercased() {
        let (_, _, text) = SidebarRenderer.ciStatusDisplay("WEIRD_THING")
        XCTAssertEqual(text, "weird_thing")
    }

    // MARK: - reviewDecisionDisplay

    func testReviewDecisionDisplayConflictTakesPrecedence() {
        let result = SidebarRenderer.reviewDecisionDisplay(
            reviewDecision: "APPROVED", mergeable: "CONFLICTING"
        )
        XCTAssertEqual(result?.text, "conflict")
    }

    func testReviewDecisionDisplayApproved() {
        let result = SidebarRenderer.reviewDecisionDisplay(
            reviewDecision: "APPROVED", mergeable: "MERGEABLE"
        )
        XCTAssertEqual(result?.text, "approved")
        XCTAssertEqual(result?.dot, "✓")
    }

    func testReviewDecisionDisplayReturnsNilForNoDecision() {
        XCTAssertNil(SidebarRenderer.reviewDecisionDisplay(reviewDecision: nil, mergeable: nil))
        XCTAssertNil(SidebarRenderer.reviewDecisionDisplay(reviewDecision: "", mergeable: nil))
    }

    // MARK: - attributedColumn

    func testAttributedColumnFocusedShowsArrow() {
        let column = makeColumn(isFocused: true, processName: "zsh")
        let attr = SidebarRenderer.attributedColumn(column)
        XCTAssertTrue(attr.string.contains("▸"))
        XCTAssertTrue(attr.string.contains("zsh"))
    }

    func testAttributedColumnUnfocusedOmitsArrow() {
        let column = makeColumn(isFocused: false, processName: "zsh")
        let attr = SidebarRenderer.attributedColumn(column)
        XCTAssertFalse(attr.string.contains("▸"))
    }

    func testAttributedColumnWebViewUsesTitle() {
        let column = makeColumn(isFocused: false, processName: nil, isWebView: true, webTitle: "GitHub")
        let attr = SidebarRenderer.attributedColumn(column)
        XCTAssertTrue(attr.string.contains("GitHub"))
    }

    func testAttributedColumnWebViewWithoutTitleFallsBackToWeb() {
        let column = makeColumn(isFocused: false, processName: nil, isWebView: true, webTitle: nil)
        let attr = SidebarRenderer.attributedColumn(column)
        XCTAssertTrue(attr.string.contains("web"))
    }

    func testAttributedColumnShellFallback() {
        let column = makeColumn(isFocused: false, processName: nil)
        let attr = SidebarRenderer.attributedColumn(column)
        XCTAssertTrue(attr.string.contains("shell"))
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
