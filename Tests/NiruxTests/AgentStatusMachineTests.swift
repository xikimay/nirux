import XCTest
@testable import Nirux

final class AgentStatusMachineTests: XCTestCase {
    private var machine = AgentStatusMachine()
    private let t0 = Date(timeIntervalSince1970: 1_000)

    // MARK: - Hook-authoritative path (Claude with hooks)

    func testClaudeHookTurnCycle() {
        XCTAssertEqual(machine.tick(fgName: "claude", isUserFocused: false, now: t0), .idle)

        XCTAssertFalse(machine.applyHook(.sessionStart, kind: .claude, isUserFocused: false))
        XCTAssertEqual(machine.state, .idle)

        XCTAssertFalse(machine.applyHook(.userPromptSubmit, kind: .claude, isUserFocused: false))
        XCTAssertEqual(machine.state, .working)

        // Output silence mid-turn keeps working — hooks are authoritative.
        XCTAssertEqual(machine.tick(fgName: "claude", isUserFocused: false, now: t0 + 60), .working)

        // Turn ends while the user watches another column → attention fires.
        XCTAssertTrue(machine.applyHook(.stop, kind: .claude, isUserFocused: false))
        XCTAssertEqual(machine.state, .needsAttention)

        // Heartbeat keeps it until the user focuses the column.
        XCTAssertEqual(machine.tick(fgName: "claude", isUserFocused: false, now: t0 + 61), .needsAttention)
        XCTAssertEqual(machine.tick(fgName: "claude", isUserFocused: true, now: t0 + 62), .idle)
    }

    func testStopWhileFocusedStaysIdle() {
        _ = machine.applyHook(.sessionStart, kind: .claude, isUserFocused: true)
        _ = machine.applyHook(.userPromptSubmit, kind: .claude, isUserFocused: true)
        XCTAssertFalse(machine.applyHook(.stop, kind: .claude, isUserFocused: true))
        XCTAssertEqual(machine.state, .idle)
    }

    func testNotificationRequestsAttention() {
        _ = machine.applyHook(.sessionStart, kind: .claude, isUserFocused: false)
        _ = machine.applyHook(.userPromptSubmit, kind: .claude, isUserFocused: false)
        XCTAssertTrue(machine.applyHook(.notification, kind: .claude, isUserFocused: false))
        XCTAssertEqual(machine.state, .needsAttention)
        // Regression: the tick must NOT flip attention back to working —
        // the agent is blocked on the prompt, hookWorking was cleared.
        XCTAssertEqual(machine.tick(fgName: "claude", isUserFocused: false, now: t0 + 2), .needsAttention)
        // Answering the permission prompt resumes work → attention clears.
        XCTAssertFalse(machine.applyHook(.preToolUse, kind: .claude, isUserFocused: false))
        XCTAssertEqual(machine.state, .working)
    }

    func testAttentionTransitionFiresOnce() {
        _ = machine.applyHook(.sessionStart, kind: .claude, isUserFocused: false)
        _ = machine.applyHook(.userPromptSubmit, kind: .claude, isUserFocused: false)
        XCTAssertTrue(machine.applyHook(.notification, kind: .claude, isUserFocused: false))
        XCTAssertFalse(machine.applyHook(.notification, kind: .claude, isUserFocused: false))
    }

    func testSessionEndClearsEverything() {
        _ = machine.applyHook(.sessionStart, kind: .claude, isUserFocused: false)
        _ = machine.applyHook(.userPromptSubmit, kind: .claude, isUserFocused: false)
        XCTAssertFalse(machine.applyHook(.sessionEnd, kind: .claude, isUserFocused: false))
        XCTAssertEqual(machine.state, .idle)
        // Back in fallback mode: no hooks remembered.
        XCTAssertEqual(machine.tick(fgName: "zsh", isUserFocused: false, now: t0 + 10), .idle)
    }

    /// Auto-compaction fires SessionStart(compact) mid-turn: the turn goes on.
    func testCompactionKeepsTheTurnRunning() {
        _ = machine.tick(fgName: "claude", isUserFocused: false, now: t0)
        _ = machine.applyHook(.sessionStart, kind: .claude, source: "startup", isUserFocused: false)
        _ = machine.applyHook(.userPromptSubmit, kind: .claude, isUserFocused: false)

        XCTAssertFalse(machine.applyHook(.sessionStart, kind: .claude, source: "compact", isUserFocused: false))
        XCTAssertEqual(machine.state, .working)
        XCTAssertEqual(machine.tick(fgName: "claude", isUserFocused: false, now: t0 + 30), .working)

        _ = machine.applyHook(.sessionStart, kind: .claude, source: "clear", isUserFocused: false)
        XCTAssertEqual(machine.state, .idle)
    }

