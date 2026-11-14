import AppKit
import XCTest
@testable import Nirux

/// What the Board as stages reads of a space's tasks, through the shell
/// (`NiruxShellView.boardReadings`): any space, the one on screen or not,
/// read without changing anything.
@MainActor
final class BoardStagesReadingsShellTests: XCTestCase {
    func testAnotherSpacesTasksReadAsTheirRowsAndReadingChangesNothing() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let side = shell.workspaceStore.createProfile(named: "side", select: false)
            shell.addWorkspace(title: "task", cwd: harness.repo, profileID: side.id, activate: false)
            let task = try XCTUnwrap(shell.workspaces.first { $0.title == "task" })
            XCTAssertNotEqual(shell.activeProfileID, side.id)
            task.nextStep = "write the import"
            task.lastSummary = "  Rewriting   the sheet "
            task.lastSummaryIsManual = true
            let read = { (infos: [WorkspaceInfo]) in
                shell.boardReadings(
                    ofSpace: side.id, sidebarInfos: infos, foregroundProcesses: [:], approvalHolds: [:], missionQuestions: [:],
                    snapshot: ProcessSnapshot(), now: Date().timeIntervalSince1970, comparable: { $0 }
                )
            }
            let state = task.columns.first?.pty?.cachedAgentState
            let first = read([])
            XCTAssertEqual(Array(first.keys), [task.id], "a space off screen's tasks, its own only")
            XCTAssertEqual(first[task.id]?.nextStep, "write the import")
            XCTAssertEqual(first[task.id]?.summary, "Rewriting the sheet", "the user's own summary, on one line")
            XCTAssertEqual(read([]), first, "reading again changes nothing")
            XCTAssertEqual(task.columns.first?.pty?.cachedAgentState, state)
            // A status line is the last turn's, not the user's summary.
            task.lastSummaryIsManual = false
            task.lastSummaryIsStatus = true
            XCTAssertNil(read([])[task.id]?.summary)
            // The rows the sidebar just built are taken as they are.
            let built = try XCTUnwrap(shell.boardReadings(
                ofSpace: shell.activeProfileID, foregroundProcesses: [:], approvalHolds: [:], missionQuestions: [:],
                snapshot: ProcessSnapshot(), now: Date().timeIntervalSince1970, comparable: { $0 }
            ).keys.first)
            XCTAssertNotEqual(built, task.id)
            var info = shell.sidebarWorkspaceInfo(at: try XCTUnwrap(shell.workspaces.firstIndex { $0 === task }), columns: [],
                                                  isActive: false, parentTitle: nil)
            info = WorkspaceInfo(
                id: info.id, index: info.index, title: info.title, profileID: info.profileID, isInactive: false, columnCount: 0,
                focusedColumn: 0, gitBranch: nil, notification: nil, isActive: false, columns: [], prInfo: nil, diffStats: nil,
                purpose: nil, nextStep: "from the sidebar's pass", blocker: nil, phase: .active, lastSummary: nil, lastActivityAt: nil
            )
            XCTAssertEqual(read([info])[task.id]?.nextStep, "from the sidebar's pass")
            // A workspace on its way out isn't read.
            task.isClosing = true
            XCTAssertEqual(read([]), [:])
            task.isClosing = false
        }
    }

    /// A review pass runs from its own hook event until its turn ends (in
    /// the drain's order), or until no `claude` is in front of its column.
    func testAPassRunsUntilItsTurnEndsOrClaudeLeavesTheFront() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let task = try XCTUnwrap(shell.activeWorkspace)
            let column = try XCTUnwrap(task.columns.first)
            let pty = try XCTUnwrap(column.pty)
            harness.waitUntil("its shell starts") { pty.shellPID != nil }
            let shellPID = try XCTUnwrap(pty.shellPID)
            let resolution = AgentHookCenter.Resolution(
                workspace: task, column: column, columnIndex: 0, isUserFocused: false, approvalHold: .never
            )
            let now = Date().timeIntervalSince1970
            let event = { (name: AgentHookEvent.Name, passes: [String]?) in
                AgentHookCenter.AppliedEvent(
                    event: AgentHookEvent(kind: .claude, name: name, reviewPasses: passes, timestamp: now), resolution: resolution
                )
            }
            shell.applyAgentHookEvents([event(.userPromptSubmit, ["codeReview"]), event(.stop, nil), event(.userPromptSubmit, nil)])
            XCTAssertEqual(task.reviewsRunning, [], "one drain: the pass, its turn's end, the next prompt")
            shell.applyAgentHookEvents([event(.userPromptSubmit, ["codeReview"])])
            XCTAssertEqual(task.reviewsRunning.map(\.column), [column.id], "no HEAD needed: the event says it runs")
            // claude in front of the column's shell, as the process table would show it; then the shell back in front.
            let claude: pid_t = 99_997
            let table = { (front: pid_t) in
                ProcessSnapshot(entries: [
                    ProcessSnapshot.Entry(
                        pid: shellPID, parentPID: 1, processGroupID: shellPID, terminalForegroundProcessGroupID: front,
                        name: "zsh", startedAt: now - 800, arguments: ["zsh"]
                    ),
                    ProcessSnapshot.Entry(
                        pid: claude, parentPID: shellPID, processGroupID: claude, terminalForegroundProcessGroupID: front,
                        name: "claude", startedAt: now - 700, arguments: ["claude"]
                    )
                ])
            }
            shell.updateSidebar(snapshot: table(claude))
            XCTAssertEqual(task.reviewsRunning.first?.isClaudeSeen, true)
            shell.updateSidebar(snapshot: table(claude))
            XCTAssertEqual(task.reviewsRunning.count, 1)
            shell.updateSidebar(snapshot: table(shellPID))
            XCTAssertEqual(task.reviewsRunning, [], "claude left the front: it exited, crashed or was quit")
            // An event naming its process: running while the table has it, whoever is in front; gone once it doesn't.
            let emitter = ProcessInstance(pid: claude, startedAt: now - 700)
            task.noteReviewPasses(
                of: AgentHookEvent(kind: .claude, name: .userPromptSubmit, emitterProcess: emitter, reviewPasses: ["codeReview"], timestamp: now),
                in: column.id, now: now
            )
            shell.updateSidebar(snapshot: table(shellPID))
            XCTAssertEqual(task.reviewsRunning.count, 1, "a Ctrl-Z: the shell in front, its claude still there")
            let shellAlone = ProcessSnapshot(entries: [ProcessSnapshot.Entry(
                pid: shellPID, parentPID: 1, processGroupID: shellPID, terminalForegroundProcessGroupID: shellPID,
                name: "zsh", startedAt: now - 800, arguments: ["zsh"]
            )])
            shell.updateSidebar(snapshot: shellAlone)
            XCTAssertEqual(task.reviewsRunning, [], "its process exited")
            // Without a process named, nothing at all in its column: gone.
            shell.applyAgentHookEvents([event(.userPromptSubmit, ["codeReview"])])
            let unrelated = ProcessSnapshot(entries: [ProcessSnapshot.Entry(
                pid: 99_996, parentPID: 1, processGroupID: 99_996, terminalForegroundProcessGroupID: 99_996,
                name: "launchd", startedAt: now - 900, arguments: []
            )])
            shell.updateSidebar(snapshot: unrelated)
            XCTAssertEqual(task.reviewsRunning, [], "no process in its column")
        }
    }
}
