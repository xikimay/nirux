import AppKit
import XCTest
@testable import Nirux

/// Back after an absence, a card above the task list says which tasks'
/// turns ended meanwhile: activating Nirux clears the rows' "finished"
/// marks.
@MainActor
final class CatchUpTests: XCTestCase {
    // MARK: - Away and back

    /// Another app, another macOS account, a screen asleep or locked: all
    /// are away, until every one is over.
    func testEveryWayOfLeavingIsAway() {
        var tracker = AwayTracker(now: 0)
        XCTAssertEqual(tracker.set(.appActive, holds: false, at: 10), .wentAway)
        XCTAssertNil(tracker.set(.screenUnlocked, holds: false, at: 20))
        XCTAssertNil(tracker.set(.appActive, holds: true, at: 30), "still locked")
        XCTAssertEqual(tracker.set(.screenUnlocked, holds: true, at: 1_000), .cameBack(since: 10))
        XCTAssertNil(tracker.awaySince)

        XCTAssertEqual(tracker.set(.sessionActive, holds: false, at: 2_000), .wentAway, "the other account in front")
        XCTAssertNil(tracker.set(.screenAwake, holds: false, at: 2_100))
        XCTAssertNil(tracker.set(.screenAwake, holds: true, at: 2_200))
        XCTAssertEqual(tracker.set(.sessionActive, holds: true, at: 3_000), .cameBack(since: 2_000))
        XCTAssertNil(tracker.set(.appActive, holds: true, at: 3_100), "nothing changed")

        let background = AwayTracker(missing: [.appActive], now: 50)
        XCTAssertEqual(background.awaySince, 50, "started in the background")
    }

    // MARK: - The card

    private let t0 = Date().timeIntervalSince1970 - 3 * 3_600

    private func endTurn(of workspace: WorkspaceState, at time: TimeInterval) throws {
        let pty = try XCTUnwrap(workspace.columns.first?.pty)
        _ = pty.applyAgentHook(AgentHookEvent(kind: .claude, name: .userPromptSubmit, sessionID: "s", timestamp: time - 60), isUserFocused: false)
        _ = pty.applyAgentHook(AgentHookEvent(kind: .claude, name: .stop, sessionID: "s", timestamp: time), isUserFocused: false)
    }

    /// Away an hour: the tasks whose turn ended meanwhile, latest first;
    /// not the one on screen, the Lead's, or one that ended before. Each
    /// goes once opened; × takes the card away; a short absence keeps it;
    /// the next long one replaces it.
    func testTheCardListsWhatEndedWhileAway() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            @MainActor func task(_ title: String, isLead: Bool = false) throws -> WorkspaceState {
                shell.addWorkspace(title: title, cwd: harness.repo)
                let workspace = try XCTUnwrap(shell.workspaces.last)
                workspace.isLead = isLead
                return workspace
            }
            let early = try task("early")
            let first = try task("first")
            let second = try task("second")
            let lead = try task("lead", isLead: true)
            let onScreen = try task("on screen")
            let leave = t0
            try endTurn(of: early, at: leave - 60)
            try endTurn(of: first, at: leave + 600)
            try endTurn(of: second, at: leave + 1_200)
            try endTurn(of: lead, at: leave + 1_300)
            try endTurn(of: onScreen, at: leave + 1_400)
            XCTAssertTrue(shell.workspaces[shell.activeWSIndex] === onScreen)

            shell.catchUpState.tracker = AwayTracker(now: leave - 1)
            shell.noteAway(.sessionActive, holds: false, now: leave)
            shell.noteAway(.sessionActive, holds: true, now: leave + 3_600)
            let card = try XCTUnwrap(shell.sidebar.catchUp, "shown at once, from the rows on screen")
            XCTAssertEqual(card.rows.map(\.title), ["second", "first"])
            XCTAssertEqual(card.rows.map(\.kind), [.done, .done])
            XCTAssertEqual(card.rows.first?.text, "Done", "no status line")
            XCTAssertEqual(card.away, "1h")

