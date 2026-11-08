import AppKit
import XCTest
@testable import Nirux

/// A task row's two lines (docs/spaces.md, Interface): the one thing to know
/// first, amber only when the user is needed; the selected row's columns.
@MainActor
final class SidebarTaskRowTests: XCTestCase {
    private func column(
        _ index: Int = 0, _ status: AgentStatus = .idle, reason: AgentAttentionReason? = nil,
        process: String = "claude", focused: Bool = false
    ) -> ColumnInfo {
        ColumnInfo(
            index: index, processName: process, abbreviatedCwd: "~/app", isFocused: focused, isWebView: false,
            webTitle: nil, terminalTitle: nil, agentStatus: status, isEditor: false, editorFileName: nil,
            attentionReason: reason
        )
    }

    private func pullRequest(
        _ state: String = "OPEN", ci: String? = nil, review: String? = nil, mergeable: String? = nil, draft: Bool = false
    ) -> PRInfo {
        PRInfo(
            number: 39, state: state, isDraft: draft, ciStatus: ci,
            checks: [ProjectBoard.Check(name: "test", workflowName: "Tests", result: .failure, startedAt: nil, url: "https://ci.test/8")],
            reviewDecision: review, mergeable: mergeable, url: "https://example.test/pull/39",
            additions: nil, deletions: nil, changedFiles: nil
        )
    }

    private func workspace(
        _ columns: [ColumnInfo], branch: String? = "fix/login", pr: PRInfo? = nil, cleanup: MergedCleanupOffer? = nil,
        isActive: Bool = false
    ) -> WorkspaceInfo {
        WorkspaceInfo(
            id: "ws", index: 4, title: "Fix login", profileID: WorkspaceProfile.defaultID, isInactive: false,
            columnCount: columns.count, focusedColumn: 0, gitBranch: branch, notification: nil, isActive: isActive,
            columns: columns, prInfo: pr, diffStats: nil, purpose: nil, nextStep: nil, blocker: nil, phase: .active,
            lastSummary: nil, lastActivityAt: Date().timeIntervalSince1970 - 720, mergedCleanup: cleanup
        )
    }

    private func status(_ info: WorkspaceInfo) -> String { info.rowSummary.status.text }

    /// Needs you, then broken, then the parent's question, then work, then
    /// the pull request, then a finished turn, else the branch.
    func testStatusLineSaysTheMostUrgentThingFirst() {
        var approval = column(0, .needsAttention, reason: .permission(tool: "Bash", summary: "npm run migrate"))
        var request = AgentPermissionRequest(toolName: "Bash", summary: "npm run migrate", key: "k", agentID: nil, sessionID: "s", requestedAt: 0)
        request.approval = PermissionApprovalTicket(requestID: "r", deadline: 100, text: "npm run migrate")
        approval.permissionApproval = SidebarPermissionApproval(request, now: 1)
        let question = column(1, .needsAttention, reason: .question("One date or a range?"))
        let failed = column(2, .needsAttention, reason: .apiError(kind: nil, detail: nil))
        let working = column(3, .working)
        var asking = column(4, .needsAttention, reason: .turnFinished)
        asking.missionQuestion = SidebarMissionQuestion(questionID: "q", parentTitle: "the Lead", text: "?", handOff: nil)

        let needsYou = workspace([working, failed, approval])
        XCTAssertEqual(needsYou.rowSummary.status, SidebarStatusLine(text: "Needs you · npm run migrate", tone: .needsYou))
        XCTAssertEqual(needsYou.rowSummary.mark, .needsYou)
        XCTAssertEqual(status(workspace([question])), "Needs you · One date or a range?")
        XCTAssertEqual(status(workspace([column(0, .needsAttention, reason: .question(nil))])), "Needs you · a question")
        XCTAssertEqual(workspace([working, failed]).rowSummary.status, SidebarStatusLine(text: "Stopped on an API error", tone: .error))
        XCTAssertEqual(workspace([working, asking]).rowSummary.status.text, "Asking the Lead", "it ended its turn to wait")
        XCTAssertEqual(workspace([working, column(5)], pr: pullRequest(ci: "FAILURE")).rowSummary.mark, .working, "it may be fixing the check")
        XCTAssertEqual(status(workspace([column(), column(1, .needsAttention, reason: .turnFinished)])), "Done")
        XCTAssertEqual(workspace([column()]).rowSummary.status, SidebarStatusLine(text: "fix/login", tone: .branch))
        XCTAssertEqual(status(workspace([column(focused: true)], branch: nil)), "~/app", "no branch: the folder")
        XCTAssertEqual(status(workspace([], branch: nil)), "No activity yet")
    }

