import AppKit
import XCTest
@testable import Nirux

/// An agent's state as light: which columns light up and which edges glow
/// (`AgentLightPlan`), and what the light's view shows and takes
/// (`EdgeGlowView`).
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

        // A title may carry anything: the pill and its label get one clean line.
        let odd = workspace(0, "feat\n\u{202E}login", [column(0, status: .needsAttention, reason: permission)])
        XCTAssertEqual(
            AgentLightPlan.make(infos: [odd, active], activeIndex: 1) { _ in true }.top?.text, "feat login needs permission"
        )
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

    // MARK: - The light's view

    func testALightMovesOnlyWhenAsked() {
        let light = EdgeGlowView(edge: .around)
        light.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        XCTAssertNil(light.light)
        XCTAssertFalse(light.isMoving)

        light.show(.working, moving: false)
        XCTAssertEqual(light.light, .working)
        XCTAssertFalse(light.isMoving, "steady: the state shows without movement")

        XCTAssertEqual(light.steadyLevel, 0.6, "between the breath's two ends")
        XCTAssertFalse(light.blendsAsAGroup, "no column-sized offscreen pass")

        light.show(.working, moving: true)
        XCTAssertTrue(light.isMoving)
        XCTAssertEqual(light.movement?.repeatCount, .infinity)
        XCTAssertEqual(light.movingLayerCount, 1, "one animation for the ring and its four glows")
        // (An animation without a cap reads 0: at the display's rate.)
        XCTAssertEqual(light.movement?.preferredFrameRateRange.maximum, 15, "no more frames than the dots ever asked for")
        XCTAssertEqual(light.steadyLevel, 1, "the breath sets the level")

        light.show(.working, moving: false)
        XCTAssertFalse(light.isMoving, "stopped as soon as nobody can see it")
        XCTAssertEqual(light.movingLayerCount, 0)
        XCTAssertEqual(light.light, .working)
        XCTAssertEqual(light.steadyLevel, 0.6)
        light.show(.alert(.waiting), moving: false)
        XCTAssertEqual(light.steadyLevel, 1, "a wait shows in full")
        light.show(.working, moving: false)

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
        XCTAssertEqual(light.movingLayerCount, 1, "the new rhythm in the old one's place")
        XCTAssertEqual(pulse.preferredFrameRateRange.maximum, 15)

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
        XCTAssertTrue(TerminalConfigBuilder.enforced.contains("window-padding-x = \(padding)"))
        XCTAssertTrue(TerminalConfigBuilder.enforced.contains("window-padding-y = \(padding)"))
        XCTAssertTrue(
            TerminalConfigBuilder.enforced.contains("window-padding-balance = false"),
            "balanced, the padding would grow with what the grid leaves over"
        )
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
        glow.show(.alert(.waiting), moving: false, target: target("codex needs permission", column: UUID()))
        XCTAssertFalse(glow.isPillShown, "another agent's name doesn't ride on the first one's seconds")

        glow.show(nil, moving: false)
        XCTAssertFalse(glow.isPillShown)
        XCTAssertNil(glow.target)
        XCTAssertFalse(glow.isAccessibilityElement())
    }

    func testThePillLeavesByItselfAfterItsTime() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let glow = rightEdge(in: container)
        let clock = ManualSchedule()
        glow.schedule = clock.schedule
        glow.pillDuration = 4
        glow.show(.alert(.waiting), moving: false, target: target(), announcing: true)
        clock.advance(by: 3.9)
        XCTAssertTrue(glow.isPillShown)
        clock.advance(by: 0.2)
        XCTAssertFalse(glow.isPillShown)
        XCTAssertEqual(glow.light, .alert(.waiting))

        // Announced again before its time is up: the first one's end
        // doesn't cut the second short.
        glow.show(.alert(.waiting), moving: false, target: target(), announcing: true)
        clock.advance(by: 3)
        glow.show(.alert(.waiting), moving: false, target: target("claude has a question"), announcing: true)
        clock.advance(by: 1.5)
        XCTAssertTrue(glow.isPillShown)
        clock.advance(by: 3)
        XCTAssertFalse(glow.isPillShown)
    }

    /// The agent says something else while its pill is up (a message
    /// turns into a permission request, a verdict into a question): the
    /// pill stays, with the new words, for its full time again. Once its
    /// time is over, new words wait for the pointer.
    func testThePillFollowsItsAgentsNewWords() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let glow = rightEdge(in: container)
        let clock = ManualSchedule()
        glow.schedule = clock.schedule
        glow.pillDuration = 4
        let agent = UUID()
        glow.show(.alert(.waiting), moving: false, target: target("claude has a message", column: agent), announcing: true)
        clock.advance(by: 3)
        glow.show(.alert(.waiting), moving: false, target: target("claude needs permission", column: agent))
        XCTAssertTrue(glow.isPillShown, "no flash")
        XCTAssertEqual(glow.pillText, "claude needs permission →")
        clock.advance(by: 3.9)
        XCTAssertTrue(glow.isPillShown, "long enough to be read")
        clock.advance(by: 0.2)
        XCTAssertFalse(glow.isPillShown)

        glow.show(.alert(.waiting), moving: false, target: target("claude asks you something", column: agent))
        XCTAssertFalse(glow.isPillShown, "its seconds are over")
        XCTAssertEqual(glow.pillText, "claude asks you something →")
    }

    /// Only the key window's pointer is tracked. Elsewhere no exit would
    /// ever take away a pill the pointer kept: it would stay over the
    /// terminal's text and take the next click there.
    func testOnlyTheKeyWindowsPointerKeepsThePill() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let container = try XCTUnwrap(window.contentView)
        let glow = rightEdge(in: container)
        // The pointer lies where the pill comes up, and doesn't move.
        glow.pointerLocation = { [unowned glow] _ in
            glow.convert(NSPoint(x: glow.pillFrame.midX, y: glow.pillFrame.midY), to: nil)
        }
        let onPill = glow.convert(NSPoint(x: glow.pillFrame.midX, y: glow.pillFrame.midY), to: container)

        // Not the key window (a test's never is).
        glow.show(.alert(.waiting), moving: false, target: target(), announcing: true)
        glow.endAnnouncement()
        XCTAssertFalse(glow.isPillShown, "nothing would take it away later")
        XCTAssertNil(glow.hitTest(onPill))

        // The key window: the pointer keeps the pill…
        var isKey = true
        glow.tracksPointer = { _ in isKey }
        glow.show(nil, moving: false)
        glow.show(.alert(.waiting), moving: false, target: target(), announcing: true)
        glow.endAnnouncement()
        XCTAssertTrue(glow.isPillShown, "under the pointer")
        XCTAssertTrue(glow.hitTest(onPill) === glow)
        let other = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: false
        )
        other.isReleasedWhenClosed = false
        defer { other.close() }
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: other)
        XCTAssertTrue(glow.isPillShown, "another window's business")
        // …until its window stops being the key one.
        isKey = false
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        XCTAssertFalse(glow.isPillShown)
        XCTAssertNil(glow.hitTest(onPill), "the click goes to the terminal")

        // Its first seconds are its own, key window or not. (The pointer
        // rests on the glow: nothing but the window says it is gone.)
        glow.pointerLocation = { [unowned glow] _ in
            glow.convert(NSPoint(x: glow.hoverStrip.midX, y: glow.hoverStrip.midY), to: nil)
        }
        glow.show(nil, moving: false)
        glow.show(.alert(.waiting), moving: false, target: target(), announcing: true)
        glow.pointerEntered(.glow)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        XCTAssertTrue(glow.isPillShown, "still announcing")
        glow.endAnnouncement()
        XCTAssertFalse(glow.isPillShown, "the pointer that was on the glow counts no more")
    }

    /// The pointer resting on the glow brings the pill back, clear of the
    /// pointer and of the column headers, and the pill stays long enough
    /// to be reached, then while the pointer is on it.
    func testThePointerBringsThePillBackAndReachesIt() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1_000, height: 700))
        let frames: [(EdgeGlowView.Edge, NSRect)] = [
            (.left, NSRect(x: 0, y: 0, width: 320, height: 700)), (.right, NSRect(x: 680, y: 0, width: 320, height: 700)),
            (.top, NSRect(x: 0, y: 700 - EdgeGlowView.topHeight, width: 1_000, height: EdgeGlowView.topHeight)),
            (.bottom, NSRect(x: 0, y: 0, width: 1_000, height: 56))
        ]
        for (edge, frame) in frames {
            let glow = edgeGlow(edge, frame: frame, in: container)
            glow.hoverDwell = 0
            glow.pillLinger = 3_600
            XCTAssertEqual(glow.trackingAreas.count, 0, "\(edge)")
            glow.show(.alert(.waiting), moving: false, target: target())
            XCTAssertFalse(glow.isPillShown)
            XCTAssertEqual(glow.trackingAreas.count, 2, "\(edge): the glow and the pill")
            XCTAssertTrue(glow.bounds.contains(glow.pillFrame), "\(edge)")
            XCTAssertFalse(glow.hoverStrip.intersects(glow.pillFrame), "\(edge): never under the pointer that brings it")
            if edge == .top {
                XCTAssertLessThanOrEqual(
                    glow.pillFrame.maxY, glow.bounds.maxY - ColumnHeaderView.height, "under the headers' buttons"
                )
            }

            glow.pointerEntered(.glow)
            XCTAssertTrue(glow.isPillShown, "\(edge)")
            glow.pointerExited(.glow)
            XCTAssertTrue(glow.isPillShown, "\(edge): time to reach it")
            glow.pointerEntered(.pill)
            let onPill = glow.convert(NSPoint(x: glow.pillFrame.midX, y: glow.pillFrame.midY), to: container)
            XCTAssertTrue(glow.hitTest(onPill) === glow, "\(edge): it takes the click")
            glow.pointerExited(.pill)
            XCTAssertFalse(glow.isPillShown, "\(edge): the pointer left it")

            glow.pointerEntered(.pill)
            XCTAssertFalse(glow.isPillShown, "\(edge): where the pill was is no way back in")
            glow.pointerExited(.pill)

            glow.pillLinger = 0
            glow.pointerEntered(.glow)
            glow.pointerExited(.glow)
            XCTAssertFalse(glow.isPillShown, "\(edge): gone once its time is up")

            glow.show(nil, moving: false)
            XCTAssertEqual(glow.trackingAreas.count, 0, "\(edge)")
        }
    }

    /// A pointer that only crosses the edge, on its way from the sidebar
    /// or the title bar, brings nothing up; one that rests there does. A
    /// pointer that comes back keeps the pill its full time: the first
    /// departure's end doesn't cut it short.
    func testThePillComesForAPointerThatRestsAndStaysWhileItComesBack() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let glow = rightEdge(in: container)
        let clock = ManualSchedule()
        glow.schedule = clock.schedule
        glow.hoverDwell = 0.3
        glow.pillLinger = 1.2
        glow.show(.alert(.waiting), moving: false, target: target())

        glow.pointerEntered(.glow)
        clock.advance(by: 0.1)
        glow.pointerExited(.glow)
        clock.advance(by: 1)
        XCTAssertFalse(glow.isPillShown, "it only crossed")

        glow.pointerEntered(.glow)
        clock.advance(by: 0.29)
        XCTAssertFalse(glow.isPillShown)
        clock.advance(by: 0.02)
        XCTAssertTrue(glow.isPillShown, "it rests there")

        glow.pointerExited(.glow)
        clock.advance(by: 1)
        glow.pointerEntered(.glow)
        glow.pointerExited(.glow)
        clock.advance(by: 0.5)
        XCTAssertTrue(glow.isPillShown, "the first departure's time is up, not the second's")
        clock.advance(by: 1)
        XCTAssertFalse(glow.isPillShown)
    }

    /// During its first seconds the pointer leaving changes nothing, and
    /// the pointer staying keeps the pill past them.
    func testThePointerKeepsThePillPastItsFirstSeconds() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let glow = rightEdge(in: container)
        glow.hoverDwell = 0
        glow.pillLinger = 0
        glow.show(.alert(.error), moving: false, target: target("claude exited mid-turn"), announcing: true)
        glow.pointerEntered(.glow)
        glow.pointerExited(.glow)
        XCTAssertTrue(glow.isPillShown, "still announcing")
        glow.pointerEntered(.glow)
        glow.endAnnouncement()
        XCTAssertTrue(glow.isPillShown, "the pointer is on the glow")
        glow.pointerExited(.glow)
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

    /// The shell's observers go away with it.
    func testObserversLeaveWithTheirBag() {
        let center = NotificationCenter()
        let name = Notification.Name("AgentLightTests.ping")
        let heard = Count()
        var bag: ObserverBag? = ObserverBag()
        bag?.add(center.addObserver(forName: name, object: nil, queue: nil) { _ in heard.value += 1 }, on: center)
        center.post(name: name, object: nil)
        XCTAssertEqual(heard.value, 1)
        bag = nil
        center.post(name: name, object: nil)
        XCTAssertEqual(heard.value, 1)
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

    /// The header's working dot and the rail's badge breathe only while
    /// animations may run. (A row shows work as a line: SidebarRowMotionTests.)
    func testTheWorkingDotsFollowAnimates() {
        let pill = ColumnStatusPill(frame: NSRect(x: 0, y: 0, width: 120, height: ColumnStatusPill.height))
        pill.status = ColumnHeaderView.Status("working", tone: .working)
        XCTAssertTrue(pill.isBreathing)
        pill.animates = false
        XCTAssertFalse(pill.isBreathing)
        pill.animates = true
        XCTAssertTrue(pill.isBreathing)

        let row = workspace(0, "checkout", [column(0, status: .working)])
        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 260, height: 660))
        sidebar.update(profiles: [], workspaces: [row])
        XCTAssertEqual(sidebar.railTileViews.values.filter(\.style.breathes).count, 1)
        sidebar.animates = false
        XCTAssertEqual(sidebar.railTileViews.values.filter(\.style.breathes).count, 0)
        sidebar.animates = true
        XCTAssertEqual(sidebar.railTileViews.values.filter(\.style.breathes).count, 1)
    }
}