            // In the flow, above every row: it covers none of their buttons.
            let cardAreas = shell.sidebar.hitAreas.filter { if case .catchUp = $0.region { true } else { false } }
            let rowAreas = shell.sidebar.hitAreas.filter { if case .catchUp = $0.region { false } else { true } }
            XCTAssertFalse(cardAreas.isEmpty)
            for card in cardAreas {
                for row in rowAreas { XCTAssertFalse(card.frame.intersects(row.frame), "\(row.region)") }
            }

            shell.handleCatchUpAction(.open(workspaceID: first.id))
            XCTAssertTrue(shell.workspaces[shell.activeWSIndex] === first)
            XCTAssertEqual(shell.sidebar.catchUp?.rows.map(\.title), ["second"], "opened")

            // A short absence keeps the card; a long one with nothing
            // ended replaces it.
            shell.noteAway(.appActive, holds: false, now: leave + 4_000)
            shell.noteAway(.appActive, holds: true, now: leave + 4_300)
            XCTAssertEqual(shell.sidebar.catchUp?.rows.map(\.title), ["second"])
            shell.noteAway(.screenUnlocked, holds: false, now: leave + 5_000)
            shell.noteAway(.screenUnlocked, holds: true, now: leave + 6_000)
            XCTAssertNil(shell.sidebar.catchUp, "nothing ended during the last one")

            try endTurn(of: second, at: leave + 7_000)
            shell.noteAway(.appActive, holds: false, now: leave + 6_500)
            shell.noteAway(.appActive, holds: true, now: leave + 7_500)
            XCTAssertNotNil(shell.sidebar.catchUp)
            shell.handleCatchUpAction(.dismiss)
            XCTAssertNil(shell.sidebar.catchUp)

