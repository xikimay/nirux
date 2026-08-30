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
}
