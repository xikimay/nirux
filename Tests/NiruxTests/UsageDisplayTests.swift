import XCTest
@testable import Nirux

final class UsageDisplayTests: XCTestCase {
    private let now: TimeInterval = 1_795_262_400

    private func event(_ secondsAgo: TimeInterval, input: Int, context: Int? = nil, subagent: String? = nil) -> UsageEvent {
        UsageEvent(timestamp: now - secondsAgo, model: "claude-opus-5-5", counts: TokenCounts(input: input), contextTokens: context, subagentID: subagent)
    }

    func testTokenCountsReadShortAndRoundAtEachUnit() {
        let values: [Double] = [0, 950, 999.6, 142_400, 999_499, 999_500, 4_240_000, 9_949_999, 9_950_000, 999_499_999, 1_050_000_000]
        XCTAssertEqual(values.map(UsageText.tokens), ["0", "950", "1k", "142k", "999k", "1.0M", "4.2M", "9.9M", "10M", "999M", "1.05G"])
        XCTAssertEqual([-5, .nan].map(UsageText.tokens), ["0", "0"])
        XCTAssertEqual(UsageText.share(29, of: 100), "29%")
        XCTAssertEqual(UsageText.share(1, of: 0), "0%")
    }

    func testCodexWindowsThatResetAreLeftOutAndTheShortestComesFirst() {
        let limits = CodexRateLimits(
            primary: .init(usedPercent: 64.4, minutes: 10_080, resetsAt: now + 3_600),
            secondary: .init(usedPercent: 12, minutes: 300, resetsAt: now + 60),
            reportedAt: now
        )
        XCTAssertEqual(UsageText.codexWindows(limits, now: now).map(\.name), ["5h", "7d"])
        XCTAssertEqual(UsageText.codexWindows(limits, now: now).map(\.percent), [12, 64])
        XCTAssertEqual(UsageText.codexWindows(limits, now: now + 61).map(\.name), ["7d"])
    }

    /// Under the column, never imposed: why, then Compact and Fresh start,
    /// which arm like Allow / Deny and click only for that offer.
    @MainActor func testAHeavyClaudeColumnOffersACompactionOrAFreshStart() throws {
        let offer = ContextOffer(reason: .heavy, contextTokens: 312_000, lastResponseAt: 100)
        var column = ColumnInfo(
            index: 0, processName: "claude", abbreviatedCwd: "~/p", isFocused: false, isWebView: false,
            webTitle: nil, terminalTitle: nil, agentStatus: .idle, isEditor: false, editorFileName: nil
        )
        column.contextOffer = offer
        func card(_ column: ColumnInfo) -> WorkspaceInfo {
            WorkspaceInfo(
                id: "ws", index: 0, title: "check-video", profileID: WorkspaceProfile.defaultID, isInactive: false,
                columnCount: 1, focusedColumn: 0, gitBranch: nil, notification: nil, isActive: false,
                columns: [column], prInfo: nil, diffStats: nil, purpose: nil, nextStep: nil, blocker: nil,
                phase: .active, lastSummary: nil, lastActivityAt: nil
            )
        }
        let info = card(column)
        XCTAssertEqual(info.cardActions, [.contextOffer(columnIndex: 0, offer)])
        XCTAssertEqual(offer.text, "Each message rereads 312k")
        XCTAssertEqual(
            ContextOffer(reason: .cold, contextTokens: 160_000, lastResponseAt: 100).text, "Cache expired: 160k to write again"
        )

        let result = SidebarWorkspaceCardRenderer(workspace: info, sidebarWidth: 260, yOffset: 800).render()
        let keys = [ContextOffer.Choice.compact, .freshStart].map {
            SidebarHoverTarget.contextOfferButtonKey(workspaceIndex: 0, columnIndex: 0, offer: offer, choice: $0)
        }
        XCTAssertEqual(Set(result.approvalButtons.keys), Set(keys))
        XCTAssertEqual(800 - result.bottomY, SidebarExpandedMetrics.workspaceHeight(for: info, sidebarWidth: 260), accuracy: 0.5)

        let compact = SidebarHitRegion.contextOffer(workspaceIndex: 0, columnIndex: 0, offer: offer, choice: .compact)
        func click(_ released: SidebarHitRegion?, count: Int = 1) -> SidebarContextOfferClick? {
            SidebarView.contextOfferClick(pressed: compact, released: released, clickCount: count, armedAtPress: true, armedAtRelease: true)
        }
        XCTAssertEqual(click(compact), SidebarContextOfferClick(workspaceIndex: 0, columnIndex: 0, choice: .compact))
        XCTAssertNil(click(.contextOffer(workspaceIndex: 0, columnIndex: 0, offer: offer, choice: .freshStart)), "released on the other")
        var later = offer
        later.lastResponseAt = 200
        XCTAssertNil(click(.contextOffer(workspaceIndex: 0, columnIndex: 0, offer: later, choice: .compact)), "another response came")
        XCTAssertNil(click(compact, count: 2))

        // Where Nirux can't hand the work over: Compact alone.
        column.contextOffer = ContextOffer(reason: .heavy, contextTokens: 312_000, lastResponseAt: 100, choices: [.compact])
        XCTAssertEqual(
            Array(SidebarWorkspaceCardRenderer(workspace: card(column), sidebarWidth: 260, yOffset: 800).render().approvalButtons.keys),
            [SidebarHoverTarget.contextOfferButtonKey(workspaceIndex: 0, columnIndex: 0, offer: column.contextOffer!, choice: .compact)]
        )
    }

