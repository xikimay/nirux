import XCTest
@testable import Nirux

/// Agents that won't go on by themselves: a dialog left open too long, a
/// turn that failed on an API error (StopFailure), a process that died
/// mid-turn. Fed with fake hook events and injected time.
final class StuckAgentTests: XCTestCase {
    private var machine = AgentStatusMachine()
    private let t0: TimeInterval = 1_000
    private let threshold: TimeInterval = 600
    private let claudeProcess = ProcessInstance(pid: 4242, startedAt: 900)

    private func event(
        _ name: AgentHookEvent.Name,
        at offset: TimeInterval = 0,
        tool: String? = nil,
        summary: String? = nil,
        key: String? = nil,
        agent: String? = nil,
        errorKind: String? = nil,
        type: String? = nil,
        message: String? = nil,
        emitter: ProcessInstance? = nil
    ) -> AgentHookEvent {
        AgentHookEvent(
            kind: .claude, name: name, sessionID: "lead", emitterProcess: emitter,
            detail: message ?? tool, toolName: tool, toolSummary: summary, toolKey: key,
            agentID: agent, notificationType: type, errorKind: errorKind, timestamp: t0 + offset
        )
    }

    private func apply(_ event: AgentHookEvent, focused: Bool = false) -> AgentHookOutcome {
        machine.apply(event, isUserFocused: focused)
    }

    private func startTurn() {
        _ = machine.tick(fgName: "claude", isUserFocused: false, now: Date(timeIntervalSince1970: t0))
        _ = apply(event(.sessionStart))
        _ = apply(event(.userPromptSubmit))
        _ = apply(event(.preToolUse, tool: "Bash"))
    }

    /// The column's foreground process by name: the claude that fired the
    /// events, or a shell.
    private func front(_ name: String?) -> ForegroundProcess? {
        name.map { ForegroundProcess(instance: claudeProcess, name: $0, arguments: [$0]) }
    }

    private func alert(at offset: TimeInterval, foreground: String? = "claude") -> AgentAttentionReason? {
        machine.takeStuckAlert(now: t0 + offset, waitThreshold: threshold, foreground: front(foreground))
    }

    private func stuck(at offset: TimeInterval, foreground: String? = "claude") -> AgentStuckState? {
        machine.stuckState(now: t0 + offset, waitThreshold: threshold, foreground: front(foreground))
    }

    private func claude(_ instance: ProcessInstance? = nil) -> ForegroundProcess {
        ForegroundProcess(instance: instance ?? claudeProcess, name: "claude", arguments: ["claude"])
    }

    private func refusal(
        at offset: TimeInterval = 10,
        foreground: ForegroundProcess? = nil
    ) -> AgentResumeRefusal? {
        let foreground = foreground ?? claude()
        return machine.resumeRefusal(foreground: foreground, ownsEmitter: { $0 == foreground.instance }, now: t0 + offset)
    }

    // MARK: - Waiting past the threshold

    func testLongWaitAlertsOnceWhenTheThresholdIsCrossed() {
        startTurn()
        _ = apply(event(.permissionRequest, at: 1, tool: "Bash", summary: "git push", key: "k"))

        XCTAssertNil(stuck(at: threshold), "not yet: the dialog opened at t0+1")
        XCTAssertNil(alert(at: threshold))

        let crossed = alert(at: threshold + 1)
        XCTAssertEqual(crossed, .stillWaiting(.permission(tool: "Bash", summary: "git push"), waited: threshold))
        XCTAssertEqual(stuck(at: threshold + 1), .waiting(.permission(tool: "Bash", summary: "git push"), since: t0 + 1))
        XCTAssertNil(alert(at: threshold + 3), "one alert per dialog")
        // Another dialog first in line for a moment doesn't make the first
        // one alert again.
        _ = apply(event(.permissionRequest, at: 2, tool: "Read", key: "k2", agent: "sub"))
        XCTAssertNil(alert(at: threshold + 4))
        XCTAssertNil(alert(at: 7_200), "still the same wait two hours on")
        XCTAssertEqual(stuck(at: 7_200), .waiting(.permission(tool: "Bash", summary: "git push"), since: t0 + 1))
    }