    /// SessionStart can arrive BEFORE the process-table snapshot notices the
    /// new foreground process — clearing hook capability on the foreground
    /// change would knock the session back into the flaky fallback.
    func testHookCapabilitySurvivesForegroundChangeTick() {
        XCTAssertFalse(machine.applyHook(.sessionStart, kind: .claude, isUserFocused: false))
        _ = machine.tick(fgName: "zsh", isUserFocused: false, now: t0) // old fg
        // Snapshot catches up: zsh → claude. Working must still come from hooks.
        _ = machine.tick(fgName: "claude", isUserFocused: false, now: t0 + 1)
        _ = machine.applyHook(.userPromptSubmit, kind: .claude, isUserFocused: false)
        XCTAssertEqual(machine.tick(fgName: "claude", isUserFocused: false, now: t0 + 120), .working)
    }

    // MARK: - Why the agent waits

    private func event(
        _ name: AgentHookEvent.Name,
        at offset: TimeInterval = 0,
        tool: String? = nil,
        summary: String? = nil,
        key: String? = nil,
        agent: String? = nil,
        session: String? = "lead",
        type: String? = nil,
        message: String? = nil
    ) -> AgentHookEvent {
        AgentHookEvent(
            kind: .claude, name: name, sessionID: session, detail: message ?? tool,
            toolName: tool, toolSummary: summary, toolKey: key, agentID: agent,
            notificationType: type, timestamp: t0.timeIntervalSince1970 + offset
        )
    }

    /// A claude session mid-turn, as the heartbeat sees it.
    private func startTurn(focused: Bool = false) {
        _ = machine.tick(fgName: "claude", isUserFocused: focused, now: t0)
        _ = machine.apply(event(.sessionStart), isUserFocused: focused)
        _ = machine.apply(event(.userPromptSubmit), isUserFocused: focused)
        _ = machine.apply(event(.preToolUse, tool: "Bash"), isUserFocused: focused)
    }

    func testPermissionRequestBlocksWithTheToolAndItsCommand() {
        startTurn()
        let outcome = machine.apply(
            event(.permissionRequest, at: 1, tool: "Bash", summary: "git push", key: "k1"), isUserFocused: false
        )
        XCTAssertEqual(outcome.attention, .permission(tool: "Bash", summary: "git push"))
        XCTAssertFalse(outcome.firedAttention, "the alert waits for Claude's own reminder")
        XCTAssertEqual(machine.state, .needsAttention)
        XCTAssertEqual(machine.attentionReason, .permission(tool: "Bash", summary: "git push"))
        XCTAssertEqual(machine.tick(fgName: "claude", isUserFocused: false, now: t0 + 30), .needsAttention)

        // Approved: the call ran → the agent works again, the dialog is gone.
        _ = machine.apply(event(.postToolUse, at: 40, tool: "Bash", key: "k1"), isUserFocused: false)
        XCTAssertEqual(machine.state, .working)
        XCTAssertTrue(machine.pendingDialogs.isEmpty)
        XCTAssertNil(machine.attentionReason)
    }

    /// Claude sends `permission_prompt` only while a dialog sits unanswered
    /// (~6 s) — the alert that a PermissionRequest answered by another hook
    /// never gets.
    func testClaudesReminderAlertsOncePerEpisode() {
        startTurn()
        _ = machine.apply(event(.permissionRequest, at: 1, tool: "Bash", summary: "rm x", key: "k"), isUserFocused: false)
        let reminder = machine.apply(
            event(.notification, at: 7, type: "permission_prompt", message: "Claude needs your permission to use Bash"),
            isUserFocused: false
        )
        XCTAssertTrue(reminder.isRepeat)
        XCTAssertTrue(reminder.firedAttention)
        XCTAssertEqual(reminder.attention, .permission(tool: "Bash", summary: "rm x"))
        XCTAssertEqual(machine.pendingDialogs.count, 1)
        XCTAssertFalse(machine.apply(event(.notification, at: 9, type: "permission_prompt"), isUserFocused: false)
            .firedAttention, "same episode: quiet")
        // Seen, then still unanswered: a new episode alerts again.
        machine.clearAttention()
        XCTAssertTrue(machine.apply(event(.notification, at: 20, type: "permission_prompt"), isUserFocused: false)
            .firedAttention)
    }

