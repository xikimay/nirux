import AppKit
import XCTest
@testable import Nirux

/// An agent's state as light: which columns light up and which edges glow
/// (`AgentLightPlan`), which turn ends sweep (`TurnEndSweeps`), and what
/// the light's view shows and takes (`EdgeGlowView`).
@MainActor
final class AgentLightTests: XCTestCase {
    private func column(
        _ index: Int, status: AgentStatus = .idle, reason: AgentAttentionReason? = nil, focused: Bool = false,
        process: String = "claude", id: UUID = UUID()
    ) -> ColumnInfo {
        ColumnInfo(
            index: index, processName: process, abbreviatedCwd: nil, isFocused: focused, isWebView: false,
            webTitle: nil, terminalTitle: nil, agentStatus: status, isEditor: false, editorFileName: nil,
            attentionReason: reason, id: id
        )
    }

    private func workspace(
        _ index: Int, _ title: String, _ columns: [ColumnInfo], focusedColumn: Int = 0, isActive: Bool = false
    ) -> WorkspaceInfo {
        WorkspaceInfo(
            id: "ws-\(index)", index: index, title: title, profileID: WorkspaceProfile.defaultID, isInactive: false,
            columnCount: columns.count, focusedColumn: focusedColumn, gitBranch: nil, notification: nil,
            isActive: isActive, columns: columns, prInfo: nil, diffStats: nil, purpose: nil, nextStep: nil,
            blocker: nil, phase: .active, lastSummary: nil, lastActivityAt: nil
        )
    }

    private let permission = AgentAttentionReason.permission(tool: "Bash", summary: "git push")

    // MARK: - Plan

    /// Work is green wherever the user looks; a wait or an error shows on
    /// the columns they aren't on; a finished turn shows nothing.
    func testAColumnsLightFollowsItsAgent() {
        XCTAssertEqual(AgentLightPlan.light(of: column(0, status: .working)), .working)
        XCTAssertEqual(AgentLightPlan.light(of: column(0, status: .working, focused: true)), .working)
        XCTAssertEqual(AgentLightPlan.light(of: column(0, status: .needsAttention, reason: permission)), .alert(.waiting))
        XCTAssertEqual(
            AgentLightPlan.light(of: column(0, status: .needsAttention, reason: .apiError(kind: nil, detail: nil))),
            .alert(.error)
        )
        XCTAssertNil(AgentLightPlan.light(of: column(0, status: .needsAttention, reason: permission, focused: true)))
        XCTAssertNil(AgentLightPlan.light(of: column(0, status: .needsAttention, reason: .turnFinished)))
        XCTAssertNil(AgentLightPlan.light(of: column(0)))
    }

    /// A waiting column the viewport shows pulses itself: the edge glows
    /// only for the one scrolled out, on its side, and names it.
    func testEdgesGlowOnlyForColumnsOutOfView() throws {
        let hiddenLeft = column(0, status: .needsAttention, reason: permission)
        let focused = column(1, status: .working, focused: true)
        let shownRight = column(2, status: .needsAttention, reason: .question("Which one?"))
        let active = workspace(0, "checkout", [hiddenLeft, focused, shownRight], focusedColumn: 1, isActive: true)

        let plan = AgentLightPlan.make(infos: [active], activeIndex: 0) { $0.index != 0 }

        XCTAssertEqual(plan.columns, [
            try XCTUnwrap(hiddenLeft.id): .alert(.waiting), try XCTUnwrap(focused.id): .working,
            try XCTUnwrap(shownRight.id): .alert(.waiting)
        ])
        XCTAssertEqual(plan.left, AgentLightPlan.EdgeAlert(
            signal: .waiting, workspaceID: "ws-0", columnID: hiddenLeft.id, text: "claude needs permission"
        ))
        XCTAssertNil(plan.right, "the column in view lights itself")
        XCTAssertNil(plan.top)
        XCTAssertNil(plan.bottom)
    }