    func testLongWaitOutlastsFocusAndAppActivation() {
        startTurn()
        _ = apply(event(.permissionRequest, at: 1, tool: "Bash", key: "k"))
        machine.clearAttention()
        _ = machine.tick(fgName: "claude", isUserFocused: true, now: Date(timeIntervalSince1970: t0 + 700))
        XCTAssertEqual(machine.state, .idle)
        XCTAssertNotNil(stuck(at: 700), "seen or not, the dialog still waits")
    }

    func testLongWaitResetsWhenTheAgentMovesOn() {
        startTurn()
        _ = apply(event(.permissionRequest, at: 1, tool: "Bash", key: "k1"))
        XCTAssertNotNil(alert(at: threshold + 1))

        // Approved: the call ran, the agent works again.
        _ = apply(event(.postToolUse, at: threshold + 5, tool: "Bash", key: "k1"))
        XCTAssertNil(stuck(at: threshold + 6))
        XCTAssertNil(alert(at: threshold + 6))

        // The next dialog starts over: quiet until it has waited as long.
        let reopened = threshold + 10
        _ = apply(event(.permissionRequest, at: reopened, tool: "Bash", key: "k2"))
        XCTAssertNil(alert(at: reopened + threshold - 1))
        XCTAssertNotNil(alert(at: reopened + threshold))
        XCTAssertNil(alert(at: reopened + threshold + 1))
    }

    func testLongWaitOffWithoutThresholdOrClaudeInFront() {
        startTurn()
        _ = apply(event(.permissionRequest, at: 1, tool: "Bash", key: "k"))
        XCTAssertNil(machine.stuckState(now: t0 + 9_999, waitThreshold: nil, foreground: front("claude")))
        XCTAssertNil(machine.takeStuckAlert(now: t0 + 9_999, waitThreshold: nil, foreground: front("claude")))
        // Suspended behind a shell: its dialog says nothing about the shell.
        XCTAssertNil(stuck(at: 9_999, foreground: "zsh"))
        XCTAssertNil(alert(at: 9_999, foreground: "zsh"))
    }

    /// A keystroke went to the dialog: approved (the tool then runs,
    /// silent, until PostToolUse) or denied with Esc (no hook at all).
    func testDialogTypedIntoIsNotAWait() {
        startTurn()
        _ = apply(event(.permissionRequest, at: 1, tool: "Bash", key: "k"))
        machine.noteKeystroke(now: Date(timeIntervalSince1970: t0 + 30))
        XCTAssertNil(stuck(at: 3_600))
        XCTAssertNil(alert(at: 3_600))

        // Claude's reminder says the dialog still waits unanswered.
        _ = apply(event(.notification, at: 3_700, type: "permission_prompt"))
        XCTAssertNotNil(stuck(at: 3_701))
    }

    /// Events queued while Nirux was closed replay at launch: a dialog of
    /// an earlier claude is not the one now in front.
    func testDialogOlderThanTheClaudeInFrontIsNotAWait() {
        startTurn()
        _ = apply(event(.permissionRequest, at: 1, tool: "Bash", key: "k"))
        let newer = ForegroundProcess(
            instance: ProcessInstance(pid: 77, startedAt: t0 + 100), name: "claude", arguments: ["claude"]
        )
        XCTAssertNil(machine.stuckState(now: t0 + 3_600, waitThreshold: threshold, foreground: newer))
        _ = apply(event(.stopFailure, at: 2, errorKind: "overloaded"))
        XCTAssertNil(machine.stuckState(now: t0 + 3_600, waitThreshold: threshold, foreground: newer))
    }

