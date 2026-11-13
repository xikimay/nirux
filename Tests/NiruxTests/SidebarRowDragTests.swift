import AppKit
import XCTest
@testable import Nirux

/// A press on a task's row is tracked until its mouse-up, and the sidebar
/// puts its updates and rebuilds aside meanwhile: the gesture has to end,
/// in the order its events came, and what was put aside has to come back.
///
/// Every gesture here is made of events posted before the press: they are
/// read in order, with no wait on a clock (the sidebar's stands still, as
/// in the other sidebar tests). Events posted to the app move no button:
/// the tests say whether it holds (`rowPressHolds`).
@MainActor
final class SidebarRowDragTests: XCTestCase {
    private func row(_ id: String, index: Int, pr: PRInfo? = nil, active: Bool = false, isLead: Bool = false) -> WorkspaceInfo {
        WorkspaceInfo(
            id: id, index: index, title: id, profileID: WorkspaceProfile.defaultID, isInactive: false, columnCount: 0,
            focusedColumn: 0, gitBranch: "feat/\(id)", notification: nil, isActive: active, columns: [], prInfo: pr,
            diffStats: nil, purpose: nil, nextStep: nil, blocker: nil, phase: .active, lastSummary: nil, lastActivityAt: nil,
            isLead: isLead
        )
    }