    /// The workspaces above and below glow on the top and bottom edges,
    /// named by their title: the most urgent, then the nearest.
    func testWorkspacesAboveAndBelowGlowOnTheirEdge() {
        let far = workspace(0, "far", [column(0, status: .needsAttention, reason: permission)])
        let near = workspace(1, "near", [column(0, status: .needsAttention, reason: .question(nil))])
        let active = workspace(2, "here", [column(0, focused: true)], isActive: true)
        let broken = workspace(3, "broken", [column(0, status: .needsAttention, reason: .exitedMidTurn)])
        let asking = workspace(4, "asking", [column(0, status: .needsAttention, reason: permission)])
        let done = workspace(5, "done", [column(0, status: .needsAttention, reason: .turnFinished)])

        let plan = AgentLightPlan.make(infos: [far, near, active, broken, asking, done], activeIndex: 2) { _ in true }

        XCTAssertEqual(plan.top?.text, "near has a question", "equally urgent: the nearest")
        XCTAssertEqual(plan.top?.workspaceID, "ws-1")
        XCTAssertEqual(plan.bottom?.text, "asking needs permission", "a wait outranks an error nearer by")
        XCTAssertEqual(plan.bottom?.signal, .waiting)
        XCTAssertNil(plan.left)
        XCTAssertNil(plan.right)

        let quiet = AgentLightPlan.make(infos: [active, done], activeIndex: 2) { _ in true }
        XCTAssertNil(quiet.bottom, "a finished turn doesn't glow")
    }

    func testALongNameIsCutInThePill() {
        let title = String(repeating: "a", count: 40)
        let above = workspace(0, title, [column(0, status: .needsAttention, reason: permission)])
        let active = workspace(1, "here", [column(0, focused: true)], isActive: true)
        let plan = AgentLightPlan.make(infos: [above, active], activeIndex: 1) { _ in true }
        XCTAssertEqual(plan.top?.text, String(repeating: "a", count: AgentLightPlan.nameLimit - 1) + "… needs permission")
    }

    /// Back in the app: what waited is seen, what works goes on.
    func testClearingAlertsKeepsWork() {
        let working = UUID()
        var plan = AgentLightPlan()
        plan.columns = [working: .working, UUID(): .alert(.waiting), UUID(): .alert(.error)]
        plan.top = AgentLightPlan.EdgeAlert(signal: .waiting, workspaceID: "w", columnID: nil, text: "w needs you")
        plan.clearAlerts()
        XCTAssertEqual(plan.columns, [working: .working])
        XCTAssertNil(plan.top)
    }

    // MARK: - Turn ends

    func testATurnThatEndsWithNothingToAskSweepsOnce() {
        let id = UUID()
        var sweeps = TurnEndSweeps()
        XCTAssertEqual(sweeps.update(columns: [column(0, status: .working, id: id)], now: 100), [])
        XCTAssertEqual(sweeps.update(columns: [column(0, status: .working, id: id)], now: 130), [])
        let finished = column(0, status: .needsAttention, reason: .turnFinished, id: id)
        XCTAssertEqual(sweeps.update(columns: [finished], now: 131), [id])
        XCTAssertEqual(sweeps.update(columns: [finished], now: 132), [], "once")
        XCTAssertEqual(sweeps.update(columns: [column(0, id: id)], now: 133), [])
    }

    /// A wait or an error has its own light; a blip of work is no turn; a
    /// column closed while it worked is forgotten.
    func testNoSweepForAWaitABlipOrAClosedColumn() {
        var sweeps = TurnEndSweeps()
        let asking = UUID()
        _ = sweeps.update(columns: [column(0, status: .working, id: asking)], now: 0)
        XCTAssertEqual(
            sweeps.update(columns: [column(0, status: .needsAttention, reason: permission, id: asking)], now: 60), []
        )

        let blip = UUID()
        _ = sweeps.update(columns: [column(0, status: .working, id: blip)], now: 100)
        XCTAssertEqual(sweeps.update(columns: [column(0, id: blip)], now: 100 + TurnEndSweeps.minimumWork - 0.1), [])

        let closed = UUID()
        _ = sweeps.update(columns: [column(0, status: .working, id: closed)], now: 200)
        _ = sweeps.update(columns: [], now: 210)
        XCTAssertEqual(sweeps.update(columns: [column(0, id: closed)], now: 220), [])
    }

