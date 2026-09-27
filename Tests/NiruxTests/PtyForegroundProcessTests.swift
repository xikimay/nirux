import XCTest
@testable import Nirux

final class PtyForegroundProcessTests: XCTestCase {
    func testForegroundGroupSelectsCodexAfterBackgroundSibling() {
        let snapshot = ProcessSnapshot(entries: [
            .init(
                pid: 10, parentPID: 1, processGroupID: 10,
                terminalForegroundProcessGroupID: 30,
                name: "zsh", startedAt: 10, arguments: ["zsh"]
            ),
            .init(
                pid: 20, parentPID: 10, processGroupID: 20,
                terminalForegroundProcessGroupID: 30,
                name: "sleep", startedAt: 20, arguments: ["sleep", "600"]
            ),
            .init(
                pid: 30, parentPID: 10, processGroupID: 30,
                terminalForegroundProcessGroupID: 30,
                name: "codex", startedAt: 30,
                arguments: ["codex", "resume", "thread-a", "--sandbox", "read-only"]
            )
        ])

        let process = snapshot.foregroundProcess(shellPID: 10)

        XCTAssertEqual(process?.instance.pid, 30)
        XCTAssertEqual(process?.name, "codex")
        XCTAssertEqual(process?.flagValue("--sandbox"), "read-only")
    }

    func testForegroundInstanceMatchesTheForegroundProcessWithoutItsArguments() {
        let snapshot = ProcessSnapshot(entries: [
            .init(pid: 10, parentPID: 1, processGroupID: 10, terminalForegroundProcessGroupID: 30,
                  name: "zsh", startedAt: 10, arguments: ["zsh"]),
            .init(pid: 30, parentPID: 10, processGroupID: 30, terminalForegroundProcessGroupID: 30,
                  name: "claude", startedAt: 30, arguments: ["claude"])
        ])
        XCTAssertEqual(snapshot.foregroundInstance(shellPID: 10), snapshot.foregroundProcess(shellPID: 10)?.instance)
        XCTAssertEqual(snapshot.foregroundInstance(shellPID: 10), ProcessInstance(pid: 30, startedAt: 30))
        XCTAssertNil(snapshot.foregroundInstance(shellPID: 99))

        XCTAssertTrue(snapshot.contains(ProcessInstance(pid: 30, startedAt: 30)))
        XCTAssertFalse(snapshot.contains(ProcessInstance(pid: 30, startedAt: 31)), "a reused pid is another process")
        XCTAssertFalse(snapshot.contains(ProcessInstance(pid: 31, startedAt: 30)))
    }

    func testForegroundProcessFallsBackWhenGroupIsUnavailable() {
        let snapshot = ProcessSnapshot(entries: [
            .init(
                pid: 10, parentPID: 1, processGroupID: 10,
                terminalForegroundProcessGroupID: -1,
                name: "zsh", startedAt: 10, arguments: ["zsh"]
            ),
            .init(
                pid: 20, parentPID: 10, processGroupID: 20,
                terminalForegroundProcessGroupID: -1,
                name: "sleep", startedAt: 20, arguments: ["sleep", "600"]
            )
        ])

        let process = snapshot.foregroundProcess(shellPID: 10)

        XCTAssertEqual(process?.instance.pid, 20)
        XCTAssertEqual(process?.name, "sleep")
    }

    func testNativeCodexEmitterBelongsToNodeWrapperForegroundJob() throws {
        let native = ProcessInstance(pid: 31, startedAt: 31)
        let snapshot = ProcessSnapshot(entries: [
            .init(
                pid: 10, parentPID: 1, processGroupID: 10,
                terminalForegroundProcessGroupID: 30,
                name: "zsh", startedAt: 10, arguments: ["zsh"]
            ),
            .init(
                pid: 20, parentPID: 10, processGroupID: 20,
                terminalForegroundProcessGroupID: 30,
                name: "sleep", startedAt: 20, arguments: ["sleep", "600"]
            ),
            .init(
                pid: 30, parentPID: 10, processGroupID: 30,
                terminalForegroundProcessGroupID: 30,
                name: "node", startedAt: 30,
                arguments: ["node", "/usr/local/lib/node_modules/@openai/codex/bin/codex.js"]
            ),
            .init(
                pid: native.pid, parentPID: 30, processGroupID: 30,
                terminalForegroundProcessGroupID: 30,
                name: "codex", startedAt: native.startedAt,
                arguments: ["/usr/local/lib/node_modules/@openai/codex/vendor/codex"]
            )
        ])
        let foreground = try XCTUnwrap(snapshot.foregroundProcess(shellPID: 10))
        var tracker = CodexSessionTracker()

        XCTAssertEqual(foreground.instance.pid, 30)
        XCTAssertEqual(foreground.name, "codex")
        XCTAssertTrue(snapshot.isProcess(native, inForegroundProcessGroupOf: 10))
        XCTAssertFalse(snapshot.isProcess(
            ProcessInstance(pid: 20, startedAt: 20),
            inForegroundProcessGroupOf: 10
        ))
        XCTAssertFalse(snapshot.isProcess(
            ProcessInstance(pid: native.pid, startedAt: 32),
            inForegroundProcessGroupOf: 10
        ))
        XCTAssertTrue(tracker.capture(
            sessionID: "thread-a",
            emitterBelongsToForegroundJob: snapshot.isProcess(
                native,
                inForegroundProcessGroupOf: 10
            ),
            foregroundProcess: foreground
        ))
        XCTAssertEqual(tracker.sessionID(for: foreground), "thread-a")
    }

    func testForegroundProcessIsNilForExitedShell() {
        let snapshot = ProcessSnapshot(entries: [])

        XCTAssertNil(snapshot.foregroundProcess(shellPID: 10))
    }

    func testChildOfMatchesOnlyALiveDirectChild() {
        let snapshot = ProcessSnapshot(entries: [
            .init(pid: 20, parentPID: 10, processGroupID: 20, terminalForegroundProcessGroupID: 20,
                  name: "claude", startedAt: 20, arguments: ["claude"]),
            .init(pid: 21, parentPID: 20, processGroupID: 20, terminalForegroundProcessGroupID: 20,
                  name: "claude", startedAt: 21, arguments: ["claude"]),
            .init(pid: 22, parentPID: 21, processGroupID: 20, terminalForegroundProcessGroupID: 20,
                  name: "node", startedAt: 22, arguments: ["node", "server.js"])
        ])

        XCTAssertTrue(snapshot.isProcess(ProcessInstance(pid: 21, startedAt: 21), childOf: 20))
        XCTAssertFalse(snapshot.isProcess(ProcessInstance(pid: 22, startedAt: 22), childOf: 20), "grandchild")
        XCTAssertFalse(snapshot.isProcess(ProcessInstance(pid: 21, startedAt: 5), childOf: 20), "reused pid")
    }
}
