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
        transcript: String? = nil
    ) -> ClaudeSessionTracker.Admission {
        tracker.admit(
            name,
            sessionID: sessionID,
            transcriptPath: transcript,
            emitter: emitter,
            emitterInForegroundJob: inForegroundJob ?? (emitter != nil && emitter == foreground?.instance),
            foregroundProcess: foreground
        )
    }

    private func restore(existing: Set<String> = []) -> ClaudeSessionTracker.Restore? {
        tracker.restore(for: parent, transcriptExists: { existing.contains($0) })
    }

    func testColumnAgentBindsItsSession() {
        XCTAssertEqual(admit(.sessionStart, "parent", from: parent.instance, foreground: parent), .adopted)
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

    func testOtherForegroundJobMembersRouteButNeverBind() {
        // A launcher's forked `claude`, or an MCP server's, shares the
        // terminal's foreground process group without being its leader.
        let member = ProcessInstance(pid: 701, startedAt: 71)
        XCTAssertEqual(admit(.stop, "child", from: member, inForegroundJob: true, foreground: parent), .accepted)
        XCTAssertNil(restore())

        _ = admit(.sessionStart, "parent", from: parent.instance, foreground: parent)
        XCTAssertEqual(admit(.stop, "other", from: member, inForegroundJob: true, foreground: parent), .rejected)
        XCTAssertEqual(admit(.stop, "parent", from: member, inForegroundJob: true, foreground: parent), .accepted)
    }

    func testClearRebindsAndIgnoresTheLeftSessionsEnd() {
        _ = admit(.sessionStart, "parent", from: parent.instance, foreground: parent)

        // The new session's SessionStart may land before the old SessionEnd.
        XCTAssertEqual(admit(.sessionStart, "cleared", from: parent.instance, foreground: parent), .adopted)
        XCTAssertEqual(admit(.sessionEnd, "parent", from: parent.instance, foreground: parent), .accepted)
        XCTAssertEqual(restore(), .resume("cleared"))
    }

    func testOnlySessionStartSwitchesABoundSession() {
        _ = admit(.sessionStart, "parent", from: parent.instance, foreground: parent)

        for name in [.userPromptSubmit, .notification, .stop, .preToolUse, .sessionEnd] as [AgentHookEvent.Name] {
            XCTAssertEqual(admit(name, "teammate", from: parent.instance, foreground: parent), .accepted, "\(name)")
        }
        XCTAssertEqual(restore(), .resume("parent"))
    }

    func testTurnEventsAdoptAnUnboundColumn() {
        XCTAssertEqual(admit(.preToolUse, "parent", from: parent.instance, foreground: parent), .accepted)
        XCTAssertEqual(admit(.userPromptSubmit, "parent", from: parent.instance, foreground: parent), .adopted)
        XCTAssertEqual(restore(), .resume("parent"))
    }

    func testUnpromptedSessionRestoresFresh() {
        let transcript = "/tmp/projects/p/parent.jsonl"
        _ = admit(.sessionStart, "parent", from: parent.instance, foreground: parent, transcript: transcript)

        XCTAssertEqual(restore(), .fresh)
        XCTAssertEqual(restore(existing: [transcript]), .resume("parent"))
    }

    func testTranscriptFollowsTheBoundSession() {
        _ = admit(.sessionStart, "parent", from: parent.instance, foreground: parent, transcript: "/t/parent.jsonl")
        _ = admit(.sessionStart, "cleared", from: parent.instance, foreground: parent, transcript: "/t/cleared.jsonl")

        XCTAssertEqual(restore(existing: ["/t/parent.jsonl"]), .fresh)
        XCTAssertEqual(restore(existing: ["/t/cleared.jsonl"]), .resume("cleared"))
    }

    func testRestartedClaudeReplacesAKilledOne() {
        _ = admit(.sessionStart, "parent", from: parent.instance, foreground: parent)
        let restarted = ForegroundProcess(
            instance: ProcessInstance(pid: 701, startedAt: 80),
            name: "claude",
            arguments: ["claude"]
        )

        // SIGKILL left no SessionEnd; the new process still binds.
        XCTAssertEqual(admit(.sessionStart, "new", from: restarted.instance, foreground: restarted), .adopted)
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

    func testLegacyEventsWithoutEmitterOnlyFailOnAContradiction() {
        XCTAssertEqual(admit(.stop, "legacy", from: nil, foreground: parent), .accepted)
        XCTAssertNil(restore(), "unverified events never bind")

        _ = admit(.sessionStart, "parent", from: parent.instance, foreground: parent)
        XCTAssertEqual(admit(.stop, "parent", from: nil, foreground: parent), .accepted)
        XCTAssertEqual(admit(.sessionEnd, "nested", from: nil, foreground: parent), .rejected)
        XCTAssertEqual(admit(.sessionEnd, nil, from: nil, foreground: parent), .accepted)
    }

    func testRestoredSessionPersistsBeforeItsFirstHook() {
        let restored = ForegroundProcess(
            instance: ProcessInstance(pid: 710, startedAt: 71),
            name: "claude",
            arguments: ["claude", "--resume", "restored", "--permission-mode", "auto"]
        )
        tracker.prepareResume(sessionID: "restored")

        XCTAssertEqual(tracker.restore(for: restored, transcriptExists: { _ in false }), .resume("restored"))
        XCTAssertEqual(
            admit(.sessionStart, "restored", from: restored.instance, foreground: restored, transcript: "/t/r.jsonl"),
            .accepted
        )
        XCTAssertEqual(tracker.restore(for: restored, transcriptExists: { $0 == "/t/r.jsonl" }), .resume("restored"))
    }

    func testRestoreThatStartedAnotherSessionFollowsTheHook() {
        let restored = ForegroundProcess(
            instance: ProcessInstance(pid: 710, startedAt: 71),
            name: "claude",
            arguments: ["claude", "--resume", "restored"]
        )
        tracker.prepareResume(sessionID: "restored")

        XCTAssertEqual(admit(.sessionStart, "forked", from: restored.instance, foreground: restored), .adopted)
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

        // `; true` keeps sh from exec'ing sleep: a live shell whose parent
        // (this test) fired it, like Claude's `sh -c <hook command>`.
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", "sleep 5; true"]
        try shell.run()
        defer { shell.terminate() }

        XCTAssertEqual(ProcessInstance.firstNonShellAncestor(from: shell.processIdentifier), me)
        XCTAssertNil(ProcessInstance.firstNonShellAncestor(from: 1))
    }
}