    // MARK: - The light's view

    func testALightMovesOnlyWhenAsked() {
        let light = EdgeGlowView(edge: .around)
        light.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        XCTAssertNil(light.light)
        XCTAssertFalse(light.isMoving)

        light.show(.working, moving: false)
        XCTAssertEqual(light.light, .working)
        XCTAssertFalse(light.isMoving, "steady: the state shows without movement")

        light.show(.working, moving: true)
        XCTAssertTrue(light.isMoving)
        XCTAssertEqual(light.movement?.repeatCount, .infinity)

        light.show(.working, moving: false)
        XCTAssertFalse(light.isMoving, "stopped as soon as nobody can see it")
        XCTAssertEqual(light.light, .working)

        light.show(.working, moving: true)
        light.show(nil, moving: true)
        XCTAssertNil(light.light)
        XCTAssertFalse(light.isMoving)
    }

    /// Work breathes slowly, a wait pulses faster: a light that changes
    /// takes the new one's rhythm, and one that doesn't keeps its own.
    func testAChangedLightTakesItsOwnRhythm() throws {
        let light = EdgeGlowView(edge: .around)
        light.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        light.show(.working, moving: true)
        let breath = try XCTUnwrap(light.movement)
        light.show(.working, moving: true)
        XCTAssertEqual(light.movement?.timeOffset, breath.timeOffset, "the same light again restarts nothing")

        light.show(.alert(.waiting), moving: true)
        let pulse = try XCTUnwrap(light.movement)
        XCTAssertEqual(light.light, .alert(.waiting))
        XCTAssertLessThan(pulse.duration, breath.duration)

        light.show(.alert(.waiting), moving: true, soft: true)
        XCTAssertTrue(light.isSoft)
        XCTAssertTrue(light.isMoving)
    }

    func testOnlyAColumnsLightSweeps() {
        let light = EdgeGlowView(edge: .around)
        light.sweep()
        XCTAssertEqual(light.sweepCount, 0, "no size yet: nothing to cross")
        light.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        light.sweep()
        XCTAssertEqual(light.sweepCount, 1)

        let edge = EdgeGlowView(edge: .top)
        edge.frame = NSRect(x: 0, y: 0, width: 400, height: 32)
        edge.sweep()
        XCTAssertEqual(edge.sweepCount, 0)
    }

    // MARK: - The pill

    private func rightEdge(in container: NSView) -> EdgeGlowView {
        let glow = EdgeGlowView(edge: .right)
        glow.frame = NSRect(x: 480, y: 0, width: 320, height: 600)
        container.addSubview(glow)
        return glow
    }

    private func target(_ text: String = "Cookies needs permission", column: UUID? = nil) -> EdgeGlowView.Target {
        EdgeGlowView.Target(workspaceID: "ws", columnID: column, text: text)
    }

    /// The pill names the agent for a few seconds, then leaves the glow
    /// alone; the same agent doesn't bring it back, another one does.
    func testThePillAnnouncesAnAgentThenLeaves() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let glow = rightEdge(in: container)
        // Never by itself during the test.
        glow.pillDuration = 3_600

        glow.show(.alert(.waiting), moving: false, target: target())
        XCTAssertTrue(glow.isPillShown)
        XCTAssertEqual(glow.pillText, "Cookies needs permission →")
        XCTAssertLessThanOrEqual(glow.pillFrame.maxX, glow.bounds.maxX)
        XCTAssertGreaterThan(glow.pillFrame.width, 100)

        glow.endAnnouncement()
        XCTAssertFalse(glow.isPillShown)
        XCTAssertEqual(glow.light, .alert(.waiting), "the glow stays")

        glow.show(.alert(.waiting), moving: false, target: target())
        XCTAssertFalse(glow.isPillShown, "a refresh of the same wait")

        glow.show(.alert(.waiting), moving: false, target: target("claude has a question"))
        XCTAssertTrue(glow.isPillShown)
        XCTAssertEqual(glow.pillText, "claude has a question →")