    @MainActor func testAColumnIsAtRestOnlyAtItsPromptAskingNothing() throws {
        let idle = column(.idle)
        XCTAssertTrue(idle.isAtRest)
        let working = column(.working)
        var asked = idle
        asked.openDialog = .askedInReply("Queue #824 now or wait?")
        var turn = idle
        turn.turnQuestion = SidebarTurnQuestion(text: "Queue #824 now or wait?", turnEndedAt: 1, isYesNo: false, columnID: UUID())
        var failed = idle
        failed.stuck = .silent(duration: "4h45m", since: 100, interruptible: true)
        var request = AgentPermissionRequest(toolName: "Bash", summary: "x", key: "k", agentID: nil, sessionID: "lead", requestedAt: 0)
        request.approval = PermissionApprovalTicket(requestID: "r", deadline: 100, text: "rm -rf build")
        var approval = idle
        approval.permissionApproval = try XCTUnwrap(SidebarPermissionApproval(request, now: 1))
        for (column, why) in [(working, "working"), (asked, "its reply asks"), (turn, "its turn asked"), (failed, "a failed turn"),
                              (approval, "a permission prompt")] {
            XCTAssertFalse(column.isAtRest, why)
        }
    }

    func testAClickOnTheOfferNeverTypesOverADraftAndKeepsTheWorkersModel() {
        XCTAssertEqual(ContextOfferAction.of(.compact, hasDraft: false, isLead: false, workerModel: nil), .typeCompact)
        XCTAssertEqual(ContextOfferAction.of(.compact, hasDraft: true, isLead: false, workerModel: nil), .refuse(ContextOfferAction.draftRefusal))
        XCTAssertEqual(ContextOfferAction.of(.freshStart, hasDraft: true, isLead: true, workerModel: nil), .confirmLeadRestart, "Restart Lead asks")
        XCTAssertEqual(ContextOfferAction.of(.freshStart, hasDraft: false, isLead: false, workerModel: "sonnet"), .resumeTask(model: "sonnet"))
        XCTAssertEqual(AgentModels.launchModel(arguments: ["--model", "sonnet", "Continue the task"]), "sonnet")
    }