    func testFocusedColumnKeepsItsDialogPendingWhileIdle() {
        startTurn(focused: true)
        _ = machine.apply(event(.permissionRequest, tool: "Bash", summary: "make", key: "k"), isUserFocused: true)
        XCTAssertEqual(machine.state, .idle)
        XCTAssertNil(machine.attentionReason, "no attention to explain while focused")
        XCTAssertEqual(machine.pendingDialogs.map(\.toolName), ["Bash"], "the dialog is still open")
    }

    func testToolEventsElsewhereKeepTheColumnBlocked() {
        startTurn()
        _ = machine.apply(event(.permissionRequest, tool: "Bash", key: "k1", agent: "sub-a"), isUserFocused: false)
        // Another subagent keeps working, even on an identical call.
        _ = machine.apply(event(.preToolUse, tool: "Read", agent: "sub-b"), isUserFocused: false)
        _ = machine.apply(event(.postToolUse, tool: "Bash", key: "k1", agent: "sub-b"), isUserFocused: false)
        XCTAssertEqual(machine.state, .needsAttention)
        XCTAssertEqual(machine.tick(fgName: "claude", isUserFocused: false, now: t0 + 5), .needsAttention)
        XCTAssertEqual(machine.pendingDialogs.count, 1)

        // The subagent ended (its denial fired no hook): the dialog went with it.
        _ = machine.apply(event(.subagentStop, agent: "sub-a"), isUserFocused: false)
        XCTAssertTrue(machine.pendingDialogs.isEmpty)
        _ = machine.apply(event(.postToolUse, tool: "Task", key: "k3"), isUserFocused: false)
        XCTAssertEqual(machine.state, .working)
    }

    /// A denial fires no hook. The agent's next tool event shows it moved
    /// on: the column works again, while the gate keeps the entry until
    /// proof — the call may run beside a dialog that is still up.
    func testSameAgentProgressResumesTheStatusButNotTheGate() {
        startTurn()
        _ = machine.apply(event(.permissionRequest, at: 1, tool: "Bash", key: "denied"), isUserFocused: false)
        _ = machine.apply(event(.preToolUse, at: 20, tool: "Edit"), isUserFocused: false)
        XCTAssertEqual(machine.state, .working)
        XCTAssertNil(machine.attentionReason)
        XCTAssertEqual(machine.pendingDialogs.count, 1, "remote prompts stay refused")
        // Claude's reminder says a dialog does wait: blocked again.
        let reminder = machine.apply(event(.notification, at: 26, type: "permission_prompt"), isUserFocused: false)
        XCTAssertTrue(reminder.firedAttention)
        XCTAssertEqual(machine.state, .needsAttention)
        XCTAssertEqual(machine.tick(fgName: "claude", isUserFocused: false, now: t0 + 27), .needsAttention)
        // The turn ends: the main thread's entries go.
        _ = machine.apply(event(.stop, at: 40), isUserFocused: false)
        XCTAssertTrue(machine.pendingDialogs.isEmpty)
    }

    func testPermissionPromptAloneIsAPendingDialog() {
        // A sandboxed command's network request fires no PermissionRequest.
        startTurn()
        let outcome = machine.apply(
            event(.notification, type: "permission_prompt", message: "Claude needs your permission"),
            isUserFocused: false
        )
        XCTAssertFalse(outcome.isRepeat)
        XCTAssertTrue(outcome.firedAttention)
        XCTAssertEqual(outcome.attention, .permission(tool: nil, summary: "Claude needs your permission"))
        XCTAssertEqual(machine.pendingDialogs.count, 1)
        // Nothing identifies its call: tool events can't clear it, the turn's end does.
        _ = machine.apply(event(.postToolUse, tool: "Bash", key: "k"), isUserFocused: false)
        XCTAssertEqual(machine.pendingDialogs.count, 1)
        _ = machine.apply(event(.stop), isUserFocused: false)
        XCTAssertTrue(machine.pendingDialogs.isEmpty)
        XCTAssertEqual(machine.attentionReason, .turnFinished)
    }

