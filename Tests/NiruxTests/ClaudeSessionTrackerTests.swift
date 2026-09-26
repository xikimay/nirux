import XCTest
@testable import Nirux

final class ClaudeSessionTrackerTests: XCTestCase {
    private let parent = ForegroundProcess(
        instance: ProcessInstance(pid: 700, startedAt: 70),
        name: "claude",
        arguments: ["claude", "--permission-mode", "auto"]
    )
    /// A `claude -p` the parent launched from its Bash tool: same column
    /// UUID, its own process, session and (detached) process group.
    private let nested = ProcessInstance(pid: 900, startedAt: 90)
    private var tracker = ClaudeSessionTracker()

    private func admit(
        _ name: AgentHookEvent.Name,
        _ sessionID: String?,
        from emitter: ProcessInstance?,
        inForegroundJob: Bool? = nil,
        foreground: ForegroundProcess?,
        source: String? = nil
    ) -> ClaudeSessionTracker.Admission {
        tracker.admit(
            name,
            sessionID: sessionID,
            source: source,
            emitter: emitter,
            emitterInForegroundJob: inForegroundJob ?? (emitter != nil && emitter == foreground?.instance),
            foregroundProcess: foreground
        )
    }

    private func restore() -> ClaudeSessionTracker.Restore? {
        tracker.restore(for: parent)
    }

    func testColumnAgentBindsItsSession() {
        XCTAssertEqual(admit(.sessionStart, "parent", from: parent.instance, foreground: parent), .restoreChanged)
        XCTAssertEqual(admit(.userPromptSubmit, "parent", from: parent.instance, foreground: parent), .accepted)
        XCTAssertEqual(restore(), .resume("parent"))
    }

    func testNestedClaudeCannotDriveTheColumnOrTakeItsSession() {
        _ = admit(.sessionStart, "parent", from: parent.instance, foreground: parent)

        let names: [AgentHookEvent.Name] = [.sessionStart, .userPromptSubmit, .preToolUse, .notification, .stop, .sessionEnd]
        for name in names {
            XCTAssertEqual(admit(name, "nested", from: nested, foreground: parent), .rejected, "\(name)")
        }
        // `claude -p --resume <parent>` shares the ID but not the process.
        XCTAssertEqual(admit(.sessionEnd, "parent", from: nested, foreground: parent), .rejected)
        XCTAssertEqual(restore(), .resume("parent"))
    }

    func testNestedClaudeIsRejectedBeforeTheParentBinds() {
        XCTAssertEqual(admit(.sessionStart, "nested", from: nested, foreground: parent), .rejected)
        XCTAssertNil(restore())
    }

    func testClaudeHooksUnderACodexColumnAreNested() {
        let codex = ForegroundProcess(
            instance: ProcessInstance(pid: 800, startedAt: 80),
            name: "codex",
            arguments: ["codex"]
        )

        XCTAssertEqual(admit(.stop, "nested", from: nested, foreground: codex), .rejected)
        XCTAssertEqual(admit(.stop, "legacy", from: nil, foreground: codex), .rejected)
    }

    func testReceiverWithoutEmitterRoutesButNeverBinds() {
        // An older Nirux build still registered as the hook command.
        _ = admit(.sessionStart, "parent", from: parent.instance, foreground: parent)
        _ = admit(.userPromptSubmit, "parent", from: parent.instance, foreground: parent)

        XCTAssertEqual(admit(.sessionStart, "legacy", from: nil, foreground: parent), .accepted)
        XCTAssertEqual(admit(.stop, "legacy", from: nil, foreground: parent), .accepted)
        XCTAssertEqual(restore(), .resume("parent"))
    }

    func testForegroundJobMemberIsNestedOnceTheSessionIsConfirmed() {
        // An MCP server's `claude -p` shares the terminal's foreground
        // process group without being its leader.
        let member = ProcessInstance(pid: 701, startedAt: 71)
        _ = admit(.sessionStart, "parent", from: parent.instance, foreground: parent)

        for name in [.sessionStart, .stop, .sessionEnd] as [AgentHookEvent.Name] {
            XCTAssertEqual(admit(name, "mcp", from: member, inForegroundJob: true, foreground: parent), .rejected, "\(name)")
        }
        XCTAssertEqual(admit(.stop, "parent", from: member, inForegroundJob: true, foreground: parent), .accepted)
        XCTAssertEqual(restore(), .resume("parent"))
    }