    func testTurnFinishedIsNotAWait() {
        startTurn()
        _ = apply(event(.stop, at: 1))
        XCTAssertNil(stuck(at: 9_999), "an agent done with its turn is not stuck")
    }

    // MARK: - StopFailure

    func testStopFailureLeavesTheAgentStoppedOnError() {
        startTurn()
        let outcome = apply(event(
            .stopFailure, at: 5, errorKind: "rate_limit", message: "API Error: 429", emitter: claudeProcess
        ))
        XCTAssertEqual(outcome.attention, .apiError(kind: "rate_limit", detail: "API Error: 429"))
        XCTAssertTrue(outcome.firedAttention)
        XCTAssertEqual(machine.state, .needsAttention)
        XCTAssertEqual(machine.attentionReason, .apiError(kind: "rate_limit", detail: "API Error: 429"))
        XCTAssertNil(machine.turnStartedAt, "the turn is over")
        XCTAssertEqual(machine.tick(fgName: "claude", isUserFocused: false, now: Date(timeIntervalSince1970: t0 + 6)),
                       .needsAttention)

        guard case .stoppedOnError(let failure)? = stuck(at: 6) else {
            return XCTFail("expected stoppedOnError, got \(String(describing: stuck(at: 6)))")
        }
        XCTAssertEqual(failure.kind, "rate_limit")
        XCTAssertEqual(failure.failedAt, t0 + 5)
        XCTAssertEqual(failure.emitter, claudeProcess)
        XCTAssertNil(alert(at: 6), "StopFailure alerted as it arrived")
    }

    func testStoppedOnErrorOutlastsSeeingItAndTheIdleReminder() {
        startTurn()
        _ = apply(event(.stopFailure, at: 5, errorKind: "overloaded"))
        machine.clearAttention()
        _ = apply(event(.notification, at: 65, message: "Claude is waiting for your input"))
        XCTAssertNotNil(machine.turnFailure)
        if case .stoppedOnError? = stuck(at: 70) {} else { XCTFail("the failure must stay visible") }
    }

    func testStoppedOnErrorClearsOnceTheAgentMoves() {
        for moved in [
            event(.userPromptSubmit, at: 10),
            event(.preToolUse, at: 10, tool: "Read"),
            event(.stop, at: 10),
            event(.sessionEnd, at: 10),
            AgentHookEvent(kind: .claude, name: .sessionStart, sessionID: "other", source: "clear", timestamp: t0 + 10)
        ] {
            machine = AgentStatusMachine()
            startTurn()
            _ = apply(event(.stopFailure, at: 5, errorKind: "overloaded"))
            _ = apply(moved)
            XCTAssertNil(machine.turnFailure, "\(moved.name)")
            XCTAssertNil(stuck(at: 11), "\(moved.name)")
        }
    }

    func testSubagentToolEventsDoNotHideTheMainThreadFailure() {
        startTurn()
        _ = apply(event(.stopFailure, at: 5, errorKind: "server_error"))
        _ = apply(event(.preToolUse, at: 6, tool: "Read", agent: "background"))
        XCTAssertNotNil(machine.turnFailure)
        XCTAssertEqual(refusal(), .notAtPrompt, "a subagent still works")
    }

    func testSubagentStopFailureEndsNothingOfTheMainThread() {
        startTurn()
        _ = apply(event(.stopFailure, at: 5, agent: "sub", errorKind: "overloaded"))
        XCTAssertNil(machine.turnFailure)
        XCTAssertEqual(machine.state, .working)
    }

    func testStopFailureStandaloneOutcomeAndActivityRow() throws {
        let failure = event(.stopFailure, errorKind: "rate_limit", message: "429 Too Many Requests")
        XCTAssertEqual(
            AgentStatusMachine.standaloneOutcome(for: failure).attention,
            .apiError(kind: "rate_limit", detail: "429 Too Many Requests")
        )
        let entry = try XCTUnwrap(ActivityEntry(event: failure, workspaceTitle: "ws", columnIndex: 0))
        XCTAssertEqual(entry.category, .attention, "older builds must still decode the history")
        XCTAssertEqual(entry.detail, "stopped on error: rate_limit · 429 Too Many Requests")
    }