    /// The Notification hook is async: a reminder can land just after the
    /// PostToolUse that closed its dialog.
    func testReminderRacingItsDialogsCloseIsDropped() {
        startTurn()
        _ = machine.apply(event(.permissionRequest, at: 2, tool: "Edit", key: "e"), isUserFocused: false)
        _ = machine.apply(event(.postToolUse, at: 8.6, tool: "Edit", key: "e"), isUserFocused: false)
        let late = machine.apply(event(.notification, at: 8.9, type: "permission_prompt"), isUserFocused: false)
        XCTAssertNil(late.attention)
        XCTAssertFalse(late.firedAttention)
        XCTAssertTrue(machine.pendingDialogs.isEmpty)
        XCTAssertEqual(machine.state, .working)
        // Long after, a reminder alone is a new dialog (a network request).
        _ = machine.apply(event(.notification, at: 30, type: "permission_prompt"), isUserFocused: false)
        XCTAssertEqual(machine.pendingDialogs.count, 1)
    }

    func testInformationalNotificationsChangeNothing() {
        startTurn()
        for type in ["auth_success", "agent_completed", "quota_auto_resume_fired", "elicitation_response"] {
            let outcome = machine.apply(event(.notification, type: type, message: "fyi"), isUserFocused: false)
            XCTAssertNil(outcome.attention, type)
            XCTAssertFalse(outcome.firedAttention, type)
            XCTAssertEqual(machine.state, .working, type)
        }
    }

    func testUntypedNotificationStillAsksWithItsMessage() {
        startTurn()
        let outcome = machine.apply(event(.notification, message: "Claude is waiting"), isUserFocused: false)
        XCTAssertTrue(outcome.firedAttention)
        XCTAssertEqual(machine.attentionReason, .message("Claude is waiting"))
        XCTAssertTrue(machine.pendingDialogs.isEmpty)
    }

    func testElicitationIsAQuestionDialogUntilAnswered() {
        startTurn()
        _ = machine.apply(event(.notification, type: "elicitation_dialog", message: "Sign in"), isUserFocused: false)
        XCTAssertEqual(machine.attentionReason, .question("Sign in"))
        XCTAssertEqual(machine.pendingDialogs.count, 1)
        _ = machine.apply(event(.notification, type: "elicitation_response"), isUserFocused: false)
        XCTAssertTrue(machine.pendingDialogs.isEmpty)
    }

    func testAskUserQuestionIsAQuestion() {
        startTurn()
        _ = machine.apply(
            event(.permissionRequest, tool: "AskUserQuestion", summary: "Which DB?", key: "q"), isUserFocused: false
        )
        XCTAssertEqual(machine.attentionReason, .question("Which DB?"))
        _ = machine.apply(event(.postToolUse, tool: "AskUserQuestion", key: "q"), isUserFocused: false)
        XCTAssertTrue(machine.pendingDialogs.isEmpty)
        XCTAssertEqual(machine.state, .working)
    }

    /// "Keep planning" fires no hook; the next proposal of the same plan
    /// call replaces the stale entry instead of queueing behind it.
    func testTheSameCallAskedAgainReplacesItsEntry() {
        startTurn()
        _ = machine.apply(event(.permissionRequest, at: 1, tool: "ExitPlanMode", key: "plan"), isUserFocused: false)
        _ = machine.apply(event(.permissionRequest, at: 60, tool: "ExitPlanMode", key: "plan"), isUserFocused: false)
        XCTAssertEqual(machine.pendingDialogs.count, 1)
        _ = machine.apply(event(.postToolUse, at: 70, tool: "ExitPlanMode", key: "plan"), isUserFocused: false)
        XCTAssertTrue(machine.pendingDialogs.isEmpty)
        XCTAssertEqual(machine.state, .working)
    }

    func testTurnBoundariesCloseOnlyTheirOwnDialogs() {
        startTurn()
        _ = machine.apply(event(.permissionRequest, tool: "Bash", key: "main"), isUserFocused: false)
        _ = machine.apply(event(.permissionRequest, tool: "Bash", key: "sub", agent: "sub-a"), isUserFocused: false)
        // Stop: the main thread's dialogs closed; a background subagent's may not have.
        _ = machine.apply(event(.stop), isUserFocused: false)
        XCTAssertEqual(machine.pendingDialogs.map(\.agentID), ["sub-a"])
        // A (queued) prompt reaches the main thread: the subagent's dialog may still be up.
        _ = machine.apply(event(.userPromptSubmit), isUserFocused: false)
        XCTAssertEqual(machine.pendingDialogs.map(\.agentID), ["sub-a"])
        _ = machine.apply(event(.subagentStop, agent: "sub-a"), isUserFocused: false)
        XCTAssertTrue(machine.pendingDialogs.isEmpty)

        _ = machine.apply(event(.permissionRequest, tool: "Bash", key: "denied"), isUserFocused: false)
        _ = machine.apply(event(.notification, type: "idle_prompt", message: "waiting"), isUserFocused: false)
        XCTAssertTrue(machine.pendingDialogs.isEmpty, "idle at its prompt: the denied dialog is gone")
        XCTAssertEqual(machine.attentionReason, .turnFinished)
        XCTAssertNil(machine.turnStartedAt)

        _ = machine.apply(event(.permissionRequest, tool: "Bash", key: "x", agent: "sub-b"), isUserFocused: false)
        _ = machine.apply(event(.sessionStart), isUserFocused: false)
        XCTAssertTrue(machine.pendingDialogs.isEmpty, "a new conversation")
    }

