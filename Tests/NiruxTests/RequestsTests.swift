import AppKit
import XCTest
@testable import Nirux

/// The requests of agents waiting for the user, as the inbox and the rail's
/// callout get them (docs/design/glass-interface.md, step 3.3).
@MainActor
final class RequestsTests: XCTestCase {
    private func mission(_ id: String, askedAt: TimeInterval) -> SidebarMissionQuestion {
        SidebarMissionQuestion(questionID: id, parentTitle: "Lead", text: "Which endpoint?", handOff: .parentClosed, askedAt: askedAt)
    }

    /// What a waiting column asks: the first that holds of a Mission
    /// question handed to the user, a permission the rows answer, its
    /// turn's question, a question dialog; else what only the terminal
    /// answers, worded from the wait.
    func testAColumnAsksTheFirstThatHolds() throws {
        let question = SidebarTurnQuestion(text: "Ship it?", turnEndedAt: 5, isYesNo: true, columnID: UUID())
        let approval = try XCTUnwrap(RequestCardViewTests.approval("npm test"))
        let dialog = AgentDialog(questions: [
            AgentDialog.Question(text: "Which one?", options: []), AgentDialog.Question(text: "And then?", options: []),
        ])
        let permission = AgentAttentionReason.permission(tool: "Bash", summary: "npm test")
        func kind(_ mission: SidebarMissionQuestion? = nil, _ approval: SidebarPermissionApproval? = nil,
                  _ question: SidebarTurnQuestion? = nil, _ dialog: AgentDialog? = nil,
                  reason: AgentAttentionReason = permission) -> WaitingRequest.Kind {
            NiruxShellView.requestKind(mission: mission, approval: approval, turnQuestion: question, dialog: dialog, reason: reason)
        }
        let asked = mission("q1", askedAt: 3)
        XCTAssertEqual(kind(asked, approval, question, dialog), .mission(asked))
        XCTAssertEqual(kind(nil, approval, question, dialog), .permission(approval))
        XCTAssertEqual(kind(nil, nil, question, dialog), .question(question))
        XCTAssertEqual(kind(nil, nil, nil, dialog), .dialog(question: "Which one?", more: 1))
        XCTAssertEqual(kind(), .terminal("Bash: npm test"), "approvals off: the terminal answers")
        XCTAssertEqual(kind(reason: AgentTrustPrompt.reason), .terminal("Trust this folder?"))
        XCTAssertEqual(kind(reason: .permission(tool: nil, summary: nil)), .terminal("A permission"))
    }

    /// ⌘J's queue holds the Mission questions handed to the user, at their
    /// time, beside the blocked agents; a column blocked otherwise counts
    /// once. Their requests say so, amber with a question.
    func testTheQueueHoldsHandedOffMissionQuestions() throws {
        let shell = NiruxShellView(frame: NSRect(x: 0, y: 0, width: 1200, height: 600))
        shell.stopHeartbeat()
        let workspace = try XCTUnwrap(shell.activeWorkspace)
        let column = try XCTUnwrap(workspace.columns.first)
        shell.addWorkspace(title: "blocked", cwd: NSHomeDirectory())
        let blocked = try XCTUnwrap(shell.workspaces.last?.columns.first)
        shell.quickSwitch.agentWait = { candidate, _, _ in
            candidate === blocked ? AgentWait(reason: .permission(tool: "Bash", summary: "rm"), since: 50) : nil
        }
        let asked = mission("q1", askedAt: 20)
        shell.requestsState.handedOff = [column.id: RequestsState.HandedOff(workspaceID: workspace.id, question: asked)]
        let queue = shell.waitingQueue(snapshot: ProcessSnapshot(entries: []), now: 100)
        XCTAssertEqual(queue.map(\.columnID), [column.id, blocked.id], "the oldest first")
        XCTAssertEqual(queue.first?.wait.since, 20)

        let requests = shell.waitingRequests(NiruxShellView.requestedAgents(in: queue, onScreen: nil), approvalHolds: [:], foregroundProcesses: [:])
        XCTAssertEqual(requests.map(\.kind), [.mission(asked), .terminal("Bash: rm")])
        XCTAssertEqual(requests.first?.taskID, workspace.id)
        XCTAssertEqual(requests.first?.icon, StateIcon(.needsYou(.question)))
        XCTAssertEqual(requests.last?.icon, StateIcon(.needsYou(.command)))

        shell.quickSwitch.agentWait = { candidate, _, _ in
            candidate === column ? AgentWait(reason: .question("Pick one"), since: 80) : nil
        }
        XCTAssertEqual(shell.waitingQueue(snapshot: ProcessSnapshot(entries: []), now: 100).map(\.columnID), [column.id], "once")
    }

    /// The callout sits right of its icon, centred on it, inside the window
    /// and the screen.
    func testTheCalloutSitsBesideItsIcon() {
        let window = NSRect(x: 0, y: 0, width: 1200, height: 800)
        let size = NSSize(width: RequestCalloutView.width, height: 200)
        let middle = NiruxShellView.calloutFrame(beside: NSRect(x: 7, y: 400, width: 38, height: 28), size: size, in: window, screen: nil)
        XCTAssertEqual(middle, NSRect(x: 45 + Theme.Space.sm, y: 314, width: size.width, height: 200))
        let low = NiruxShellView.calloutFrame(beside: NSRect(x: 7, y: 10, width: 38, height: 28), size: size, in: window, screen: nil)
        XCTAssertEqual(low.minY, Theme.Space.sm, "kept in the window")
        let screen = NSRect(x: 0, y: 100, width: 1200, height: 700)
        XCTAssertEqual(NiruxShellView.calloutFrame(beside: NSRect(x: 7, y: 10, width: 38, height: 28), size: size, in: window, screen: screen).minY,
                       100 + Theme.Space.sm, "and on the screen")
    }

    /// The inbox hangs under the bar as ⌘P does, at its own size.
    func testTheInboxHangsUnderTheBar() {
        let place = CommandPalette.place(
            underBar: NSRect(x: 400, y: 760, width: 400, height: 36), in: NSRect(x: 0, y: 0, width: 1200, height: 800),
            screen: nil, size: NSSize(width: RequestInboxView.width, height: 300)
        )
        XCTAssertEqual(place.frame, NSRect(x: 600 - RequestInboxView.width / 2, y: 760 - CommandPalette.barGap - 300, width: RequestInboxView.width, height: 300))
    }
}