    // MARK: - Resume

    func testResumeOfferedOnlyAtThePromptOfTheClaudeThatFailed() {
        XCTAssertEqual(refusal(), .notStopped, "nothing failed")
        startTurn()
        _ = apply(event(.stopFailure, at: 5, errorKind: "overloaded", emitter: claudeProcess))

        XCTAssertNil(refusal())
        XCTAssertEqual(refusal(foreground: ForegroundProcess(instance: claudeProcess, name: "zsh", arguments: [])),
                       .notClaude)
        XCTAssertEqual(refusal(foreground: claude(ProcessInstance(pid: 7, startedAt: 1))), .notClaude,
                       "another claude than the one that failed")

        machine.markResumeSent(now: t0 + 10)
        XCTAssertEqual(refusal(at: 11), .alreadySent)
        XCTAssertNil(refusal(at: 10 + AgentStatusMachine.resumeRetryDelay), "no new turn: offered again")
    }

    func testResumeRefusedWhileADialogMayBeOpen() {
        startTurn()
        // A subagent's dialog outlives the main thread's failure.
        _ = apply(event(.permissionRequest, at: 2, tool: "Bash", key: "k", agent: "sub"))
        _ = apply(event(.stopFailure, at: 5, errorKind: "overloaded"))
        XCTAssertNotNil(machine.turnFailure)
        XCTAssertEqual(refusal(), .notAtPrompt)
    }

    func testResumeRefusedOnceAPromptWentIn() {
        startTurn()
        _ = apply(event(.stopFailure, at: 5, errorKind: "overloaded"))
        _ = apply(event(.userPromptSubmit, at: 8))
        XCTAssertEqual(refusal(), .notStopped)
    }

    func testResumeTakesAnyClaudeWhenTheFailureNamedNoEmitter() {
        startTurn()
        _ = apply(event(.stopFailure, at: 5, errorKind: "overloaded"))
        XCTAssertNil(refusal(foreground: claude(ProcessInstance(pid: 9, startedAt: 2))),
                     "no emitter recorded: any claude in front")
        XCTAssertEqual(refusal(foreground: claude(ProcessInstance(pid: 9, startedAt: t0 + 6))), .notClaude,
                       "but not one started after the failure")
    }

    /// Only an error `continue` can get past; a rate limit or a login may
    /// come with Claude's own menu, which fires no hook and Enter answers.
    func testResumeOnlyForErrorsItCanGetPast() {
        for (kind, refused) in [
            ("overloaded", false), ("server_error", false), ("unknown", false), ("max_output_tokens", false),
            (nil, false), ("rate_limit", true), ("authentication_failed", true), ("billing_error", true),
            ("invalid_request", true), ("model_not_found", true)
        ] as [(String?, Bool)] {
            machine = AgentStatusMachine()
            startTurn()
            _ = apply(event(.stopFailure, at: 5, errorKind: kind))
            XCTAssertEqual(refusal(), refused ? .needsFix : nil, kind ?? "nil")
        }
    }

    /// Text typed since the failure is the user's draft: `continue` would
    /// join it, and Enter would send it.
    func testResumeRefusedOverTheUsersDraft() {
        startTurn()
        _ = apply(event(.stopFailure, at: 5, errorKind: "overloaded"))
        machine.noteKeystroke(now: Date(timeIntervalSince1970: t0 + 7))
        XCTAssertEqual(refusal(), .userTyped)
    }