    /// An agent-team teammate reports its own session through the lead's
    /// column: its turn ending closes none of the lead's dialogs.
    func testAnotherSessionsTurnClosesNothingOfThisOne() {
        startTurn()
        _ = machine.apply(event(.permissionRequest, tool: "Bash", summary: "git push -f", key: "k"), isUserFocused: false)
        _ = machine.apply(event(.stop, session: "teammate"), isUserFocused: false)
        _ = machine.apply(event(.userPromptSubmit, session: "teammate"), isUserFocused: false)
        _ = machine.apply(event(.notification, session: "teammate", type: "idle_prompt"), isUserFocused: false)
        _ = machine.apply(event(.sessionEnd, session: "teammate"), isUserFocused: false)
        XCTAssertEqual(machine.pendingDialogs.map(\.summary), ["git push -f"])
        _ = machine.apply(event(.postToolUse, tool: "Bash", key: "k", session: "teammate"), isUserFocused: false)
        XCTAssertEqual(machine.pendingDialogs.count, 1, "the same command, another session's call")
        _ = machine.apply(event(.sessionEnd), isUserFocused: false)
        XCTAssertTrue(machine.pendingDialogs.isEmpty)
    }

    func testCompactionKeepsPendingDialogs() {
        startTurn()
        _ = machine.apply(event(.permissionRequest, tool: "Bash", key: "k"), isUserFocused: false)
        _ = machine.apply(
            AgentHookEvent(kind: .claude, name: .sessionStart, source: "compact", timestamp: t0.timeIntervalSince1970),
            isUserFocused: false
        )
        XCTAssertEqual(machine.pendingDialogs.count, 1)
    }

    func testStopSaysTheTurnFinished() {
        startTurn()
        let outcome = machine.apply(event(.stop), isUserFocused: false)
        XCTAssertTrue(outcome.firedAttention)
        XCTAssertEqual(outcome.attention, .turnFinished)
        XCTAssertEqual(machine.attentionReason, .turnFinished)
    }

    // MARK: - Turn timer

    func testTurnTimerRunsFromPromptToStop() {
        _ = machine.tick(fgName: "claude", isUserFocused: false, now: t0)
        _ = machine.apply(event(.sessionStart), isUserFocused: false)
        XCTAssertNil(machine.turnStartedAt)
        _ = machine.apply(event(.userPromptSubmit, at: 100), isUserFocused: false)
        _ = machine.apply(event(.preToolUse, at: 150, tool: "Bash"), isUserFocused: false)
        _ = machine.apply(event(.permissionRequest, at: 160, tool: "Bash", key: "k"), isUserFocused: false)
        _ = machine.apply(event(.postToolUse, at: 400, tool: "Bash", key: "k"), isUserFocused: false)
        XCTAssertEqual(machine.turnStartedAt, t0.timeIntervalSince1970 + 100, "the whole turn, waits included")
        _ = machine.apply(event(.stop, at: 500), isUserFocused: false)
        XCTAssertNil(machine.turnStartedAt)
        // A turn already running when Nirux started: from the first event seen.
        _ = machine.apply(event(.preToolUse, at: 900, tool: "Read"), isUserFocused: false)
        XCTAssertEqual(machine.turnStartedAt, t0.timeIntervalSince1970 + 900)
        _ = machine.apply(event(.sessionEnd, at: 950), isUserFocused: false)
        XCTAssertNil(machine.turnStartedAt)
    }

