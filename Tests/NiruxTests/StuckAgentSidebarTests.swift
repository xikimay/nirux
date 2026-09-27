import AppKit
import XCTest
@testable import Nirux

/// How a stuck agent reads on its workspace card: the badge on its row, the
/// Resume block under a failed turn, and the click that resumes it.
@MainActor
final class StuckAgentSidebarTests: XCTestCase {
    private func column(
        _ stuck: SidebarStuckState?, status: AgentStatus = .idle, process: String = "claude"
    ) -> ColumnInfo {
        ColumnInfo(
            index: 1, processName: process, abbreviatedCwd: "~/p", isFocused: false, isWebView: false,
            webTitle: nil, terminalTitle: nil, agentStatus: status, isEditor: false, editorFileName: nil,
            attentionReason: status == .needsAttention ? .permission(tool: "Bash", summary: "x") : nil,
            stuck: stuck
        )
    }

    private func workspace(_ columns: [ColumnInfo]) -> WorkspaceInfo {
        WorkspaceInfo(
            id: "ws", index: 2, title: "fix-login", profileID: WorkspaceProfile.defaultID, isInactive: false,
            columnCount: columns.count, focusedColumn: 0, gitBranch: nil, hasNotification: false, isActive: false,
            columns: columns, prInfo: nil, diffStats: nil, purpose: nil, nextStep: nil, blocker: nil,
            phase: .active, lastSummary: nil, lastActivityAt: nil
        )
    }

    private func failed(_ resume: SidebarStuckState.Resume) -> SidebarStuckState {
        .stoppedOnError(kind: "rate_limit", detail: "API Error: 429", failedAt: 1_005, resume: resume)
    }

    private func labels(_ views: [NSView]) -> [String] {
        views.compactMap { ($0 as? NSTextField)?.stringValue }
    }

    private struct ResumeRegion: Equatable {
        let workspace: Int
        let column: Int
        let failedAt: TimeInterval
    }

    private func resumeRegions(_ hitAreas: [SidebarHitArea]) -> [ResumeRegion] {
        hitAreas.compactMap {
            if case let .agentResume(workspace, column, failedAt) = $0.region {
                return ResumeRegion(workspace: workspace, column: column, failedAt: failedAt)
            }
            return nil
        }
    }

    /// The row's text, without the process icon.
    private func rowText(_ column: ColumnInfo) -> String {
        PilotSidebarRenderer.attributedColumn(column, fontSize: 11).string.replacingOccurrences(of: "\u{FFFC} ", with: "")
    }

    func testRowSaysWhyTheAgentIsStuckWhateverItsStatus() {
        let waiting = column(.waiting(.permission(tool: "Bash", summary: "git push"), duration: "2h05m"))
        XCTAssertEqual(
            rowText(waiting), "  claude · waiting 2h05m",
            "focused or seen, the wait still shows"
        )
        XCTAssertEqual(PilotSidebarRenderer.attentionTooltip(for: waiting), "needs permission — waiting 2h05m — Bash: git push")

        let stopped = column(failed(.offered), status: .needsAttention)
        XCTAssertEqual(
            rowText(stopped), "  claude · API error",
            "the failure outranks the attention label"
        )
        XCTAssertEqual(
            PilotSidebarRenderer.attentionTooltip(for: stopped), "Stopped on an API error — rate_limit: API Error: 429"
        )
        XCTAssertEqual(
            rowText(column(.exitedMidTurn(processName: "claude"), process: "zsh")), "  claude · exited mid-turn",
            "the agent that died, not the shell back in front"
        )
    }

    func testCardGrowsByTheResumeBlockOnly() {
        let plain = SidebarExpandedMetrics.workspaceHeight(for: workspace([column(nil)]))
        let stopped = SidebarExpandedMetrics.workspaceHeight(for: workspace([column(failed(.offered))]))
        XCTAssertEqual(
            stopped - plain, SidebarExpandedMetrics.resumeBlockHeight + SidebarExpandedMetrics.approvalBottomGap
        )
        let waiting = column(.waiting(.question(nil), duration: "12m"))
        XCTAssertEqual(SidebarExpandedMetrics.workspaceHeight(for: workspace([waiting])), plain)
    }

    func testFailedTurnOffersResume() throws {
        let info = workspace([column(failed(.offered))])
        let result = SidebarWorkspaceCardRenderer(workspace: info, sidebarWidth: 260, padding: 20, yOffset: 800).render()

        XCTAssertEqual(resumeRegions(result.hitAreas), [ResumeRegion(workspace: 2, column: 1, failedAt: 1_005)])
        XCTAssertTrue(labels(result.views).contains("rate_limit — API Error: 429"))
        XCTAssertEqual(
            Array(result.approvalButtons.keys), [SidebarHoverTarget.resumeButtonKey(workspaceIndex: 2, columnIndex: 1)],
            "armed and hovered like Allow / Deny"
        )
        let resumeHit = try XCTUnwrap(result.hitAreas.firstIndex {
            if case .agentResume = $0.region { return true }
            return false
        })
        let blockHit = try XCTUnwrap(result.hitAreas.firstIndex {
            if case .actionBlock(2) = $0.region { return true }
            return false
        })
        let workspaceHit = try XCTUnwrap(result.hitAreas.firstIndex {
            if case .workspace = $0.region { return true }
            return false
        })
        XCTAssertLessThan(resumeHit, blockHit)
        XCTAssertLessThan(blockHit, workspaceHit, "the block swallows clicks meant for what was there")
        XCTAssertEqual(
            800 - result.bottomY, SidebarExpandedMetrics.workspaceHeight(for: info), accuracy: 0.5,
            "layout matches the metrics the scroll view is sized with"
        )
    }

