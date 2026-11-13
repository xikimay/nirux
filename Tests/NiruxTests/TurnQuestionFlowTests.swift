import AppKit
import XCTest
@testable import Nirux

/// The question a Claude turn ended on, in a real window: it stays on its
/// card when its row is clicked, with the choices its message lists, until
/// it is put aside from the row's menu, the card's Dismiss, or by
/// archiving its task. And what a question dialog asks on its task's row.
@MainActor
final class TurnQuestionFlowTests: UIFlowTestCase {
    /// The row's menu item this class runs: `SidebarPanelFlowTests` never
    /// sees it, since its menus have no question to dismiss.
    override class var coverage: UIFlowCoverage? {
        UIFlowCoverage(
            kind: .sidebarMenuItem,
            tests: ["testAClickKeepsTheQuestionUntilItIsDismissed": [SidebarView.dismissQuestionTitle]],
            exemptions: [:]
        )
    }

    private static let message = "Two ways to fix it:\n\n1. Rebase on main\n2. Merge main in\n\nWhich one do you want?"

    /// A task whose column runs a stand-in `claude`, while the user looks
    /// at another task.
    private func askingTask(
        in harness: UIFlowHarness
    ) throws -> (task: WorkspaceState, columnIndex: Int, pty: PtySession, elsewhere: WorkspaceState) {
        let shell = harness.shell
        let elsewhere = try XCTUnwrap(shell.activeWorkspace)
        shell.addWorkspace(title: "asks", cwd: harness.worktree)
        let task = try XCTUnwrap(shell.activeWorkspace)
        task.addColumn(command: "exec -a claude /bin/sleep 600", cwd: harness.worktree)
        let pty = try XCTUnwrap(task.columns.last?.pty)
        shell.focusWorkspace(id: elsewhere.id)
        harness.waitUntil("its claude in front") { pty.foregroundProcess(snapshot: ProcessSnapshot())?.name == "claude" }
        return (task, task.columns.count - 1, pty, elsewhere)
    }

    /// A question dialog's options reach its task's row while the dialog
    /// is the one on screen, but for the column the user looks at, and
    /// leave once its call ran: answered in the terminal.
    func testADialogsOptionsShowOnItsRow() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let (task, columnIndex, pty, _) = try askingTask(in: harness)
            @MainActor func row() -> WorkspaceInfo? {
                shell.updateSidebar()
                return shell.sidebar.displayedWorkspaceInfos.first { $0.id == task.id }
            }
            let dialog = AgentDialog(questions: [.init(
                text: "Which one do you want?", options: [.init(label: "Rebase", detail: "on main"), .init(label: "Merge", detail: nil)]
            )])
            func event(_ name: AgentHookEvent.Name, tool: String? = nil) -> AgentHookEvent {
                AgentHookEvent(
                    kind: .claude, name: name, sessionID: "s", toolName: tool, toolSummary: tool.map { _ in "Which one do you want?" },
                    toolKey: tool.map { _ in "q" }, timestamp: Date().timeIntervalSince1970
                )
            }
            _ = pty.applyAgentHook(event(.userPromptSubmit), isUserFocused: false)
            var request = event(.permissionRequest, tool: "AskUserQuestion")
            request.dialog = dialog
            _ = pty.applyAgentHook(request, isUserFocused: false)
            let asking = try XCTUnwrap(row())
            XCTAssertEqual(asking.columns[safe: columnIndex]?.dialog, dialog)
            XCTAssertEqual(asking.cardActions, [.dialog(columnIndex: columnIndex, dialog)])
            XCTAssertEqual(asking.rowSummary.lineText, "Needs you · a question")

            // Its column in front, Nirux in front: the user reads the
            // dialog itself, and its row keeps its one line.
            shell.sideEffects.appIsActive = { true }
            shell.focusWorkspace(id: task.id, column: columnIndex)
            let watched = try XCTUnwrap(row())
            XCTAssertNil(watched.columns[safe: columnIndex]?.dialog)
            XCTAssertEqual(watched.cardActions, [])
            XCTAssertEqual(watched.rowSummary.lineText, "Needs you · Which one do you want?")
            shell.sideEffects.appIsActive = { false }
            XCTAssertEqual(try XCTUnwrap(row()).columns[safe: columnIndex]?.dialog, dialog, "Nirux behind: on its row again")