/// Counted from a notification block, which Swift takes for concurrent.
private final class Count: @unchecked Sendable {
    var value = 0
}

/// A classifier whose run never starts within a test: the test gives the
/// verdicts itself.
private final class UnreachedClassifier: TurnEndClassifier, @unchecked Sendable {
    func classify(_ message: String) async -> TurnEndVerdict { .unknown }
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

    /// The hook centre, wired to `shell` as the app wires the shared one,
    /// with the turn-end classifier on: a final message waits for its
    /// verdict, which the test gives.
    private func hookCenter(for shell: NiruxShellView) -> AgentHookCenter {
        let center = AgentHookCenter()
        center.turnEndClassifier = UnreachedClassifier()
        center.resolver = { [weak shell] uuid in shell?.resolveAgentColumn(uuid: uuid) }
        center.onTurnDone = { [weak shell] resolution, endedAt in
            shell?.agentTurnDone(in: resolution.column, endedAt: endedAt)
        }
        return center
    }

    /// A hook event as the centre routes it: its column takes it, then
    /// the centre settles the turn end it may be.
    @discardableResult
    private func hook(
        _ name: AgentHookEvent.Name, kind: AgentHookEvent.Kind = .claude, finalMessage: String? = nil,
        on column: ColumnState, of shell: NiruxShellView, through center: AgentHookCenter
    ) throws -> AgentHookOutcome {
        let uuid = try XCTUnwrap(column.agentUUID)
        let event = AgentHookEvent(
            kind: kind, name: name, agentUUID: uuid, finalMessage: finalMessage, timestamp: Date().timeIntervalSince1970
        )
        let outcome = try XCTUnwrap(column.pty).applyAgentHook(event, isUserFocused: false)
        let resolution = try XCTUnwrap(shell.resolveAgentColumn(uuid: uuid))
        center.settleTurnEnd(of: event, outcome: outcome, in: resolution, waitsOnParent: false)
        return outcome
    }

