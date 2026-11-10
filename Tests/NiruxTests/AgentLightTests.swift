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
        process: String = "claude", id: UUID = UUID(), turnEndedAt: TimeInterval = 0
    ) -> ColumnInfo {
        ColumnInfo(
            index: index, processName: process, abbreviatedCwd: nil, isFocused: focused, isWebView: false,
            webTitle: nil, terminalTitle: nil, agentStatus: status, isEditor: false, editorFileName: nil,
            attentionReason: reason, id: id, turnEndedAt: turnEndedAt
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

    /// A wait or an error first, then work; a finished turn shows nothing.
    /// The focused column lights up like the others: its dialog still waits
    /// while the user is in another app.
    func testAColumnsLightFollowsItsAgent() {
        XCTAssertEqual(AgentLightPlan.light(of: column(0, status: .working)), .working)
        XCTAssertEqual(AgentLightPlan.light(of: column(0, status: .working, focused: true)), .working)
        XCTAssertEqual(AgentLightPlan.light(of: column(0, status: .needsAttention, reason: permission)), .alert(.waiting))
        XCTAssertEqual(
            AgentLightPlan.light(of: column(0, status: .needsAttention, reason: .apiError(kind: nil, detail: nil))),
            .alert(.error)
        )
        var dialog = column(0, focused: true)
        dialog.openDialog = permission
        XCTAssertEqual(AgentLightPlan.light(of: dialog), .alert(.waiting), "its dialog is open, whoever looks")
        XCTAssertNil(AgentLightPlan.light(of: column(0, status: .needsAttention, reason: .turnFinished)))
        XCTAssertNil(AgentLightPlan.light(of: column(0)))
        XCTAssertNil(AgentLightPlan.light(of: column(0, focused: true)))
    }

    /// A waiting column the viewport shows pulses itself: the edge glows
    /// only for those scrolled out, on their side, and names the nearest.
    func testEdgesGlowOnlyForColumnsOutOfView() throws {
        let farLeft = column(0, status: .needsAttention, reason: permission, process: "codex")
        let nearLeft = column(1, status: .needsAttention, reason: permission)
        let focused = column(2, status: .working, focused: true)
        let shownRight = column(3, status: .needsAttention, reason: .question("Which one?"))
        let active = workspace(0, "checkout", [farLeft, nearLeft, focused, shownRight], focusedColumn: 2, isActive: true)

        let plan = AgentLightPlan.make(infos: [active], activeIndex: 0) { $0.index >= 2 }

        XCTAssertEqual(plan.columns, [
            try XCTUnwrap(farLeft.id): .alert(.waiting), try XCTUnwrap(nearLeft.id): .alert(.waiting),
            try XCTUnwrap(focused.id): .working, try XCTUnwrap(shownRight.id): .alert(.waiting)
        ])
        XCTAssertEqual(plan.left, AgentLightPlan.EdgeAlert(
            signal: .waiting, workspaceID: "ws-0", columnID: nearLeft.id, text: "claude needs permission"
        ))
        XCTAssertNil(plan.right, "the column in view lights itself")
        XCTAssertNil(plan.top)
        XCTAssertNil(plan.bottom)
        XCTAssertEqual(plan.edgeAlerts, [try XCTUnwrap(plan.left)])
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

    /// Back in the app: the columns' waits are seen, work goes on, and the
    /// edges keep what they show until the next refresh.
    func testClearingColumnAlertsKeepsWorkAndTheEdges() {
        let working = UUID()
        let edge = AgentLightPlan.EdgeAlert(signal: .waiting, workspaceID: "w", columnID: nil, text: "w needs you")
        var plan = AgentLightPlan()
        plan.columns = [working: .working, UUID(): .alert(.waiting), UUID(): .alert(.error)]
        plan.top = edge
        plan.clearColumnAlerts()
        XCTAssertEqual(plan.columns, [working: .working])
        XCTAssertEqual(plan.top, edge)
    }

    // MARK: - Turn ends

    func testAReportedTurnEndSweepsOnce() {
        let id = UUID()
        var sweeps = TurnEndSweeps()
        XCTAssertEqual(sweeps.update(columns: [column(0, status: .working, id: id)]), [])
        let finished = column(0, status: .needsAttention, reason: .turnFinished, id: id, turnEndedAt: 50)
        XCTAssertEqual(sweeps.update(columns: [finished]), [id])
        XCTAssertEqual(sweeps.update(columns: [finished]), [], "once")

        XCTAssertEqual(sweeps.update(columns: [column(0, status: .working, id: id, turnEndedAt: 50)]), [])
        XCTAssertEqual(sweeps.update(columns: [column(0, id: id, turnEndedAt: 90)]), [id], "the next turn's end")
    }

    /// Silence or a dead agent reports no end; a wait or an error has its
    /// own light; work that goes on is no end; a column seen for the first
    /// time ended nothing in front of the user.
    func testNoSweepWithoutAReportedEndOrWithSomethingToAsk() {
        var sweeps = TurnEndSweeps()
        let silent = UUID()
        _ = sweeps.update(columns: [column(0, status: .working, id: silent)])
        XCTAssertEqual(sweeps.update(columns: [column(0, id: silent)]), [], "it stopped without saying so")

        let asking = UUID()
        _ = sweeps.update(columns: [column(0, status: .working, id: asking)])
        XCTAssertEqual(
            sweeps.update(columns: [column(0, status: .needsAttention, reason: permission, id: asking, turnEndedAt: 10)]), []
        )

        let busy = UUID()
        _ = sweeps.update(columns: [column(0, status: .working, id: busy)])
        XCTAssertEqual(sweeps.update(columns: [column(0, status: .working, id: busy, turnEndedAt: 20)]), [])
        XCTAssertEqual(sweeps.update(columns: [column(0, id: busy, turnEndedAt: 20)]), [], "that end is past")

        XCTAssertEqual(sweeps.update(columns: [column(0, id: UUID(), turnEndedAt: 30)]), [], "first seen")
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

    /// The ring lies on the column's edge, where the terminal's padding
    /// is; on the focused column it lies inside the focus ring, which
    /// keeps its own color. The glow never reaches far over the cells.
    func testTheLightStaysOnTheEdgeAndInsideTheFocusRing() {
        let light = EdgeGlowView(edge: .around)
        light.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        light.show(.working, moving: false)
        XCTAssertEqual(light.ringFrame, light.bounds)
        XCTAssertEqual(Set(light.glowFrames.map { min($0.width, $0.height) }), [EdgeGlowView.columnGlowDepth])

        light.show(.working, moving: false, soft: true)
        let inside = light.bounds.insetBy(dx: EdgeGlowView.focusRingWidth, dy: EdgeGlowView.focusRingWidth)
        XCTAssertEqual(light.ringFrame, inside)
        XCTAssertTrue(light.glowFrames.allSatisfy { inside.contains($0) }, "nothing over the focus ring")

        light.show(.working, moving: false)
        XCTAssertEqual(light.ringFrame, light.bounds, "focus moved on")
    }

    /// The ring is as wide as the padding every terminal is given, so it
    /// covers no cell.
    func testTheRingIsAsWideAsTheTerminalsPadding() {
        let padding = Int(EdgeGlowView.ringWidth)
        XCTAssertEqual(CGFloat(padding), EdgeGlowView.ringWidth)
        XCTAssertTrue(TerminalConfigBuilder.enforced.contains("window-padding-x = \(padding)"))
        XCTAssertTrue(TerminalConfigBuilder.enforced.contains("window-padding-y = \(padding)"))
    }

    /// A viewport edge's glow is a bar on the padding: it stops before the
    /// text, however much room the view keeps for its pill.
    func testAnEdgesGlowStopsBeforeTheText() {
        let right = EdgeGlowView(edge: .right)
        right.frame = NSRect(x: 0, y: 0, width: 320, height: 600)
        XCTAssertEqual(right.glowFrames, [NSRect(x: 312, y: 0, width: 8, height: 600)])
        let bottom = EdgeGlowView(edge: .bottom)
        bottom.frame = NSRect(x: 0, y: 0, width: 900, height: 56)
        XCTAssertEqual(bottom.glowFrames, [NSRect(x: 0, y: 0, width: 900, height: 8)])
    }

    func testOnlyAColumnsLightSweeps() {
        let light = EdgeGlowView(edge: .around)
        light.sweep()
        XCTAssertFalse(light.isSweeping, "no size yet: nothing to cross")
        light.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        light.sweep()
        XCTAssertTrue(light.isSweeping)

        let edge = EdgeGlowView(edge: .top)
        edge.frame = NSRect(x: 0, y: 0, width: 400, height: 32)
        edge.sweep()
        XCTAssertFalse(edge.isSweeping)
    }

    // MARK: - The pill

    private func edgeGlow(_ edge: EdgeGlowView.Edge, frame: NSRect, in container: NSView) -> EdgeGlowView {
        let glow = EdgeGlowView(edge: edge)
        glow.frame = frame
        // Never by itself during a test.
        glow.pillDuration = 3_600
        container.addSubview(glow)
        return glow
    }

    private func rightEdge(in container: NSView) -> EdgeGlowView {
        edgeGlow(.right, frame: NSRect(x: 480, y: 0, width: 320, height: 600), in: container)
    }

    private func target(_ text: String = "Cookies needs permission", column: UUID? = nil) -> EdgeGlowView.Target {
        EdgeGlowView.Target(workspaceID: "ws", columnID: column, text: text)
    }

    /// The pill names the agent for a few seconds, then leaves the glow
    /// alone. It shows when its owner announces the agent, not at each
    /// refresh of the same wait; an agent that isn't announced waits for
    /// the pointer.
    func testThePillAnnouncesAnAgentThenLeaves() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let glow = rightEdge(in: container)

        glow.show(.alert(.waiting), moving: false, target: target(), announcing: true)
        XCTAssertTrue(glow.isPillShown)
        XCTAssertEqual(glow.pillText, "Cookies needs permission →")
        XCTAssertLessThanOrEqual(glow.pillFrame.maxX, glow.bounds.maxX)
        XCTAssertGreaterThan(glow.pillFrame.width, 100)

        glow.show(.alert(.waiting), moving: false, target: target())
        XCTAssertTrue(glow.isPillShown, "a refresh during its first seconds leaves it")
        glow.endAnnouncement()
        XCTAssertFalse(glow.isPillShown)
        XCTAssertEqual(glow.light, .alert(.waiting), "the glow stays")
        glow.show(.alert(.waiting), moving: false, target: target())
        XCTAssertFalse(glow.isPillShown, "a refresh of the same wait")

        glow.show(.alert(.waiting), moving: false, target: target("claude has a question"))
        XCTAssertFalse(glow.isPillShown, "not announced: its name waits for the pointer")
        XCTAssertEqual(glow.pillText, "claude has a question →")
        XCTAssertEqual(glow.accessibilityLabel(), "claude has a question")

        glow.show(.alert(.waiting), moving: false, target: target("claude has a question"), announcing: true)
        XCTAssertTrue(glow.isPillShown)
        glow.show(.alert(.waiting), moving: false, target: target("codex needs permission"))
        XCTAssertFalse(glow.isPillShown, "another agent's name doesn't ride on the first one's seconds")

        glow.show(nil, moving: false)
        XCTAssertFalse(glow.isPillShown)
        XCTAssertNil(glow.target)
        XCTAssertFalse(glow.isAccessibilityElement())
    }

    func testThePillLeavesByItselfAfterItsTime() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let glow = rightEdge(in: container)
        glow.pillDuration = 0.05
        glow.show(.alert(.waiting), moving: false, target: target(), announcing: true)
        XCTAssertTrue(glow.isPillShown)
        let deadline = Date().addingTimeInterval(10)
        while glow.isPillShown, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertFalse(glow.isPillShown)
    }

    /// The pointer near the glow brings the pill back, and the pill stays
    /// while the pointer travels onto it: on every edge it lies within
    /// reach of the strip that brought it.
    func testThePointerBringsThePillBackAndReachesIt() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1_000, height: 700))
        let frames: [(EdgeGlowView.Edge, NSRect)] = [
            (.left, NSRect(x: 0, y: 0, width: 320, height: 700)), (.right, NSRect(x: 680, y: 0, width: 320, height: 700)),
            (.top, NSRect(x: 0, y: 668, width: 1_000, height: 32)), (.bottom, NSRect(x: 0, y: 0, width: 1_000, height: 56))
        ]
        for (edge, frame) in frames {
            let glow = edgeGlow(edge, frame: frame, in: container)
            glow.show(.alert(.waiting), moving: false, target: target())
            XCTAssertFalse(glow.isPillShown)
            // On the edge's strip, and off both the strip and the pill.
            let onStrip: NSPoint
            let away: NSPoint
            switch edge {
            case .left: (onStrip, away) = (NSPoint(x: 3, y: 40), NSPoint(x: 300, y: 40))
            case .right: (onStrip, away) = (NSPoint(x: frame.width - 3, y: 40), NSPoint(x: 20, y: 40))
            case .top: (onStrip, away) = (NSPoint(x: 40, y: frame.height - 3), NSPoint(x: 40, y: 1))
            default: (onStrip, away) = (NSPoint(x: 40, y: 3), NSPoint(x: 40, y: 52))
            }
            XCTAssertFalse(glow.hoverStrip.contains(away) || glow.pillFrame.contains(away), "\(edge)")
            XCTAssertTrue(glow.hoverStrip.intersects(glow.pillFrame), "\(edge): no gap to cross on the way to the pill")

            glow.pointerMoved(to: onStrip)
            XCTAssertTrue(glow.isPillShown, "\(edge)")
            // Onto the pill's far end, out of the strip.
            let farEnd: NSPoint
            switch edge {
            case .left: farEnd = NSPoint(x: glow.pillFrame.maxX - 2, y: glow.pillFrame.midY)
            case .right: farEnd = NSPoint(x: glow.pillFrame.minX + 2, y: glow.pillFrame.midY)
            case .top: farEnd = NSPoint(x: glow.pillFrame.midX, y: glow.pillFrame.minY + 1)
            default: farEnd = NSPoint(x: glow.pillFrame.midX, y: glow.pillFrame.maxY - 1)
            }
            if edge != .top { XCTAssertFalse(glow.hoverStrip.contains(farEnd), "\(edge)") }
            glow.pointerMoved(to: farEnd)
            XCTAssertTrue(glow.isPillShown, "\(edge): it stays under the pointer")
            XCTAssertTrue(glow.hitTest(glow.convert(farEnd, to: container)) === glow, "\(edge): and takes the click")

            glow.pointerMoved(to: away)
            XCTAssertFalse(glow.isPillShown, "\(edge): the pointer left")
            // Where the pill was is no way back in.
            glow.pointerMoved(to: farEnd)
            if edge != .top { XCTAssertFalse(glow.isPillShown, "\(edge)") }
        }
    }

    /// During its first seconds the pointer leaving changes nothing, and
    /// the pointer staying keeps the pill past them.
    func testThePointerKeepsThePillPastItsFirstSeconds() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let glow = rightEdge(in: container)
        glow.show(.alert(.error), moving: false, target: target("claude exited mid-turn"), announcing: true)
        glow.pointerMoved(to: NSPoint(x: 317, y: 40))
        glow.pointerMoved(to: NSPoint(x: 100, y: 40))
        XCTAssertTrue(glow.isPillShown, "still announcing")
        glow.pointerMoved(to: NSPoint(x: 317, y: 40))
        glow.endAnnouncement()
        XCTAssertTrue(glow.isPillShown, "the pointer is on the glow")
        glow.pointerMoved(to: NSPoint(x: 100, y: 40))
        XCTAssertFalse(glow.isPillShown)
    }

    /// The glow is decoration over headers, terminals and the resize
    /// handle at the viewport's edge: only its pill, while it shows, takes
    /// a click, which goes to the agent.
    func testOnlyAShownPillTakesClicks() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let glow = rightEdge(in: container)
        var clicked: [EdgeGlowView.Target] = []
        glow.onClick = { clicked.append($0) }
        let onEdge = NSPoint(x: 797, y: 40)
        let agent = target(column: UUID())

        glow.show(.alert(.waiting), moving: false, target: agent, announcing: true)
        let onPill = NSPoint(x: glow.frame.minX + glow.pillFrame.midX, y: glow.frame.minY + glow.pillFrame.midY)
        XCTAssertTrue(glow.hitTest(onPill) === glow)
        XCTAssertNil(glow.hitTest(onEdge), "the edge keeps its resize handle and its text")
        XCTAssertNil(glow.hitTest(NSPoint(x: 500, y: 300)), "and so does the room kept for the pill")

        glow.endAnnouncement()
        XCTAssertNil(glow.hitTest(onPill), "a pill that left takes nothing")

        XCTAssertTrue(glow.accessibilityPerformPress())
        XCTAssertEqual(clicked, [agent])

        let columnLight = EdgeGlowView(edge: .around)
        columnLight.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        container.addSubview(columnLight)
        columnLight.show(.alert(.waiting), moving: false)
        XCTAssertNil(columnLight.hitTest(NSPoint(x: 1, y: 150)), "a column's light takes no click")
    }

    // MARK: - The other dots that move

    /// A waiting column's ring among the column dots pulses or stands
    /// still at once, and an empty space keeps none.
    func testTheColumnDotsRingFollowsPulses() throws {
        let indicator = ColumnIndicatorView(frame: NSRect(x: 0, y: 0, width: 300, height: 16))
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 300, pixelsHigh: 16, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let draw = {
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSGraphicsContext.current = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
            indicator.draw(indicator.bounds)
        }
        indicator.update(columnCount: 3, focusedIndex: 0, columnSignals: [nil, .waiting, .finished])
        try draw()
        XCTAssertEqual(indicator.pulsingRings, [true], "one ring, for the wait")

        indicator.pulses = false
        XCTAssertEqual(indicator.pulsingRings, [false], "at once, without waiting for a draw")
        try draw()
        XCTAssertEqual(indicator.pulsingRings, [false])
        indicator.pulses = true
        XCTAssertEqual(indicator.pulsingRings, [true])

        indicator.update(columnCount: 0, focusedIndex: 0)
        try draw()
        XCTAssertEqual(indicator.pulsingRings, [], "an empty space keeps no ring")
    }

    /// The header's working dot and the row's breathe only while
    /// animations may run.
    func testTheWorkingDotsFollowAnimates() throws {
        try XCTSkipIf(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, "this Mac reduces motion")
        let pill = ColumnStatusPill(frame: NSRect(x: 0, y: 0, width: 120, height: ColumnStatusPill.height))
        pill.status = ColumnHeaderView.Status("working", tone: .working)
        XCTAssertTrue(pill.isBreathing)
        pill.animates = false
        XCTAssertFalse(pill.isBreathing)
        pill.animates = true
        XCTAssertTrue(pill.isBreathing)

        let row = workspace(0, "checkout", [column(0, status: .working)])
        let breathingDots = { (animates: Bool) in
            SidebarWorkspaceCardRenderer(workspace: row, sidebarWidth: 260, yOffset: 500, animates: animates).render()
                .views.filter { $0.layer?.animation(forKey: "breathe") != nil }.count
        }
        XCTAssertEqual(breathingDots(true), 1)
        XCTAssertEqual(breathingDots(false), 0)
    }
}

