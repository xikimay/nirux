import XCTest
@testable import Nirux

final class ClaudeSessionTrackerTests: XCTestCase {
    private let parent = ForegroundProcess(
        instance: ProcessInstance(pid: 700, startedAt: 70),
        name: "claude",
        arguments: ["claude", "--permission-mode", "auto"]
    )
    /// A `claude -p` the parent launched from its Bash tool: same column
    /// UUID, its own process and session.
    private let nested = ProcessInstance(pid: 900, startedAt: 90)
    private var tracker = ClaudeSessionTracker()

    private func admit(
        _ name: AgentHookEvent.Name,
        _ sessionID: String?,
        from emitter: ProcessInstance?,
        foreground: ForegroundProcess?
    ) -> ClaudeSessionTracker.Admission {
        tracker.admit(name, sessionID: sessionID, emitter: emitter, foregroundProcess: foreground)
    }

    func testColumnAgentBindsItsSession() {
        XCTAssertEqual(admit(.sessionStart, "parent", from: parent.instance, foreground: parent), .adopted)
        XCTAssertEqual(admit(.userPromptSubmit, "parent", from: parent.instance, foreground: parent), .accepted)
        XCTAssertEqual(tracker.sessionID(for: parent), "parent")
    }

    func testNestedClaudeCannotDriveTheColumnOrTakeItsSession() {
        _ = admit(.sessionStart, "parent", from: parent.instance, foreground: parent)

        let names: [AgentHookEvent.Name] = [.sessionStart, .userPromptSubmit, .preToolUse, .notification, .stop, .sessionEnd]
        for name in names {
            XCTAssertEqual(admit(name, "nested", from: nested, foreground: parent), .rejected, "\(name)")
        }
        // `claude -p --resume <parent>` shares the ID but not the process.
        XCTAssertEqual(admit(.sessionEnd, "parent", from: nested, foreground: parent), .rejected)
        XCTAssertEqual(tracker.sessionID(for: parent), "parent")
    }

    func testNestedClaudeIsRejectedBeforeTheParentBinds() {
        XCTAssertEqual(admit(.sessionStart, "nested", from: nested, foreground: parent), .rejected)
        XCTAssertNil(tracker.sessionID(for: parent))
    }

    func testClearRebindsAndIgnoresTheLeftSessionsEnd() {
        _ = admit(.sessionStart, "parent", from: parent.instance, foreground: parent)

        // The new session's SessionStart may land before the old SessionEnd.
        XCTAssertEqual(admit(.sessionStart, "cleared", from: parent.instance, foreground: parent), .adopted)
        XCTAssertEqual(admit(.sessionEnd, "parent", from: parent.instance, foreground: parent), .accepted)
        XCTAssertEqual(tracker.sessionID(for: parent), "cleared")
    }

    func testToolEventsAndSessionEndNeverRebind() {
        _ = admit(.sessionStart, "parent", from: parent.instance, foreground: parent)

        XCTAssertEqual(admit(.preToolUse, "subagent", from: parent.instance, foreground: parent), .accepted)
        XCTAssertEqual(admit(.sessionEnd, "other", from: parent.instance, foreground: parent), .accepted)
        XCTAssertEqual(tracker.sessionID(for: parent), "parent")
    }

    func testTurnEventsRecoverAMissedSessionStart() {
        _ = admit(.sessionStart, "parent", from: parent.instance, foreground: parent)

        XCTAssertEqual(admit(.userPromptSubmit, "resumed", from: parent.instance, foreground: parent), .adopted)
        XCTAssertEqual(tracker.sessionID(for: parent), "resumed")
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
        XCTAssertEqual(tracker.sessionID(for: restarted), "new")
        XCTAssertEqual(admit(.sessionEnd, "parent", from: parent.instance, foreground: restarted), .rejected)
    }

    func testWithoutClaudeInTheForegroundEventsRouteButBindNothing() {
        let shell = ForegroundProcess(
            instance: ProcessInstance(pid: 600, startedAt: 60),
            name: "zsh",
            arguments: ["-zsh"]
        )

        XCTAssertEqual(admit(.stop, "quick", from: nested, foreground: shell), .accepted)
        XCTAssertEqual(admit(.stop, "queued", from: nested, foreground: nil), .accepted)
        XCTAssertNil(tracker.sessionID(for: parent))
    }

    func testLegacyEventsWithoutEmitterOnlyFailOnAContradiction() {
        XCTAssertEqual(admit(.stop, "legacy", from: nil, foreground: parent), .accepted)
        XCTAssertNil(tracker.sessionID(for: parent), "unverified events never bind")

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

        XCTAssertEqual(tracker.sessionID(for: restored), "restored")
        XCTAssertEqual(admit(.sessionStart, "restored", from: restored.instance, foreground: restored), .accepted)
    }

    func testRestoreThatStartedAnotherSessionFollowsTheHook() {
        let restored = ForegroundProcess(
            instance: ProcessInstance(pid: 710, startedAt: 71),
            name: "claude",
            arguments: ["claude", "--resume", "restored"]
        )
        tracker.prepareResume(sessionID: "restored")

        XCTAssertEqual(admit(.sessionStart, "forked", from: restored.instance, foreground: restored), .adopted)
        XCTAssertEqual(tracker.sessionID(for: restored), "forked")
    }

    func testRestoreIsNotLentToAPickerOrFreshProcess() {
        let picker = ForegroundProcess(
            instance: ProcessInstance(pid: 711, startedAt: 72),
            name: "claude",
            arguments: ["claude", "--resume", "--permission-mode", "auto"]
        )
        tracker.prepareResume(sessionID: "restored")

        XCTAssertNil(tracker.sessionID(for: picker))
    }

    func testReplacedProcessDropsItsBinding() {
        _ = admit(.sessionStart, "parent", from: parent.instance, foreground: parent)
        let replacement = ForegroundProcess(
            instance: ProcessInstance(pid: 700, startedAt: 75),
            name: "claude",
            arguments: ["claude"]
        )

        XCTAssertTrue(tracker.invalidateBinding(ifProcessChangedTo: replacement))
        XCTAssertNil(tracker.sessionID(for: replacement))
    }

    func testNearestAncestorWalksUpToTheNamedProcess() throws {
        let selfName = try XCTUnwrap(ProcessSnapshot.execName(from: ProcessSnapshot.arguments(of: getpid(), maxArgs: 2)))
        let parentName = try XCTUnwrap(ProcessSnapshot.execName(from: ProcessSnapshot.arguments(of: getppid(), maxArgs: 2)))

        XCTAssertEqual(
            ProcessInstance.nearestAncestor(named: selfName, from: getpid()),
            ProcessInstance.running(pid: getpid())
        )
        if parentName != selfName {
            XCTAssertEqual(
                ProcessInstance.nearestAncestor(named: parentName, from: getpid()),
                ProcessInstance.running(pid: getppid())
            )
        }
        XCTAssertNil(ProcessInstance.nearestAncestor(named: "no-such-agent-\(UUID().uuidString)", from: getpid()))
    }
}