            // Off: no card.
            try endTurn(of: second, at: leave + 8_500)
            shell.setCatchUp(enabled: false)
            shell.noteAway(.appActive, holds: false, now: leave + 8_000)
            shell.noteAway(.appActive, holds: true, now: leave + 9_000)
            XCTAssertNil(shell.sidebar.catchUp)
        }
    }

    /// Five rows, then "N more"; another space's tasks get a line that
    /// goes there.
    func testMoreRowsAndOtherSpaces() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let home = shell.activeProfileID
            var tasks: [WorkspaceState] = []
            for index in 0..<7 {
                shell.addWorkspace(title: "task \(index)", cwd: harness.repo)
                tasks.append(try XCTUnwrap(shell.workspaces.last))
            }
            shell.createSpace(NewSpacePanel.Draft(name: "Client", colorHex: WorkspaceProfile.palette[1].hex, anchors: []))
            let client = shell.activeProfileID
            XCTAssertNotEqual(client, home)
            shell.addWorkspace(title: "client task", cwd: harness.repo, profileID: client)
            let elsewhere = try XCTUnwrap(shell.workspaces.last)
            shell.selectProfile(home)
            shell.addWorkspace(title: "on screen", cwd: harness.repo)
            for (offset, task) in (tasks + [elsewhere]).enumerated() { try endTurn(of: task, at: t0 + 600 + Double(offset)) }

            shell.catchUpState.tracker = AwayTracker(now: t0 - 1)
            shell.noteAway(.appActive, holds: false, now: t0)
            shell.noteAway(.appActive, holds: true, now: t0 + 1_800)
            shell.updateSidebar()
            let card = try XCTUnwrap(shell.sidebar.catchUp)
            XCTAssertEqual(card.rows.count, 7)
            XCTAssertEqual(card.shownRows.count, 5)
            XCTAssertEqual(card.hiddenRowCount, 2)
            XCTAssertEqual(card.otherSpaces, [SidebarCatchUp.OtherSpace(profileID: client, name: "Client", count: 1)])
            shell.handleCatchUpAction(.expand)
            XCTAssertEqual(shell.sidebar.catchUp?.shownRows.count, 7)
            shell.handleCatchUpAction(.space(profileID: client))
            XCTAssertEqual(shell.activeProfileID, client)
            let there = try XCTUnwrap(shell.sidebar.catchUp)
            XCTAssertEqual(there.rows, [], "its only task is on screen there: opened")
            let homeName = try XCTUnwrap(shell.workspaceStore.profiles.first { $0.id == home }?.name)
            XCTAssertEqual(there.otherSpaces, [SidebarCatchUp.OtherSpace(profileID: home, name: homeName, count: 7)])
        }
    }

    /// A row says what its task's row says: what it asks, what broke, else
    /// its last turn's line.
    func testARowSaysWhatItsTaskRowSays() {
        func info(_ reason: AgentAttentionReason?, status: AgentStatus, line: String? = nil) -> WorkspaceInfo {
            var info = WorkspaceInfo(
                id: "ws", index: 0, title: "feat/export", profileID: WorkspaceProfile.defaultID, isInactive: false,
                columnCount: 1, focusedColumn: 0, gitBranch: "feat/export", notification: nil, isActive: false,
                columns: [ColumnInfo(
                    index: 0, processName: "claude", abbreviatedCwd: nil, isFocused: false, isWebView: false, webTitle: nil,
                    terminalTitle: nil, agentStatus: status, isEditor: false, editorFileName: nil, attentionReason: reason
                )],
                prInfo: nil, diffStats: nil, purpose: nil, nextStep: nil, blocker: nil, phase: .active,
                lastSummary: nil, lastActivityAt: nil
            )
            info.turnStatusLine = line
            return info
        }
        let asks = SidebarCatchUp.row(for: info(.question("Merge #41 now?"), status: .needsAttention))
        XCTAssertEqual(asks.kind, .asks)
        XCTAssertEqual(asks.text, "Needs you · Merge #41 now?")
        let broken = SidebarCatchUp.row(for: info(.apiError(kind: nil, detail: nil), status: .needsAttention))
        XCTAssertEqual(broken.kind, .broken)
        XCTAssertEqual(broken.text, "Stopped on an API error")
        XCTAssertEqual(SidebarCatchUp.row(for: info(nil, status: .idle, line: "fix pushed, CI green")).text, "fix pushed, CI green")
        XCTAssertEqual(SidebarCatchUp.row(for: info(nil, status: .idle)).text, "Done")
        XCTAssertTrue(SidebarCatchUp.Kind.asks < .broken && SidebarCatchUp.Kind.broken < .done, "needs-you first")
    }

    /// The card's views: a group VoiceOver names, buttons it can press,
    /// and nothing that takes the keyboard.
    func testTheCardNeverTakesTheKeyboard() {
        var pressed: [SidebarCatchUpAction] = []
        let catchUp = SidebarCatchUp(
            away: "42m",
            rows: [SidebarCatchUp.Row(workspaceID: "a", title: "feat/export", kind: .asks, text: "Needs you · Merge #41 now?")],
            otherSpaces: [SidebarCatchUp.OtherSpace(profileID: "p", name: "Client", count: 2)]
        )
        let card = SidebarCatchUpCardRenderer(catchUp: catchUp, sidebarWidth: 260, top: 500) { pressed.append($0) }.render()
        XCTAssertTrue(card.views.allSatisfy { !$0.acceptsFirstResponder })
        XCTAssertEqual(card.views.first?.accessibilityLabel(), "While you were away, 42m: 3 tasks")
        let buttons = card.views.filter { $0.accessibilityRole() == .button }
        XCTAssertEqual(buttons.compactMap { $0.accessibilityLabel() }, [
            "Dismiss what happened while you were away", "feat/export: Needs you · Merge #41 now?", "Also in Client · 2"
        ])
        for button in buttons { XCTAssertTrue(button.accessibilityPerformPress()) }
        XCTAssertEqual(pressed, [.dismiss, .open(workspaceID: "a"), .space(profileID: "p")])
        let actions = card.hitAreas.compactMap { area -> SidebarCatchUpAction? in
            guard case .catchUp(let action) = area.region else { return nil }
            return action
        }
        XCTAssertEqual(actions, [.dismiss, .open(workspaceID: "a"), .space(profileID: "p")])
        let height = SidebarCatchUpCardRenderer.height(of: catchUp)
        XCTAssertEqual(card.views.first?.frame.minY, 500 - height)
    }
}
