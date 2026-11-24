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
        func column(_ status: AgentStatus) -> ColumnInfo {
            ColumnInfo(
                index: 0, processName: "claude", abbreviatedCwd: "~/p", isFocused: false, isWebView: false,
                webTitle: nil, terminalTitle: nil, agentStatus: status, isEditor: false, editorFileName: nil
            )
        }
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
        XCTAssertEqual(usage.text, "300k · 4.3M")
        XCTAssertTrue(usage.isContextHeavy)
        let lines = usage.toolTip(now: now).components(separatedBy: "\n")
        XCTAssertTrue(lines.contains("Idle for 2h: its cache expired, the next message writes it again"))
        XCTAssertTrue(lines.contains("Subagents: 2%"))
        XCTAssertTrue(lines.contains("Past 280k of context: 98%"))
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
        XCTAssertEqual(UsageReportText.sections(week, names: names).map(\.title), ["By agent", "Causes (they overlap)", "Tasks", "Spaces"])
        let rows = Dictionary(uniqueKeysWithValues: UsageReportText.sections(week, names: names).map { ($0.title, $0.rows) })
        XCTAssertEqual(rows["By agent"], [["Claude", "900", "90%"], ["Codex", "100", "10%"]])
        XCTAssertEqual(rows["Causes (they overlap)"]?.last, ["Leads", "600", "60%"])
        XCTAssertEqual(rows["Tasks"], [
            ["Lead", "600", "60%", "peak 600", ""], ["Closed task", "300", "30%", "peak 300", ""], ["Outside tasks", "100", "10%"]
        ])
        XCTAssertEqual(rows["Spaces"], [["Nirux", "1k", "100%"]])
    }
}