    func testResumesOwnKeystrokeIsNotADraft() {
        startTurn()
        _ = apply(event(.stopFailure, at: 5, errorKind: "overloaded"))
        machine.markResumeSent(now: t0 + 10)
        machine.noteKeystroke(now: Date(timeIntervalSince1970: t0 + 10.01))
        machine.noteResumeTyped()
        XCTAssertNil(refusal(at: 10 + AgentStatusMachine.resumeRetryDelay), "no turn started: offered again")
        machine.markResumeSent(now: t0 + 100)
        XCTAssertNil(refusal(at: 50), "a clock set back reads as the delay over")
    }

    func testResumeRefusedForHeadlessClaude() {
        startTurn()
        _ = apply(event(.stopFailure, at: 5, errorKind: "overloaded"))
        let headless = ForegroundProcess(instance: claudeProcess, name: "claude", arguments: ["claude", "-p", "fix it"])
        XCTAssertEqual(refusal(foreground: headless), .notClaude)
    }

    /// Claude doesn't wait for StopFailure: one that lands after the next
    /// prompt is about the turn before, and ends nothing.
    func testLateStopFailureOfAnEarlierPromptEndsNothing() {
        startTurn()
        _ = apply(AgentHookEvent(kind: .claude, name: .userPromptSubmit, sessionID: "lead", promptID: "p2", timestamp: t0 + 6))
        _ = apply(AgentHookEvent(
            kind: .claude, name: .stopFailure, sessionID: "lead", errorKind: "overloaded", promptID: "p1", timestamp: t0 + 7
        ))
        XCTAssertNil(machine.turnFailure)
        XCTAssertEqual(machine.state, .working)

        _ = apply(AgentHookEvent(
            kind: .claude, name: .stopFailure, sessionID: "lead", errorKind: "overloaded", promptID: "p2", timestamp: t0 + 9
        ))
        XCTAssertNotNil(machine.turnFailure, "its own prompt's failure counts")
    }

    func testQuotaAutoResumeClearsTheFailure() {
        startTurn()
        _ = apply(event(.stopFailure, at: 5, errorKind: "rate_limit"))
        _ = apply(event(.notification, at: 3_600, type: "quota_auto_resume_fired"))
        XCTAssertNil(machine.turnFailure, "Claude went on by itself")
    }

    // MARK: - Died mid-turn

    private func exit(at offset: TimeInterval, seenAt: TimeInterval? = nil, firedHooks: Bool = true) -> AgentMidTurnExit {
        AgentMidTurnExit(
            processName: "claude", exitedAt: t0 + offset, lastSeenAt: t0 + (seenAt ?? offset - 2),
            sessionID: "lead", arguments: ["claude"], firedHooks: firedHooks
        )
    }

    func testExitMidTurnIsConfirmedAfterItsSessionEndHadTime() {
        startTurn()
        machine.noteAgentExited(exit(at: 20))
        XCTAssertNil(stuck(at: 21, foreground: "zsh"), "SessionEnd may still be in the queue")
        XCTAssertNil(alert(at: 21, foreground: "zsh"))

        let confirmed = 20 + AgentStatusMachine.exitConfirmationDelay
        XCTAssertEqual(stuck(at: confirmed, foreground: "zsh"), .exitedMidTurn(exit(at: 20)))
        XCTAssertEqual(alert(at: confirmed, foreground: "zsh"), .exitedMidTurn)
        XCTAssertNil(alert(at: confirmed + 2, foreground: "zsh"), "one alert")
        XCTAssertNotNil(stuck(at: confirmed + 60, foreground: "zsh"))
    }

    func testLateSessionEndMeansACleanExit() {
        startTurn()
        machine.noteAgentExited(exit(at: 20))
        _ = apply(event(.sessionEnd, at: 19))
        XCTAssertNil(machine.midTurnExit)
        XCTAssertNil(stuck(at: 30, foreground: "zsh"))
    }

    func testExitBetweenTurnsOrWithoutHooksIsAQuit() {
        startTurn()
        _ = apply(event(.stop, at: 5))
        machine.noteAgentExited(exit(at: 20))
        XCTAssertNil(machine.midTurnExit, "no turn in flight")

        var unhooked = AgentStatusMachine()
        unhooked.noteAgentExited(exit(at: 20, firedHooks: false))
        XCTAssertNil(unhooked.midTurnExit, "without hooks, no SessionEnd tells a quit from a crash")
    }

