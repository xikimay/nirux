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