    func testFallbackTurnTimerFollowsOutput() {
        _ = machine.tick(fgName: "codex", isUserFocused: false, now: t0)
        machine.noteUserInput(now: t0 + 5)
        machine.noteRead(now: t0 + 6)
        _ = machine.tick(fgName: "codex", isUserFocused: false, now: t0 + 6.5)
        XCTAssertEqual(machine.turnStartedAt, (t0 + 6.5).timeIntervalSince1970)
        machine.noteRead(now: t0 + 8)
        _ = machine.tick(fgName: "codex", isUserFocused: false, now: t0 + 8.5)
        XCTAssertEqual(machine.turnStartedAt, (t0 + 6.5).timeIntervalSince1970, "same stretch of output")
        _ = machine.tick(fgName: "codex", isUserFocused: false, now: t0 + 20)
        XCTAssertNil(machine.turnStartedAt)
        XCTAssertNil(machine.attentionReason, "silence doesn't say why")
    }

    /// Codex's final output lands just before its notify: it must not
    /// revive the finished turn (and wipe its "done").
    func testCodexFinalOutputDoesNotReviveItsTurn() {
        _ = machine.tick(fgName: "codex", isUserFocused: false, now: t0)
        machine.noteUserInput(now: t0 + 5)
        machine.noteRead(now: t0 + 6)
        _ = machine.tick(fgName: "codex", isUserFocused: false, now: t0 + 6.5)
        machine.noteRead(now: t0 + 7) // the final answer
        let done = machine.apply(
            AgentHookEvent(kind: .codex, name: .turnComplete, timestamp: (t0 + 7.2).timeIntervalSince1970),
            isUserFocused: false
        )
        XCTAssertTrue(done.firedAttention)
        XCTAssertEqual(machine.tick(fgName: "codex", isUserFocused: false, now: t0 + 7.5), .needsAttention)
        XCTAssertEqual(machine.tick(fgName: "codex", isUserFocused: false, now: t0 + 12), .needsAttention)
        XCTAssertEqual(machine.attentionReason, .turnFinished)
    }

    // MARK: - After a dialog is answered

    func testAnsweredDialogShowsTheRunningToolAsWorking() {
        startTurn()
        _ = machine.apply(event(.permissionRequest, at: 1, tool: "Bash", key: "k"), isUserFocused: false)
        // Output alone (no answer typed) proves nothing.
        machine.noteRead(now: t0 + 3)
        XCTAssertEqual(machine.tick(fgName: "claude", isUserFocused: false, now: t0 + 3.5), .needsAttention)

        // The user answers in the column; the approved command runs, with
        // Claude's spinner, and no hook fires until it ends.
        machine.noteKeystroke(now: t0 + 10)
        machine.noteUserInput(now: t0 + 10)
        machine.noteRead(now: t0 + 10.1) // the dialog closing: echo
        XCTAssertEqual(machine.tick(fgName: "claude", isUserFocused: true, now: t0 + 10.2), .idle)
        machine.noteRead(now: t0 + 11)
        XCTAssertEqual(machine.tick(fgName: "claude", isUserFocused: false, now: t0 + 11.5), .working)
        machine.noteRead(now: t0 + 60)
        XCTAssertEqual(machine.tick(fgName: "claude", isUserFocused: false, now: t0 + 61), .working)
        XCTAssertEqual(machine.pendingDialogs.count, 1, "remote prompts stay blocked until hooks confirm")

        // Silence (a denial ended the turn): idle, never attention.
        XCTAssertEqual(machine.tick(fgName: "claude", isUserFocused: false, now: t0 + 70), .idle)
        XCTAssertEqual(machine.tick(fgName: "claude", isUserFocused: false, now: t0 + 90), .idle)
    }

    func testTypingWithSeveralDialogsOpenProvesNothing() {
        startTurn()
        _ = machine.apply(event(.permissionRequest, at: 1, tool: "Bash", key: "a", agent: "sub-a"), isUserFocused: false)
        _ = machine.apply(event(.permissionRequest, at: 2, tool: "Bash", key: "b", agent: "sub-b"), isUserFocused: false)
        machine.noteKeystroke(now: t0 + 10)
        machine.noteRead(now: t0 + 11)
        XCTAssertEqual(machine.tick(fgName: "claude", isUserFocused: false, now: t0 + 11.5), .needsAttention)
    }

    func testReminderUndoesAnAssumedAnswer() {
        startTurn()
        _ = machine.apply(event(.permissionRequest, at: 1, tool: "Bash", key: "k"), isUserFocused: false)
        machine.noteKeystroke(now: t0 + 2) // arrow keys in the dialog
        _ = machine.apply(event(.notification, at: 9, type: "permission_prompt"), isUserFocused: false)
        machine.noteRead(now: t0 + 10)
        XCTAssertEqual(machine.tick(fgName: "claude", isUserFocused: false, now: t0 + 10.5), .needsAttention)
    }

