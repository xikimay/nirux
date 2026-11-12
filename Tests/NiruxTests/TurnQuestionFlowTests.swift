import AppKit
import XCTest
@testable import Nirux

/// The question a Claude turn ended on, in a real window: it stays on its
/// card when its row is clicked, with the choices its message lists, until
/// it is put aside from the row's menu, the card's Dismiss, or by
/// archiving its task.
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

    func testAClickKeepsTheQuestionUntilItIsDismissed() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let elsewhere = try XCTUnwrap(shell.activeWorkspace)
            shell.addWorkspace(title: "asks", cwd: harness.worktree)
            let task = try XCTUnwrap(shell.activeWorkspace)
            task.addColumn(command: "exec -a claude /bin/sleep 600", cwd: harness.worktree)
            let column = try XCTUnwrap(task.columns.last)
            let columnIndex = task.columns.count - 1
            let pty = try XCTUnwrap(column.pty)
            // The user looks at another task while this one's agent asks.
            shell.focusWorkspace(id: elsewhere.id)
            harness.waitUntil("its claude in front") { pty.foregroundProcess(snapshot: ProcessSnapshot())?.name == "claude" }

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

            // An archived task asks nothing.
            _ = try ask()
            shell.handleWorkspaceSidebarAction(.markInactive, workspaceIndex: try XCTUnwrap(shell.workspaces.firstIndex { $0 === task }))
            XCTAssertTrue(task.isInactive)
            XCTAssertNil(pty.agentQuestion(foreground: pty.foregroundProcess(snapshot: ProcessSnapshot())))
        }
    }
}
