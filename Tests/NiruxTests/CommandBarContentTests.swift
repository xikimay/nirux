import AppKit
import XCTest
@testable import Nirux

/// What the window's command bar shows (docs/design/glass-interface.md,
/// step 3.1): the space, the task on screen and where it stands, and the
/// agents waiting for the user.
@MainActor
final class CommandBarContentTests: XCTestCase {
    private let space = WorkspaceProfile(id: "acme", name: "Acme", colorHex: "#9ECE6A")

    private func column(_ index: Int, _ status: AgentStatus, reason: AgentAttentionReason? = nil, elapsed: TimeInterval? = nil) -> ColumnInfo {
        var column = ColumnInfo(
            index: index, processName: "claude", abbreviatedCwd: "~/app", isFocused: index == 0, isWebView: false,
            webTitle: nil, terminalTitle: nil, agentStatus: status, isEditor: false, editorFileName: nil, attentionReason: reason
        )
        column.agentElapsedSeconds = elapsed
        return column
    }

    private func task(_ columns: [ColumnInfo]) -> WorkspaceInfo {
        WorkspaceInfo(
            id: "ws", index: 0, title: "Fix checkout rounding", profileID: space.id, isInactive: false,
            columnCount: columns.count, focusedColumn: 0, gitBranch: "fix/checkout", notification: nil, isActive: true,
            columns: columns, prInfo: nil, diffStats: nil, purpose: nil, nextStep: nil, blocker: nil, phase: .active,
            lastSummary: nil, lastActivityAt: Date().timeIntervalSince1970 - 300, mergedCleanup: nil
        )
    }

    /// The space by name and colour; the task's title, its row's state as
    /// an icon (no station yet: an empty ring) and its status as the row
    /// says it, with the turn's time only while it works; the count as
    /// given.
    func testItSaysWhatTheRowSays() {
        let working = NiruxShellView.commandBarContent(space: space, task: task([column(0, .working, elapsed: 720)]), waitingCount: 2)
        XCTAssertEqual(working.spaceName, "Acme")
        XCTAssertEqual(working.spaceColor, NSColor.niruxColor(hex: "#9ECE6A"))
        XCTAssertEqual(working.taskTitle, "Fix checkout rounding")
        XCTAssertEqual(working.taskIcon, StateIcon(.working))
        XCTAssertEqual(working.taskDetail, "Working 12m")
        XCTAssertEqual(working.waitingCount, 2)

        let asks = NiruxShellView.commandBarContent(
            space: space, task: task([column(0, .working, elapsed: 120), column(1, .needsAttention, reason: .permission(tool: "Bash", summary: "npm run migrate"))]),
            waitingCount: 1
        )
        XCTAssertEqual(asks.taskIcon, StateIcon(.needsYou(.command)), "the waiting column's reason, not the focused one's")
        XCTAssertEqual(asks.taskDetail, "Needs you · Bash: npm run migrate", "the row's words, no time: it waits")
        let question = NiruxShellView.commandBarContent(space: space, task: task([column(0, .needsAttention, reason: .question("One date or a range?"))]), waitingCount: 1)
        XCTAssertEqual(question.taskIcon, StateIcon(.needsYou(.question)))
        // Focused, the column's attention is cleared, not its dialog; a
        // permission the row offers is a command whatever the attention says.
        var dialog = column(0, .idle)
        dialog.openDialog = .permission(tool: "Bash", summary: "git push")
        XCTAssertEqual(WorkspaceInfo.waitReason(of: dialog), .command)
        var offered = column(0, .idle)
        var request = AgentPermissionRequest(toolName: "Bash", summary: "git push", key: "k", agentID: nil, sessionID: "s", requestedAt: 0)
        request.approval = PermissionApprovalTicket(requestID: "r", deadline: 100, text: "git push")
        offered.permissionApproval = SidebarPermissionApproval(request, now: 1)
        XCTAssertEqual(WorkspaceInfo.waitReason(of: offered), .command)
        XCTAssertEqual(WorkspaceInfo.waitReason(of: column(0, .needsAttention, reason: .question("?"))), .question)
        let failed = NiruxShellView.commandBarContent(space: space, task: task([column(0, .needsAttention, reason: .apiError(kind: nil, detail: nil))]), waitingCount: 0)
        XCTAssertEqual(failed.taskIcon, StateIcon(.error))
    }

    /// The count: of what ⌘J would visit, what waits for the user's answer,
    /// not an agent stopped on an error or exited (which ⌘J also visits),
    /// nor the column on screen.
    func testTheCountIsWhatWaitsForAnAnswerOffScreen() {
        let shown = UUID()
        func agent(_ reason: AgentAttentionReason, column: UUID = UUID()) -> WaitingAgent {
            WaitingAgent(workspaceID: "ws", columnID: column, wait: AgentWait(reason: reason, since: 1))
        }
        let queue = [
            agent(.permission(tool: "Bash", summary: nil)), agent(.apiError(kind: nil, detail: nil)), agent(.exitedMidTurn),
            agent(.question("Which base?"), column: shown),
        ]
        XCTAssertEqual(NiruxShellView.commandBarWaitingCount(queue: queue, onScreen: shown), 1)
        XCTAssertEqual(NiruxShellView.commandBarWaitingCount(queue: queue, onScreen: nil), 2)
    }

    /// A wait for the user's answer stops blocking once the agent works
    /// again (an answered dialog lingers until its tool ends); an error
    /// still blocks. ⌘J and the spaces' marks read waits so.
    func testAnAnsweredDialogDoesNotBlockAWorkingAgent() {
        let asks = AgentWait(reason: .permission(tool: "Bash", summary: nil), since: 1)
        XCTAssertTrue(asks.blocks(whileStatus: .needsAttention))
        XCTAssertFalse(asks.blocks(whileStatus: .working), "approved, its tool runs: nobody waits")
        XCTAssertTrue(AgentWait(reason: .apiError(kind: nil, detail: nil), since: 1).blocks(whileStatus: .working))
    }

    /// A space with nothing open says so; a colour that doesn't read falls
    /// back to the accent.
    func testNothingOpenAndAnUnreadableColour() {
        let empty = NiruxShellView.commandBarContent(space: WorkspaceProfile(id: "x", name: "Empty", colorHex: "teal"), task: nil, waitingCount: 0)
        XCTAssertNil(empty.taskTitle)
        XCTAssertNil(empty.taskIcon)
        XCTAssertEqual(empty.spaceColor, Theme.Color.accent)
    }
}
