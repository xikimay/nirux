import AppKit
import XCTest
@testable import Nirux

/// Task summaries and their expanded, selected and compact presentations.
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
        _ state: GitHub.PullRequestState = .open, ci: String? = nil, review: String? = nil, mergeable: String? = nil, draft: Bool = false
    ) -> PRInfo {
        PRInfo(
            number: 39, state: state, isDraft: draft, ciStatus: ci,
            checks: [GitHub.Check(name: "test", workflowName: "Tests", result: .failure, startedAt: nil, url: "https://ci.test/8")],
            reviewDecision: review, mergeable: mergeable, url: "https://example.test/pull/39",
            additions: nil, deletions: nil, changedFiles: nil
        )
    }

    private func workspace(
        _ columns: [ColumnInfo], branch: String? = "fix/login", pr: PRInfo? = nil, cleanup: MergedCleanupOffer? = nil,
        isActive: Bool = false, nextStep: String? = nil, blocker: String? = nil, purpose: String? = nil
    ) -> WorkspaceInfo {
        WorkspaceInfo(
            id: "ws", index: 4, title: "Fix login", profileID: WorkspaceProfile.defaultID, isInactive: false,
            columnCount: columns.count, focusedColumn: 0, gitBranch: branch, notification: nil, isActive: isActive,
            columns: columns, prInfo: pr, diffStats: nil, purpose: purpose, nextStep: nextStep, blocker: blocker, phase: .active,
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

    /// docs/design/pr-follow-up.md: a round's turn says so where "Working"
    /// was; a pull request handed over waits on the user, in amber, once no
    /// agent works, and after the agent's own question.
    func testTheFollowUpSaysItsRoundAndHandsOverInAmber() {
        var round = workspace([column(0, .working)], pr: pullRequest(ci: "FAILURE"))
        round.followUp = .round("Auto follow-up 1/3 · failed checks")
        XCTAssertEqual(round.rowSummary.status, SidebarStatusLine(text: "Auto follow-up 1/3 · failed checks", tone: .neutral))
        let words = "#39 still fails its checks: the automatic round pushed nothing"
        for (columns, expected) in [
            ([column()], SidebarStatusLine(text: "Needs you · " + words, tone: .needsYou)),
            ([column(0, .working)], SidebarStatusLine(text: "Working", tone: .neutral)),
            ([column(0, .needsAttention, reason: .question("Which?"))], SidebarStatusLine(text: "Needs you · Which?", tone: .needsYou))
        ] {
            var stopped = workspace(columns, pr: pullRequest(ci: "FAILURE"))
            stopped.followUp = .stopped(words)
            XCTAssertEqual(stopped.rowSummary.status, expected)
        }
    }

    /// A blocker (the Lead's or the user's) waits behind the user, a break,
    /// a question, work and an agent to resume, in grey; it comes before a
    /// finished turn and
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
        XCTAssertEqual(status(workspace([column()], pr: pullRequest(ci: "FAILURE"), blocker: blocker)), "#39 · checks failed")
        var paused = column(1)
        paused.deferredAgent = SidebarDeferredAgent(processName: "claude", summary: "claude session", columnID: UUID())
        XCTAssertEqual(status(workspace([column(), paused], blocker: blocker)), "Paused · Resume", "its agent isn't running")

        let blocked = workspace([finished], pr: pullRequest(ci: "SUCCESS"), nextStep: next, blocker: blocker)
        XCTAssertEqual(blocked.rowSummary.status, SidebarStatusLine(text: "Blocked · \(blocker)", tone: .neutral))
        XCTAssertEqual(blocked.rowSummary.mark, .blocked)
        XCTAssertEqual(blocked.cardActions, [], "no third line")
        XCTAssertEqual(workspace([column()], isActive: true, nextStep: next, blocker: blocker).cardActions, [.next(next)])

        XCTAssertEqual(status(workspace([column()], nextStep: next)), "Next · \(next)")
        XCTAssertEqual(workspace([column()], isActive: true, nextStep: next).cardActions, [.next(next)])
        XCTAssertEqual(status(workspace([finished], nextStep: next)), "Done")
        XCTAssertEqual(status(workspace([column()], pr: pullRequest(ci: "PENDING"), nextStep: next)), "#39 · checks running")
        XCTAssertEqual(workspace([column()], pr: pullRequest(ci: "PENDING"), isActive: true, nextStep: next).cardActions, [.next(next)])
        XCTAssertEqual(status(workspace([column()], nextStep: " ", blocker: "")), "fix/login", "blank says nothing")
        var lead = workspace([column()], isActive: true, nextStep: next)
        lead.isLead = true
        XCTAssertEqual(lead.cardActions, [.next(next)], "the Lead's row has no status line")
    }

    /// Where the task stands: its last turn's own line beside a grey check
    /// in "Done"'s place while the finished turn is unseen, then (or the
    /// user's summary) the resting line after the pull request and the
    /// next step, in the branch's place.
    func testStatusLineSaysWhereTheTaskStands() {
        let line = "fix pushed, CI green"
        let finished = column(0, .needsAttention, reason: .turnFinished)
        func standing(_ info: WorkspaceInfo) -> WorkspaceInfo {
            var info = info
            info.statusLine = line
            info.turnStatusLine = line
            return info
        }
        let unseen = standing(workspace([finished], pr: pullRequest(ci: "SUCCESS"), nextStep: "merge it")).rowSummary
        XCTAssertEqual(unseen.status, SidebarStatusLine(text: line, tone: .neutral))
        XCTAssertEqual(unseen.mark, .finished)
        let seen = standing(workspace([column()])).rowSummary
        XCTAssertEqual(seen.status, SidebarStatusLine(text: line, tone: .neutral), "not the branch's machine font")
        XCTAssertEqual(seen.mark, .idle)
        XCTAssertEqual(status(standing(workspace([column()], nextStep: "merge it"))), "Next · merge it")
        XCTAssertEqual(status(standing(workspace([column()], pr: pullRequest(ci: "PENDING")))), "#39 · checks running")
        XCTAssertEqual(status(standing(workspace([finished], blocker: "no API key"))), "Blocked · no API key")
        XCTAssertEqual(status(standing(workspace([column(0, .working)]))), "Working")
        XCTAssertEqual(status(standing(workspace([column(0, .needsAttention, reason: .question("Which?"))]))), "Needs you · Which?")
        XCTAssertEqual(workspace([finished]).rowSummary.mark, .idle, "no line: Done, by the grey dot")
        var usersOwn = workspace([finished])
        usersOwn.statusLine = "Ships Friday"
        XCTAssertEqual(status(usersOwn), "Done", "the user's summary is no turn's outcome")
        var resting = workspace([column()])
        resting.statusLine = "Ships Friday"
        XCTAssertEqual(status(resting), "Ships Friday")
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
        commented.prFeedback = PRFeedback.Counts(humans: 1, bots: 0)
        XCTAssertEqual(commented.rowSummary.status.text, "#39 · checks passed", "feedback nobody dealt with")

        let merged = line(pullRequest(.merged), cleanup: .available)
        XCTAssertEqual(merged.status, SidebarStatusLine(text: "Merged · Clean up", tone: .neutral, action: .cleanUp, linkText: "Clean up"))
        XCTAssertEqual(merged.mark, .merged)
        XCTAssertEqual(line(pullRequest(.merged), cleanup: .inProgress).status.action, nil, "a second click does nothing")
        XCTAssertEqual(line(pullRequest(.closed)).status.text, "fix/login")
    }

    func testTheGoalFitsBetweenTitleAndStepAndTakesNoSpaceWhenBlank() throws {
        func render(_ purpose: String?) -> SidebarWorkspaceCardRenderResult {
            let info = workspace([column()], nextStep: "Build Sources/Importer.swift", purpose: purpose)
            return SidebarWorkspaceCardRenderer(workspace: info, sidebarWidth: 260, yOffset: 400).render()
        }
        let row = render(" Explain  the login\n flow ")
        let labels = row.views.compactMap { $0 as? NSTextField }
        let title = try XCTUnwrap(labels.first { $0.stringValue == "Fix login" })
        let goal = try XCTUnwrap(labels.first { $0.stringValue == "Explain the login flow" })
        let step = try XCTUnwrap(row.views.first { $0.accessibilityLabel() == "Code" })
        XCTAssertLessThanOrEqual(goal.frame.maxY, title.frame.minY)
        XCTAssertLessThanOrEqual(step.frame.maxY, goal.frame.minY)
        XCTAssertFalse(labels.contains { $0.stringValue.contains("Sources/") || $0.stringValue == "fix/login" })
        XCTAssertEqual(render(nil).bottomY, render("  \n ").bottomY)
        XCTAssertEqual(render(nil).bottomY - row.bottomY, SidebarExpandedMetrics.statusRowHeight)
    }

    func testTheChipUsesTheBoardStationAndTheOpenPullRequest() throws {
        let green = pullRequest(ci: "SUCCESS")
        var task = workspace([column()], pr: green)
        func chip(_ info: WorkspaceInfo) -> String? {
            SidebarWorkspaceCardRenderer(workspace: info, sidebarWidth: 260, yOffset: 400).render().views
                .compactMap { $0 as? SidebarBadgeView }.first { $0.accessibilityRole() == .staticText }?.accessibilityLabel()
        }
        XCTAssertEqual(chip(task), "Ready #39")
        task.boardProgress = SidebarBoardProgress(station: .reviews, number: 39)
        XCTAssertEqual(chip(task), "Review #39")
        XCTAssertEqual(task.rowSummary.mark, .idle, "the state icon follows the Board too")
        task.boardProgress = SidebarBoardProgress(station: .checks, number: 39)
        XCTAssertEqual(chip(task), "Checks #39")
        XCTAssertEqual(chip(workspace([column()], pr: pullRequest(.merged))), "Merged #39")
        XCTAssertEqual(chip(workspace([column()], pr: pullRequest(.closed))), "Code")
        var changes = workspace([column()], pr: pullRequest(ci: "SUCCESS", review: "CHANGES_REQUESTED"))
        changes.boardProgress = SidebarBoardProgress(station: .merge, number: 39)
        XCTAssertEqual(chip(changes), "Review #39")
        var planning = column(0, .working)
        planning.isPlanning = true
        XCTAssertEqual(chip(workspace([planning])), "Plan")
        XCTAssertEqual(chip(workspace([planning, column(1, .working)])), "Code")
        task.boardProgress = SidebarBoardProgress(station: .reviews, number: 12)
        XCTAssertEqual(chip(task), "Ready #39", "a board reading for another PR cannot move this one")
        var boardOnly = workspace([column()])
        boardOnly.boardProgress = SidebarBoardProgress(station: .merge, number: 41, mergeStep: .merged)
        XCTAssertEqual(chip(boardOnly), "Merged #41")
    }

    func testChipAndStatusFollowTheCurrentPullRequestWhenBoardReadingsAge() throws {
        let ready = SidebarBoardProgress(station: .merge, number: 39, mergeStep: .ready)
        let beforePR = SidebarBoardProgress(station: .code)
        func shown(_ board: SidebarBoardProgress, _ pr: PRInfo?) throws -> [String] {
            var task = workspace([column()], pr: pr)
            task.boardProgress = board
            let views = SidebarWorkspaceCardRenderer(workspace: task, sidebarWidth: 260, yOffset: 400).render().views
            let chip = try XCTUnwrap(views.compactMap { $0 as? SidebarBadgeView }.first { $0.accessibilityRole() == .staticText })
            let status = views.compactMap { $0 as? NSTextField }.first { $0.frame.midY == chip.frame.midY }
            return [try XCTUnwrap(chip.accessibilityLabel()), status?.stringValue ?? ""]
        }
        XCTAssertEqual(try shown(ready, pullRequest(ci: "SUCCESS")), ["Ready #39", "Checks passed"])
        XCTAssertEqual(try shown(ready, pullRequest(ci: "FAILURE")), ["Checks #39", "checks failed"])
        XCTAssertEqual(try shown(ready, pullRequest(ci: "PENDING")), ["Checks #39", "checks running"])
        XCTAssertEqual(try shown(ready, pullRequest(ci: "SUCCESS", draft: true)), ["Code #39", "draft"])
        XCTAssertEqual(try shown(ready, pullRequest(ci: "SUCCESS", review: "CHANGES_REQUESTED")), ["Review #39", "checks passed"])
        XCTAssertEqual(try shown(beforePR, nil), ["Code", ""])
        XCTAssertEqual(try shown(beforePR, pullRequest(ci: "SUCCESS")), ["Ready #39", "Checks passed"])
        XCTAssertEqual(try shown(.init(station: .reviews, number: 39), pullRequest(ci: "SUCCESS")), ["Review #39", "checks passed"])
        XCTAssertEqual(try shown(ready, nil), ["Ready #39", ""])
    }

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

    /// What stops a task is read whole: its line wraps, up to four lines,
    /// as the selected row's does; another row's takes two; a branch, a
    /// link and a command its block repeats keep to one. The row is as
    /// tall as its lines, and the tooltip has what "…" cuts.
    func testStatusLineWrapsUpToItsLimit() throws {
        let sentence = "Claude needs your permission to connect to the staging database before it runs the seed script, "
            + "because the credentials in the environment file expired last night and the script would stop halfway"
        func lines(_ info: WorkspaceInfo) -> Int { SidebarCardLayout(workspace: info, sidebarWidth: 260).statusLineCount }
        let waiting = workspace([column(0, .needsAttention, reason: .message(sentence))])
        XCTAssertEqual(lines(waiting), 4)
        XCTAssertEqual(lines(workspace([column()], blocker: sentence)), 4, "a blocker says what the task waits on")
        XCTAssertEqual(lines(workspace([column()], nextStep: sentence)), 1)
        XCTAssertEqual(lines(workspace([column()], isActive: true, nextStep: sentence)), 1, "the selected row has a separate next-step block")
        XCTAssertEqual(lines(workspace([column()], branch: "feat/" + String(repeating: "a-very-long-name-", count: 6))), 1)
        XCTAssertEqual(workspace([column()], pr: pullRequest(.merged), cleanup: .available).rowSummary.statusLineLimit(isSelected: true), 1)
        let broken = SidebarRowSummary(mark: .error, status: SidebarStatusLine(text: sentence, tone: .error), trailing: nil)
        XCTAssertEqual(broken.statusLineLimit(isSelected: false), 4, "what broke stops the task too")
        // Its own line breaks would spend those lines on blanks.
        XCTAssertEqual(status(workspace([column()], nextStep: "Write the importer\n\n then the export side ")), "Next · Write the importer then the export side")

        func render(_ info: WorkspaceInfo) -> SidebarWorkspaceCardRenderResult {
            SidebarWorkspaceCardRenderer(workspace: info, sidebarWidth: 260, yOffset: 500).render()
        }
        let oneLine = SidebarExpandedMetrics.rowPaddingY * 2 + SidebarExpandedMetrics.titleRowHeight
            + SidebarExpandedMetrics.statusGap + SidebarExpandedMetrics.statusRowHeight
        let row = render(waiting)
        let label = try XCTUnwrap(row.views.compactMap { $0 as? NSTextField }.first { $0.stringValue == "Needs you · \(sentence)" })
        XCTAssertEqual(label.frame.height, 4 * SidebarExpandedMetrics.statusRowHeight)
        XCTAssertEqual(label.maximumNumberOfLines, 4)
        XCTAssertEqual(label.cell?.truncatesLastVisibleLine, true, "then “…”")
        XCTAssertTrue(label.toolTip?.contains(sentence) == true)
        XCTAssertEqual(500 - row.bottomY, oneLine + 3 * SidebarExpandedMetrics.statusRowHeight)

        // A sentence that fits is whole, on the lines it takes and no more.
        let short = "Claude needs your permission to connect to the staging database"
        let fitting = render(workspace([column(0, .needsAttention, reason: .message(short))]))
        let whole = try XCTUnwrap(fitting.views.compactMap { $0 as? NSTextField }.first { $0.stringValue == "Needs you · \(short)" })
        let taken = whole.frame.height / SidebarExpandedMetrics.statusRowHeight
        XCTAssertTrue((2...3).contains(Int(taken)), "\(taken) lines")
        XCTAssertEqual(500 - fitting.bottomY, oneLine + (taken - 1) * SidebarExpandedMetrics.statusRowHeight)

        // The command its Allow / Deny block shows whole stays on one line.
        var approval = column(0, .needsAttention, reason: .permission(tool: "Bash", summary: sentence))
        var request = AgentPermissionRequest(toolName: "Bash", summary: sentence, key: "k", agentID: nil, sessionID: "s", requestedAt: 0)
        request.approval = PermissionApprovalTicket(requestID: "r", deadline: 100, text: sentence)
        approval.permissionApproval = SidebarPermissionApproval(request, now: 1)
        XCTAssertEqual(lines(workspace([approval])), 1)

        // The selected row's next step, under a line that says something
        // else: up to three lines, inside its row.
        let next = workspace([column(0, .working)], isActive: true, nextStep: sentence)
        let selected = render(next)
        let step = try XCTUnwrap(selected.views.compactMap { $0 as? NSTextField }.first { $0.stringValue.hasSuffix(sentence) })
        XCTAssertEqual(step.frame.height, 3 * SidebarExpandedMetrics.actionLineHeight)
        XCTAssertEqual(step.frame.minY, selected.bottomY + SidebarExpandedMetrics.rowPaddingY, accuracy: 0.5)

        // What follows a status of several lines starts under it.
        let tall = render(workspace([column()], isActive: true, blocker: sentence))
        let status = try XCTUnwrap(tall.views.compactMap { $0 as? NSTextField }.first { $0.stringValue == "Blocked · \(sentence)" })
        let chip = try XCTUnwrap(tall.hitAreas.first { if case .column = $0.region { true } else { false } })
        XCTAssertLessThanOrEqual(chip.frame.maxY, status.frame.minY)
    }

    /// Rows change height as their text does. A list at its top stays at
    /// its top, and a list scrolled down keeps its topmost row in view
    /// where it is, whether a row above or below takes more lines.
    func testListKeepsItsPlaceWhenARowChangesHeight() throws {
        _ = NSApplication.shared
        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 260, height: 300))
        let window = NSWindow(contentRect: sidebar.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = sidebar
        defer { window.close() }
        sidebar.isExpanded = true
        let sentence = String(repeating: "waiting for the search team to rotate the staging key ", count: 4)
        /// Twenty tasks, numbered as the store does: closing one renumbers
        /// those after it.
        func rows(blocked: Set<Int>, closed: Int? = nil, archived: Set<Int> = [], renamed: String = "") -> [WorkspaceInfo] {
            (0..<20).filter { $0 != closed }.enumerated().map { index, task in
                WorkspaceInfo(
                    id: "ws-\(task)", index: index, title: "Task \(task)\(renamed)", profileID: WorkspaceProfile.defaultID,
                    isInactive: archived.contains(task),
                    columnCount: 1, focusedColumn: 0, gitBranch: "fix/\(task)", notification: nil, isActive: false,
                    columns: [column()], prInfo: nil, diffStats: nil, purpose: nil, nextStep: nil,
                    blocker: blocked.contains(task) ? sentence : nil, phase: .active, lastSummary: nil, lastActivityAt: nil
                )
            }
        }
        let clip = sidebar.contentScrollView.contentView
        func hiddenAbove() -> CGFloat { sidebar.contentDocumentView.frame.height - clip.bounds.maxY }
        /// From the visible top down to the top of that task's row.
        func place(of task: Int) throws -> CGFloat {
            let index = try XCTUnwrap(sidebar.lastInfos.first { $0.id == "ws-\(task)" }?.index)
            let row = try XCTUnwrap(sidebar.hitAreas.first { if case .workspace(index) = $0.region { true } else { false } })
            return clip.bounds.maxY - row.frame.maxY
        }
        sidebar.update(profiles: [], workspaces: rows(blocked: []))
        sidebar.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(sidebar.contentDocumentView.frame.height, 600, "a list taller than the sidebar")
        XCTAssertEqual(hiddenAbove(), 0, accuracy: 0.5)
        let short = sidebar.contentDocumentView.frame.height
        sidebar.update(profiles: [], workspaces: rows(blocked: [15]))
        XCTAssertGreaterThan(sidebar.contentDocumentView.frame.height, short, "a row out of view grew")
        XCTAssertEqual(hiddenAbove(), 0, accuracy: 0.5, "the top stays")

        clip.scroll(to: NSPoint(x: 0, y: clip.bounds.origin.y - 200))
        sidebar.contentScrollView.reflectScrolledClipView(clip)
        XCTAssertEqual(hiddenAbove(), 200, accuracy: 0.5)
        let inView = try XCTUnwrap(sidebar.hitAreas.compactMap { area -> Int? in
            guard case .workspace(let index) = area.region, clip.bounds.contains(area.frame) else { return nil }
            return index
        }.min())
        let before = try place(of: inView)
        sidebar.update(profiles: [], workspaces: rows(blocked: []))
        XCTAssertEqual(try place(of: inView), before, accuracy: 0.5, "a row below shrank")
        sidebar.update(profiles: [], workspaces: rows(blocked: [0]))
        XCTAssertEqual(try place(of: inView), before, accuracy: 0.5, "a row above grew")
        sidebar.update(profiles: [], workspaces: rows(blocked: [0, 15]))
        XCTAssertEqual(try place(of: inView), before, accuracy: 0.5, "a row below grew")
        XCTAssertGreaterThan(inView, 1)
        sidebar.update(profiles: [], workspaces: rows(blocked: [0, 15, inView + 1]))
        XCTAssertEqual(try place(of: inView), before, accuracy: 0.5, "the row under it grew: the topmost row holds the list")
        // With a row below changing height at once, or the list would
        // hold by itself.
        sidebar.update(profiles: [], workspaces: rows(blocked: [0], closed: 1))
        XCTAssertEqual(try place(of: inView), before, accuracy: 0.5, "a task above closed: the rows after it took new numbers")
        sidebar.update(profiles: [], workspaces: rows(blocked: [0, 15]))
        XCTAssertEqual(try place(of: inView), before, accuracy: 0.5, "a task above opened")

        // The row that holds the list is archived, the Archived list
        // unfolded: found again at the bottom, it doesn't take the list
        // there. The clip stays as it is.
        sidebar.update(profiles: [], workspaces: rows(blocked: [0, 15], closed: 1, archived: [19]))
        sidebar.toggleInactiveSection()
        clip.scroll(to: NSPoint(x: 0, y: sidebar.contentDocumentView.frame.height - clip.bounds.height - 200))
        sidebar.contentScrollView.reflectScrolledClipView(clip)
        let held = try XCTUnwrap(sidebar.hitAreas.compactMap { area -> (index: Int, top: CGFloat)? in
            guard case .workspace(let index) = area.region, area.frame.intersects(clip.bounds) else { return nil }
            return (index, area.frame.maxY)
        }.max { $0.top < $1.top }?.index)
        let heldTask = try XCTUnwrap(Int(try XCTUnwrap(sidebar.lastInfos.first { $0.index == held }).id.dropFirst(3)))
        var origin = clip.bounds.origin.y
        XCTAssertGreaterThan(origin, 100, "far from the bottom")
        sidebar.update(profiles: [], workspaces: rows(blocked: [0, 15], closed: 1, archived: [19, heldTask]))
        XCTAssertTrue(try XCTUnwrap(sidebar.lastInfos.first { $0.id == "ws-\(heldTask)" }).isInactive)
        XCTAssertEqual(clip.bounds.origin.y, origin, accuracy: 0.5, "the row that held the list moved")

        // Back at its top: what comes in above the first row shows.
        clip.scroll(to: NSPoint(x: 0, y: sidebar.contentDocumentView.frame.height - clip.bounds.height))
        sidebar.contentScrollView.reflectScrolledClipView(clip)
        let space = ProfileInfo(
            id: WorkspaceProfile.defaultID, name: "Acme", colorHex: "#78A3F7", isActive: true, workspaceCount: 20,
            taskCount: 20, attention: nil
        )
        sidebar.update(profiles: [space], workspaces: rows(blocked: [0, 15]))
        XCTAssertEqual(hiddenAbove(), 0, accuracy: 0.5, "the space picker, not hidden above the first row")

        // Past an end of the list, mid-bounce, the clip is the scroll
        // view's: a rebuild that moves nothing leaves it alone. (A clip
        // that takes any origin, as the scroll view's does while it
        // bounces.)
        let loose = UnconstrainedClipView(frame: clip.frame)
        sidebar.contentScrollView.contentView = loose
        sidebar.contentScrollView.documentView = sidebar.contentDocumentView
        let top = sidebar.contentDocumentView.frame.height - loose.bounds.height
        for (name, bounced) in [("past the top", top + 30), ("past the bottom", -30)] {
            loose.setBoundsOrigin(NSPoint(x: 0, y: bounced))
            XCTAssertEqual(loose.bounds.origin.y, bounced, "a clip that bounces")
            sidebar.update(profiles: [space], workspaces: rows(blocked: [0, 15], renamed: " (\(name))"))
            XCTAssertEqual(sidebar.contentDocumentView.frame.height - loose.bounds.height, top, accuracy: 0.01, "the same heights")
            XCTAssertEqual(loose.bounds.origin.y, bounced, accuracy: 0.01, name)
        }
    }

    /// "Clean up" is a link over its own words: a click on "Merged" or
    /// beside the line selects the row. An agent's state on the line keeps
    /// Clean up in a line of its own.
    func testCleanUpLinksOnlyItsWords() throws {
        let merged = workspace([column()], pr: pullRequest(.merged), cleanup: .available)
        let result = SidebarWorkspaceCardRenderer(workspace: merged, sidebarWidth: 260, yOffset: 500).render()
        let link = try XCTUnwrap(result.hitAreas.first { if case .link = $0.region { true } else { false } })
        guard case .link(let url, let label) = link.region else { return XCTFail("no link") }
        XCTAssertEqual(url, SidebarView.cleanupActionURL(workspaceIndex: 4))
        XCTAssertEqual(label.stringValue, "Merged · Clean up")
        let prefixWidth = ceil(NSAttributedString(string: "Merged · ", attributes: [.font: Theme.Font.body]).size().width)
        XCTAssertGreaterThan(link.frame.minX, label.frame.minX + prefixWidth - 4)
        XCTAssertLessThan(link.frame.maxX, label.frame.maxX)

        let working = workspace([column(0, .working)], pr: pullRequest(.merged), cleanup: .available)
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

    /// A question that waits on the user shows what its child recommends,
    /// with Reply… and Accept; an access question's says what it needs, with
    /// Reply… alone. One its parent may still answer shows none on the row.
    func testAMissionRecommendationWaitsWithItsQuestion() {
        let question = SidebarMissionQuestion(
            questionID: "q", parentTitle: "Lead", text: "Which format?", handOff: .handedOver(why: "Yours."),
            kind: .decision, recommendation: "ISO 8601"
        )
        func row(_ question: SidebarMissionQuestion) -> WorkspaceInfo {
            var child = column(1)
            child.missionQuestion = question
            return workspace([child])
        }
        func answers(_ question: SidebarMissionQuestion) -> [Bool] {
            SidebarWorkspaceCardRenderer(workspace: row(question), sidebarWidth: 260, yOffset: 500).render().hitAreas.compactMap {
                if case let .missionAnswer(_, 1, "q", accepts) = $0.region { accepts } else { nil }
            }
        }
        XCTAssertEqual(row(question).cardActions, [.missionRecommendation(columnIndex: 1, question)])
        XCTAssertEqual(answers(question), [true, false], "Accept at the right edge, then Reply…")
        var marked = question
        marked.recommendation = "Use **ISO** `8601`"
        let shown = SidebarWorkspaceCardRenderer(workspace: row(marked), sidebarWidth: 260, yOffset: 500).render().views
            .compactMap { ($0 as? NSTextField)?.stringValue }
        XCTAssertTrue(shown.contains { $0.hasSuffix("Use **ISO** `8601`") }, "what Accept sends, as it is: \(shown)")
        var asked = column(1)
        asked.missionQuestion = question
        let turn = SidebarTurnQuestion(text: "Which format?", turnEndedAt: 1, isYesNo: false, columnID: UUID())
        asked.turnQuestion = turn
        XCTAssertEqual(
            workspace([asked]).cardActions, [.missionRecommendation(columnIndex: 1, question), .turnQuestion(columnIndex: 1, turn)],
            "the recommendation before a turn's question block asking it again"
        )
        var access = question
        access.kind = .access
        XCTAssertEqual(answers(access), [false], "accepting gives no access")
        var long = question
        long.recommendation = String(repeating: "Backfill from the archive, then drop it. ", count: 7)
        XCTAssertEqual(answers(long), [false], "Accept sends what the row shows whole only; the popover has the rest")
        let asking = SidebarMissionQuestion(
            questionID: "q", parentTitle: "Lead", text: "Which format?", handOff: nil, kind: .decision, recommendation: "ISO 8601"
        )
        XCTAssertEqual(row(asking).cardActions, [], "the Lead may still answer")
    }

    /// Reply… and Accept act like Allow / Deny: one click, pressed and
    /// released on the same button of the same question, armed.
    func testOnlyASingleClickReleasedOnTheSameMissionAnswerActs() {
        let accept = SidebarHitRegion.missionAnswer(workspaceIndex: 2, columnIndex: 1, questionID: "q", accepts: true)
        let moved = SidebarHitRegion.missionAnswer(workspaceIndex: 0, columnIndex: 3, questionID: "q", accepts: true)
        func click(
            _ released: SidebarHitRegion?, clicks: Int = 1, armedAtPress: Bool = true, armedAtRelease: Bool = true
        ) -> SidebarMissionAnswerClick? {
            SidebarView.missionAnswerClick(
                pressed: accept, released: released, clickCount: clicks, armedAtPress: armedAtPress, armedAtRelease: armedAtRelease
            )
        }
        XCTAssertEqual(click(moved), SidebarMissionAnswerClick(workspaceIndex: 0, columnIndex: 3, questionID: "q", accepts: true))
        XCTAssertEqual(SidebarView.armedButtonKey(for: accept), SidebarView.armedButtonKey(for: moved), "the same button wherever it is")
        XCTAssertNil(click(.missionAnswer(workspaceIndex: 2, columnIndex: 1, questionID: "q", accepts: false)), "slid onto Reply…")
        XCTAssertNil(click(.missionAnswer(workspaceIndex: 2, columnIndex: 1, questionID: "r", accepts: true)), "another question")
        XCTAssertNil(click(.actionBlock(workspaceIndex: 2)))
        XCTAssertNil(click(accept, clicks: 2))
        XCTAssertNil(click(accept, armedAtPress: false))
        XCTAssertNil(click(accept, armedAtRelease: false))
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
        XCTAssertTrue(
            SidebarWorkspaceCardRenderer(workspace: askingLead, sidebarWidth: 260, yOffset: 500).render().views
                .contains { ($0 as? NSTextField)?.stringValue == "Needs you · Ship it?" },
            "the question itself"
        )
        XCTAssertEqual(
            SidebarExpandedMetrics.workspaceHeight(for: askingLead, sidebarWidth: 260),
            SidebarExpandedMetrics.leadRowHeight
                + SidebarExpandedMetrics.actionBlockHeight(askingLead.cardActions, width: 224, textWidth: 208)
                + SidebarExpandedMetrics.rowPaddingY,
            "its block ends a row's padding above its edge"
        )
    }
}

/// A clip view past an end of its document, as a scroll view's is while
/// it bounces.
private final class UnconstrainedClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect { proposedBounds }
}
