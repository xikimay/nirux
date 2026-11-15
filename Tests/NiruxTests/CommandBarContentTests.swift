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
    /// an icon (no station yet: an empty ring) and its status, with the
    /// turn's time only while it works; the count as given.
    func testItSaysWhatTheRowSays() {
        let working = NiruxShellView.commandBarContent(space: space, task: task([column(0, .working, elapsed: 720)]), waitingCount: 2)
        XCTAssertEqual(working.spaceName, "Acme")
        XCTAssertEqual(working.spaceColor, NSColor.niruxColor(hex: "#9ECE6A"))
        XCTAssertEqual(working.taskTitle, "Fix checkout rounding")
        XCTAssertEqual(working.taskIcon, StateIcon(.working))
        XCTAssertEqual(working.taskDetail, "working 12m")
        XCTAssertEqual(working.waitingCount, 2)

        let asks = NiruxShellView.commandBarContent(
            space: space, task: task([column(0, .working, elapsed: 120), column(1, .needsAttention, reason: .permission(tool: "Bash", summary: "npm run migrate"))]),
            waitingCount: 1
        )
        XCTAssertEqual(asks.taskIcon, StateIcon(.needsYou(.command)), "the waiting column's reason, not the focused one's")
        XCTAssertEqual(asks.taskDetail, "needs you · Bash: npm run migrate", "the row's words, no time: it waits")
        let question = NiruxShellView.commandBarContent(space: space, task: task([column(0, .needsAttention, reason: .question("One date or a range?"))]), waitingCount: 1)
        XCTAssertEqual(question.taskIcon, StateIcon(.needsYou(.question)))
        let failed = NiruxShellView.commandBarContent(space: space, task: task([column(0, .needsAttention, reason: .apiError(kind: nil, detail: nil))]), waitingCount: 0)
        XCTAssertEqual(failed.taskIcon, StateIcon(.error))
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