    /// Through the hook centre and the sidebar's own refresh: a prompt
    /// lights the column, and the turn's end sweeps it once, then nothing.
    func testAColumnLightsWhileItsAgentWorksAndSweepsAtItsTurnsEnd() throws {
        try withShell { shell, _, _ in
            let center = hookCenter(for: shell)
            shell.sidebar.isExpanded = true
            let column = try XCTUnwrap(shell.activeWorkspace?.columns.first)
            // A process table that can't be read leaves the agent as its
            // hooks say.
            let unread = ProcessSnapshot(entries: [])
            shell.updateSidebar(snapshot: unread)
            XCTAssertNil(column.light)

            try hook(.userPromptSubmit, on: column, of: shell, through: center)
            XCTAssertTrue(shell.agentLights.endedTurns.isEmpty, "a prompt ends nothing")
            shell.updateSidebar(snapshot: unread)
            let light = try XCTUnwrap(column.light)
            XCTAssertEqual(light.light, .working)
            XCTAssertTrue(light.isMoving)
            XCTAssertTrue(light.isSoft, "the focused column")
            XCTAssertFalse(light.isSweeping)

            XCTAssertTrue(shell.sidebar.turnEndNotedAt.isEmpty)
            try hook(.stop, on: column, of: shell, through: center)
            XCTAssertEqual(Array(shell.agentLights.endedTurns.keys), [column.id])
            shell.updateSidebar(snapshot: unread)
            XCTAssertNil(light.light, "then nothing")
            XCTAssertTrue(light.isSweeping)
            XCTAssertTrue(shell.agentLights.endedTurns.isEmpty, "once")
            let workspaceID = try XCTUnwrap(shell.activeWorkspace?.id)
            XCTAssertEqual(Array(shell.sidebar.turnEndNotedAt.keys), [workspaceID], "and its row draws its check")
            XCTAssertEqual(
                shell.sidebar.expandedViews.filter { $0.identifier == SidebarWorkspaceCardRenderer.turnEndCheckID }.count, 1
            )
        }
    }

