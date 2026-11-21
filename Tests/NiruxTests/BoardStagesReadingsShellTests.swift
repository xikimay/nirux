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
                    snapshot: ProcessSnapshot(), now: Date().timeIntervalSince1970
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
                snapshot: ProcessSnapshot(), now: Date().timeIntervalSince1970
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
    /// the drain's order), or until the process that sent it exits.
    func testAPassRunsUntilItsTurnEndsOrItsProcessExits() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let task = try XCTUnwrap(shell.activeWorkspace)
            let column = try XCTUnwrap(task.columns.first)
            let pty = try XCTUnwrap(column.pty)
            harness.waitUntil("its shell starts") { pty.shellPID != nil }
            let shellPID = try XCTUnwrap(pty.shellPID)
            // The column's own shell stands in for its claude: a process the real table has.
            let emitter = try XCTUnwrap(ProcessInstance.running(pid: shellPID))
            let resolution = AgentHookCenter.Resolution(
                workspace: task, column: column, columnIndex: 0, isUserFocused: false, approvalHold: .never
            )
            let now = Date().timeIntervalSince1970
            let event = { (name: AgentHookEvent.Name, passes: [String]?) in
                AgentHookCenter.AppliedEvent(
                    event: AgentHookEvent(kind: .claude, name: name, emitterProcess: emitter, reviewPasses: passes, timestamp: now),
                    resolution: resolution
                )
            }
            shell.applyAgentHookEvents([event(.userPromptSubmit, ["codeReview"]), event(.stop, nil), event(.userPromptSubmit, nil)])
            XCTAssertEqual(task.reviewsRunning, [], "one drain: the pass, its turn's end, the next prompt")
            shell.applyAgentHookEvents([event(.userPromptSubmit, ["codeReview"])])
            XCTAssertEqual(task.reviewsRunning.map(\.column), [column.id], "no HEAD needed: the event says it runs")
            // The process table: its process there, then not.
            let shellEntry = ProcessSnapshot.Entry(
                pid: shellPID, parentPID: 1, processGroupID: shellPID, terminalForegroundProcessGroupID: shellPID,
                name: "zsh", startedAt: emitter.startedAt, arguments: ["zsh"]
            )
            shell.updateSidebar(snapshot: ProcessSnapshot(entries: [shellEntry]))
            XCTAssertEqual(task.reviewsRunning.count, 1)
            shell.updateSidebar(snapshot: ProcessSnapshot(entries: []))
            XCTAssertEqual(task.reviewsRunning.count, 1, "an empty process table says nothing")
            let unrelated = ProcessSnapshot.Entry(
                pid: 99_996, parentPID: 1, processGroupID: 99_996, terminalForegroundProcessGroupID: 99_996,
                name: "launchd", startedAt: now - 900, arguments: []
            )
            shell.updateSidebar(snapshot: ProcessSnapshot(entries: [unrelated]))
            XCTAssertEqual(task.reviewsRunning, [], "its process exited")
            // An event naming no process: nothing to follow, gone at the next look.
            task.noteReviewPasses(
                of: AgentHookEvent(kind: .claude, name: .userPromptSubmit, reviewPasses: ["codeReview"], timestamp: now), in: column.id, now: now
            )
            shell.updateSidebar(snapshot: ProcessSnapshot(entries: [shellEntry]))
            XCTAssertEqual(task.reviewsRunning, [])
            // Its column closed, its process still there: gone.
            task.noteReviewPasses(
                of: AgentHookEvent(kind: .claude, name: .userPromptSubmit, emitterProcess: emitter, reviewPasses: ["codeReview"], timestamp: now),
                in: UUID(), now: now
            )
            shell.updateSidebar(snapshot: ProcessSnapshot(entries: [shellEntry]))
            XCTAssertEqual(task.reviewsRunning, [])
        }
    }

    /// A session resumed (as Nirux restores them at launch) or ended, through
    /// the hook drain: the readers of a task's last activity (its row's age,
    /// the Board's reading, the context panel's activity line) keep its last
    /// turn. A new session's start moves them.
    func testAResumeOrAnEndLeavesWhatReadsTheTasksLastActivity() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let task = try XCTUnwrap(shell.activeWorkspace)
            let column = try XCTUnwrap(task.columns.first)
            let pty = try XCTUnwrap(column.pty)
            harness.waitUntil("its shell starts") { pty.shellPID != nil }
            let emitter = try XCTUnwrap(ProcessInstance.running(pid: try XCTUnwrap(pty.shellPID)))
            let resolution = AgentHookCenter.Resolution(
                workspace: task, column: column, columnIndex: 0, isUserFocused: false, approvalHold: .never
            )
            let turn = Date().timeIntervalSince1970 - 2 * 3600
            let event = { (name: AgentHookEvent.Name, source: String?, time: TimeInterval) in
                AgentHookCenter.AppliedEvent(
                    event: AgentHookEvent(kind: .claude, name: name, emitterProcess: emitter, source: source, timestamp: time),
                    resolution: resolution
                )
            }
            shell.applyAgentHookEvents([event(.stop, nil, turn), event(.sessionEnd, nil, turn + 60), event(.sessionStart, "resume", turn + 3600)])
            let index = try XCTUnwrap(shell.workspaces.firstIndex { $0 === task })
            @MainActor func readers() -> (row: SidebarRowSummary.Trailing?, board: TimeInterval?, panel: String) {
                let info = shell.sidebarWorkspaceInfo(at: index, columns: [], isActive: false, parentTitle: nil)
                let board = shell.boardReadings(
                    ofSpace: task.profileID, sidebarInfos: [info], foregroundProcesses: [:], approvalHolds: [:], missionQuestions: [:],
                    snapshot: ProcessSnapshot(), now: Date().timeIntervalSince1970
                )[task.id]?.lastActivityAt
                shell.showWorkspaceContextPanel(workspaceIndex: index)
                defer { shell.workspaceContextPanel?.purposeEditor?.window?.orderOut(nil) }
                return (info.rowSummary.trailing, board, shell.workspaceContextPanel?.liveContextLabel?.stringValue ?? "")
            }
            let kept = readers()
            XCTAssertEqual(kept.row, .age(SidebarView.cardAge(since: turn)))
            XCTAssertEqual(kept.board, turn)
            XCTAssertTrue(kept.panel.contains("(\(SidebarView.relativeAge(since: turn)) ago)"), kept.panel)

            let started = Date().timeIntervalSince1970
            shell.applyAgentHookEvents([event(.sessionStart, "startup", started)])
            let moved = readers()
            XCTAssertEqual(moved.row, .age(SidebarView.cardAge(since: started)))
            XCTAssertEqual(moved.board, started)
        }
    }
}