/// The lights in a window: when they may move, the turn end's sweep, the
/// way back from an edge, and the setting.
@MainActor
final class AgentLightShellTests: XCTestCase {
    private func withShell(
        reducesMotion: Bool = false, _ body: (NiruxShellView, NSWindow, String) throws -> Void
    ) throws {
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
            // Whatever the machine: a window in view, a display awake.
            shell.sideEffects.windowShows = { _ in true }
            shell.sideEffects.reducesMotion = { reducesMotion }
            shell.agentLights.isDisplayAsleep = false
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = shell
            defer { window.close() }
            try body(shell, window, folder)
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

    private let permission = AgentAttentionReason.permission(tool: "Bash", summary: "git push")

    /// Lights breathe for the columns in the viewport of the workspace on
    /// screen, and only while someone can see them move: each thing that
    /// hides the window, or asks for stillness, stops them all by itself.
    func testLightsMoveOnlyWhereAndWhenTheyAreSeen() throws {
        try withShell { shell, window, _ in
            let workspace = try fourColumns(in: shell)
            let working = Array(repeating: AgentStatus.working, count: 4)
            shell.updateAgentLights(infos: [info(workspace, index: 0, in: shell, statuses: working)])

            let lights = try workspace.columns.map { try XCTUnwrap($0.light) }
            XCTAssertEqual(lights.map(\.light), Array(repeating: .working, count: 4))
            XCTAssertEqual(lights.map(\.isMoving), [true, true, true, false], "the last one is out of the viewport")
            XCTAssertEqual(lights.map(\.isSoft), [true, false, false, false], "softer on the focused column")
            XCTAssertEqual(lights[1].frame, workspace.columns[1].view.frame)
            XCTAssertTrue(lights[1].superview === workspace.columns[1].view.superview, "over the column, not inside it")
            XCTAssertTrue(shell.sidebar.animates)
            XCTAssertEqual(
                workspace.columns.map { $0.header?.statusPill.animates }, [true, true, true, false],
                "the headers' dots with them"
            )

            let system = NSWorkspace.shared.notificationCenter
            let conditions: [(String, (Bool) -> Void)] = [
                ("the window is covered", { on in
                    shell.sideEffects.windowShows = { _ in !on }
                    NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
                }),
                ("macOS reduces motion", { on in
                    shell.sideEffects.reducesMotion = { on }
                    system.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
                }),
                ("the display sleeps", { on in
                    system.post(
                        name: on ? NSWorkspace.screensDidSleepNotification : NSWorkspace.screensDidWakeNotification,
                        object: nil
                    )
                }),
                ("another user has the screen", { on in
                    system.post(
                        name: on ? NSWorkspace.sessionDidResignActiveNotification
                            : NSWorkspace.sessionDidBecomeActiveNotification,
                        object: nil
                    )
                }),
                ("animations are off", { on in shell.animatesInterface = !on })
            ]
            for (name, set) in conditions {
                set(true)
                XCTAssertEqual(lights.map(\.isMoving), [false, false, false, false], name)
                XCTAssertEqual(lights.map(\.light), Array(repeating: .working, count: 4), "\(name): the state still shows")
                XCTAssertFalse(shell.columnIndicator.pulses, name)
                XCTAssertFalse(shell.sidebar.animates, name)
                XCTAssertEqual(workspace.columns.map { $0.header?.statusPill.animates }, [false, false, false, false], name)
                set(false)
                XCTAssertEqual(lights.map(\.isMoving), [true, true, true, false], name)
                XCTAssertTrue(shell.columnIndicator.pulses, name)
                XCTAssertTrue(shell.sidebar.animates, name)
            }

            // A layout alone: the column scrolled into view moves, the one
            // scrolled out stops, and the light follows its column.
            workspace.focusedIndex = 3
            workspace.columns[1].widthFraction = 0.5
            shell.relayout(animated: false)
            XCTAssertEqual(lights.map(\.isMoving), [false, true, true, true])
            XCTAssertEqual(lights.map(\.isSoft), [false, false, false, true])
            XCTAssertEqual(lights.map(\.frame), workspace.columns.map(\.view.frame))
        }
    }

    /// A workspace that isn't on screen keeps its lights still.
    func testAnotherWorkspacesLightsStayStill() throws {
        try withShell { shell, _, folder in
            let first = try XCTUnwrap(shell.activeWorkspace)
            shell.addWorkspace(title: "second", cwd: folder)
            let second = try XCTUnwrap(shell.activeWorkspace)
            XCTAssertFalse(first === second)
            let light = {
                shell.updateAgentLights(infos: [
                    self.info(first, index: 0, in: shell, statuses: [.working]),
                    self.info(second, index: 1, in: shell, statuses: [.working])
                ])
            }
            light()
            XCTAssertEqual(first.columns[0].light?.light, .working)
            XCTAssertEqual(first.columns[0].light?.isMoving, false)
            XCTAssertEqual(second.columns[0].light?.isMoving, true)

            // (A switch refreshes the sidebar from the real columns, which
            // run no agent: the lights are given again.)
            shell.switchToWorkspace(0)
            light()
            XCTAssertEqual(first.columns[0].light?.isMoving, true)
            XCTAssertEqual(second.columns[0].light?.isMoving, false)
        }
    }

    private func hook(_ name: AgentHookEvent.Name, on column: ColumnState) throws {
        _ = try XCTUnwrap(column.pty).applyAgentHook(
            AgentHookEvent(kind: .claude, name: name, timestamp: Date().timeIntervalSince1970), isUserFocused: false
        )
    }

    /// Through the sidebar's own refresh: a prompt lights the column, and
    /// the turn's end sweeps it once, then nothing.
    func testAColumnLightsWhileItsAgentWorksAndSweepsAtItsTurnsEnd() throws {
        try withShell { shell, _, _ in
            let column = try XCTUnwrap(shell.activeWorkspace?.columns.first)
            // A process table that can't be read leaves the agent as its
            // hooks say.
            let unread = ProcessSnapshot(entries: [])
            shell.updateSidebar(snapshot: unread)
            XCTAssertNil(column.light)

            try hook(.userPromptSubmit, on: column)
            shell.updateSidebar(snapshot: unread)
            let light = try XCTUnwrap(column.light)
            XCTAssertEqual(light.light, .working)
            XCTAssertTrue(light.isMoving)
            XCTAssertTrue(light.isSoft, "the focused column")
            XCTAssertFalse(light.isSweeping)

            try hook(.stop, on: column)
            shell.updateSidebar(snapshot: unread)
            XCTAssertNil(light.light, "then nothing")
            XCTAssertTrue(light.isSweeping)
        }
    }

    func testNoSweepWhileMotionIsReduced() throws {
        try withShell(reducesMotion: true) { shell, _, _ in
            let column = try XCTUnwrap(shell.activeWorkspace?.columns.first)
            let unread = ProcessSnapshot(entries: [])
            shell.updateSidebar(snapshot: unread)
            try hook(.userPromptSubmit, on: column)
            shell.updateSidebar(snapshot: unread)
            let light = try XCTUnwrap(column.light)
            XCTAssertEqual(light.light, .working)
            XCTAssertFalse(light.isMoving, "steady")

            try hook(.stop, on: column)
            shell.updateSidebar(snapshot: unread)
            XCTAssertNil(light.light)
            XCTAssertFalse(light.isSweeping)
        }
    }

    /// A column scrolled out that waits: its side's edge glows and names
    /// it once, a click on the pill goes to it, and neither a refresh nor
    /// coming back to the app brings the pill back for the same wait.
    func testTheEdgeNamesAnAgentOutOfViewOnce() throws {
        try withShell { shell, _, _ in
            let workspace = try fourColumns(in: shell)
            let glow = shell.edgeGlowRight
            glow.pillDuration = 3_600
            let permission = self.permission
            let refresh = { (waiting: Bool) in
                shell.updateAgentLights(infos: [self.info(
                    workspace, index: 0, in: shell,
                    statuses: [.working, .needsAttention, .idle, waiting ? .needsAttention : .idle],
                    reasons: waiting ? [1: permission, 3: permission] : [1: permission]
                )])
            }
            refresh(true)
            XCTAssertEqual(workspace.columns[1].light?.light, .alert(.waiting), "in view: it pulses itself")
            XCTAssertEqual(glow.light, .alert(.waiting))
            XCTAssertEqual(glow.target?.columnID, workspace.columns[3].id, "the one out of view")
            XCTAssertEqual(glow.pillText, "claude needs permission →")
            XCTAssertTrue(glow.isPillShown)
            XCTAssertTrue(glow.isMoving)
            XCTAssertNil(shell.edgeGlowLeft.light)
            XCTAssertGreaterThan(glow.frame.width, glow.pillFrame.width)

            glow.endAnnouncement()
            refresh(true)
            XCTAssertFalse(glow.isPillShown, "a refresh of the same wait")

            // Back in the app: the column's ring goes, the edge keeps its
            // glow, and the pill stays away.
            shell.clearAgentAlertLights()
            XCTAssertNil(workspace.columns[1].light?.light)
            XCTAssertEqual(workspace.columns[0].light?.light, .working)
            XCTAssertEqual(glow.light, .alert(.waiting))
            refresh(true)
            XCTAssertFalse(glow.isPillShown)
            XCTAssertEqual(workspace.columns[1].light?.light, .alert(.waiting), "its dialog is still open")

            // Answered, then another wait: named again. Not while nobody
            // can see the window: then when it shows.
            refresh(false)
            XCTAssertNil(glow.light)
            shell.sideEffects.windowShows = { _ in false }
            refresh(true)
            XCTAssertEqual(glow.target?.columnID, workspace.columns[3].id)
            XCTAssertFalse(glow.isPillShown)
            shell.sideEffects.windowShows = { _ in true }
            shell.applyAgentLights()
            XCTAssertTrue(glow.isPillShown)

            XCTAssertTrue(glow.accessibilityPerformPress())
            XCTAssertEqual(workspace.focusedIndex, 3)
        }
    }

    /// ⌘W: the column's light leaves as it starts to close, and goes with
    /// it.
    func testAClosingColumnGivesItsLightUp() throws {
        try withShell { shell, _, _ in
            let workspace = try fourColumns(in: shell)
            let working = Array(repeating: AgentStatus.working, count: 4)
            shell.updateAgentLights(infos: [info(workspace, index: 0, in: shell, statuses: working)])
            let light = try XCTUnwrap(workspace.columns[0].light)
            XCTAssertEqual(light.light, .working)

            shell.closeActiveColumn()
            XCTAssertTrue(workspace.columns[0].isClosing)
            XCTAssertNil(light.light, "at once, not at the next refresh")

            workspace.closeColumn(at: 0)
            XCTAssertNil(light.superview)
        }
    }

    func testTheSettingDefaultsToOnAndIsSaved() throws {
        let older = try JSONDecoder().decode(PersistedSettings.self, from: Data("{}".utf8))
        XCTAssertTrue(older.animatesInterface)
        XCTAssertTrue(PersistedSettings().animatesInterface)
        let odd = try JSONDecoder().decode(PersistedSettings.self, from: Data(#"{"animatesInterface": "yes"}"#.utf8))
        XCTAssertTrue(odd.animatesInterface, "a value it can't read doesn't lose the state file")

        var off = PersistedSettings()
        off.animatesInterface = false
        let decoded = try JSONDecoder().decode(PersistedSettings.self, from: JSONEncoder().encode(off))
        XCTAssertFalse(decoded.animatesInterface)
    }
}