    /// Ctrl-Z, `fg`, then a crash: the shell in front cleared the column's
    /// hook kind, but this very process proved it fires hooks.
    func testExitAfterASuspendStillCounts() {
        startTurn()
        _ = machine.tick(fgName: "zsh", isUserFocused: false, now: Date(timeIntervalSince1970: t0 + 5))
        _ = machine.tick(fgName: "claude", isUserFocused: false, now: Date(timeIntervalSince1970: t0 + 8))
        XCTAssertNil(machine.hookKind)
        machine.noteAgentExited(exit(at: 20))
        XCTAssertNotNil(machine.midTurnExit)
    }

    /// Keys typed after the agent was last seen alive reached the dying
    /// claude or the shell: the user is there, and the shell line isn't
    /// empty.
    func testExitAfterTheUserTypedIsTheirs() {
        startTurn()
        machine.noteKeystroke(now: Date(timeIntervalSince1970: t0 + 19))
        machine.noteAgentExited(exit(at: 20, seenAt: 18))
        XCTAssertNil(machine.midTurnExit)
    }

    func testExitNoticeEndsWhenTheUserTypesOrAnAgentReturns() {
        startTurn()
        machine.noteAgentExited(exit(at: 20))
        machine.noteKeystroke(now: Date(timeIntervalSince1970: t0 + 30))
        XCTAssertNil(machine.midTurnExit, "typing at the shell: the user took over")

        machine = AgentStatusMachine()
        startTurn()
        machine.noteAgentExited(exit(at: 20))
        XCTAssertNil(stuck(at: 40, foreground: "claude"), "an agent is back in front")
        _ = apply(AgentHookEvent(kind: .claude, name: .sessionStart, sessionID: "new", source: "resume", timestamp: t0 + 41))
        XCTAssertNil(machine.midTurnExit)
    }

    // MARK: - Hook payload

    func testStopFailurePayloadParses() {
        let payload: [String: Any] = [
            "hook_event_name": "StopFailure",
            "session_id": "s",
            "error": "rate_limit",
            "error_details": "429 {\"type\":\"error\"}\n\u{1B}[31m",
            "last_assistant_message": "API Error: Rate limit reached"
        ]
        let event = AgentHookEvent(kind: .claude, payload: payload, env: ["NIRUX_AGENT_UUID": "u"], now: 5)
        XCTAssertEqual(event?.name, .stopFailure)
        XCTAssertEqual(event?.errorKind, "rate_limit")
        XCTAssertEqual(event?.detail, "429 {\"type\":\"error\"} [31m", "cleaned: no control characters")

        let bare = AgentHookEvent(
            kind: .claude,
            payload: ["hook_event_name": "StopFailure", "last_assistant_message": "API Error: 529 Overloaded"],
            env: [:], now: 5
        )
        XCTAssertNil(bare?.errorKind)
        XCTAssertEqual(bare?.detail, "API Error: 529 Overloaded")
    }