    func testLauncherChildRoutesWhenTheLeaderNeverConfirmed() {
        // A launcher that forks the real `claude`: the leader never fires
        // hooks, so its child's events route (but cannot bind).
        let restored = ForegroundProcess(
            instance: ProcessInstance(pid: 720, startedAt: 72),
            name: "claude",
            arguments: ["claude", "--resume", "restored"]
        )
        let child = ProcessInstance(pid: 721, startedAt: 73)
        tracker.prepareResume(sessionID: "restored")
        XCTAssertEqual(tracker.restore(for: restored), .resume("restored"))

        XCTAssertEqual(admit(.sessionStart, "cleared", from: child, inForegroundJob: true, foreground: restored), .accepted)
        XCTAssertEqual(tracker.restore(for: restored), .resume("restored"))
    }

    func testClearRebindsAndDropsTheLeftSessionsEnd() {
        _ = admit(.sessionStart, "parent", from: parent.instance, foreground: parent, source: "startup")
        _ = admit(.userPromptSubmit, "parent", from: parent.instance, foreground: parent)

        // The new session's SessionStart may land before the old SessionEnd.
        XCTAssertEqual(admit(.sessionStart, "cleared", from: parent.instance, foreground: parent, source: "clear"), .restoreChanged)
        XCTAssertEqual(admit(.sessionEnd, "parent", from: parent.instance, foreground: parent), .rejected)
        XCTAssertEqual(restore(), .fresh, "nothing was said in the cleared session yet")

        _ = admit(.userPromptSubmit, "cleared", from: parent.instance, foreground: parent)
        XCTAssertEqual(restore(), .resume("cleared"))
    }

    func testOnlySessionStartSwitchesABoundSession() {
        _ = admit(.sessionStart, "parent", from: parent.instance, foreground: parent)

        for name in [.userPromptSubmit, .notification, .stop, .preToolUse] as [AgentHookEvent.Name] {
            XCTAssertEqual(admit(name, "teammate", from: parent.instance, foreground: parent), .accepted, "\(name)")
        }
        XCTAssertEqual(restore(), .resume("parent"))
    }

    func testTurnEventsAdoptAnUnboundColumn() {
        XCTAssertEqual(admit(.preToolUse, "parent", from: parent.instance, foreground: parent), .accepted)
        XCTAssertEqual(admit(.userPromptSubmit, "parent", from: parent.instance, foreground: parent), .restoreChanged)
        XCTAssertEqual(restore(), .resume("parent"))
    }

    func testUnpromptedSessionRestoresFresh() {
        XCTAssertEqual(admit(.sessionStart, "parent", from: parent.instance, foreground: parent, source: "startup"), .restoreChanged)
        XCTAssertEqual(restore(), .fresh)

        // Ending the session or notifying says nothing was prompted.
        _ = admit(.sessionEnd, "parent", from: parent.instance, foreground: parent)
        _ = admit(.notification, "parent", from: parent.instance, foreground: parent)
        XCTAssertEqual(restore(), .fresh)

        // The first prompt changes what restore does: persist it now.
        XCTAssertEqual(admit(.userPromptSubmit, "parent", from: parent.instance, foreground: parent), .restoreChanged)
        XCTAssertEqual(admit(.stop, "parent", from: parent.instance, foreground: parent), .accepted)
        XCTAssertEqual(restore(), .resume("parent"))
    }

    func testUnpromptedLeadAdoptsTheSessionItFirstPromptsIn() {
        _ = admit(.sessionStart, "announced", from: parent.instance, foreground: parent, source: "startup")

        XCTAssertEqual(admit(.userPromptSubmit, "actual", from: parent.instance, foreground: parent), .restoreChanged)
        XCTAssertEqual(restore(), .resume("actual"))
    }

    func testResumedForkedAndCompactedSessionsHaveAConversation() {
        for source in ["resume", "fork", "compact", "some-future-source"] {
            var tracker = ClaudeSessionTracker()
            _ = tracker.admit(
                .sessionStart, sessionID: source, source: source,
                emitter: parent.instance, emitterInForegroundJob: true, foregroundProcess: parent
            )
            XCTAssertEqual(tracker.restore(for: parent), .resume(source), source)
        }
    }

    func testCompactionMarksABoundSessionPrompted() {
        _ = admit(.sessionStart, "parent", from: parent.instance, foreground: parent, source: "startup")
        _ = admit(.sessionStart, "parent", from: parent.instance, foreground: parent, source: "compact")
        XCTAssertEqual(restore(), .resume("parent"))
    }