    /// An expanded sidebar in a window that is never shown, on a clock
    /// that stands still.
    private func sidebar(_ rows: [WorkspaceInfo]) -> (SidebarView, NSWindow) {
        // What an earlier test left in the queue isn't this one's.
        NSApplication.shared.discardEvents(matching: .any, before: nil)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 660))
        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 260, height: 660))
        sidebar.clock = { 3_000 }
        host.addSubview(sidebar)
        let window = NSWindow(contentRect: host.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        sidebar.isExpanded = true
        sidebar.update(profiles: [], workspaces: rows)
        host.layoutSubtreeIfNeeded()
        return (sidebar, window)
    }

    /// The tasks whose rows are drawn, top to bottom.
    private func rowsDrawn(_ sidebar: SidebarView) -> [String] {
        sidebar.hitAreas.compactMap { area -> (id: String, top: CGFloat)? in
            guard case .workspace(let index) = area.region, let info = sidebar.lastInfos.first(where: { $0.index == index })
            else { return nil }
            return (info.id, area.frame.maxY)
        }.sorted { $0.top > $1.top }.map(\.id)
    }

    private func frame(ofRow index: Int, in sidebar: SidebarView) throws -> NSRect {
        try XCTUnwrap(sidebar.hitAreas.first { if case .workspace(index) = $0.region { true } else { false } }?.frame)
    }

    private func mouse(_ type: NSEvent.EventType, at point: NSPoint, in sidebar: SidebarView, window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: sidebar.contentDocumentView.convert(point, to: nil), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1
        ))
    }

    private func post(_ type: NSEvent.EventType, at point: NSPoint, in sidebar: SidebarView, window: NSWindow) {
        guard let event = try? mouse(type, at: point, in: sidebar, window: window) else { return XCTFail("no mouse event") }
        NSApp.postEvent(event, atStart: false)
    }

    /// Ticks of the drag's own, queued where they are posted.
    private func postTicks(_ count: Int) {
        for _ in 0..<count {
            guard let tick = NSEvent.otherEvent(
                with: .periodic, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0
            ) else { return XCTFail("no periodic event") }
            NSApp.postEvent(tick, atStart: false)
        }
    }

    /// The presses and mouse-ups still waiting in the queue, in order.
    private func queuedClicks() -> [NSEvent.EventType] {
        var types: [NSEvent.EventType] = []
        while let event = NSApp.nextEvent(
            matching: [.leftMouseDown, .leftMouseUp], until: .distantPast, inMode: .default, dequeue: true
        ) { types.append(event.type) }
        return types
    }

    /// The button reads up (or down, with `holds`). `found` runs at the
    /// look of that number, before its answer.
    @discardableResult
    private func button(of sidebar: SidebarView, holds: Bool = false, found: [Int: @MainActor () -> Void] = [:]) -> Press {
        let press = Press(holds: holds, found: found)
        sidebar.rowPressHolds = { _ in press.look() }
        return press
    }

    /// What ended a stuck gesture before: the next click's mouse-up, long
    /// after, here at `point`. What it returns says whether that was needed.
    private func laterMouseUp(at point: NSPoint, in sidebar: SidebarView, window: NSWindow) -> LaterMouseUp {
        let later = LaterMouseUp()
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self, weak sidebar, weak window] in
            guard let self, let sidebar, let window, sidebar.workspaceDrag != nil else { return }
            later.wasNeeded = true
            self.post(.leftMouseUp, at: point, in: sidebar, window: window)
        }
        return later
    }

    // MARK: - A drag that loses its mouse-up

    /// A row dragged past the click threshold whose mouse-up never comes
    /// (a modal or another app took it) ends by itself once as many of
    /// its ticks as make the wait found the button up, not before: the
    /// list that changed meanwhile shows, and nothing is clicked or moved.
    func testADragThatLosesItsMouseUpEndsByItself() throws {
        let (sidebar, window) = sidebar([row("a", index: 0, active: true), row("b", index: 1), row("c", index: 2)])
        defer { window.close() }
        var clicked: [Int] = []
        var moved: [[Int]] = []
        sidebar.onWorkspaceClicked = { clicked.append($0) }
        sidebar.onWorkspaceReordered = { moved.append([$0, $1]) }
        let waited = Waited()
        // A task leaves while the row is held.
        let press = button(of: sidebar, found: [1: { [weak sidebar] in
            guard let sidebar else { return }
            sidebar.update(profiles: [], workspaces: Array(sidebar.lastInfos.dropLast()))
            waited.update = sidebar.deferredDragUpdate != nil
        }])

        let start = try frame(ofRow: 1, in: sidebar).center
        post(.leftMouseDragged, at: NSPoint(x: start.x, y: start.y - 10), in: sidebar, window: window)
        postTicks(SidebarView.lostPressTicks)
        let later = laterMouseUp(at: start, in: sidebar, window: window)
        sidebar.mouseDown(with: try mouse(.leftMouseDown, at: start, in: sidebar, window: window))

        XCTAssertFalse(later.wasNeeded, "the drag held the sidebar until another mouse-up")
        XCTAssertEqual(press.looks, SidebarView.lostPressTicks, "lost once the wait is over, not before")
        XCTAssertNil(sidebar.workspaceDrag)
        XCTAssertNil(sidebar.dragGhostView, "its ghost goes with it")
        XCTAssertTrue(waited.update, "the update was put aside")
        XCTAssertEqual(sidebar.lastInfos.map(\.id), ["a", "b"], "and is applied")
        XCTAssertEqual(rowsDrawn(sidebar), ["a", "b"])
        XCTAssertEqual(clicked, [], "a gesture that was lost clicks nothing")
        XCTAssertEqual(moved, [], "and moves nothing")
    }

    /// The button can read up before its mouse-up is handed over, and the
    /// app can be busy meanwhile: the mouse-up still comes in its turn,
    /// after the drags queued before it, and drops the row where the last
    /// of them left it.
    func testAMouseUpBehindWhatIsQueuedDropsTheRowWhereItWasDragged() throws {
        let (sidebar, window) = sidebar([row("a", index: 0, active: true), row("b", index: 1), row("c", index: 2)])
        defer { window.close() }
        var moved: [[Int]] = []
        sidebar.onWorkspaceReordered = { moved.append([$0, $1]) }
        button(of: sidebar)

        let start = try frame(ofRow: 0, in: sidebar).center
        let underAll = NSPoint(x: start.x, y: try frame(ofRow: 2, in: sidebar).minY + 2)
        let underTheSecond = NSPoint(x: start.x, y: try frame(ofRow: 1, in: sidebar).minY + 2)
        post(.leftMouseDragged, at: NSPoint(x: start.x, y: start.y - 10), in: sidebar, window: window)
        post(.leftMouseDragged, at: underAll, in: sidebar, window: window)
        // The whole wait in ticks, then a last drag back up a row and the mouse-up.
        postTicks(SidebarView.lostPressTicks)
        post(.leftMouseDragged, at: underTheSecond, in: sidebar, window: window)
        post(.leftMouseUp, at: underTheSecond, in: sidebar, window: window)
        let later = laterMouseUp(at: underAll, in: sidebar, window: window)
        sidebar.mouseDown(with: try mouse(.leftMouseDown, at: start, in: sidebar, window: window))

        XCTAssertFalse(later.wasNeeded)
        XCTAssertNil(sidebar.workspaceDrag)
        XCTAssertEqual(moved, [[0, 1]], "under the second row, where the last drag left it")
    }

    /// Events posted to the app move no button: a drag whose button reads
    /// up all along isn't taken for lost while it keeps moving.
    func testADragThatKeepsMovingIsNotLost() throws {
        let (sidebar, window) = sidebar([row("a", index: 0, active: true), row("b", index: 1), row("c", index: 2)])
        defer { window.close() }
        var moved: [[Int]] = []
        sidebar.onWorkspaceReordered = { moved.append([$0, $1]) }

        let start = try frame(ofRow: 0, in: sidebar).center
        let underAll = NSPoint(x: start.x, y: try frame(ofRow: 2, in: sidebar).minY + 2)
        let almost = SidebarView.lostPressTicks - 1
        // Almost the wait, a move, almost the wait again: at its last tick, the drop.
        button(of: sidebar, found: [2 * almost: { [weak self, weak sidebar, weak window] in
            guard let self, let sidebar, let window else { return }
            self.post(.leftMouseDragged, at: underAll, in: sidebar, window: window)
            self.post(.leftMouseUp, at: underAll, in: sidebar, window: window)
        }])
        post(.leftMouseDragged, at: NSPoint(x: start.x, y: start.y - 10), in: sidebar, window: window)
        postTicks(almost)
        post(.leftMouseDragged, at: NSPoint(x: start.x, y: start.y - 20), in: sidebar, window: window)
        postTicks(almost)
        let later = laterMouseUp(at: underAll, in: sidebar, window: window)
        sidebar.mouseDown(with: try mouse(.leftMouseDown, at: start, in: sidebar, window: window))

        XCTAssertFalse(later.wasNeeded)
        XCTAssertNil(sidebar.workspaceDrag)
        XCTAssertEqual(moved, [[0, 2]])
    }

    // MARK: - A press made since

    /// A click made after a drag lost its mouse-up is its own: its
    /// mouse-up neither drops nor clicks the row first pressed, and stays
    /// behind its press for whoever that press goes to.
    func testALaterClickIsNotTheLostDragsDrop() throws {
        let (sidebar, window) = sidebar([row("a", index: 0, active: true), row("b", index: 1), row("c", index: 2)])
        defer { window.close() }
        var clicked: [Int] = []
        var moved: [[Int]] = []
        sidebar.onWorkspaceClicked = { clicked.append($0) }
        sidebar.onWorkspaceReordered = { moved.append([$0, $1]) }
        // That click's press makes the button read down again.
        button(of: sidebar, holds: true)

        let start = try frame(ofRow: 1, in: sidebar).center
        let elsewhere = NSPoint(x: start.x, y: 30)
        post(.leftMouseDragged, at: NSPoint(x: start.x, y: start.y - 10), in: sidebar, window: window)
        post(.leftMouseDown, at: elsewhere, in: sidebar, window: window)
        post(.leftMouseUp, at: elsewhere, in: sidebar, window: window)
        sidebar.mouseDown(with: try mouse(.leftMouseDown, at: start, in: sidebar, window: window))

        XCTAssertNil(sidebar.workspaceDrag)
        XCTAssertEqual(clicked, [])
        XCTAssertEqual(moved, [])
        XCTAssertEqual(queuedClicks(), [.leftMouseDown, .leftMouseUp], "the click is whole, in its order")
    }

    /// A press made since, still held: the lost gesture ends at its next
    /// tick, without waiting, and the press goes on to whoever it is for.
    func testAPressMadeSinceEndsTheLostDragAtOnce() throws {
        let (sidebar, window) = sidebar([row("a", index: 0, active: true), row("b", index: 1), row("c", index: 2)])
        defer { window.close() }
        let press = button(of: sidebar, holds: true)

        let start = try frame(ofRow: 1, in: sidebar).center
        post(.leftMouseDragged, at: NSPoint(x: start.x, y: start.y - 10), in: sidebar, window: window)
        post(.leftMouseDown, at: NSPoint(x: start.x, y: 30), in: sidebar, window: window)
        postTicks(1)
        let later = laterMouseUp(at: start, in: sidebar, window: window)
        sidebar.mouseDown(with: try mouse(.leftMouseDown, at: start, in: sidebar, window: window))

        XCTAssertFalse(later.wasNeeded, "the drag waited for the new press's mouse-up")
        XCTAssertEqual(press.looks, 0, "the press queued says it all")
        XCTAssertNil(sidebar.workspaceDrag)
        XCTAssertEqual(queuedClicks(), [.leftMouseDown])
    }

    /// A quick double click, the app busy: the first click's mouse-up is
    /// queued before the second press, and is still the first click's,
    /// at a tick as when it is taken.
    func testAMouseUpQueuedBeforeALaterPressIsItsOwn() throws {
        let (sidebar, window) = sidebar([row("a", index: 0, active: true), row("b", index: 1), row("c", index: 2)])
        defer { window.close() }
        var clicked: [Int] = []
        sidebar.onWorkspaceClicked = { clicked.append($0) }
        button(of: sidebar, holds: true)

        let start = try frame(ofRow: 1, in: sidebar).center
        let press = try mouse(.leftMouseDown, at: start, in: sidebar, window: window)
        postTicks(1)
        post(.leftMouseUp, at: start, in: sidebar, window: window)
        post(.leftMouseDown, at: start, in: sidebar, window: window)
        post(.leftMouseUp, at: start, in: sidebar, window: window)
        sidebar.mouseDown(with: press)

        XCTAssertEqual(clicked, [1])
        XCTAssertEqual(queuedClicks(), [.leftMouseDown, .leftMouseUp])
    }

    // MARK: - A row that doesn't drag

    /// The Lead's row doesn't drag: its press is a click, when its
    /// mouse-up comes. Lost, it clicks nothing.
    func testALostPressOnARowThatDoesNotDragClicksNothing() throws {
        let (sidebar, window) = sidebar([row("lead", index: 0, isLead: true), row("a", index: 1, active: true)])
        defer { window.close() }
        var clicked: [Int] = []
        sidebar.onWorkspaceClicked = { clicked.append($0) }
        button(of: sidebar)
        let start = try frame(ofRow: 0, in: sidebar).center

        // No mouse-up, the button up: nothing comes for the wait.
        sidebar.mouseDown(with: try mouse(.leftMouseDown, at: start, in: sidebar, window: window))
        XCTAssertEqual(clicked, [], "a press that was lost clicks nothing")

        post(.leftMouseUp, at: start, in: sidebar, window: window)
        sidebar.mouseDown(with: try mouse(.leftMouseDown, at: start, in: sidebar, window: window))
        XCTAssertEqual(clicked, [0], "its mouse-up makes it a click")

        // Lost, and a click made since: that click's mouse-up isn't this
        // press's.
        let elsewhere = NSPoint(x: start.x, y: 30)
        post(.leftMouseDown, at: elsewhere, in: sidebar, window: window)
        post(.leftMouseUp, at: elsewhere, in: sidebar, window: window)
        sidebar.mouseDown(with: try mouse(.leftMouseDown, at: start, in: sidebar, window: window))
        XCTAssertEqual(clicked, [0], "a later click clicks nothing here")
        XCTAssertEqual(queuedClicks(), [.leftMouseDown, .leftMouseUp], "and is whole, in its order")
    }

    // MARK: - What was put aside

    /// Rows that may no longer move mid-drag (the window got covered) are
    /// rebuilt still when the drag ends, even when the refresh put aside
    /// meanwhile brings the same rows; and nothing stays owed.
    func testARebuildSkippedDuringADragIsMadeAtItsEnd() throws {
        let checksRunning = PRInfo(
            number: 39, state: "OPEN", isDraft: false, ciStatus: "PENDING", checks: [], reviewDecision: nil, mergeable: nil,
            url: "https://example.test/pull/39", additions: nil, deletions: nil, changedFiles: nil
        )
        let (sidebar, window) = sidebar([row("a", index: 0, active: true), row("pr", index: 1, pr: checksRunning)])
        defer { window.close() }
        button(of: sidebar, holds: true)
        let ring = { () -> CAShapeLayer? in
            sidebar.expandedViews.first { $0.identifier == SidebarWorkspaceCardRenderer.checksRingID }?
                .layer?.sublayers?.first as? CAShapeLayer
        }
        XCTAssertNotNil(try XCTUnwrap(ring()).animation(forKey: SidebarWorkspaceCardRenderer.checksRingKey), "the ring turns")

        let start = try frame(ofRow: 0, in: sidebar).center
        let waited = Waited()
        DispatchQueue.main.async { [weak self, weak sidebar, weak window] in
            guard let self, let sidebar, let window else { return }
            sidebar.animates = false
            sidebar.update(profiles: [], workspaces: sidebar.lastInfos)
            waited.rebuild = sidebar.rebuildSkippedDuringDrag
            waited.update = sidebar.deferredDragUpdate != nil
            self.post(.leftMouseUp, at: start, in: sidebar, window: window)
        }
        sidebar.mouseDown(with: try mouse(.leftMouseDown, at: start, in: sidebar, window: window))

        XCTAssertEqual([waited.rebuild, waited.update], [true, true], "the press was tracked: both waited for its end")
        XCTAssertNil(sidebar.workspaceDrag)
        let still = try XCTUnwrap(ring())
        XCTAssertNil(still.animationKeys(), "the rows were rebuilt for what may move now")
        XCTAssertNotNil(still.lineDashPattern)
        XCTAssertFalse(sidebar.rebuildSkippedDuringDrag, "the rebuild was made: the next press owes none")
    }
}

/// The button as the gesture finds it: how many times it looked, and what
/// happens at a look of a given number, before its answer.
@MainActor
private final class Press {
    private let holds: Bool
    private var found: [Int: @MainActor () -> Void]
    private(set) var looks = 0

    init(holds: Bool, found: [Int: @MainActor () -> Void]) {
        self.holds = holds
        self.found = found
    }

    func look() -> Bool {
        looks += 1
        found.removeValue(forKey: looks)?()
        return holds
    }
}

@MainActor
private final class LaterMouseUp {
    var wasNeeded = false
}

/// What waited for a tracked press to end.
@MainActor
private final class Waited {
    var rebuild = false
    var update = false
}

private extension NSRect {
    var center: NSPoint { NSPoint(x: midX, y: midY) }
}