    @MainActor func testATaskTakesItsOwnCLIAgainOnlyForAFreshStart() {
        XCTAssertEqual(
            NiruxShellView.taskSwitchRefusal(current: .claude, choice: .claude, awaitingResume: false, freshStart: false),
            "This task already runs claude. Choose another CLI."
        )
        XCTAssertNil(NiruxShellView.taskSwitchRefusal(current: .claude, choice: .claude, awaitingResume: false, freshStart: true))
        XCTAssertNil(NiruxShellView.taskSwitchRefusal(current: .claude, choice: .claude, awaitingResume: true, freshStart: false))
        XCTAssertNil(NiruxShellView.taskSwitchRefusal(current: .codex, choice: .claude, awaitingResume: false, freshStart: false))
    }

    /// Cold, heavy, its own session, allowed by its space, holding nothing:
    /// each missing one keeps the Lead's conversation.
    func testAColdLeadStartsAfreshOnlyWhenItHoldsNothing() throws {
        let session = UsageSession(
            key: UsageSessionKey(.claude, "s"), attribution: UsageAttribution(spaceID: "space", taskID: "lead"), contextTokens: 300_000,
            events: [event(7_200, input: 300_000, context: 300_000)]
        )
        let latest = try XCTUnwrap(UsageReport(sessions: [session], now: now).latestSessions["lead"])
        func starts(
            _ sessionID: String? = "s", runningSince: TimeInterval = 0, context: Int = 300_000, spaceAllows: Bool = true,
            holdings: LeadHoldings = LeadHoldings()
        ) -> Bool {
            var latest = latest
            latest.contextTokens = context
            return ColdLead.startsFresh(
                latest: latest, sessionID: sessionID, runningSince: runningSince, now: now, spaceAllows: spaceAllows, holdings: holdings
            )
        }
        XCTAssertTrue(starts())
        XCTAssertFalse(starts("other"), "another conversation runs in its terminal")
        XCTAssertFalse(starts(nil), "its hooks haven't named it")
        XCTAssertFalse(starts(runningSince: now - 60), "just resumed")
        XCTAssertFalse(starts(context: 150_000))
        XCTAssertFalse(starts(spaceAllows: false))
        let held: [(WritableKeyPath<LeadHoldings, Bool>, String)] = [
            (\.isBusy, "working"), (\.hasDialog, "a dialog"), (\.hasQuestion, "a question to the user"), (\.hasDraft, "a draft"),
            (\.owesMissionReply, "a task's question"), (\.runsItsQueue, "the queue it started")
        ]
        for (key, why) in held {
            var holdings = LeadHoldings()
            holdings[keyPath: key] = true
            XCTAssertFalse(starts(holdings: holdings), why)
        }
    }

    func testALeadOwesAReplyToItsTasksQuestionUntilItAnswers() {
        let question = MissionEvent(
            id: "q", missionID: "m", childWorkspaceID: "task", childAgentUUID: "agent", kind: .question,
            message: "Queue it now?", inReplyTo: nil, timestamp: now - 7_200
        )
        func mission(_ events: [MissionEvent], status: Mission.Status = .active) -> Mission {
            Mission(
                id: "m", parentWorkspaceID: "lead", parentAgentUUID: "lead-agent", childWorkspaceID: "task", childAgentUUID: "agent",
                childAgentKind: "claude", branch: "feat/x", status: status, createdAt: now - 9_000, updatedAt: now, events: events,
                reportsToLead: true
            )
        }
        XCTAssertTrue(mission([question]).awaitsReply(from: "lead"))
        XCTAssertFalse(mission([question]).awaitsReply(from: "other"))
        let answer = MissionEvent(
            id: "a", missionID: "m", childWorkspaceID: "task", childAgentUUID: "agent", kind: .response,
            message: "Yes", inReplyTo: "q", timestamp: now - 60
        )
        XCTAssertFalse(mission([question, answer]).awaitsReply(from: "lead"))
        var handed = question
        handed.handedToUserBecause = "a decision"
        XCTAssertFalse(mission([handed]).awaitsReply(from: "lead"), "the user answers it")
        XCTAssertFalse(mission([question], status: .completed).awaitsReply(from: "lead"))
    }