        glow.show(nil, moving: false)
        XCTAssertFalse(glow.isPillShown)
        XCTAssertNil(glow.target)
    }

    func testThePillLeavesByItselfAfterItsTime() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let glow = rightEdge(in: container)
        glow.pillDuration = 0.05
        glow.show(.alert(.waiting), moving: false, target: target())
        XCTAssertTrue(glow.isPillShown)
        let deadline = Date().addingTimeInterval(10)
        while glow.isPillShown, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertFalse(glow.isPillShown)
    }

    private func pointerEvent(_ type: NSEvent.EventType) throws -> NSEvent {
        try XCTUnwrap(NSEvent.enterExitEvent(
            with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 0, trackingNumber: 0, userData: nil
        ))
    }

    /// The pointer over the glow brings the pill back, and keeps it past
    /// its first seconds.
    func testThePointerOverTheGlowBringsThePillBack() throws {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let glow = rightEdge(in: container)
        glow.pillDuration = 3_600
        glow.show(.alert(.waiting), moving: false, target: target())
        glow.endAnnouncement()
        XCTAssertFalse(glow.isPillShown)

        glow.mouseEntered(with: try pointerEvent(.mouseEntered))
        XCTAssertTrue(glow.isPillShown)
        glow.mouseExited(with: try pointerEvent(.mouseExited))
        XCTAssertFalse(glow.isPillShown)

        // During its first seconds the pointer leaving changes nothing,
        // and the pointer staying keeps it.
        glow.show(.alert(.error), moving: false, target: target("claude exited mid-turn"))
        glow.mouseEntered(with: try pointerEvent(.mouseEntered))
        glow.mouseExited(with: try pointerEvent(.mouseExited))
        XCTAssertTrue(glow.isPillShown)
        glow.mouseEntered(with: try pointerEvent(.mouseEntered))
        glow.endAnnouncement()
        XCTAssertTrue(glow.isPillShown, "the pointer is on the glow")
    }

    /// The glow is decoration over headers and terminals, but for the pill
    /// while it shows and the edge itself: a click there goes to the agent.
    func testOnlyThePillAndTheEdgeTakeClicks() throws {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let glow = rightEdge(in: container)
        glow.pillDuration = 3_600
        var clicked: [EdgeGlowView.Target] = []
        glow.onClick = { clicked.append($0) }
        let onEdge = NSPoint(x: 797, y: 40)
        let inGlow = NSPoint(x: 780, y: 40)

        glow.show(.alert(.waiting), moving: false)
        XCTAssertNil(glow.hitTest(onEdge), "no agent to go to")

        let agent = target(column: UUID())
        glow.show(.alert(.waiting), moving: false, target: agent)
        let onPill = NSPoint(x: glow.frame.minX + glow.pillFrame.midX, y: glow.frame.minY + glow.pillFrame.midY)
        XCTAssertTrue(glow.hitTest(onEdge) === glow)
        XCTAssertTrue(glow.hitTest(onPill) === glow)
        XCTAssertNil(glow.hitTest(inGlow), "the rest of the glow lets clicks through")
        XCTAssertNil(glow.hitTest(NSPoint(x: 500, y: 300)), "and so does the room kept for the pill")

        glow.endAnnouncement()
        XCTAssertNil(glow.hitTest(onPill), "a pill that left takes nothing")
        XCTAssertTrue(glow.hitTest(onEdge) === glow)

        glow.mouseDown(with: try pointerEvent(.mouseEntered))
        XCTAssertEqual(clicked, [agent])
        XCTAssertTrue(glow.accessibilityPerformPress())
        XCTAssertEqual(clicked, [agent, agent])
        XCTAssertEqual(glow.accessibilityLabel(), "Cookies needs permission")

        let columnLight = EdgeGlowView(edge: .around)
        columnLight.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        container.addSubview(columnLight)
        columnLight.show(.alert(.waiting), moving: false)
        XCTAssertNil(columnLight.hitTest(NSPoint(x: 1, y: 150)), "a column's light takes no click")
    }
}