    func testStopFailureRoundTripsThroughTheQueue() throws {
        let original = event(.stopFailure, errorKind: "billing_error", message: "Credit balance too low")
        let decoded = try JSONDecoder().decode(AgentHookEvent.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
    }

    // MARK: - Session to resume after an exit

    func testTheDeadClaudesConfirmedSessionOutlivesItsBinding() {
        var tracker = ClaudeSessionTracker()
        let process = claude()
        _ = tracker.admit(.sessionStart, sessionID: "conv", source: "startup", emitter: .foregroundProcess,
                          foregroundProcess: process)
        XCTAssertNil(tracker.lastConfirmedSessionID(of: process.instance), "never prompted: nothing to resume")
        _ = tracker.admit(.userPromptSubmit, sessionID: "conv", source: nil, emitter: .foregroundProcess,
                          foregroundProcess: process)
        // The shell is back in front: saves drop the binding.
        XCTAssertNil(tracker.restore(for: ForegroundProcess(instance: ProcessInstance(pid: 1, startedAt: 1),
                                                           name: "zsh", arguments: [])))
        XCTAssertEqual(tracker.lastConfirmedSessionID(of: process.instance), "conv")
        XCTAssertNil(tracker.lastConfirmedSessionID(of: ProcessInstance(pid: 5, startedAt: 5)))
    }

    func testClaudeLaunchModeFromArguments() {
        XCTAssertEqual(ClaudeLaunchMode.detect(arguments: ["claude", "--dangerously-skip-permissions"]), .skipPermissions)
        XCTAssertEqual(ClaudeLaunchMode.detect(arguments: ["claude", "--permission-mode", "plan"]), .plan)
        XCTAssertNil(ClaudeLaunchMode.detect(arguments: ["claude", "--permission-mode"]))
        XCTAssertNil(ClaudeLaunchMode.detect(arguments: ["claude"]))
    }

    // MARK: - Setting

    func testWaitThresholdSettingRoundTripsAndNeverBreaksTheStateFile() throws {
        func decode(_ json: String) throws -> PersistedSettings {
            try JSONDecoder().decode(PersistedSettings.self, from: Data(json.utf8))
        }
        XCTAssertNil(try decode("{}").stuckAgentMinutes, "unset: the default applies")
        XCTAssertEqual(try decode(#"{"stuckAgentMinutes": 25}"#).stuckAgentMinutes, 25)
        XCTAssertEqual(try decode(#"{"stuckAgentMinutes": -5}"#).stuckAgentMinutes, 0)
        XCTAssertNil(try decode(#"{"stuckAgentMinutes": "soon"}"#).stuckAgentMinutes, "a bad value reads as unset")

        var settings = PersistedSettings()
        settings.stuckAgentMinutes = 0
        let decoded = try JSONDecoder().decode(PersistedSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.stuckAgentMinutes, 0, "off stays off")
    }

    // MARK: - Texts

    func testStuckReasonTexts() {
        let wait = AgentAttentionReason.stillWaiting(.permission(tool: "Bash", summary: "git push"), waited: 7_500)
        XCTAssertEqual(wait.headline, "needs permission — waiting 2h05m")
        XCTAssertEqual(wait.detailLine, "Bash: git push")
        XCTAssertEqual(wait.activitySummary, "waiting 2h05m · permission: Bash · git push")
        XCTAssertTrue(wait.isBlockingDialog)
        XCTAssertFalse(wait.isFailure)

        let failure = AgentAttentionReason.apiError(kind: "overloaded", detail: nil)
        XCTAssertEqual(failure.shortLabel, "API error")
        XCTAssertEqual(failure.detailLine, "overloaded")
        XCTAssertTrue(failure.isFailure)
        XCTAssertEqual(AgentAttentionReason.exitedMidTurn.headline, "exited mid-turn")

        let text = NiruxNotifier.attentionText(processName: "claude", workspaceTitle: "ws", reason: wait)
        XCTAssertEqual(text.title, "claude needs permission — waiting 2h05m")
        XCTAssertEqual(text.body, "Bash: git push")
        XCTAssertEqual(RemoteDialogText.attentionLabel(failure), "Agent stopped on an API error")
        XCTAssertEqual(RemoteDialogText.attentionLabel(wait), "Agent needs permission")
        let telegram = RemoteDialogText.stuckNotification(wait)
        XCTAssertEqual(telegram.label, "Agent needs permission")
        XCTAssertEqual(telegram.detail, "Tool: Bash\nWaiting for 2h05m", "the tool, never its command")
        XCTAssertEqual(RemoteDialogText.stuckNotification(.exitedMidTurn).label, "Agent exited mid-turn")
    }
}