    func testRestartedClaudeReplacesAKilledOne() {
        _ = admit(.sessionStart, "parent", from: parent.instance, foreground: parent)
        let restarted = ForegroundProcess(
            instance: ProcessInstance(pid: 701, startedAt: 80),
            name: "claude",
            arguments: ["claude"]
        )

        // SIGKILL left no SessionEnd; the new process still binds.
        XCTAssertEqual(admit(.sessionStart, "new", from: restarted.instance, foreground: restarted), .restoreChanged)
        XCTAssertEqual(tracker.restore(for: restarted), .resume("new"))
        XCTAssertEqual(admit(.sessionEnd, "parent", from: parent.instance, foreground: restarted), .rejected)
    }

    func testWithoutAnAgentInTheForegroundEventsRouteButBindNothing() {
        let shell = ForegroundProcess(
            instance: ProcessInstance(pid: 600, startedAt: 60),
            name: "zsh",
            arguments: ["-zsh"]
        )

        XCTAssertEqual(admit(.sessionEnd, "finished", from: parent.instance, foreground: shell), .accepted)
        XCTAssertEqual(admit(.stop, "queued", from: nested, foreground: nil), .accepted)
        XCTAssertNil(restore())
    }

    func testRestoredSessionPersistsBeforeItsFirstHook() {
        let restored = ForegroundProcess(
            instance: ProcessInstance(pid: 710, startedAt: 71),
            name: "claude",
            arguments: ["claude", "--resume", "restored", "--permission-mode", "auto"]
        )
        tracker.prepareResume(sessionID: "restored")

        XCTAssertEqual(tracker.restore(for: restored), .resume("restored"))
        XCTAssertEqual(admit(.sessionStart, "restored", from: restored.instance, foreground: restored, source: "resume"), .accepted)
        XCTAssertEqual(tracker.restore(for: restored), .resume("restored"))
    }

    func testRestoreThatStartedAnotherSessionFollowsTheHook() {
        let restored = ForegroundProcess(
            instance: ProcessInstance(pid: 710, startedAt: 71),
            name: "claude",
            arguments: ["claude", "--resume", "restored"]
        )
        tracker.prepareResume(sessionID: "restored")

        XCTAssertEqual(admit(.sessionStart, "forked", from: restored.instance, foreground: restored), .restoreChanged)
        XCTAssertEqual(tracker.restore(for: restored), .resume("forked"))
    }

    func testRestoreIsNotLentToAPickerOrFreshProcess() {
        let picker = ForegroundProcess(
            instance: ProcessInstance(pid: 711, startedAt: 72),
            name: "claude",
            arguments: ["claude", "--resume", "--permission-mode", "auto"]
        )
        tracker.prepareResume(sessionID: "restored")

        XCTAssertNil(tracker.restore(for: picker))
    }

    func testReplacedProcessDropsItsBinding() {
        _ = admit(.sessionStart, "parent", from: parent.instance, foreground: parent)
        let replacement = ForegroundProcess(
            instance: ProcessInstance(pid: 700, startedAt: 75),
            name: "claude",
            arguments: ["claude"]
        )

        XCTAssertTrue(tracker.invalidateBinding(ifProcessChangedTo: replacement))
        XCTAssertNil(tracker.restore(for: replacement))
    }

    func testHookEmitterSkipsTheHookShell() throws {
        let me = try XCTUnwrap(ProcessInstance.running(pid: getpid()))
        XCTAssertEqual(ProcessInstance.firstNonShellAncestor(from: getpid()), me)

        // A live shell whose parent (this test) fired it, like Claude's
        // `sh -c <hook command>`. `read` is a builtin: no grandchild to leak.
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", "read line; true"]
        shell.standardInput = Pipe()
        try shell.run()
        defer { shell.terminate() }

        XCTAssertEqual(ProcessInstance.firstNonShellAncestor(from: shell.processIdentifier), me)
        XCTAssertNil(ProcessInstance.firstNonShellAncestor(from: 1))
    }

    func testHookEmitterWiring() {
        XCTAssertEqual(ProcessInstance.hookEmitter(for: .claude), ProcessInstance.firstNonShellAncestor(from: getppid()))
        XCTAssertEqual(ProcessInstance.hookEmitter(for: .codex), ProcessInstance.running(pid: getppid()))
    }
}
