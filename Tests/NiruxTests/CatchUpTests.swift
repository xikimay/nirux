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
    /// are away, until every one is over. Read whole each time: a lock's
    /// notifications that reach an inactive app late leave nothing behind.
    func testEveryWayOfLeavingIsAway() {
        var tracker = AwayTracker(now: 0)
        XCTAssertEqual(tracker.update(missing: [.appActive], at: 10), .wentAway)
        XCTAssertNil(tracker.update(missing: [.appActive, .screenUnlocked], at: 20))
        XCTAssertNil(tracker.update(missing: [.screenUnlocked], at: 30), "still locked")
        XCTAssertEqual(tracker.update(missing: [], at: 1_000), .cameBack(since: 10))
        XCTAssertNil(tracker.awaySince)

        XCTAssertEqual(tracker.update(missing: [.sessionActive], at: 2_000), .wentAway, "the other account in front")
        XCTAssertNil(tracker.update(missing: [.sessionActive, .screenAwake], at: 2_100))
        XCTAssertEqual(tracker.update(missing: [], at: 3_000), .cameBack(since: 2_000))
        XCTAssertNil(tracker.update(missing: [], at: 3_100), "nothing changed")

        let switchedOut = AwayTracker(missing: [.sessionActive], now: 50)
        XCTAssertEqual(switchedOut.awaySince, 50, "started in a session switched out")
    }

    // MARK: - The card

    private let t0 = Date().timeIntervalSince1970 - 5 * 3_600

    private func endTurn(of workspace: WorkspaceState, at time: TimeInterval) throws {
        let pty = try XCTUnwrap(workspace.columns.first?.pty)
        _ = pty.applyAgentHook(AgentHookEvent(kind: .claude, name: .userPromptSubmit, sessionID: "s", timestamp: time - 60), isUserFocused: false)
        _ = pty.applyAgentHook(AgentHookEvent(kind: .claude, name: .stop, sessionID: "s", timestamp: time), isUserFocused: false)
    }

    /// Waits on state, never on time: the card comes in after the
    /// activation's own work, and CI runs several classes at once. The
    /// description is read at the timeout: it can say what the test saw.
    @discardableResult
    private func waitFor(
        _ description: @autoclosure () -> String, timeout: TimeInterval = 15, file: StaticString = #filePath,
        line: UInt = #line, _ condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        let met = condition()
        XCTAssertTrue(met, "timed out waiting for \(description())", file: file, line: line)
        return met
    }

    /// Away an hour: the tasks whose turn ended meanwhile, latest first;
    /// not the one on screen, the Lead's, an archived one, or one that
    /// ended before. Each goes once opened or answered from its row; a
    /// later absence puts its own ahead and keeps the rest; × takes the
    /// card away.
    func testTheCardListsWhatEndedWhileAway() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            // The rail draws no card.
            if !shell.isSidebarExpanded { harness.runPaletteCommand("Show/Hide Sidebar") }
            harness.waitUntil("the sidebar to expand") { shell.sidebar.isExpanded }
            @MainActor func task(_ title: String) throws -> WorkspaceState {
                shell.addWorkspace(title: title, cwd: harness.repo)
                return try XCTUnwrap(shell.workspaces.last)
            }
            let early = try task("early")
            let first = try task("first")
            let second = try task("second")
            let third = try task("third")
            let lead = try task("lead")
            lead.isLead = true
            let archived = try task("archived")
            archived.isInactive = true
            let onScreen = try task("on screen")
            let leave = t0
            try endTurn(of: early, at: leave - 60)
            try endTurn(of: first, at: leave + 600)
            try endTurn(of: second, at: leave + 1_200)
            try endTurn(of: third, at: leave + 1_250)
            try endTurn(of: lead, at: leave + 1_300)
            try endTurn(of: archived, at: leave + 1_350)
            try endTurn(of: onScreen, at: leave + 1_400)
            XCTAssertTrue(shell.workspaces[shell.activeWSIndex] === onScreen)

            shell.catchUpState.tracker = AwayTracker(now: leave - 1)
            shell.noteAway(missing: [.sessionActive], now: leave)
            shell.noteAway(missing: [], now: leave + 3_600)
            waitFor("the card") { shell.sidebar.catchUp?.rows.count == 3 }
            let card = try XCTUnwrap(shell.sidebar.catchUp)
            XCTAssertEqual(card.rows.map(\.title), ["third", "second", "first"])
            XCTAssertEqual(card.rows.map(\.kind), [.done, .done, .done])
            XCTAssertEqual(card.rows.first?.text, "Done", "no status line")
            XCTAssertEqual(card.since, SidebarCatchUp.sinceText(leave))

            // In the flow: it covers none of the rows' buttons.
            harness.waitUntil("the card on screen") { shell.sidebar.hitAreas.contains { area in
                guard case .catchUp = area.region else { return false }
                return true
            } }
            let cardAreas = shell.sidebar.hitAreas.filter { if case .catchUp = $0.region { true } else { false } }
            let rowAreas = shell.sidebar.hitAreas.filter { if case .catchUp = $0.region { false } else { true } }
            XCTAssertFalse(cardAreas.isEmpty)
            for card in cardAreas {
                for row in rowAreas { XCTAssertFalse(card.frame.intersects(row.frame), "\(row.region)") }
            }

            shell.handleCatchUpAction(.open(workspaceID: first.id))
            XCTAssertTrue(shell.workspaces[shell.activeWSIndex] === first)
            XCTAssertEqual(shell.sidebar.catchUp?.rows.map(\.title), ["third", "second"], "opened")
            shell.noteCatchUpTaskAnswered(workspaceIndex: try XCTUnwrap(shell.workspaces.firstIndex { $0 === third }))
            shell.updateSidebar()
            XCTAssertEqual(shell.sidebar.catchUp?.rows.map(\.title), ["second"], "answered from its row")

            // A short absence, or a long one with nothing ended, keeps it;
            // another puts what ended ahead, and keeps where it began.
            try endTurn(of: third, at: leave + 4_100)
            shell.noteAway(missing: [.appActive], now: leave + 4_000)
            shell.noteAway(missing: [], now: leave + 4_300)
            shell.noteAway(missing: [.screenUnlocked], now: leave + 5_000)
            shell.noteAway(missing: [], now: leave + 6_000)
            shell.updateSidebar()
            XCTAssertEqual(shell.sidebar.catchUp?.rows.map(\.title), ["second"])
            try endTurn(of: early, at: leave + 7_000)
            shell.noteAway(missing: [.appActive], now: leave + 6_500)
            shell.noteAway(missing: [], now: leave + 7_500)
            waitFor("early on the card") { shell.sidebar.catchUp?.rows.count == 2 }
            XCTAssertEqual(shell.sidebar.catchUp?.rows.map(\.title), ["early", "second"])
            XCTAssertEqual(shell.sidebar.catchUp?.since, SidebarCatchUp.sinceText(leave))
            shell.handleCatchUpAction(.open(workspaceID: second.id))
            XCTAssertEqual(shell.sidebar.catchUp?.rows.map(\.title), ["early"])
            XCTAssertEqual(shell.sidebar.catchUp?.since, SidebarCatchUp.sinceText(leave + 6_500), "the oldest left")
            early.isInactive = true
            shell.updateSidebar()
            XCTAssertNil(shell.sidebar.catchUp, "archived since")

            try endTurn(of: third, at: leave + 8_100)
            shell.noteAway(missing: [.appActive], now: leave + 7_600)
            shell.noteAway(missing: [], now: leave + 8_700)
            waitFor("the card again") { shell.sidebar.catchUp != nil }
            XCTAssertEqual(shell.sidebar.catchUp?.rows.map(\.title), ["third"])
            shell.handleCatchUpAction(.dismiss)
            XCTAssertNil(shell.sidebar.catchUp)

            // Off: no card.
            try endTurn(of: third, at: leave + 9_500)
            shell.setCatchUp(enabled: false)
            shell.noteAway(missing: [.appActive], now: leave + 9_000)
            shell.noteAway(missing: [], now: leave + 10_000)
            shell.updateSidebar()
            XCTAssertNil(shell.sidebar.catchUp)
            // Back on: nothing piled up while it was off.
            shell.setCatchUp(enabled: true)
            XCTAssertNil(shell.sidebar.catchUp)
        }
    }

    /// The click that activated Nirux, or a double click, never lands on
    /// the card's rows as they come or move.
    func testThePressesWaitForTheCardToStand() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            if !shell.isSidebarExpanded { harness.runPaletteCommand("Show/Hide Sidebar") }
            harness.waitUntil("the sidebar to expand") { shell.sidebar.isExpanded }
            var tasks: [WorkspaceState] = []
            for title in ["first", "second"] {
                shell.addWorkspace(title: title, cwd: harness.repo)
                tasks.append(try XCTUnwrap(shell.workspaces.last))
            }
            shell.addWorkspace(title: "on screen", cwd: harness.repo)
            let onScreen = try XCTUnwrap(shell.workspaces.last)
            for (offset, task) in tasks.enumerated() { try endTurn(of: task, at: t0 + 600 + Double(offset)) }
            var clock: CFTimeInterval = 1_000
            shell.sidebar.clock = { clock }
            shell.catchUpState.tracker = AwayTracker(now: t0 - 1)
            shell.noteAway(missing: [.appActive], now: t0)
            shell.noteAway(missing: [], now: t0 + 1_800)
            // On screen once the sidebar has widened.
            harness.waitUntil("the card's rows") { shell.sidebar.hitAreas.contains { area in
                guard case .catchUp(.open) = area.region else { return false }
                return true
            } }
            @MainActor func press(_ workspace: WorkspaceState, clickCount: Int, at time: TimeInterval) throws {
                let cardAreas = shell.sidebar.hitAreas.filter { if case .catchUp = $0.region { true } else { false } }
                let area = try XCTUnwrap(shell.sidebar.hitAreas.first { area in
                    guard case .catchUp(.open(let id)) = area.region else { return false }
                    return id == workspace.id
                }, """
                    \(workspace.title)'s row: card \(shell.sidebar.catchUp.map { $0.rows.map(\.title) } ?? []), \
                    \(cardAreas.count) card areas, expanded \(shell.sidebar.isExpanded), width \(shell.sidebar.bounds.width), \
                    on screen \(shell.workspaces[safe: shell.activeWSIndex]?.title ?? "-"), \
                    away since \(shell.catchUpState.tracker.awaySince.map { "\($0)" } ?? "-"), listed \(shell.catchUpState.workspaceIDs.count)
                    """)
                shell.sidebar.mouseDown(with: try XCTUnwrap(NSEvent.mouseEvent(
                    with: .leftMouseDown,
                    location: shell.sidebar.contentDocumentView.convert(NSPoint(x: area.frame.midX, y: area.frame.midY), to: nil),
                    modifierFlags: [], timestamp: time, windowNumber: harness.window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: clickCount, pressure: 0
                )))
            }
            let uptime = ProcessInfo.processInfo.systemUptime
            try press(tasks[1], clickCount: 1, at: uptime)
            XCTAssertTrue(shell.workspaces[shell.activeWSIndex] === onScreen, "the card just came")
            clock += SidebarView.catchUpArming
            try press(tasks[1], clickCount: 1, at: uptime + 1)
            XCTAssertTrue(shell.workspaces[shell.activeWSIndex] === tasks[1])
            XCTAssertEqual(shell.sidebar.catchUp?.rows.map(\.title), ["first"])
            clock += SidebarView.catchUpArming
            try press(tasks[0], clickCount: 2, at: uptime + 1.1)
            XCTAssertTrue(shell.workspaces[shell.activeWSIndex] === tasks[1], "the second press of a double click")
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
            shell.noteAway(missing: [.appActive], now: t0)
            shell.noteAway(missing: [], now: t0 + 1_800)
            waitFor("the card") { shell.sidebar.catchUp?.rows.count == 7 }
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

    /// A list taller than the sidebar: the card comes into view, not above
    /// the visible part. Checked in height, what the reveal scrolls: the
    /// width a scroller leaves is LegacyScrollerTests' to check.
    func testTheCardComesIntoView() throws {
        let rows = (0..<30).map { index in
            WorkspaceInfo(
                id: "ws\(index)", index: index, title: "task \(index)", profileID: WorkspaceProfile.defaultID,
                isInactive: false, columnCount: 1, focusedColumn: 0, gitBranch: "feat/\(index)", notification: nil,
                isActive: index == 29, columns: [ColumnInfo(
                    index: 0, processName: "claude", abbreviatedCwd: nil, isFocused: false, isWebView: false, webTitle: nil,
                    terminalTitle: nil, agentStatus: .idle, isEditor: false, editorFileName: nil, attentionReason: nil
                )],
                prInfo: nil, diffStats: nil, purpose: nil, nextStep: nil, blocker: nil, phase: .active,
                lastSummary: nil, lastActivityAt: nil
            )
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 260, height: 300))
        window.contentView = sidebar
        sidebar.layoutSubtreeIfNeeded()
        sidebar.isExpanded = true
        sidebar.update(profiles: [], workspaces: rows)
        let visibleBefore = sidebar.contentScrollView.documentVisibleRect
        sidebar.catchUp = SidebarCatchUp(
            since: "since 12:40",
            rows: (0..<3).map { SidebarCatchUp.Row(workspaceID: "ws\($0)", title: "task \($0)", kind: .done, text: "Done") },
            otherSpaces: []
        )
        sidebar.refreshCatchUpCard(reveal: true)
        let scroll = sidebar.contentScrollView
        // Read each time: a rebuild lays the card out again.
        let dismissFrame = {
            sidebar.hitAreas.first { area in
                guard case .catchUp(.dismiss) = area.region else { return false }
                return true
            }?.frame
        }
        let dismiss = try XCTUnwrap(dismissFrame())
        // The rebuild leaves it above the visible part: the reveal brings it in.
        XCTAssertGreaterThan(dismiss.minY, scroll.documentVisibleRect.maxY, "the card comes in above the visible part")
        waitFor("""
            the card in view: visible was \(visibleBefore), is \(scroll.documentVisibleRect), \
            its × at \(dismissFrame().map { "\($0)" } ?? "-"), scroller style \(scroll.scrollerStyle.rawValue)
            """) {
            guard let dismiss = dismissFrame() else { return false }
            let visible = scroll.documentVisibleRect
            return visible.minY <= dismiss.minY && dismiss.maxY <= visible.maxY
        }
        XCTAssertEqual(scroll.documentVisibleRect.minX, 0, "the list never scrolls sideways")
    }

    /// A row says what its task's row says: what it asks, what broke, that
    /// it works or waits on something else; else its last turn's line.
    func testARowSaysWhatItsTaskRowSays() {
        func info(_ reason: AgentAttentionReason?, status: AgentStatus, blocker: String? = nil, line: String? = nil) -> WorkspaceInfo {
            var info = WorkspaceInfo(
                id: "ws", index: 0, title: "feat/export", profileID: WorkspaceProfile.defaultID, isInactive: false,
                columnCount: 1, focusedColumn: 0, gitBranch: "feat/export", notification: nil, isActive: false,
                columns: [ColumnInfo(
                    index: 0, processName: "claude", abbreviatedCwd: nil, isFocused: false, isWebView: false, webTitle: nil,
                    terminalTitle: nil, agentStatus: status, isEditor: false, editorFileName: nil, attentionReason: reason
                )],
                prInfo: nil, diffStats: nil, purpose: nil, nextStep: nil, blocker: blocker, phase: .active,
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
        let working = SidebarCatchUp.row(for: info(nil, status: .working, line: "fix pushed"))
        XCTAssertEqual(working.kind, .working)
        XCTAssertEqual(working.text, "Working", "not the former turn's line")
        let blocked = SidebarCatchUp.row(for: info(nil, status: .idle, blocker: "waits for #212", line: "fix pushed"))
        XCTAssertEqual(blocked.kind, .quiet)
        XCTAssertEqual(blocked.text, "Blocked · waits for #212")
        XCTAssertEqual(SidebarCatchUp.row(for: info(nil, status: .idle, line: "fix pushed, CI green")).text, "fix pushed, CI green")
        XCTAssertEqual(SidebarCatchUp.row(for: info(nil, status: .idle)).text, "Done")
        XCTAssertEqual(
            [SidebarCatchUp.Kind.working, .quiet, .done, .broken, .asks].sorted(), [.asks, .broken, .done, .quiet, .working],
            "needs-you first, then broken, then done"
        )
    }

    /// The card's views: a group VoiceOver names, buttons it can press,
    /// and nothing that takes the keyboard.
    func testTheCardNeverTakesTheKeyboard() {
        var pressed: [SidebarCatchUpAction] = []
        let catchUp = SidebarCatchUp(
            since: "since 12:40",
            rows: [SidebarCatchUp.Row(workspaceID: "a", title: "feat/export", kind: .asks, text: "Needs you · Merge #41 now?")],
            otherSpaces: [SidebarCatchUp.OtherSpace(profileID: "p", name: "Client", count: 2)]
        )
        let card = SidebarCatchUpCardRenderer(catchUp: catchUp, sidebarWidth: 260, top: 500) { pressed.append($0) }.render()
        XCTAssertTrue(card.views.allSatisfy { !$0.acceptsFirstResponder })
        XCTAssertEqual(card.views.first?.accessibilityLabel(), "While you were away, since 12:40: 3 tasks")
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
        // Its × doesn't reach into the first row.
        XCTAssertFalse(card.hitAreas[0].frame.intersects(card.hitAreas[1].frame))
    }
}