    /// A turn's end draws its check on the row of the workspace it ended
    /// in, and on no other.
    func testATurnsEndShowsOnItsOwnWorkspacesRow() throws {
        try withShell { shell, _, folder in
            shell.sidebar.isExpanded = true
            let first = try XCTUnwrap(shell.activeWorkspace)
            shell.addWorkspace(title: "second", cwd: folder)
            let second = try XCTUnwrap(shell.activeWorkspace)
            let infos = [
                info(first, index: 0, in: shell, statuses: [.idle]), info(second, index: 1, in: shell, statuses: [.idle])
            ]
            shell.sidebar.update(profiles: [], workspaces: infos)
            shell.agentTurnDone(in: second.columns[0], endedAt: 1)
            shell.updateAgentLights(infos: infos)
            XCTAssertEqual(Array(shell.sidebar.turnEndNotedAt.keys), [second.id])
        }
    }

    /// A Claude turn end whose final message is being read sweeps once it
    /// is found done, without waiting for a heartbeat; one found to ask
    /// doesn't. Codex's report sweeps at once, whatever its output says
    /// of work meanwhile.
    func testAVerdictSettlesTheSweep() throws {
        try withShell { shell, _, _ in
            let center = hookCenter(for: shell)
            shell.sidebar.isExpanded = true
            let workspace = try XCTUnwrap(shell.activeWorkspace)
            let column = try XCTUnwrap(workspace.columns.first)
            let uuid = try XCTUnwrap(column.agentUUID)
            let unread = ProcessSnapshot(entries: [])
            shell.updateSidebar(snapshot: unread)
            try hook(.userPromptSubmit, on: column, of: shell, through: center)
            shell.updateSidebar(snapshot: unread)
            let light = try XCTUnwrap(column.light)

            let request = try XCTUnwrap(
                hook(.stop, finalMessage: "All done.", on: column, of: shell, through: center).turnEnd
            )
            XCTAssertTrue(shell.agentLights.endedTurns.isEmpty, "not before it is known to be done")
            shell.updateSidebar(snapshot: unread)
            XCTAssertNil(light.light)
            XCTAssertFalse(light.isSweeping)
            XCTAssertTrue(shell.sidebar.turnEndNotedAt.isEmpty, "nor a check on its row")

            center.applyTurnEndVerdict(.done, for: request, agentUUID: uuid)
            XCTAssertEqual(Array(shell.agentLights.endedTurns.keys), [column.id])
            XCTAssertFalse(shell.isMetadataRefreshScheduled)
            shell.turnEndSettled()
            XCTAssertTrue(shell.isMetadataRefreshScheduled, "a refresh of its own, not the next heartbeat's")
            // That refresh, without letting the run loop start the column's
            // shell under the test (a new shell resets its agent's state).
            shell.updateSidebar(snapshot: unread)
            XCTAssertTrue(light.isSweeping)

            // The next turn asks. (Never the notification center: it
            // aborts a test run.)
            column.onAgentAttention = { _ in }
            try hook(.userPromptSubmit, on: column, of: shell, through: center)
            let asking = try XCTUnwrap(
                hook(.stop, finalMessage: "Let me know.", on: column, of: shell, through: center).turnEnd
            )
            center.applyTurnEndVerdict(.asks, for: asking, agentUUID: uuid)
            XCTAssertTrue(shell.agentLights.endedTurns.isEmpty, "amber, no sweep")

            workspace.addColumn()
            let codex = try XCTUnwrap(workspace.columns.last)
            workspace.focusedIndex = 1
            shell.relayout(animated: false)
            try hook(.turnComplete, kind: .codex, on: codex, of: shell, through: center)
            XCTAssertEqual(Array(shell.agentLights.endedTurns.keys), [codex.id])
            // Its closing output reads as work until it falls silent.
            shell.updateAgentLights(infos: [info(workspace, index: 0, in: shell, statuses: [.idle, .working])])
            XCTAssertEqual(codex.light?.isSweeping, true)
        }
    }