    /// The fresh Lead learns where its previous conversation is; its first
    /// prompt still reads as a restart.
    func testAFreshLeadIsHandedItsPreviousConversation() {
        XCTAssertEqual(NiruxShellView.leadHandoverLines(previous: nil, context: ["Last conversation entry: Queue #824 when green."]),
                       ["Last conversation entry: Queue #824 when green."])
        let record = AgentSessionRecord(
            schemaVersion: 1, agent: .claude, sessionID: "s1", startedAt: 0, lastStartAt: 0, lastActivityAt: 0, status: .idle, hasConversation: true
        )
        XCTAssertEqual(NiruxShellView.leadHandoverLines(previous: record, context: []).first?.hasPrefix(
            "Previous conversation in Session History: claude s1."
        ), true)
        let prompt = ([NiruxShellView.leadRestartPrompt(for: .claude)] + ["Last conversation entry: Queue #824 when green."])
            .joined(separator: "\n")
        XCTAssertTrue(NiruxShellView.isLeadRestart(prompt: prompt, agent: .claude))
        XCTAssertTrue(NiruxShellView.isLeadRestart(prompt: NiruxShellView.leadRelaunchPrompt(for: .claude), agent: .claude))
        XCTAssertFalse(NiruxShellView.isLeadRestart(prompt: "Fix the build", agent: .claude))
    }

    func testATaskRowReadsItsLatestSessionsContextAndItsWeek() throws {
        let session = UsageSession(
            key: UsageSessionKey(.claude, "s"), attribution: UsageAttribution(spaceID: "space", taskID: "task"), contextTokens: 300_000,
            events: [event(7_200, input: 4_200_000, context: 300_000), event(7_000, input: 100_000, subagent: "a")]
        )
        let report = UsageReport(sessions: [session], now: now)
        XCTAssertNil(SidebarTaskUsage(report, taskID: "other"))
        let usage = try XCTUnwrap(SidebarTaskUsage(report, taskID: "task"))
        XCTAssertEqual(usage.chip?.text, "300k", "past 280k: each message rereads it")
        XCTAssertTrue(usage.isContextHeavy)
        let lines = usage.toolTip(now: now).components(separatedBy: "\n")
        XCTAssertTrue(lines.contains("Context of its latest session: 300k tokens"), "the numbers live in the tooltip")
        XCTAssertTrue(lines.contains("Last 7 days: 4.3M tokens, in Opus 5.5 input tokens at list prices"))
        XCTAssertTrue(lines.contains("Idle for 2h: its cache expired, the next message writes it again"))
        XCTAssertTrue(lines.contains("Subagents: 2%"))
        XCTAssertTrue(lines.contains("Past 280k of context: 98%"))
    }

    /// From the soft cap, the row warns and its tooltip says why; under it,
    /// it says nothing of subagents.
    @MainActor func testARowWarnsOnceItsSessionReachesTheSubagentsSoftCap() throws {
        func usage(subagents: Int) throws -> SidebarTaskUsage {
            let session = UsageSession(
                key: UsageSessionKey(.claude, "s"), attribution: UsageAttribution(spaceID: "space", taskID: "task"), contextTokens: 90_000,
                subagents: subagents, events: [event(60, input: 90_000, context: 90_000)]
            )
            return try XCTUnwrap(SidebarTaskUsage(UsageReport(sessions: [session], now: now), taskID: "task"))
        }
        let under = try usage(subagents: SidebarTaskUsage.subagentSoftCap - 1)
        XCTAssertFalse(under.isWarning)
        XCTAssertFalse(under.toolTip(now: now).contains("subagents in its latest session"))
        let capped = try usage(subagents: SidebarTaskUsage.subagentSoftCap)
        XCTAssertTrue(capped.isWarning)
        XCTAssertFalse(capped.isContextHeavy)
        XCTAssertTrue(capped.toolTip(now: now).components(separatedBy: "\n")
            .contains("5 subagents in its latest session: from the 5th, separate work costs less as a task"))

        // The row's count says it as a warning.
        func shown(_ usage: SidebarTaskUsage) -> String? {
            var info = WorkspaceInfo(
                id: "task", index: 0, title: "check-video", profileID: WorkspaceProfile.defaultID, isInactive: false,
                columnCount: 0, focusedColumn: 0, gitBranch: nil, notification: nil, isActive: false,
                columns: [], prInfo: nil, diffStats: nil, purpose: nil, nextStep: nil, blocker: nil,
                phase: .active, lastSummary: nil, lastActivityAt: nil
            )
            info.usage = usage
            let labels = SidebarWorkspaceCardRenderer(workspace: info, sidebarWidth: 260, yOffset: 800).render().views
                .compactMap { $0 as? NSTextField }
            return usage.chip.flatMap { chip in labels.first { $0.stringValue.hasSuffix(chip.text) }?.stringValue }
        }
        XCTAssertEqual(shown(capped), "⚠︎ 5 subagents")
        XCTAssertNil(shown(under), "a task that doesn't burn shows no number")
    }