/// The lights in a window: when they may move, the turn end's sweep, the
/// way back from an edge, and the setting.
@MainActor
final class AgentLightShellTests: XCTestCase {
    private func withShell(_ body: (NiruxShellView, String) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nirux-lights-\(UUID().uuidString)").path
        let stateDirectory = root + "/state"
        let folder = root + "/work"
        for path in [stateDirectory, folder] {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
        let previousStateDirectory = ProcessInfo.processInfo.environment["NIRUX_STATE_DIR"]
        setenv("NIRUX_STATE_DIR", stateDirectory, 1)
        defer {
            if let previousStateDirectory {
                setenv("NIRUX_STATE_DIR", previousStateDirectory, 1)
            } else {
                unsetenv("NIRUX_STATE_DIR")
            }
            try? FileManager.default.removeItem(atPath: root)
        }

        _ = NSApplication.shared
        try autoreleasepool {
            let shell = NiruxShellView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
            shell.stopHeartbeat()
            // Whatever the machine: a window in view, motion not reduced.
            shell.sideEffects.windowShows = { _ in true }
            shell.sideEffects.reducesMotion = { false }
            shell.agentLights.isDisplayAsleep = false
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = shell
            defer { window.close() }
            try body(shell, folder)
        }
    }

    /// Four columns in the first workspace, each 0.4 of the viewport: from
    /// the first one, three show and the last is out of the viewport; from
    /// the last one, the first is.
    private func fourColumns(in shell: NiruxShellView) throws -> WorkspaceState {
        let workspace = try XCTUnwrap(shell.activeWorkspace)
        for _ in 0..<3 { workspace.addColumn() }
        for column in workspace.columns { column.widthFraction = 0.4 }
        workspace.focusedIndex = 0
        shell.relayout(animated: false)
        XCTAssertEqual(workspace.columns.count, 4)
        return workspace
    }

    private func info(_ workspace: WorkspaceState, index: Int, in shell: NiruxShellView, statuses: [AgentStatus],
                      reasons: [Int: AgentAttentionReason] = [:]) -> WorkspaceInfo {
        let isActive = shell.activeWorkspace === workspace
        let columns = workspace.columns.enumerated().map { offset, column in
            ColumnInfo(
                index: offset, processName: "claude", abbreviatedCwd: nil,
                isFocused: isActive && offset == workspace.focusedIndex, isWebView: false, webTitle: nil,
                terminalTitle: nil, agentStatus: statuses[offset], isEditor: false, editorFileName: nil,
                attentionReason: reasons[offset], id: column.id
            )
        }
        return WorkspaceInfo(
            id: workspace.id, index: index, title: workspace.title, profileID: workspace.profileID, isInactive: false,
            columnCount: columns.count, focusedColumn: workspace.focusedIndex, gitBranch: nil, notification: nil,
            isActive: isActive, columns: columns, prInfo: nil, diffStats: nil, purpose: nil, nextStep: nil,
            blocker: nil, phase: .active, lastSummary: nil, lastActivityAt: nil
        )
    }

    /// Lights breathe for the columns in the viewport of the workspace on
    /// screen, and only while someone can see them move.
    func testLightsMoveOnlyWhereAndWhenTheyAreSeen() throws {
        try withShell { shell, _ in
            let workspace = try fourColumns(in: shell)
            let working = Array(repeating: AgentStatus.working, count: 4)
            shell.updateAgentLights(infos: [info(workspace, index: 0, in: shell, statuses: working)])

            let lights = try workspace.columns.map { try XCTUnwrap($0.light) }
            XCTAssertEqual(lights.map(\.light), Array(repeating: .working, count: 4))
            XCTAssertEqual(lights.map(\.isMoving), [true, true, true, false], "the last one is out of the viewport")
            XCTAssertEqual(lights.map(\.isSoft), [true, false, false, false], "softer on the focused column")
            XCTAssertEqual(lights[1].frame, workspace.columns[1].view.frame)
            XCTAssertTrue(lights[1].superview === workspace.columns[1].view.superview, "over the column, not inside it")

            // Each of these stops every light, and gives the movement back.
            let conditions: [(String, (Bool) -> Void)] = [
                ("the window is covered", { on in shell.sideEffects.windowShows = { _ in !on } }),
                ("macOS reduces motion", { on in shell.sideEffects.reducesMotion = { on } }),
                ("the display sleeps", { on in shell.agentLights.isDisplayAsleep = on })
            ]
            for (name, set) in conditions {
                set(true)
                shell.applyAgentLights()
                XCTAssertEqual(lights.map(\.isMoving), [false, false, false, false], name)
                XCTAssertEqual(lights.map(\.light), Array(repeating: .working, count: 4), "\(name): the state still shows")
                set(false)
                shell.applyAgentLights()
                XCTAssertEqual(lights.map(\.isMoving), [true, true, true, false], name)
            }

            shell.animatesInterface = false
            XCTAssertEqual(lights.map(\.isMoving), [false, false, false, false], "the setting applies at once")
            XCTAssertFalse(shell.columnIndicator.pulses)
            shell.animatesInterface = true
            XCTAssertEqual(lights.map(\.isMoving), [true, true, true, false])
            XCTAssertTrue(shell.columnIndicator.pulses)

            // Scrolled into view: it moves, and the one scrolled out stops.
            // (Focusing refreshes the sidebar from the real columns, which
            // run no agent: the lights are given again.)
            shell.focusColumnByIndex(3)
            shell.updateAgentLights(infos: [info(workspace, index: 0, in: shell, statuses: working)])
            XCTAssertEqual(lights.map(\.isMoving), [false, true, true, true])
            XCTAssertEqual(lights.map(\.isSoft), [false, false, false, true])
        }
    }

    /// A workspace that isn't on screen keeps its lights still.
    func testAnotherWorkspacesLightsStayStill() throws {
        try withShell { shell, folder in
            let first = try XCTUnwrap(shell.activeWorkspace)
            shell.addWorkspace(title: "second", cwd: folder)
            let second = try XCTUnwrap(shell.activeWorkspace)
            XCTAssertFalse(first === second)
            shell.updateAgentLights(infos: [
                info(first, index: 0, in: shell, statuses: [.working]),
                info(second, index: 1, in: shell, statuses: [.working])
            ])
            XCTAssertEqual(first.columns[0].light?.light, .working)
            XCTAssertEqual(first.columns[0].light?.isMoving, false)
            XCTAssertEqual(second.columns[0].light?.isMoving, true)

            // (A switch refreshes the sidebar from the real columns, which
            // run no agent: the lights are given again.)
            shell.switchToWorkspace(0)
            shell.updateAgentLights(infos: [
                info(first, index: 0, in: shell, statuses: [.working]),
                info(second, index: 1, in: shell, statuses: [.working])
            ])
            XCTAssertEqual(first.columns[0].light?.isMoving, true)
            XCTAssertEqual(second.columns[0].light?.isMoving, false)
        }
    }

    /// A turn that ends sweeps its column once, if the column is in view
    /// and lights may move.
    func testATurnEndSweepsTheColumnInView() throws {
        try withShell { shell, _ in
            let workspace = try fourColumns(in: shell)
            let working = Array(repeating: AgentStatus.working, count: 4)
            shell.updateAgentLights(infos: [info(workspace, index: 0, in: shell, statuses: working)], now: 0)
            shell.updateAgentLights(
                infos: [info(workspace, index: 0, in: shell, statuses: [.idle, .working, .working, .idle])], now: 10
            )
            XCTAssertEqual(workspace.columns[0].light?.sweepCount, 1)
            XCTAssertNil(workspace.columns[0].light?.light, "then nothing")
            XCTAssertEqual(workspace.columns[1].light?.sweepCount, 0, "still working")
            XCTAssertEqual(workspace.columns[3].light?.sweepCount, 0, "out of view")

            shell.sideEffects.reducesMotion = { true }
            shell.updateAgentLights(
                infos: [info(workspace, index: 0, in: shell, statuses: [.idle, .idle, .working, .idle])], now: 20
            )
            XCTAssertEqual(workspace.columns[1].light?.sweepCount, 0, "no sweep while motion is reduced")
            XCTAssertNil(workspace.columns[1].light?.light)
        }
    }

    /// A column scrolled out that waits: its side's edge glows and names
    /// it, and a click there goes to it. Back in the app, the waits' lights
    /// go at once and work stays lit.
    func testTheEdgeNamesAnAgentOutOfViewAndGoesToIt() throws {
        try withShell { shell, _ in
            let workspace = try fourColumns(in: shell)
            let permission = AgentAttentionReason.permission(tool: "Bash", summary: "git push")
            shell.updateAgentLights(infos: [info(
                workspace, index: 0, in: shell, statuses: [.working, .needsAttention, .idle, .needsAttention],
                reasons: [1: permission, 3: permission]
            )])

            XCTAssertEqual(workspace.columns[1].light?.light, .alert(.waiting), "in view: it pulses itself")
            XCTAssertEqual(shell.edgeGlowRight.light, .alert(.waiting))
            XCTAssertEqual(shell.edgeGlowRight.target?.columnID, workspace.columns[3].id, "the one out of view")
            XCTAssertEqual(shell.edgeGlowRight.pillText, "claude needs permission →")
            XCTAssertTrue(shell.edgeGlowRight.isMoving)
            XCTAssertNil(shell.edgeGlowLeft.light)
            XCTAssertGreaterThan(shell.edgeGlowRight.frame.width, shell.edgeGlowRight.pillFrame.width)

            shell.edgeGlowRight.mouseDown(with: try XCTUnwrap(NSEvent.enterExitEvent(
                with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                eventNumber: 0, trackingNumber: 0, userData: nil
            )))
            XCTAssertEqual(workspace.focusedIndex, 3)

            // (The click refreshed the sidebar from the real columns, which
            // run no agent: the lights are given again, with a workspace
            // below that waits.)
            shell.updateAgentLights(infos: [
                info(
                    workspace, index: 0, in: shell, statuses: [.working, .needsAttention, .idle, .idle],
                    reasons: [1: permission]
                ),
                WorkspaceInfo(
                    id: "below", index: 1, title: "below", profileID: workspace.profileID, isInactive: false,
                    columnCount: 1, focusedColumn: 0, gitBranch: nil, notification: nil, isActive: false,
                    columns: [ColumnInfo(
                        index: 0, processName: "claude", abbreviatedCwd: nil, isFocused: false, isWebView: false,
                        webTitle: nil, terminalTitle: nil, agentStatus: .needsAttention, isEditor: false,
                        editorFileName: nil, attentionReason: permission, id: UUID()
                    )],
                    prInfo: nil, diffStats: nil, purpose: nil, nextStep: nil, blocker: nil, phase: .active,
                    lastSummary: nil, lastActivityAt: nil
                )
            ])
            XCTAssertEqual(workspace.columns[1].light?.light, .alert(.waiting))
            XCTAssertEqual(shell.edgeGlowBottom.pillText, "↓ below needs permission")

            shell.clearAgentAlertLights()
            XCTAssertNil(workspace.columns[1].light?.light)
            XCTAssertNil(shell.edgeGlowBottom.light)
            XCTAssertEqual(workspace.columns[0].light?.light, .working)
        }
    }

    /// A closing column gives its light up, and a closed one takes it away.
    func testAClosedColumnTakesItsLightAway() throws {
        try withShell { shell, _ in
            let workspace = try fourColumns(in: shell)
            let working = Array(repeating: AgentStatus.working, count: 4)
            let infos = [info(workspace, index: 0, in: shell, statuses: working)]
            shell.updateAgentLights(infos: infos)
            let closing = workspace.columns[1]
            let light = try XCTUnwrap(closing.light)
            closing.isClosing = true
            shell.applyAgentLights()
            XCTAssertNil(light.light)

            workspace.closeColumn(at: 1)
            XCTAssertNil(light.superview)
        }
    }

    func testTheSettingDefaultsToOnAndIsSaved() throws {
        let older = try JSONDecoder().decode(PersistedSettings.self, from: Data("{}".utf8))
        XCTAssertTrue(older.animatesInterface)
        XCTAssertTrue(PersistedSettings().animatesInterface)

        var off = PersistedSettings()
        off.animatesInterface = false
        let decoded = try JSONDecoder().decode(PersistedSettings.self, from: JSONEncoder().encode(off))
        XCTAssertFalse(decoded.animatesInterface)
    }
}
