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

    /// The chip's words, without its icon and dots.
    private func chipText(_ column: ColumnInfo) -> String {
        SidebarColumnChip(column).text.string.replacingOccurrences(of: "\u{FFFC}", with: "")
    }

    func testChipSaysWhyTheAgentWaits() {
        let waiting = column(.needsAttention, reason: .permission(tool: "Bash", summary: "git push\u{1B}[2J"))
        XCTAssertEqual(chipText(waiting), "permission")
        XCTAssertEqual(SidebarColumnChip(waiting).style, .waiting)
        XCTAssertEqual(
            SidebarRenderer.attentionTooltip(for: waiting), "needs permission — Bash: git push[2J"
        )
        XCTAssertEqual(SidebarColumnChip(waiting).toolTip, "claude · permission\nneeds permission — Bash: git push[2J")
        let done = column(.needsAttention, reason: .turnFinished)
        XCTAssertEqual(chipText(done), "done")
        XCTAssertEqual(SidebarColumnChip(done).style, .plain)
        XCTAssertEqual(SidebarRenderer.attentionTooltip(for: done), "finished its turn")
        XCTAssertNil(SidebarRenderer.attentionTooltip(for: column(.idle, reason: nil)))
        XCTAssertEqual(chipText(column(.idle, reason: nil)), "")
    }

    /// Amber means one thing: an agent waits for the user's answer. An
    /// error is red, a finished turn neutral.
    func testOnlyAWaitOnTheUserIsAmber() {
        let cases: [(AgentAttentionReason, AttentionSignal)] = [
            (.permission(tool: "Bash", summary: nil), .waiting),
            (.permission(tool: "ExitPlanMode", summary: nil), .waiting),
            (.question(nil), .waiting),
            (.message("needs you"), .waiting),
            (.stillWaiting(.question(nil), waited: 3600), .waiting),
            (.apiError(kind: "rate_limit", detail: nil), .error),
            (.exitedMidTurn, .error),
            (.turnFinished, .finished)
        ]
        for (reason, signal) in cases {
            XCTAssertEqual(reason.signal, signal, "\(reason)")
        }
        XCTAssertEqual(SidebarRenderer.color(for: .waiting), Theme.Color.waiting)
        XCTAssertEqual(SidebarRenderer.color(for: .error), Theme.Color.error)
        XCTAssertNotEqual(SidebarRenderer.color(for: .finished), Theme.Color.waiting)
        XCTAssertNotEqual(SidebarRenderer.color(for: .finished), Theme.Color.accent)
        XCTAssertEqual(SidebarColumnChip(column(.needsAttention, reason: .apiError(kind: nil, detail: nil))).style, .error)
    }

    /// Silence from an agent without hooks may be its own approval prompt.
    func testUnexplainedSilenceStaysAmber() {
        let silent = column(.needsAttention, reason: nil)
        XCTAssertEqual(silent.attention, .waiting)
        XCTAssertEqual(chipText(silent), "needs you")
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
        let (symbol, color, text) = SidebarRenderer.ciStatusDisplay("SUCCESS")
        XCTAssertEqual(text, "passed")
        XCTAssertEqual(symbol, Theme.Symbol.checksPassed)
        XCTAssertEqual(color, Theme.Color.success)
    }

    func testCIStatusDisplayFailureColorsRed() {
        let (symbol, color, _) = SidebarRenderer.ciStatusDisplay("FAILURE")
        XCTAssertEqual(symbol, Theme.Symbol.checksFailed)
        XCTAssertEqual(color, Theme.Color.error)
    }

    /// A running check is grey: amber is for the user's answer.
    func testCIStatusDisplayRunningIsNeverAmber() {
        let (symbol, color, text) = SidebarRenderer.ciStatusDisplay("PENDING")
        XCTAssertEqual(text, "running")
        XCTAssertEqual(symbol, Theme.Symbol.checksRunning)
        XCTAssertEqual(color, Theme.Color.textTertiary)
    }

    func testCIStatusDisplayUnknownStateLowercased() {
        let (symbol, _, text) = SidebarRenderer.ciStatusDisplay("WEIRD_THING")
        XCTAssertEqual(text, "weird_thing")
        XCTAssertNil(symbol)
    }

    // MARK: - reviewDecisionText

    func testReviewDecisionTextConflictTakesPrecedence() {
        XCTAssertEqual(SidebarRenderer.reviewDecisionText(reviewDecision: "APPROVED", mergeable: "CONFLICTING"), "conflict")
    }

    func testReviewDecisionTextApproved() {
        XCTAssertEqual(SidebarRenderer.reviewDecisionText(reviewDecision: "APPROVED", mergeable: "MERGEABLE"), "approved")
    }

    func testReviewDecisionTextReturnsNilForNoDecision() {
        XCTAssertNil(SidebarRenderer.reviewDecisionText(reviewDecision: nil, mergeable: nil))
        XCTAssertNil(SidebarRenderer.reviewDecisionText(reviewDecision: "", mergeable: nil))
    }

    /// The card drops the CI and review lines: its PR sign's tooltip says
    /// them.
    func testPullRequestToolTipSaysChecksAndReview() {
        let pullRequest = PRInfo(
            number: 7, state: "OPEN", isDraft: false, ciStatus: "FAILURE", checks: [], reviewDecision: "CHANGES_REQUESTED",
            mergeable: "MERGEABLE", url: "https://example.test/pr/7", additions: nil, deletions: nil, changedFiles: nil
        )
        XCTAssertEqual(
            SidebarRenderer.pullRequestToolTip(pullRequest), "Pull request #7 open · checks failed · changes requested"
        )
    }

    // MARK: - Diff

    func testDiffShowsInsertionsAndDeletions() {
        let diff = SidebarRenderer.diffAttributedString("2 files changed, 42 insertions(+), 8 deletions(-)")
        XCTAssertEqual(diff.string, "+42 \u{2212}8")
        XCTAssertEqual(SidebarRenderer.diffAttributedString("1 file changed, 10 insertions(+)").string, "+10")
        XCTAssertEqual(SidebarRenderer.diffAttributedString("3 files changed").string, "3 files")
    }

    // MARK: - Column chips

    func testFocusedChipSaysSo() {
        let focused = SidebarColumnChip(makeColumn(isFocused: true, processName: "zsh"))
        XCTAssertEqual(focused.style, .focused)
        XCTAssertEqual(focused.accessibilityLabel, "zsh, focused")
        XCTAssertEqual(SidebarColumnChip(makeColumn(isFocused: false, processName: "zsh")).style, .plain)
    }

    func testColumnNameWebViewUsesTitle() {
        let column = makeColumn(isFocused: false, processName: nil, isWebView: true, webTitle: "GitHub")
        XCTAssertEqual(SidebarRenderer.columnName(column), "GitHub")
    }

    func testColumnNameWebViewWithoutTitleFallsBackToWeb() {
        let column = makeColumn(isFocused: false, processName: nil, isWebView: true, webTitle: nil)
        XCTAssertEqual(SidebarRenderer.columnName(column), "web")
    }

    func testColumnNameShellFallback() {
        XCTAssertEqual(SidebarRenderer.columnName(makeColumn(isFocused: false, processName: nil)), "shell")
    }

    func testWorkingChipShowsTheTurnsTime() {
        let column = ColumnInfo(
            index: 0, processName: "claude", abbreviatedCwd: nil, isFocused: false, isWebView: false, webTitle: nil,
            terminalTitle: nil, agentStatus: .working, isEditor: false, editorFileName: nil, agentElapsedSeconds: 732
        )
        XCTAssertEqual(chipText(column), "12m")
        XCTAssertEqual(SidebarColumnChip(column).toolTip, "claude · working 12m")
    }

    // MARK: - Test helpers

    private func makePR(state: String, isDraft: Bool) -> PRInfo {
        PRInfo(
            number: 1, state: state, isDraft: isDraft, ciStatus: nil,
            checks: [], reviewDecision: nil, mergeable: nil,
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