    /// Past its space's budget, the row warns and says its follow-ups wait;
    /// under it, or with no budget, it says nothing of one.
    /// A cold task says so without a warning; its share of the last half
    /// hour, and a Lead's space's share of the week, are in the tooltip.
    func testARowSaysWhyItSpendsAndKeepsItsSharesInTheTooltip() throws {
        let sessions = [
            UsageSession(
                key: UsageSessionKey(.claude, "s"), attribution: UsageAttribution(spaceID: "space", taskID: "task"), contextTokens: 210_000,
                events: [event(4_000, input: 210_000, context: 210_000), event(600, input: 1_000, subagent: "a")]
            ),
            UsageSession(key: UsageSessionKey(.claude, "o"), events: [event(300, input: 3_000)])
        ]
        let report = UsageReport(sessions: sessions, now: now)
        var usage = try XCTUnwrap(SidebarTaskUsage(report, taskID: "task"))
        XCTAssertEqual(usage.chip?.text, "Cold")
        XCTAssertEqual(usage.chip?.isWarning, false)
        let warm = try XCTUnwrap(SidebarTaskUsage(UsageReport(sessions: sessions, now: now - 3_500), taskID: "task"))
        XCTAssertNil(warm.chip, "its cache still warm")
        XCTAssertTrue(usage.toolTip(now: now).contains("Last 30 minutes: 25% of Claude’s spend in Nirux"))
        usage.spaceWeekShare = 0.62
        XCTAssertTrue(usage.toolTip(now: now).contains("Its space: 62% of the week’s spend in Nirux"))
    }

    func testARowWarnsPastItsBudget() throws {
        let session = UsageSession(
            key: UsageSessionKey(.claude, "s"), attribution: UsageAttribution(spaceID: "space", taskID: "task"), contextTokens: 90_000,
            events: [event(60, input: 26_000_000, context: 90_000)]
        )
        let report = UsageReport(sessions: [session], now: now)
        let over = try XCTUnwrap(SidebarTaskUsage(report, taskID: "task", budget: 25_000_000))
        XCTAssertTrue(over.isOverBudget)
        XCTAssertTrue(over.isWarning)
        XCTAssertEqual(over.chip?.text, "Budget")
        XCTAssertTrue(over.toolTip(now: now).components(separatedBy: "\n")
            .contains("Past its budget of 25M: its pull request's follow-ups wait (Space Settings › Defaults)"))
        let under = try XCTUnwrap(SidebarTaskUsage(report, taskID: "task", budget: 50_000_000))
        XCTAssertFalse(under.isOverBudget)
        XCTAssertFalse(under.isWarning)
        XCTAssertFalse(try XCTUnwrap(SidebarTaskUsage(report, taskID: "task")).isOverBudget, "no budget")
    }