    func testNoResumeButtonUnlessOffered() {
        for (resume, text) in [
            (SidebarStuckState.Resume.sending, "Resuming…"),
            (.unavailable, "Resume once claude is back at its prompt")
        ] {
            let result = SidebarWorkspaceCardRenderer(
                workspace: workspace([column(failed(resume))]), sidebarWidth: 260, padding: 20, yOffset: 800
            ).render()
            XCTAssertTrue(resumeRegions(result.hitAreas).isEmpty, text)
            XCTAssertTrue(result.approvalButtons.isEmpty, text)
            XCTAssertTrue(labels(result.views).contains(text))
        }
    }

    func testOnlyASingleClickReleasedOnTheSameResumeResumes() {
        let resume = SidebarHitRegion.agentResume(workspaceIndex: 2, columnIndex: 1, failedAt: 1_005)
        let laterFailure = SidebarHitRegion.agentResume(workspaceIndex: 2, columnIndex: 1, failedAt: 2_000)
        func resumes(
            _ released: SidebarHitRegion?, clicks: Int = 1, armedAtPress: Bool = true, armedAtRelease: Bool = true
        ) -> Bool {
            SidebarView.resumeClick(
                pressed: resume, released: released, clickCount: clicks,
                armedAtPress: armedAtPress, armedAtRelease: armedAtRelease
            ) != nil
        }
        XCTAssertTrue(resumes(resume))
        XCTAssertFalse(resumes(laterFailure), "a failure the button didn't show")
        XCTAssertFalse(resumes(.actionBlock(workspaceIndex: 2)))
        XCTAssertFalse(resumes(nil))
        XCTAssertFalse(resumes(resume, clicks: 2))
        XCTAssertFalse(resumes(resume, armedAtPress: false))
        XCTAssertFalse(resumes(resume, armedAtRelease: false))
        XCTAssertNil(SidebarView.approvalClickDecision(
            pressed: resume, released: resume, clickCount: 1, armedAtPress: true, armedAtRelease: true
        ), "Resume is no permission decision")
        XCTAssertEqual(
            SidebarView.armedButtonKey(for: resume), SidebarHoverTarget.resumeButtonKey(workspaceIndex: 2, columnIndex: 1)
        )
    }

    func testAgentExitOverlayOffersResumeAndDismiss() {
        let overlay = ShellExitedOverlay(content: .agentExited(processName: "claude"))
        overlay.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        overlay.layout()
        let texts = overlay.subviews.compactMap { ($0 as? NSTextField)?.stringValue }
        XCTAssertTrue(texts.contains("claude exited mid-turn"))
        let buttons = overlay.subviews.compactMap { $0 as? NSButton }.filter { !$0.isHidden }
        XCTAssertEqual(buttons.sorted { $0.frame.minX < $1.frame.minX }.map(\.title), ["Dismiss", "Resume Session"])

        var resumed = 0
        var dismissed = 0
        overlay.onRestart = { resumed += 1 }
        overlay.onDismiss = { dismissed += 1 }
        buttons.first { $0.title == "Resume Session" }?.performClick(nil)
        buttons.first { $0.title == "Dismiss" }?.performClick(nil)
        XCTAssertEqual([resumed, dismissed], [1, 1])

        overlay.configure(.shellExited)
        XCTAssertEqual(overlay.subviews.compactMap { $0 as? NSButton }.filter { !$0.isHidden }.map(\.title), ["Restart Shell"])
    }

    func testSettingsChoiceTitles() {
        XCTAssertEqual(NiruxApp.stuckAgentChoiceTitle(minutes: 0), "Never")
        XCTAssertEqual(NiruxApp.stuckAgentChoiceTitle(minutes: 10), "10 minutes")
        XCTAssertEqual(NiruxApp.stuckAgentChoiceTitle(minutes: 60), "1 hour")
        XCTAssertEqual(NiruxApp.stuckAgentChoiceTitle(minutes: 120), "2 hours")
        XCTAssertEqual(NiruxShellView.stuckWaitThreshold(minutes: 10), 600)
        XCTAssertNil(NiruxShellView.stuckWaitThreshold(minutes: 0), "off")
    }

    // MARK: - The column follows its agent

    private func entry(_ process: ForegroundProcess) -> ProcessSnapshot.Entry {
        ProcessSnapshot.Entry(
            pid: process.instance.pid, parentPID: 1, processGroupID: process.instance.pid,
            terminalForegroundProcessGroupID: 0, name: process.name,
            startedAt: process.instance.startedAt, arguments: process.arguments
        )
    }