    func testKeystrokesBeforeTheDialogDontCountAsAnAnswer() {
        startTurn()
        machine.noteKeystroke(now: t0 + 1) // typing ahead while Claude works
        machine.noteUserInput(now: t0 + 1)
        _ = machine.apply(event(.permissionRequest, at: 2, tool: "Bash", key: "k"), isUserFocused: false)
        machine.noteRead(now: t0 + 5)
        XCTAssertEqual(machine.tick(fgName: "claude", isUserFocused: false, now: t0 + 5.5), .needsAttention)
    }

    func testResetForgetsDialogsAndTurn() {
        startTurn()
        _ = machine.apply(event(.permissionRequest, tool: "Bash", key: "k"), isUserFocused: false)
        machine.reset()
        XCTAssertTrue(machine.pendingDialogs.isEmpty)
        XCTAssertNil(machine.turnStartedAt)
        XCTAssertNil(machine.attentionReason)
    }

    func testStandaloneOutcomeReadsTheEventAlone() {
        XCTAssertEqual(
            AgentStatusMachine.standaloneOutcome(for: event(.permissionRequest, tool: "Bash", summary: "ls", key: "k"))
                .attention,
            .permission(tool: "Bash", summary: "ls")
        )
        let prompt = AgentStatusMachine.standaloneOutcome(for: event(.notification, type: "permission_prompt", message: "m"))
        XCTAssertFalse(prompt.isRepeat)
        XCTAssertFalse(prompt.firedAttention)
        XCTAssertNil(AgentStatusMachine.standaloneOutcome(for: event(.notification, type: "auth_success")).attention)
    }

    // MARK: - Fallback path (no hooks — codex, unhooked claude)

    /// Fallback attention requires engagement: first keystroke + 5s settle
    /// after the foreground change. Without that, startup banners and
    /// session replay fabricate a working → needsAttention cycle.
    func testFallbackOutputActivityCycle() {
        XCTAssertEqual(machine.tick(fgName: "codex", isUserFocused: false, now: t0), .idle)
        machine.noteUserInput(now: t0 + 5)
        machine.noteRead(now: t0 + 6)
        XCTAssertEqual(machine.tick(fgName: "codex", isUserFocused: false, now: t0 + 6.5), .working)
        // Silence after the activity window ends the turn → attention.
        XCTAssertEqual(machine.tick(fgName: "codex", isUserFocused: false, now: t0 + 20), .needsAttention)
        // Focus clears it.
        XCTAssertEqual(machine.tick(fgName: "codex", isUserFocused: true, now: t0 + 21), .idle)
    }

    func testStartupNoiseNeverSignalsAttention() {
        // Fresh codex column: banner/redraw output, no keystroke ever.
        _ = machine.tick(fgName: "codex", isUserFocused: false, now: t0)
        machine.noteRead(now: t0 + 1)
        machine.noteRead(now: t0 + 2)
        XCTAssertEqual(machine.tick(fgName: "codex", isUserFocused: false, now: t0 + 10), .idle)
        XCTAssertEqual(machine.tick(fgName: "codex", isUserFocused: false, now: t0 + 60), .idle)
    }

    func testSettlingWindowAfterForegroundChange() {
        _ = machine.tick(fgName: "zsh", isUserFocused: false, now: t0)
        machine.noteUserInput(now: t0 + 1) // user types "codex\n"
        _ = machine.tick(fgName: "codex", isUserFocused: false, now: t0 + 2) // fg change
        machine.noteRead(now: t0 + 3) // banner output
        XCTAssertEqual(machine.tick(fgName: "codex", isUserFocused: false, now: t0 + 4), .idle,
                       "still settling — banner is not a turn")
        machine.noteRead(now: t0 + 7.5)
        XCTAssertEqual(machine.tick(fgName: "codex", isUserFocused: false, now: t0 + 8), .working)
    }