    /// Past its budget, a task's card offers Continue, Fresh start (only
    /// while its columns rest) and Close…; they arm like Allow / Deny and
    /// click only for that task, budget and choice.
    @MainActor func testATaskPastItsBudgetOffersAChoice() throws {
        let offer = SidebarBudgetOffer(workspaceID: "ws", budget: 25_000_000, choices: BudgetChoice.allCases)
        let info = overBudgetTask([column(.idle)])
        XCTAssertEqual(info.cardActions, [.budget(offer)])
        let result = SidebarWorkspaceCardRenderer(workspace: info, sidebarWidth: 260, yOffset: 800).render()
        XCTAssertEqual(Set(result.approvalButtons.keys), Set(BudgetChoice.allCases.map {
            SidebarHoverTarget.budgetChoiceButtonKey(offer: offer, choice: $0)
        }))
        XCTAssertEqual(800 - result.bottomY, SidebarExpandedMetrics.workspaceHeight(for: info, sidebarWidth: 260), accuracy: 0.5)
        XCTAssertEqual(overBudgetTask([column(.working)]).cardActions, [
            .budget(SidebarBudgetOffer(workspaceID: "ws", budget: 25_000_000, choices: [.keepGoing, .close]))
        ], "no Fresh start mid-turn")

        let keepGoing = SidebarHitRegion.budgetChoice(workspaceIndex: 0, offer: offer, choice: .keepGoing)
        func click(_ released: SidebarHitRegion?) -> SidebarBudgetClick? {
            SidebarView.budgetChoiceClick(pressed: keepGoing, released: released, clickCount: 1, armedAtPress: true, armedAtRelease: true)
        }
        XCTAssertEqual(click(keepGoing), SidebarBudgetClick(workspaceID: "ws", choice: .keepGoing))
        XCTAssertNil(click(.budgetChoice(workspaceIndex: 0, offer: offer, choice: .close)), "released on another")
        let other = SidebarBudgetOffer(workspaceID: "other", budget: 25_000_000, choices: BudgetChoice.allCases)
        XCTAssertNil(click(.budgetChoice(workspaceIndex: 0, offer: other, choice: .keepGoing)), "another task's, at the same place")
        XCTAssertNotEqual(
            SidebarHoverTarget.budgetChoiceButtonKey(offer: offer, choice: .keepGoing),
            SidebarHoverTarget.budgetChoiceButtonKey(offer: other, choice: .keepGoing),
            "another task's row moved there: not armed"
        )
        var unbudgeted = info
        unbudgeted.usage = SidebarTaskUsage(UsageReport(sessions: [overBudgetSession], now: now), taskID: "ws")
        XCTAssertEqual(unbudgeted.cardActions, [], "no budget, no choice")
    }