    /// A prompt, or a tool call, that came with the Stop in the same batch
    /// of hook events: the agent works again, and nothing sweeps "done".
    func testATurnEndLeftBehindSweepsNothing() throws {
        try withShell { shell, _, _ in
            let center = hookCenter(for: shell)
            let column = try XCTUnwrap(shell.activeWorkspace?.columns.first)
            let unread = ProcessSnapshot(entries: [])
            try hook(.userPromptSubmit, on: column, of: shell, through: center)
            shell.updateSidebar(snapshot: unread)
            let light = try XCTUnwrap(column.light)

            try hook(.stop, on: column, of: shell, through: center)
            XCTAssertEqual(Array(shell.agentLights.endedTurns.keys), [column.id])
            try hook(.userPromptSubmit, on: column, of: shell, through: center)
            shell.updateSidebar(snapshot: unread)
            XCTAssertEqual(light.light, .working)
            XCTAssertFalse(light.isSweeping)
            XCTAssertTrue(shell.agentLights.endedTurns.isEmpty)
        }
    }

    func testNoSweepWhileMotionIsReduced() throws {
        try withShell(reducesMotion: true) { shell, _, _ in
            let center = hookCenter(for: shell)
            shell.sidebar.isExpanded = true
            let column = try XCTUnwrap(shell.activeWorkspace?.columns.first)
            let unread = ProcessSnapshot(entries: [])
            shell.updateSidebar(snapshot: unread)
            try hook(.userPromptSubmit, on: column, of: shell, through: center)
            shell.updateSidebar(snapshot: unread)
            let light = try XCTUnwrap(column.light)
            XCTAssertEqual(light.light, .working)
            XCTAssertFalse(light.isMoving, "steady")

            try hook(.stop, on: column, of: shell, through: center)
            XCTAssertEqual(Array(shell.agentLights.endedTurns.keys), [column.id])
            shell.updateSidebar(snapshot: unread)
            XCTAssertNil(light.light)
            XCTAssertFalse(light.isSweeping)
            XCTAssertTrue(shell.sidebar.turnEndNotedAt.isEmpty, "nor a check on its row")
        }
    }