    /// The pull request's line, and where a click on it goes.
    func testPullRequestLines() {
        func line(_ pr: PRInfo, cleanup: MergedCleanupOffer? = nil) -> SidebarRowSummary {
            workspace([column()], pr: pr, cleanup: cleanup).rowSummary
        }
        let failed = line(pullRequest(ci: "FAILURE"))
        XCTAssertEqual(failed.status, SidebarStatusLine(text: "#39 · checks failed", tone: .error, action: .open(url: "https://ci.test/8")))
        XCTAssertEqual(failed.mark, .error)
        XCTAssertEqual(line(pullRequest(ci: "PENDING")).status.action, .open(url: "https://example.test/pull/39/checks"))
        XCTAssertEqual(line(pullRequest(ci: "PENDING")).status.text, "#39 · checks running")
        XCTAssertEqual(line(pullRequest(ci: "SUCCESS", review: "REVIEW_REQUIRED", mergeable: "MERGEABLE")).status.text, "#39 · checks passed")
        XCTAssertEqual(line(pullRequest(ci: "SUCCESS", mergeable: "CONFLICTING")).status.text, "#39 · checks passed")
        XCTAssertEqual(line(pullRequest(draft: true)).status.text, "#39 · draft")

        let ready = line(pullRequest(ci: "SUCCESS", review: "APPROVED", mergeable: "MERGEABLE"))
        XCTAssertEqual(ready.status.text, "Ready to merge")
        XCTAssertEqual(ready.mark, .readyToMerge)
        XCTAssertEqual(ready.trailing, "#39", "the number the line doesn't say")

        let merged = line(pullRequest("MERGED"), cleanup: .available)
        XCTAssertEqual(merged.status, SidebarStatusLine(text: "Merged · Clean up", tone: .neutral, action: .cleanUp))
        XCTAssertEqual(merged.mark, .merged)
        XCTAssertEqual(line(pullRequest("MERGED"), cleanup: .inProgress).status.action, nil, "a second click does nothing")
        XCTAssertEqual(line(pullRequest("CLOSED")).status.text, "fix/login")
    }

    /// Only the selected row lists its columns and its links; every row
    /// keeps two lines, amber only for the user.
    func testOnlyTheSelectedRowShowsItsColumns() throws {
        let columns = [column(0, .working), column(1, process: "zsh")]
        func render(_ info: WorkspaceInfo) -> SidebarWorkspaceCardRenderResult {
            SidebarWorkspaceCardRenderer(workspace: info, sidebarWidth: 260, yOffset: 500).render()
        }
        func chips(_ result: SidebarWorkspaceCardRenderResult) -> Int {
            result.hitAreas.filter { if case .column = $0.region { true } else { false } }.count
        }
        let other = workspace(columns, pr: pullRequest(ci: "PENDING"))
        let selected = workspace(columns, pr: pullRequest(ci: "PENDING"), isActive: true)
        XCTAssertEqual(chips(render(other)), 0)
        XCTAssertEqual(chips(render(selected)), 2)
        let twoLines = SidebarExpandedMetrics.rowPaddingY * 2 + SidebarExpandedMetrics.titleRowHeight
            + SidebarExpandedMetrics.statusGap + SidebarExpandedMetrics.statusRowHeight
        XCTAssertEqual(500 - render(other).bottomY, twoLines)
        XCTAssertEqual(500 - render(selected).bottomY, SidebarExpandedMetrics.workspaceHeight(for: selected, sidebarWidth: 260))
        XCTAssertGreaterThan(SidebarExpandedMetrics.workspaceHeight(for: selected, sidebarWidth: 260), twoLines)

        let waiting = render(workspace([column(0, .needsAttention, reason: .question("Which?"))]))
        let line = try XCTUnwrap(waiting.views.compactMap { $0 as? NSTextField }.first { $0.stringValue == "Needs you · Which?" })
        XCTAssertEqual(line.attributedStringValue.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, Theme.Color.waiting)
        let working = render(other).views.compactMap { $0 as? NSTextField }.first { $0.stringValue == "Working" }
        XCTAssertEqual(working?.attributedStringValue.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, Theme.Color.textSecondary)
    }

    /// A status line that does something is a link as wide as its text: a
    /// click beside it selects the row.
    func testStatusLinkIsAsWideAsItsText() throws {
        let result = SidebarWorkspaceCardRenderer(
            workspace: workspace([column()], pr: pullRequest(ci: "FAILURE")), sidebarWidth: 260, yOffset: 500
        ).render()
        let link = try XCTUnwrap(result.hitAreas.first { if case .link = $0.region { true } else { false } })
        guard case .link(let url, let label) = link.region else { return XCTFail("no link") }
        XCTAssertEqual(url, SidebarView.openActionURL(workspaceIndex: 4, url: "https://ci.test/8"))
        XCTAssertEqual(label.stringValue, "#39 · checks failed")
        XCTAssertLessThan(link.frame.maxX, label.frame.maxX)
    }
}