    /// VoiceOver's press on a budget choice, once armed, hands the shell its
    /// task's id and the choice.
    @MainActor func testABudgetChoicePressReachesItsTask() throws {
        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 260, height: 800))
        let window = NSWindow(contentRect: sidebar.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = sidebar
        sidebar.isExpanded = true
        sidebar.update(profiles: [], workspaces: [overBudgetTask([column(.idle)], isActive: true)])
        var chosen: [String] = []
        sidebar.onBudgetChoice = { chosen.append("\($0) \($1.rawValue)") }
        let button = try XCTUnwrap(NiruxApp.pressTarget(label: BudgetChoice.keepGoing.accessibilityLabel, in: [window]))
        XCTAssertFalse(button.accessibilityPerformPress(), "not armed yet")
        let offer = SidebarBudgetOffer(workspaceID: "ws", budget: 25_000_000, choices: BudgetChoice.allCases)
        waitUntil("armed") { sidebar.isApprovalButtonArmed(SidebarHoverTarget.budgetChoiceButtonKey(offer: offer, choice: .keepGoing)) }
        XCTAssertTrue(button.accessibilityPerformPress())
        XCTAssertEqual(chosen, ["ws keepGoing"])
    }

    /// Continue on the card outlives a relaunch; a task that never chose it
    /// writes nothing.
    func testContinuePastTheBudgetIsSaved() throws {
        let passing = PersistedWorkspace(id: "a", title: "a", cwd: "/tmp", columns: [], focusedColumnIndex: 0, budgetPassedAt: 1_000)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(passing)) as? [String: Any])
        XCTAssertEqual(json["budgetPassedAt"] as? Double, 1_000)
        XCTAssertEqual(try JSONDecoder().decode(PersistedWorkspace.self, from: JSONEncoder().encode(passing)).budgetPassedAt, 1_000)
        let none = PersistedWorkspace(id: "b", title: "b", cwd: "/tmp", columns: [], focusedColumnIndex: 0)
        let empty = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(none)) as? [String: Any])
        XCTAssertNil(empty["budgetPassedAt"])
    }

    private var overBudgetSession: UsageSession {
        UsageSession(
            key: UsageSessionKey(.claude, "s"), attribution: UsageAttribution(spaceID: "space", taskID: "ws"), contextTokens: 90_000,
            events: [event(60, input: 26_000_000, context: 90_000)]
        )
    }

    @MainActor private func overBudgetTask(_ columns: [ColumnInfo], isActive: Bool = false) -> WorkspaceInfo {
        var info = WorkspaceInfo(
            id: "ws", index: 0, title: "check-video", profileID: WorkspaceProfile.defaultID, isInactive: false,
            columnCount: columns.count, focusedColumn: 0, gitBranch: nil, notification: nil, isActive: isActive,
            columns: columns, prInfo: nil, diffStats: nil, purpose: nil, nextStep: nil, blocker: nil,
            phase: .active, lastSummary: nil, lastActivityAt: nil
        )
        info.usage = SidebarTaskUsage(UsageReport(sessions: [overBudgetSession], now: now), taskID: "ws", budget: 25_000_000)
        return info
    }

    private func column(_ status: AgentStatus) -> ColumnInfo {
        ColumnInfo(
            index: 0, processName: "claude", abbreviatedCwd: "~/p", isFocused: false, isWebView: false,
            webTitle: nil, terminalTitle: nil, agentStatus: status, isEditor: false, editorFileName: nil
        )
    }

    func testTheUsageWindowRanksTasksAndCountsWhatTheyLeaveOut() {
        let sessions = [
            UsageSession(key: UsageSessionKey(.claude, "a"), attribution: UsageAttribution(spaceID: "space", taskID: "lead"),
                         events: [event(60, input: 600)]),
            UsageSession(key: UsageSessionKey(.claude, "b"), attribution: UsageAttribution(spaceID: "space", taskID: "closed"),
                         events: [event(60, input: 300)]),
            UsageSession(key: UsageSessionKey(.codex, "c"), attribution: UsageAttribution(spaceID: "space"), events: [event(60, input: 100)])
        ]
        let week = UsageReport(sessions: sessions, now: now).week
        let names = UsageNames(tasks: ["lead": .init(title: "Lead", isLead: true)], spaces: ["space": "Nirux"])
        XCTAssertEqual(UsageReportText.headline(week), "1k tokens · 3 responses · 3 sessions")
        XCTAssertEqual(UsageReportText.sections(week, names: names).map(\.title), ["By agent", "Causes (they overlap)", "Spaces"])
        let rows = Dictionary(uniqueKeysWithValues: UsageReportText.sections(week, names: names).map { ($0.title, $0.rows) })
        XCTAssertEqual(rows["By agent"], [["Claude", "900", "90%"], ["Codex", "100", "10%"]])
        XCTAssertEqual(rows["Causes (they overlap)"], [["Leads", "600", "60%"]], "causes at zero are left out")
        XCTAssertEqual(rows["Spaces"], [["Nirux", "1k", "100%"]])
        // The tasks go to the table, in points of the weekly limit when calibrated.
        let calibrated = UsageWeek(rise: [0, 0, 0, 0, 0, 0, 9], dayTasks: [[:], [:], [:], [:], [:], [:], ["lead": 600, "closed": 300]])
        let table = UsageReportText.tableRows(week, names: names, week: calibrated, dayTasks: [[:], [:], [:], [:], [:], [:], ["lead": 600, "closed": 300]])
        XCTAssertEqual(table.map(\.title), ["Lead", "Closed task", "Outside tasks"])
        XCTAssertEqual(table.first?.points ?? 0, 6, accuracy: 0.001)
        XCTAssertEqual(table.first?.tokens, 600)
    }

    /// A cause says what its remedy saves, as a share of the period.
    func testTheUsageWindowSaysWhatEachRemedySaves() {
        let heavy = UsageEvent(timestamp: now - 60, model: "claude-opus-5-5", counts: TokenCounts(input: 1_000), contextTokens: 560_000)
        let week = UsageReport(sessions: [UsageSession(key: UsageSessionKey(.claude, "a"), events: [heavy, event(120, input: 1_000)])], now: now).week
        let causes = UsageReportText.sections(week, names: UsageNames()).first { $0.title == "Causes (they overlap)" }?.rows
        XCTAssertEqual(causes?.first, ["Context past 280k", "1k", "50%", "Compacting there saves ≈ 25%"])
    }

    /// Each day's rise of Claude's weekly limit splits between tasks by
    /// their share of that day's spend; the busiest by name, the rest as one.
    func testTheWeekSplitsEachDaysRiseByTask() throws {
        let week = try XCTUnwrap(UsageWeek(rise: [0, 10, 6], dayTasks: [[:], ["a": 600, "b": 400], ["a": 100, "": 200]]))
        XCTAssertEqual(week.tasks, ["a", "b", ""])
        XCTAssertEqual(week.days, [[0, 0, 0], [6, 4, 0], [2, 0, 4]])
        XCTAssertEqual(week.pointsPerToken ?? 0, 16.0 / 1_300, accuracy: 1e-9)
        let elsewhere = try XCTUnwrap(UsageWeek(rise: [10, 5], dayTasks: [[:], ["a": 1_000]]))
        XCTAssertEqual(elsewhere.pointsPerToken ?? 0, 5.0 / 1_000, accuracy: 1e-9, "a rise with no spend in Nirux divides nothing")
        XCTAssertNil(UsageWeek(rise: [0, 0, 0], dayTasks: [[:], [:], [:]]), "no readings, no points")
    }

    /// The window shows the limits on top and, with the weekly readings,
    /// the week in points of the limit rather than tokens.
    @MainActor
    func testTheUsageWindowShowsTheLimitsAndTheWeekInPoints() throws {
        let starts = UsageReport(sessions: [], now: now).days.map(\.start)
        let session = UsageSession(
            key: UsageSessionKey(.claude, "a"), attribution: UsageAttribution(spaceID: "space", taskID: "lead"),
            events: [UsageEvent(timestamp: starts[6] + 60, model: "claude-opus-5-5", counts: TokenCounts(input: 1_000))]
        )
        let report = UsageReport(sessions: [session], now: now)
        let resetsAt = now + 3 * 86_400
        let readings = [QuotaReading(time: starts[6] + 30, usedPercent: 40, resetsAt: resetsAt), QuotaReading(time: starts[6] + 90, usedPercent: 52, resetsAt: resetsAt)]
        let limit = try XCTUnwrap(QuotaLimit(agent: .claude, length: 7 * 86_400, readings: readings, now: now))
        let controller = UsageWindowController()
        defer { controller.close() }
        controller.update(report: report, names: UsageNames(tasks: ["lead": .init(title: "Lead", isLead: true)]), limits: [limit], weekReadings: readings)
        XCTAssertEqual(controller.limitsStack.arrangedSubviews.count, 1)
        XCTAssertFalse(controller.weekChart.isHidden)
        XCTAssertEqual(controller.weekChart.week?.days.last?.reduce(0, +), 12)
        XCTAssertEqual(controller.tasksTable.text(row: 0, column: "task"), "Lead")
        XCTAssertEqual(controller.tasksTable.text(row: 0, column: "points"), "≈ 12%")

        controller.update(report: report, names: UsageNames(), limits: [], weekReadings: [])
        XCTAssertTrue(controller.weekChart.isHidden, "without readings, the week by agent in tokens")
        XCTAssertTrue(controller.limitsStack.isHidden)
    }
}