            _ = pty.applyAgentHook(event(.postToolUse, tool: "AskUserQuestion"), isUserFocused: false)
            XCTAssertNil(pty.pendingAgentDialog, "answered: the call ran")
            XCTAssertNil(try XCTUnwrap(row()).columns[safe: columnIndex]?.dialog)
        }
    }

    func testAClickKeepsTheQuestionUntilItIsDismissed() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let (task, columnIndex, pty, elsewhere) = try askingTask(in: harness)

            @MainActor func row() -> WorkspaceInfo? {
                shell.updateSidebar()
                return shell.sidebar.displayedWorkspaceInfos.first { $0.id == task.id }
            }
            @MainActor func card() -> ColumnInfo? { row()?.columns[safe: columnIndex] }
            @MainActor func menu() throws -> NSMenu {
                let index = try XCTUnwrap(shell.workspaces.firstIndex { $0 === task })
                return shell.sidebar.workspaceActionMenu(workspaceIndex: index, columnIndex: nil)
            }
            @MainActor func menuOffersDismiss() throws -> Bool {
                try menu().items.contains { $0.title == SidebarView.dismissQuestionTitle }
            }
            func event(_ name: AgentHookEvent.Name, at time: TimeInterval, message: String? = nil, agent: String? = nil) -> AgentHookEvent {
                AgentHookEvent(
                    kind: .claude, name: name, sessionID: "s", toolName: agent.map { _ in "Bash" }, agentID: agent,
                    finalMessage: message, timestamp: time
                )
            }
            /// A turn that ends on the question, its verdict in.
            @MainActor func ask() throws -> SidebarTurnQuestion {
                let now = Date().timeIntervalSince1970
                _ = pty.applyAgentHook(event(.userPromptSubmit, at: now), isUserFocused: false)
                let request = try XCTUnwrap(
                    pty.applyAgentHook(event(.stop, at: now + 0.001, message: Self.message), isUserFocused: false).turnEnd
                )
                _ = pty.applyTurnEndVerdict(
                    .asks(TurnEndQuestion(text: "Which one do you want?", isYesNo: false)), for: request, isUserFocused: false
                )
                return try XCTUnwrap(card()?.turnQuestion, "the question on its card")
            }

            XCTAssertNil(card()?.turnQuestion)
            XCTAssertFalse(try menuOffersDismiss())
            let asked = try ask()
            XCTAssertEqual(asked.choices.map(\.text), ["Rebase on main", "Merge main in"])
            XCTAssertEqual(row()?.rowSummary.mark, .needsYou)

            // A click on its row: its column in front. The question, its
            // choices and the amber stay.
            let index = try XCTUnwrap(shell.workspaces.firstIndex { $0 === task })
            shell.sidebar.clickRow(index)
            XCTAssertIdentical(shell.activeWorkspace, task)
            XCTAssertEqual(task.focusedIndex, columnIndex, "the column that asks")
            let clicked = try XCTUnwrap(row())
            XCTAssertEqual(clicked.columns[safe: columnIndex]?.turnQuestion, asked)
            XCTAssertEqual(clicked.rowSummary.mark, .needsYou)
            XCTAssertTrue(clicked.cardActions.contains(.turnQuestion(columnIndex: columnIndex, asked)))
            // Read on screen once Nirux is in front too: Next Waiting Agent
            // then goes to it after the waits nobody saw.
            @MainActor func isRead() -> Bool? {
                pty.agentBlockedWait(now: Date().timeIntervalSince1970, foreground: pty.foregroundProcess(snapshot: ProcessSnapshot()))?.isRead
            }
            XCTAssertEqual(isRead(), false, "Nirux behind: nobody read it")
            shell.sideEffects.appIsActive = { true }
            _ = row()
            XCTAssertEqual(isRead(), true)
            shell.sideEffects.appIsActive = { false }

            // A subagent works on: the card has no button to answer with,
            // the row still says the question, and its menu puts it aside.
            _ = pty.applyAgentHook(event(.preToolUse, at: Date().timeIntervalSince1970, agent: "sub"), isUserFocused: false)
            XCTAssertNil(card()?.turnQuestion)
            XCTAssertEqual(card()?.questionAskedAt, asked.turnEndedAt)
            XCTAssertEqual(row()?.rowSummary.mark, .needsYou)
            harness.perform([SidebarView.dismissQuestionTitle], in: try menu())
            XCTAssertNil(card()?.questionAskedAt)
            XCTAssertNotEqual(row()?.rowSummary.mark, .needsYou)
            XCTAssertFalse(try menuOffersDismiss())
            XCTAssertTrue(pty.isCurrentTurnEnd(asked.turnEndedAt), "a reply would still go in")

            // The next one, asked while the user is elsewhere, from the
            // card's own Dismiss: a button of the question before does
            // nothing to it, and what the workspace kept for a user away
            // goes with it.
            shell.focusWorkspace(id: elsewhere.id)
            let next = try ask()
            XCTAssertNotEqual(next.turnEndedAt, asked.turnEndedAt)
            task.raiseNotification(.finished)
            shell.catchUpState.workspaceIDs = [task.id]
            shell.sidebar.onTurnAnswer?(asked, .dismiss, nil)
            XCTAssertEqual(card()?.turnQuestion, next, "another question's button")
            XCTAssertEqual(task.notification, .finished)
            shell.sidebar.onTurnAnswer?(next, .dismiss, nil)
            XCTAssertNil(card()?.questionAskedAt)
            XCTAssertNil(task.notification)
            XCTAssertEqual(shell.catchUpState.workspaceIDs, [], "dealt with: off the catch-up card")

            // An archived task asks nothing, and has nothing unseen.
            _ = try ask()
            task.raiseNotification(.finished)
            shell.handleWorkspaceSidebarAction(.markInactive, workspaceIndex: try XCTUnwrap(shell.workspaces.firstIndex { $0 === task }))
            XCTAssertTrue(task.isInactive)
            XCTAssertNil(pty.agentQuestion(foreground: pty.foregroundProcess(snapshot: ProcessSnapshot())))
            XCTAssertNil(task.notification)
        }
    }
}
