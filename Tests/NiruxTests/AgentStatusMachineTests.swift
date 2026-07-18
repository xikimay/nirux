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

    func testFallbackOutputActivityCycle() {
        XCTAssertEqual(machine.tick(fgName: "codex", isUserFocused: false, now: t0), .idle)
        machine.noteRead(now: t0 + 1)
        XCTAssertEqual(machine.tick(fgName: "codex", isUserFocused: false, now: t0 + 1.5), .working)
        // Silence after the activity window ends the turn → attention.
        XCTAssertEqual(machine.tick(fgName: "codex", isUserFocused: false, now: t0 + 10), .needsAttention)
        // Focus clears it.
        XCTAssertEqual(machine.tick(fgName: "codex", isUserFocused: true, now: t0 + 11), .idle)
    }

    func testFallbackSilenceWhileFocusedIsQuiet() {
        machine.noteRead(now: t0)
        XCTAssertEqual(machine.tick(fgName: "claude", isUserFocused: true, now: t0), .working)
        XCTAssertEqual(machine.tick(fgName: "claude", isUserFocused: true, now: t0 + 10), .idle)
    }

    func testEchoAfterTypingIsNotWork() {
        machine.noteInteraction(now: t0)
        machine.noteRead(now: t0 + 0.1) // echo
        XCTAssertEqual(machine.tick(fgName: "claude", isUserFocused: false, now: t0 + 0.2), .idle)
        machine.noteRead(now: t0 + 1.0) // outside the echo window → real output
        XCTAssertEqual(machine.tick(fgName: "claude", isUserFocused: false, now: t0 + 1.1), .working)
    }

    func testCodexTurnCompleteMarksAttention() {
        machine.noteRead(now: t0)
        _ = machine.tick(fgName: "codex", isUserFocused: false, now: t0 + 0.5)
        XCTAssertEqual(machine.state, .working)
        XCTAssertTrue(machine.applyHook(.turnComplete, kind: .codex, isUserFocused: false))
        XCTAssertEqual(machine.state, .needsAttention)
        // Codex keeps the fallback for working: fresh output revives it.
        machine.noteRead(now: t0 + 2)
        XCTAssertEqual(machine.tick(fgName: "codex", isUserFocused: false, now: t0 + 2.5), .working)
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
        machine.reset(now: t0)
        XCTAssertEqual(machine.state, .idle)
        XCTAssertNil(machine.foregroundSince)
        // Output fallback works again (hooks forgotten).
        machine.noteRead(now: t0 + 1)
        XCTAssertEqual(machine.tick(fgName: "claude", isUserFocused: false, now: t0 + 1.5), .working)
    }
}
