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

    func testForegroundProcessIsNilForExitedShell() {
        let snapshot = ProcessSnapshot(entries: [])

        XCTAssertNil(snapshot.foregroundProcess(shellPID: 10))
    }
}