    func testKilledCommandOutputDoesNotLeakIntoNextAgent() {
        _ = machine.tick(fgName: "zsh", isUserFocused: false, now: t0)
        machine.noteUserInput(now: t0)
        _ = machine.tick(fgName: "node", isUserFocused: false, now: t0 + 1) // noisy dev server
        machine.noteRead(now: t0 + 9.5)
        // Server killed, unhooked agent launched immediately after.
        _ = machine.tick(fgName: "claude", isUserFocused: false, now: t0 + 10)
        XCTAssertEqual(machine.tick(fgName: "claude", isUserFocused: false, now: t0 + 16), .idle,
                       "stale output from the killed command must not count")
    }

    func testFallbackSilenceWhileFocusedIsQuiet() {
        _ = machine.tick(fgName: "claude", isUserFocused: true, now: t0)
        machine.noteUserInput(now: t0 + 5)
        machine.noteRead(now: t0 + 6)
        XCTAssertEqual(machine.tick(fgName: "claude", isUserFocused: true, now: t0 + 6.5), .working)
        XCTAssertEqual(machine.tick(fgName: "claude", isUserFocused: true, now: t0 + 20), .idle)
    }

    func testEchoAfterTypingIsNotWork() {
        _ = machine.tick(fgName: "claude", isUserFocused: false, now: t0)
        machine.noteUserInput(now: t0 + 5)
        machine.noteRead(now: t0 + 5.1) // echo
        XCTAssertEqual(machine.tick(fgName: "claude", isUserFocused: false, now: t0 + 5.2), .idle)
        machine.noteRead(now: t0 + 6.0) // outside the echo window → real output
        XCTAssertEqual(machine.tick(fgName: "claude", isUserFocused: false, now: t0 + 6.1), .working)
    }

    func testCodexTurnCompleteMarksAttention() {
        _ = machine.tick(fgName: "codex", isUserFocused: false, now: t0)
        machine.noteUserInput(now: t0 + 5)
        machine.noteRead(now: t0 + 6)
        _ = machine.tick(fgName: "codex", isUserFocused: false, now: t0 + 6.5)
        XCTAssertEqual(machine.state, .working)
        XCTAssertTrue(machine.applyHook(.turnComplete, kind: .codex, isUserFocused: false))
        XCTAssertEqual(machine.state, .needsAttention)
        // Codex keeps the fallback for working: fresh output revives it.
        machine.noteRead(now: t0 + 8)
        XCTAssertEqual(machine.tick(fgName: "codex", isUserFocused: false, now: t0 + 8.5), .working)
    }

    // MARK: - Generic transitions

    func testNonAgentForegroundIsAlwaysIdle() {
        _ = machine.applyHook(.sessionStart, kind: .claude, isUserFocused: false)
        _ = machine.applyHook(.userPromptSubmit, kind: .claude, isUserFocused: false)
        XCTAssertEqual(machine.tick(fgName: "vim", isUserFocused: false, now: t0), .idle)
        XCTAssertEqual(machine.tick(fgName: "zsh", isUserFocused: false, now: t0 + 1), .idle)
    }

    func testClearAttention() {
        _ = machine.applyHook(.sessionStart, kind: .claude, isUserFocused: false)
        _ = machine.applyHook(.notification, kind: .claude, isUserFocused: false)
        machine.clearAttention()
        XCTAssertEqual(machine.state, .idle)
    }

    func testForegroundSinceTracksChanges() {
        XCTAssertNil(machine.foregroundSince)
        _ = machine.tick(fgName: "claude", isUserFocused: false, now: t0)
        XCTAssertEqual(machine.foregroundSince, t0)
        _ = machine.tick(fgName: "claude", isUserFocused: false, now: t0 + 5)
        XCTAssertEqual(machine.foregroundSince, t0, "unchanged while the same process runs")
        _ = machine.tick(fgName: "zsh", isUserFocused: false, now: t0 + 9)
        XCTAssertEqual(machine.foregroundSince, t0 + 9)
    }

    func testReset() {
        _ = machine.applyHook(.sessionStart, kind: .claude, isUserFocused: false)
        _ = machine.applyHook(.userPromptSubmit, kind: .claude, isUserFocused: false)
        machine.reset()
        XCTAssertEqual(machine.state, .idle)
        XCTAssertNil(machine.foregroundSince)
        XCTAssertFalse(machine.hasUserInput)
        // Output fallback works again (hooks forgotten) — after engagement.
        _ = machine.tick(fgName: "claude", isUserFocused: false, now: t0)
        machine.noteUserInput(now: t0 + 5)
        machine.noteRead(now: t0 + 6)
        XCTAssertEqual(machine.tick(fgName: "claude", isUserFocused: false, now: t0 + 6.5), .working)
    }
}
