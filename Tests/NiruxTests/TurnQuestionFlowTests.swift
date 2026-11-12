import AppKit
import XCTest
@testable import Nirux

/// The question a Claude turn ended on, in a real window: it stays on its
/// card when its row is clicked, with the choices its message lists, until
/// it is put aside from the row's menu or the card's Dismiss.
@MainActor
final class TurnQuestionFlowTests: XCTestCase {
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
            @MainActor func menuOffersDismiss() throws -> Bool {
                let index = try XCTUnwrap(shell.workspaces.firstIndex { $0 === task })
                return shell.sidebar.workspaceActionMenu(workspaceIndex: index, columnIndex: nil).items.contains {
                    $0.title == SidebarView.dismissQuestionTitle
                }
            }
            /// A turn that ends on the question, its verdict in.
            @MainActor func ask() throws -> SidebarTurnQuestion {
                let now = Date().timeIntervalSince1970
                func event(_ name: AgentHookEvent.Name, after: TimeInterval, message: String? = nil) -> AgentHookEvent {
                    AgentHookEvent(kind: .claude, name: name, sessionID: "s", finalMessage: message, timestamp: now + after)
                }
                _ = pty.applyAgentHook(event(.userPromptSubmit, after: 0), isUserFocused: false)
                let request = try XCTUnwrap(
                    pty.applyAgentHook(event(.stop, after: 0.001, message: Self.message), isUserFocused: false).turnEnd
                )
                _ = pty.applyTurnEndVerdict(
                    .asks(TurnEndQuestion(text: "Which one do you want?", isYesNo: false)), for: request, isUserFocused: false
                )
                return try XCTUnwrap(row()?.columns[safe: columnIndex]?.turnQuestion, "the question on its card")
            }

            XCTAssertNil(row()?.columns[safe: columnIndex]?.turnQuestion)
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

            // Put aside from the row's menu: nothing says it waits.
            XCTAssertTrue(try menuOffersDismiss())
            harness.perform([SidebarView.dismissQuestionTitle], in: shell.sidebar.workspaceActionMenu(workspaceIndex: index, columnIndex: nil))
            let dismissed = try XCTUnwrap(row())
            XCTAssertNil(dismissed.columns[safe: columnIndex]?.turnQuestion)
            XCTAssertNotEqual(dismissed.rowSummary.mark, .needsYou)
            XCTAssertFalse(try menuOffersDismiss())
            XCTAssertTrue(pty.isCurrentTurnEnd(asked.turnEndedAt), "a reply would still go in")

            // The next one, from the card's own Dismiss; a button of the
            // question before does nothing to it.
            let next = try ask()
            XCTAssertNotEqual(next.turnEndedAt, asked.turnEndedAt)
            shell.sidebar.onTurnAnswer?(asked, .dismiss, nil)
            XCTAssertEqual(row()?.columns[safe: columnIndex]?.turnQuestion, next, "another question's button")
            shell.sidebar.onTurnAnswer?(next, .dismiss, nil)
            XCTAssertNil(row()?.columns[safe: columnIndex]?.turnQuestion)
        }
    }
}