    /// A sweep says the turn just ended: one that can't play now (its
    /// column is out of view) never plays later.
    func testASweepOutOfViewIsNotKeptForLater() throws {
        try withShell { shell, _, _ in
            let workspace = try fourColumns(in: shell)
            let idle = Array(repeating: AgentStatus.idle, count: 4)
            shell.agentTurnDone(in: workspace.columns[3], endedAt: 1)
            shell.updateAgentLights(infos: [info(workspace, index: 0, in: shell, statuses: idle)])
            XCTAssertTrue(shell.agentLights.endedTurns.isEmpty)
            XCTAssertNotEqual(workspace.columns[3].light?.isSweeping, true)

            workspace.focusedIndex = 3
            shell.relayout(animated: false)
            shell.updateAgentLights(infos: [info(workspace, index: 0, in: shell, statuses: idle)])
            XCTAssertNotEqual(workspace.columns[3].light?.isSweeping, true, "old news")
        }
    }

    /// One definition of "in view" (`WorkspaceState.showsColumn(at:)`): a
    /// column that shows only a sliver is out of view for the edge that
    /// names it and for its own light alike, which doesn't pulse there.
    func testASliverOfAColumnIsOutOfView() throws {
        try withShell { shell, _, _ in
            let workspace = try fourColumns(in: shell)
            for (column, fraction) in zip(workspace.columns, [0.48, 0.48, 0.4, 0.4]) { column.widthFraction = fraction }
            shell.relayout(animated: false)
            let viewport = workspace.containerView.frame.width
            let sliver = viewport - workspace.columns[2].view.frame.minX
            XCTAssertGreaterThan(sliver, 0, "it shows")
            XCTAssertLessThan(sliver, NiruxShellView.minimumShownColumnWidth, "but only a sliver")
            XCTAssertTrue(workspace.showsColumn(at: 1))
            XCTAssertFalse(workspace.showsColumn(at: 2))
            XCTAssertFalse(workspace.showsColumn(at: 9))

            shell.updateAgentLights(infos: [info(
                workspace, index: 0, in: shell, statuses: [.idle, .needsAttention, .needsAttention, .idle],
                reasons: [1: permission, 2: permission]
            )])
            XCTAssertEqual(shell.edgeGlowRight.target?.columnID, workspace.columns[2].id, "the edge names it")
            XCTAssertEqual(workspace.columns[2].light?.light, .alert(.waiting))
            XCTAssertEqual(workspace.columns[2].light?.isMoving, false, "its own light doesn't pulse on top")
            XCTAssertEqual(workspace.columns[1].light?.isMoving, true)
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
            XCTAssertEqual(shell.agentLights.announced, [workspace.columns[3].id])
            shell.updateAgentLights(infos: [self.info(
                workspace, index: 0, in: shell, statuses: [.working, .needsAttention, .idle, .needsAttention],
                reasons: [1: permission, 3: .question("Which one?")]
            )])
            XCTAssertEqual(glow.pillText, "claude has a question →")
            XCTAssertFalse(glow.isPillShown, "the same column's wait, under another name")
            // Another space on screen lists none of these columns: the
            // wait is remembered for the way back.
            shell.updateAgentLights(infos: [])
            XCTAssertEqual(shell.agentLights.announced, [workspace.columns[3].id])
            refresh(true)
            XCTAssertFalse(glow.isPillShown)

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

            // Its turn ending meanwhile sweeps nothing: the column is leaving.
            let neighbour = try XCTUnwrap(workspace.columns[1].light)
            shell.agentTurnDone(in: workspace.columns[0], endedAt: 1)
            shell.agentTurnDone(in: workspace.columns[1], endedAt: 1)
            shell.updateAgentLights(infos: [info(
                workspace, index: 0, in: shell, statuses: [.idle, .idle, .working, .working]
            )])
            XCTAssertFalse(light.isSweeping)
            XCTAssertTrue(neighbour.isSweeping)

            workspace.closeColumn(at: 0)
            XCTAssertNil(light.superview)
        }
    }

    /// A close that doesn't happen after all (the column's sibling went
    /// first, and a workspace keeps its last column) gives the column its
    /// light back at once.
    func testAColumnThatStaysAfterAllGetsItsLightBack() throws {
        try withShell { shell, _, _ in
            let workspace = try XCTUnwrap(shell.activeWorkspace)
            workspace.addColumn()
            workspace.focusedIndex = 0
            shell.relayout(animated: false)
            shell.updateAgentLights(infos: [info(workspace, index: 0, in: shell, statuses: [.working, .working])])
            let column = workspace.columns[0]
            let light = try XCTUnwrap(column.light)
            shell.closeActiveColumn()
            XCTAssertTrue(column.isClosing)
            XCTAssertNil(light.light)
            column.view.alphaValue = 0

            // Its sibling goes during the exit animation, whose end finds
            // nothing left to remove.
            workspace.closeColumn(at: 1)
            shell.finishColumnClose(column, in: workspace)
            XCTAssertEqual(workspace.columns.count, 1)
            XCTAssertFalse(column.isClosing)
            XCTAssertEqual(column.view.alphaValue, 1)
            XCTAssertEqual(light.light, .working, "not at the next refresh")
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
