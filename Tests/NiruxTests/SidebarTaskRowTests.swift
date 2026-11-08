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
        isActive: Bool = false, nextStep: String? = nil, blocker: String? = nil
    ) -> WorkspaceInfo {
        WorkspaceInfo(
            id: "ws", index: 4, title: "Fix login", profileID: WorkspaceProfile.defaultID, isInactive: false,
            columnCount: columns.count, focusedColumn: 0, gitBranch: branch, notification: nil, isActive: isActive,
            columns: columns, prInfo: pr, diffStats: nil, purpose: nil, nextStep: nextStep, blocker: blocker, phase: .active,
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
        var answered = asking
        answered.missionQuestion?.isAnswered = true
        XCTAssertEqual(status(workspace([working, answered])), "Working", "a restarted Claude works through the user's prompt")
        XCTAssertEqual(status(workspace([answered])), "Answer ready · from the Lead")
        XCTAssertEqual(status(workspace([column(1, .needsAttention, reason: .turnFinished)], pr: pullRequest(ci: "SUCCESS"))), "Done",
                       "until the user looks, before the pull request's line")
        XCTAssertEqual(needsYou.rowSummary.focusColumn, 0, "a click brings up the asking column")
        XCTAssertEqual(workspace([working, failed]).rowSummary.focusColumn, 2)
        XCTAssertNil(workspace([working]).rowSummary.focusColumn)
        XCTAssertEqual(workspace([working, column(5)], pr: pullRequest(ci: "FAILURE")).rowSummary.mark, .working, "it may be fixing the check")
        XCTAssertEqual(status(workspace([column(), column(1, .needsAttention, reason: .turnFinished)])), "Done")
        XCTAssertEqual(workspace([column()]).rowSummary.status, SidebarStatusLine(text: "fix/login", tone: .branch))
        XCTAssertEqual(status(workspace([column(focused: true)], branch: nil)), "~/app", "no branch: the folder")
        XCTAssertEqual(status(workspace([], branch: nil)), "No activity yet")
    }

    /// A blocker (the Lead's or the user's) waits behind the user, a break,
    /// a question and work, in grey; it comes before a finished turn and
    /// the pull request. The next step takes the branch's place; the
    /// selected row prints it under a status line that says something
    /// else. Neither adds a line to another row.
    func testBlockerAndNextStepRankAfterWork() {
        let blocker = "waits for #212 to merge"
        let next = "write the import side"
        var asking = column(1, .needsAttention, reason: .turnFinished)
        asking.missionQuestion = SidebarMissionQuestion(questionID: "q", parentTitle: "the Lead", text: "?", handOff: nil)
        let question = column(0, .needsAttention, reason: .question("Which?"))
        let finished = column(0, .needsAttention, reason: .turnFinished)
        XCTAssertEqual(status(workspace([question], blocker: blocker)), "Needs you · Which?")
        XCTAssertEqual(status(workspace([column(0, .needsAttention, reason: .apiError(kind: nil, detail: nil))], blocker: blocker)),
                       "Stopped on an API error")
        XCTAssertEqual(status(workspace([column(0, .working), asking], blocker: blocker)), "Asking the Lead")
        XCTAssertEqual(status(workspace([column(0, .working)], blocker: blocker)), "Working")

        let blocked = workspace([finished], pr: pullRequest(ci: "SUCCESS"), nextStep: next, blocker: blocker)
        XCTAssertEqual(blocked.rowSummary.status, SidebarStatusLine(text: "Blocked · \(blocker)", tone: .neutral))
        XCTAssertEqual(blocked.rowSummary.mark, .blocked)
        XCTAssertEqual(blocked.cardActions, [], "no third line")
        XCTAssertEqual(workspace([column()], isActive: true, nextStep: next, blocker: blocker).cardActions, [.next(next)])

        XCTAssertEqual(status(workspace([column()], nextStep: next)), "Next · \(next)")
        XCTAssertEqual(workspace([column()], isActive: true, nextStep: next).cardActions, [], "the status line says it")
        XCTAssertEqual(status(workspace([finished], nextStep: next)), "Done")
        XCTAssertEqual(status(workspace([column()], pr: pullRequest(ci: "PENDING"), nextStep: next)), "#39 · checks running")
        XCTAssertEqual(workspace([column()], pr: pullRequest(ci: "PENDING"), isActive: true, nextStep: next).cardActions, [.next(next)])
        XCTAssertEqual(status(workspace([column()], nextStep: " ", blocker: "")), "fix/login", "blank says nothing")
    }

    /// The pull request's line, and where a click on it goes.
    func testPullRequestLines() {
        func line(_ pr: PRInfo, cleanup: MergedCleanupOffer? = nil) -> SidebarRowSummary {
            workspace([column()], pr: pr, cleanup: cleanup).rowSummary
        }
        let failed = line(pullRequest(ci: "FAILURE"))
        XCTAssertEqual(failed.status, SidebarStatusLine(text: "#39 · checks failed", tone: .error), "no link: a click selects the row")
        XCTAssertEqual(failed.mark, .error)
        XCTAssertEqual(line(pullRequest(ci: "PENDING")).status, SidebarStatusLine(text: "#39 · checks running", tone: .neutral))
        XCTAssertEqual(line(pullRequest(ci: "SUCCESS", review: "REVIEW_REQUIRED", mergeable: "MERGEABLE")).status.text, "#39 · checks passed")
        XCTAssertEqual(line(pullRequest(ci: "SUCCESS", mergeable: "CONFLICTING")).status.text, "#39 · checks passed")
        XCTAssertEqual(line(pullRequest(draft: true)).status.text, "#39 · draft")

        let ready = line(pullRequest(ci: "SUCCESS", review: "APPROVED", mergeable: "MERGEABLE"))
        XCTAssertEqual(ready.status.text, "Ready to merge")
        XCTAssertEqual(ready.mark, .readyToMerge)
        XCTAssertEqual(ready.trailing, .pullRequest(39), "the number the line doesn't say")
        XCTAssertEqual(line(pullRequest(ci: "SUCCESS", mergeable: "UNKNOWN")).status.text, "Ready to merge", "no flicker while GitHub recomputes")
        var commented = workspace([column()], pr: pullRequest(ci: "SUCCESS", review: "APPROVED", mergeable: "MERGEABLE"))
        commented.prFeedback = SidebarPRFeedback(humans: 1, bots: 0)
        XCTAssertEqual(commented.rowSummary.status.text, "#39 · checks passed", "feedback nobody dealt with")

        let merged = line(pullRequest("MERGED"), cleanup: .available)
        XCTAssertEqual(merged.status, SidebarStatusLine(text: "Merged · Clean up", tone: .neutral, action: .cleanUp, linkText: "Clean up"))
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

    /// "Clean up" is a link over its own words: a click on "Merged" or
    /// beside the line selects the row. An agent's state on the line keeps
    /// Clean up in a line of its own.
    func testCleanUpLinksOnlyItsWords() throws {
        let merged = workspace([column()], pr: pullRequest("MERGED"), cleanup: .available)
        let result = SidebarWorkspaceCardRenderer(workspace: merged, sidebarWidth: 260, yOffset: 500).render()
        let link = try XCTUnwrap(result.hitAreas.first { if case .link = $0.region { true } else { false } })
        guard case .link(let url, let label) = link.region else { return XCTFail("no link") }
        XCTAssertEqual(url, SidebarView.cleanupActionURL(workspaceIndex: 4))
        XCTAssertEqual(label.stringValue, "Merged · Clean up")
        let prefixWidth = ceil(NSAttributedString(string: "Merged · ", attributes: [.font: Theme.Font.body]).size().width)
        XCTAssertGreaterThan(link.frame.minX, label.frame.minX + prefixWidth - 4)
        XCTAssertLessThan(link.frame.maxX, label.frame.maxX)

        let working = workspace([column(0, .working)], pr: pullRequest("MERGED"), cleanup: .available)
        XCTAssertEqual(working.rowSummary.status.text, "Working")
        XCTAssertEqual(working.cardActions, [.cleanup(.available, pullRequest: 39)])
    }

    /// A Mission question the status line doesn't show (another column
    /// waits on the user first) keeps a line that opens it.
    func testEveryMissionQuestionOpensFromTheRow() {
        let asking = column(0, .needsAttention, reason: .question("Which?"))
        var child = column(1)
        let question = SidebarMissionQuestion(questionID: "q", parentTitle: "web-main", text: "Keep it?", handOff: .parentClosed)
        child.missionQuestion = question
        let row = workspace([asking, child])
        XCTAssertEqual(row.rowSummary.status.text, "Needs you · Which?")
        XCTAssertEqual(row.cardActions, [.missionQuestion(columnIndex: 1, question)])
        XCTAssertEqual(workspace([child]).cardActions, [], "the status line shows it")
    }

    /// A click on a row that waits on the user brings up the asking column,
    /// whose chip only shows once the row is selected; another row, or the
    /// selected one, keeps the workspace's focused column.
    func testClickingAWaitingRowFocusesTheAskingColumn() {
        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 260, height: 600))
        sidebar.isExpanded = true
        var waiting = workspace([column(0), column(2, .needsAttention, reason: .question("Which?"))])
        waiting = WorkspaceInfo(
            id: "waiting", index: 1, title: "Waiting", profileID: WorkspaceProfile.defaultID, isInactive: false,
            columnCount: 2, focusedColumn: 0, gitBranch: nil, notification: nil, isActive: false, columns: waiting.columns,
            prInfo: nil, diffStats: nil, purpose: nil, nextStep: nil, blocker: nil, phase: .active, lastSummary: nil,
            lastActivityAt: nil
        )
        sidebar.update(profiles: [], workspaces: [workspace([column()], isActive: true), waiting])
        var columns: [String] = []
        var workspaces: [Int] = []
        sidebar.onColumnClicked = { columns.append("\($0):\($1)") }
        sidebar.onWorkspaceClicked = { workspaces.append($0) }

        sidebar.clickRow(1)
        sidebar.clickRow(4)
        XCTAssertEqual(columns, ["1:2"])
        XCTAssertEqual(workspaces, [4])
    }

    /// The space's Lead sits above the Tasks header, on one line: its sign,
    /// its title, a dot for its state, no columns; a question it can't show
    /// on that line gets one of its own.
    func testLeadRowSitsAboveTasksOnOneLine() throws {
        var lead = workspace([column(0, .working)], isActive: true)
        lead = WorkspaceInfo(
            id: "lead", index: 0, title: "Lead", profileID: WorkspaceProfile.defaultID, isInactive: false,
            columnCount: 1, focusedColumn: 0, gitBranch: nil, notification: nil, isActive: true, columns: lead.columns,
            prInfo: nil, diffStats: nil, purpose: nil, nextStep: nil, blocker: nil, phase: .active, lastSummary: nil,
            lastActivityAt: nil
        )
        lead.isLead = true
        XCTAssertEqual(SidebarExpandedMetrics.workspaceHeight(for: lead, sidebarWidth: 260), SidebarExpandedMetrics.leadRowHeight)
        let result = SidebarWorkspaceCardRenderer(workspace: lead, sidebarWidth: 260, yOffset: 500).render()
        XCTAssertFalse(result.hitAreas.contains { if case .column = $0.region { true } else { false } }, "no chips")

        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 260, height: 600))
        sidebar.isExpanded = true
        sidebar.update(profiles: [], workspaces: [lead, workspace([column()])])
        let leadRow = try XCTUnwrap(sidebar.hitAreas.first { if case .workspace(0) = $0.region { true } else { false } })
        let taskRow = try XCTUnwrap(sidebar.hitAreas.first { if case .workspace(4) = $0.region { true } else { false } })
        let tasks = try XCTUnwrap(sidebar.expandedViews.compactMap { $0 as? NSTextField }.first { $0.stringValue == "Tasks" })
        XCTAssertGreaterThan(leadRow.frame.minY, tasks.frame.maxY)
        XCTAssertLessThan(taskRow.frame.maxY, tasks.frame.minY)

        var asked = column(1)
        let question = SidebarMissionQuestion(questionID: "q", parentTitle: "you", text: "Ship it?", handOff: .parentClosed)
        asked.missionQuestion = question
        var askingLead = lead
        askingLead = WorkspaceInfo(
            id: "lead", index: 0, title: "Lead", profileID: WorkspaceProfile.defaultID, isInactive: false,
            columnCount: 1, focusedColumn: 0, gitBranch: nil, notification: nil, isActive: true, columns: [asked],
            prInfo: nil, diffStats: nil, purpose: nil, nextStep: nil, blocker: nil, phase: .active, lastSummary: nil,
            lastActivityAt: nil
        )
        askingLead.isLead = true
        XCTAssertEqual(askingLead.cardActions, [.missionQuestion(columnIndex: 1, question)])
        XCTAssertEqual(
            SidebarExpandedMetrics.workspaceHeight(for: askingLead, sidebarWidth: 260),
            SidebarExpandedMetrics.leadRowHeight + SidebarExpandedMetrics.actionBlockHeight(askingLead.cardActions)
                + SidebarExpandedMetrics.rowPaddingY,
            "its block ends a row's padding above its edge"
        )
    }
}