    func testColumnTellsAnExitFromASuspend() throws {
        let column = ColumnState(cwd: "/tmp")
        let pty = try XCTUnwrap(column.pty)
        let claude = ForegroundProcess(
            instance: ProcessInstance(pid: 500, startedAt: 10), name: "claude",
            arguments: ["claude", "--permission-mode", "plan"]
        )
        let shell = ForegroundProcess(instance: ProcessInstance(pid: 400, startedAt: 5), name: "zsh", arguments: ["zsh"])
        let bothAlive = ProcessSnapshot(entries: [entry(shell), entry(claude)])
        let claudeGone = ProcessSnapshot(entries: [entry(shell)])

        // Its hooks confirm a prompted session: a turn is in flight.
        for name in [AgentHookEvent.Name.sessionStart, .userPromptSubmit] {
            let event = AgentHookEvent(
                kind: .claude, name: name, agentUUID: column.agentUUID, sessionID: "conv",
                emitterProcess: claude.instance, source: name == .sessionStart ? "startup" : nil, timestamp: 90
            )
            _ = column.admitClaudeHook(event, foregroundProcess: claude, snapshot: bothAlive)
            pty.applyAgentHook(event, isUserFocused: false)
        }
        column.trackForegroundAgent(claude, snapshot: bothAlive, now: 100)

        // Ctrl-Z: the shell is in front, the agent still runs.
        column.trackForegroundAgent(shell, snapshot: bothAlive, now: 102)
        XCTAssertNil(pty.agentMidTurnExit, "suspended, not gone")

        // Back in front, then gone from the process table.
        column.trackForegroundAgent(claude, snapshot: bothAlive, now: 104)
        column.trackForegroundAgent(shell, snapshot: claudeGone, now: 106)
        let exit = try XCTUnwrap(pty.agentMidTurnExit)
        XCTAssertEqual(exit.exitedAt, 106)
        XCTAssertEqual(exit.sessionID, "conv", "its conversation, to resume")
        XCTAssertEqual(ClaudeLaunchMode.detect(arguments: exit.arguments), .plan, "and the flags it ran with")
        XCTAssertNil(pty.agentStuckState(now: 107, waitThreshold: nil, foregroundName: "zsh"), "SessionEnd may still come")
        XCTAssertEqual(pty.agentStuckState(now: 110, waitThreshold: nil, foregroundName: "zsh"), .exitedMidTurn(exit))

        // An agent in front again ends it.
        column.trackForegroundAgent(claude, snapshot: bothAlive, now: 112)
        XCTAssertNil(pty.agentMidTurnExit)
    }

    // MARK: - Resume in a live terminal

    private func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline { return false }
            try await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    /// `continue` reaches the `claude` whose turn failed only once it is
    /// back at its prompt, and once per click.
    func testResumeTypesContinueOnlyAtTheFailedClaudesPrompt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nirux-resume-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let pty = PtySession()
        // Echoes what it is sent, under the name `claude`.
        pty.start(shell: "/bin/zsh", args: ["-f", "-c", "exec -a claude /bin/cat"], cwd: directory.path)
        let started = try await waitUntil { pty.foregroundProcess(snapshot: ProcessSnapshot())?.name == "claude" }
        XCTAssertTrue(started)
        let claude = try XCTUnwrap(pty.foregroundProcess(snapshot: ProcessSnapshot()))
        let now = Date().timeIntervalSince1970
        func hook(_ name: AgentHookEvent.Name, agent: String? = nil, tool: String? = nil) -> AgentHookEvent {
            AgentHookEvent(
                kind: .claude, name: name, sessionID: "lead", emitterProcess: claude.instance,
                toolName: tool, toolKey: tool.map { _ in "k" }, agentID: agent,
                errorKind: name == .stopFailure ? "overloaded" : nil, timestamp: now
            )
        }

        XCTAssertEqual(pty.resumeFailedTurn(snapshot: ProcessSnapshot(), now: now), .notStopped)
        for event in [
            hook(.sessionStart), hook(.userPromptSubmit),
            // A subagent's dialog is still up when the main thread fails.
            hook(.permissionRequest, agent: "sub", tool: "Bash"), hook(.stopFailure)
        ] {
            pty.applyAgentHook(event, isUserFocused: false)
        }
        XCTAssertEqual(pty.resumeFailedTurn(snapshot: ProcessSnapshot(), now: now), .notAtPrompt)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(pty.recentOutput().contains("continue"), "nothing typed into a dialog")

        pty.applyAgentHook(hook(.subagentStop, agent: "sub"), isUserFocused: false)
        XCTAssertNil(pty.resumeFailedTurn(snapshot: ProcessSnapshot(), now: now + 1))
        let typed = try await waitUntil { pty.recentOutput().contains("continue") }
        XCTAssertTrue(typed)
        XCTAssertEqual(pty.resumeFailedTurn(snapshot: ProcessSnapshot(), now: now + 2), .alreadySent, "one click, one continue")
    }
}
